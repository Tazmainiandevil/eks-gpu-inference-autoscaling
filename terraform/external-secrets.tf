data "aws_caller_identity" "current" {}

# ── IAM role for External Secrets Operator ────────────────────────────────────
# Follows the same Pod Identity pattern as Karpenter and the EBS CSI driver.
# ESO's service account (external-secrets/external-secrets) is bound to this role
# so it can call secretsmanager:GetSecretValue without any in-cluster credentials.

resource "aws_iam_role" "external_secrets" {
  name               = "${var.cluster_name}-external-secrets-role"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_assume_role.json
}

data "aws_iam_policy_document" "external_secrets_assume_role" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid = "SecretsManagerRead"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    # Scoped to secrets prefixed with the cluster name — one cluster cannot
    # read secrets belonging to another cluster in the same account.
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.cluster_name}/*"
    ]
  }
}

resource "aws_iam_policy" "external_secrets" {
  name        = "${var.cluster_name}-external-secrets-policy"
  description = "Allow External Secrets Operator to read cluster-scoped Secrets Manager secrets"
  policy      = data.aws_iam_policy_document.external_secrets.json
}

resource "aws_iam_role_policy_attachment" "external_secrets" {
  role       = aws_iam_role.external_secrets.name
  policy_arn = aws_iam_policy.external_secrets.arn
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
}

# ── Secrets Manager VPC endpoint ──────────────────────────────────────────────
# ESO polls Secrets Manager on every refreshInterval tick. Without this endpoint,
# each poll traverses the NAT Gateway ($0.045/GB + $0.045/hr). The Interface
# endpoint keeps traffic on the AWS backbone and routes through the existing
# vpc_endpoints security group (port 443 from VPC CIDR already allowed).

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  tags = { Name = "${var.cluster_name}-secretsmanager" }
}
