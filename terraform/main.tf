data "aws_availability_zones" "available" {}

provider "aws" {
  region = var.aws_region
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnets)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnets[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name                                            = "${var.cluster_name}-private-${count.index + 1}"
    "karpenter.sh/discovery"                        = var.cluster_name
    "kubernetes.io/cluster/${var.cluster_name}"     = "shared"
    "kubernetes.io/role/internal-elb"               = "1"
  }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnets)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name                                        = "${var.cluster_name}-public-${count.index + 1}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.igw]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Security group for Interface VPC endpoints — allows HTTPS from within the VPC only.
resource "aws_security_group" "vpc_endpoints" {
  name   = "${var.cluster_name}-vpc-endpoints"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${var.cluster_name}-vpc-endpoints"
  }
}

# ECR API endpoint — authenticates pulls without going via NAT Gateway.
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  tags = { Name = "${var.cluster_name}-ecr-api" }
}

# ECR DKR endpoint — transfers image layer manifests without going via NAT Gateway.
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  tags = { Name = "${var.cluster_name}-ecr-dkr" }
}

# S3 Gateway endpoint — ECR stores image layers in S3 internally.
# Gateway endpoints are free and route S3 traffic over the AWS backbone.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags = { Name = "${var.cluster_name}-s3" }
}

# STS Interface endpoint — required for EKS Pod Identity credential resolution.
# Without this, sts:AssumeRoleWithWebIdentity calls from Karpenter and EBS CSI
# traverse the NAT Gateway, adding latency and cost on every pod startup.
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  tags = { Name = "${var.cluster_name}-sts" }
}

module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "21.15.1"

  name               = var.cluster_name
  kubernetes_version = var.k8s_version
  vpc_id             = aws_vpc.main.id
  subnet_ids         = aws_subnet.private[*].id
  endpoint_public_access  = var.endpoint_public_access
  endpoint_private_access = true

  # Grant the IAM identity that runs Terraform full cluster-admin access.
  # This creates an EKS Access Entry for the caller so kubectl works immediately
  # after apply without a separate aws eks create-access-entry step.
  enable_cluster_creator_admin_permissions = true

  addons = {
    vpc-cni = {
      most_recent    = true
      before_compute = true   # must be active before any nodes join the cluster
      # Enable prefix delegation so each node supports ~110 pods instead of the
      # default 17 (t3.medium) / 35 (t3.large) imposed by the ENI IP limit.
      # Without this, a full platform stack (ArgoCD + Knative + Dragonfly +
      # Kyverno + OpenCost + inference) exhausts the per-node pod limit on t3.medium.
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    coredns = {
      most_recent = true
      # Tolerate the system taint so CoreDNS schedules on system nodes.
      # Without this, CoreDNS stays Pending until the app node group is ready,
      # but the app node group is outside module.eks and won't be created until
      # module.eks completes — a deadlock. CoreDNS is a platform component and
      # belongs on system nodes anyway.
      configuration_values = jsonencode({
        tolerations = [{
          key      = "system"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }]
      })
    }
    kube-proxy = {
      most_recent = true
      # kube-proxy is a DaemonSet with built-in tolerations for all taints — no change needed.
    }
    aws-ebs-csi-driver = {
      most_recent = true
      # IAM handled via Pod Identity association below — no service_account_role_arn needed.
      # Tolerate system taint so the CSI controller schedules on system nodes (same deadlock
      # risk as CoreDNS — controller is a Deployment that needs a schedulable node).
      configuration_values = jsonencode({
        controller = {
          tolerations = [{
            key      = "system"
            operator = "Equal"
            value    = "true"
            effect   = "NoSchedule"
          }]
        }
      })
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    system = {
      # System pods: karpenter, keda, prometheus, kyverno, monitoring
      desired_size   = var.system_node_group.desired_capacity
      min_size       = var.system_node_group.min_capacity
      max_size       = var.system_node_group.max_capacity
      instance_types = var.system_node_group.instance_types
      capacity_type  = var.system_node_group.capacity_type

      node_repair_config = {
        enabled = true
      }

      taints = {
        system = {
          key    = "system"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      # Kubernetes node labels — used by nodeAffinity in platform workloads.
      # (tags are EC2/AWS tags; labels are what pods can target with affinity rules)
      labels = {
        role          = "system"
        node-type     = "system"
      }

      tags = {
        role             = "system"
        NodeGroupType    = "system"
      }
    }
  }

  tags = {
    Name = var.cluster_name
  }
}


resource "aws_iam_role" "karpenter" {
  name               = "${var.cluster_name}-karpenter-role"
  assume_role_policy = data.aws_iam_policy_document.karpenter_assume_role.json
}

resource "aws_iam_policy" "karpenter" {
  name        = "${var.cluster_name}-karpenter-policy"
  description = "Karpenter IAM policy"
  policy      = templatefile("${path.module}/policies/karpenter-policy.json", {
    ClusterName = var.cluster_name
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_attach" {
  role       = aws_iam_role.karpenter.name
  policy_arn = aws_iam_policy.karpenter.arn
}

data "aws_iam_policy_document" "karpenter_assume_role" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = module.eks.cluster_name
  namespace       = "karpenter"
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter.arn
}


resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json
}

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role" "gpu_node" {
  name = "${var.cluster_name}-gpu-node-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "gpu_node_EKS_Worker" {
  role       = aws_iam_role.gpu_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "gpu_node_EKS_CNI" {
  role       = aws_iam_role.gpu_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "gpu_node_ECR_ReadOnly" {
  role       = aws_iam_role.gpu_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# EC2 Spot service-linked role — required for Karpenter to launch spot instances.
# Only one can exist per account; `aws_iam_service_linked_role` is a no-op if it already exists.
resource "aws_iam_service_linked_role" "spot" {
  aws_service_name = "spot.amazonaws.com"
  # Ignore errors if the role already exists in this account
  lifecycle {
    ignore_changes = [aws_service_name]
  }
}

# SQS queue for Karpenter spot interruption handling.
# Karpenter drains the node gracefully when EC2 sends a 2-minute warning.
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-spot-interruption"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = {
    Name        = "${var.cluster_name}-spot-interruption"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.karpenter_interruption.arn
    }]
  })
}

# Karpenter requires four EventBridge rules to handle the full node lifecycle.
# All four route to the same SQS queue; Karpenter distinguishes event type internally.

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${var.cluster_name}-spot-interruption"
  description = "EC2 Spot 2-minute termination warning"
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "spot_rebalance" {
  name        = "${var.cluster_name}-spot-rebalance"
  description = "EC2 Spot rebalance recommendation — proactive drain before interruption"
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Instance Rebalance Recommendation"]
  })
}

resource "aws_cloudwatch_event_target" "spot_rebalance" {
  rule = aws_cloudwatch_event_rule.spot_rebalance.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "instance_state_change" {
  name        = "${var.cluster_name}-instance-state-change"
  description = "EC2 instance state changes (stopping/terminated) for early NodeClaim cleanup"
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Instance State-change Notification"]
  })
}

resource "aws_cloudwatch_event_target" "instance_state_change" {
  rule = aws_cloudwatch_event_rule.instance_state_change.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "scheduled_change" {
  name        = "${var.cluster_name}-scheduled-change"
  description = "AWS Health scheduled maintenance events (retirement, hardware failure)"
  event_pattern = jsonencode({
    source        = ["aws.health"]
    "detail-type" = ["AWS Health Event"]
  })
}

resource "aws_cloudwatch_event_target" "scheduled_change" {
  rule = aws_cloudwatch_event_rule.scheduled_change.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

# EKS Access Entry for the shared node role used by app and GPU node groups.
# terraform-aws-modules/eks v21 uses Access Entries (not aws-auth ConfigMap).
# The module creates entries for node groups it manages (system); standalone
# aws_eks_node_group resources need an explicit entry or nodes can't join.
# Both app_node_group and gpu_node_group share aws_iam_role.gpu_node, so one
# entry covers both.
resource "aws_eks_access_entry" "node_groups" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.gpu_node.arn
  type          = "EC2_LINUX"

  depends_on = [module.eks]
}

# Launch template for app nodes — sets maxPods to 110 to match VPC CNI prefix
# delegation capacity (t3.medium with prefix delegation supports ~110 pods vs 17
# without). Without this override the kubelet bootstrap caps at the ENI IP limit
# even when ENABLE_PREFIX_DELEGATION is set on the VPC CNI DaemonSet.
resource "aws_launch_template" "app_node" {
  name_prefix = "${var.cluster_name}-app-"

  user_data = base64encode(<<-EOF
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="==BOUNDARY=="

    --==BOUNDARY==
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      kubelet:
        config:
          maxPods: 110

    --==BOUNDARY==--
    EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.cluster_name}-app-nodes"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# App node group: for non-GPU workloads (APIs, services, data pipelines)
resource "aws_eks_node_group" "app_node_group" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "${var.cluster_name}-app"
  node_role_arn   = aws_iam_role.gpu_node.arn  # Shared node role (app + GPU groups)
  subnet_ids      = aws_subnet.private[*].id

  depends_on = [
    aws_iam_role_policy_attachment.gpu_node_EKS_Worker,
    aws_iam_role_policy_attachment.gpu_node_EKS_CNI,
    aws_iam_role_policy_attachment.gpu_node_ECR_ReadOnly,
    aws_eks_access_entry.node_groups,
  ]

  launch_template {
    id      = aws_launch_template.app_node.id
    version = aws_launch_template.app_node.latest_version
  }

  scaling_config {
    desired_size = var.app_node_group.desired_capacity
    min_size     = var.app_node_group.min_capacity
    max_size     = var.app_node_group.max_capacity
  }

  instance_types = var.app_node_group.instance_types
  capacity_type  = var.app_node_group.capacity_type

  labels = {
    role         = "app"
    node-type    = "general-purpose"
  }

  tags = {
    Name          = "${var.cluster_name}-app-nodes"
    Environment   = var.environment
    ManagedBy     = "Terraform"
    NodeGroupType = "app"
  }
}

# GPU node group: for GPU inference workloads (baseline capacity; Karpenter handles burst)
resource "aws_eks_node_group" "gpu_node_group" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "${var.cluster_name}-gpu"
  node_role_arn   = aws_iam_role.gpu_node.arn
  subnet_ids      = aws_subnet.private[*].id

  depends_on = [
    aws_iam_role_policy_attachment.gpu_node_EKS_Worker,
    aws_iam_role_policy_attachment.gpu_node_EKS_CNI,
    aws_iam_role_policy_attachment.gpu_node_ECR_ReadOnly,
    aws_eks_access_entry.node_groups,
  ]

  scaling_config {
    desired_size = var.inference_config.baseline_gpu_nodes
    min_size     = var.inference_config.baseline_gpu_nodes
    max_size     = var.gpu_node_group.max_size
  }

  instance_types = [var.gpu_node_group.instance_type]
  capacity_type  = var.gpu_node_group.spot ? "SPOT" : "ON_DEMAND"
  labels = {
    role      = "gpu"
    node-type = "gpu"
  }

  taint {
    key    = var.gpu_node_group.taint_key
    value  = var.gpu_node_group.taint_value
    effect = var.gpu_node_group.taint_effect
  }

  tags = {
    Name          = "${var.cluster_name}-gpu-nodes"
    Environment   = var.environment
    ManagedBy     = "Terraform"
    NodeGroupType = "gpu"
  }
}

# The EKS module creates two relevant security groups:
#   cluster_security_group_id         — module-created additional cluster SG
#   cluster_primary_security_group_id — EKS-auto-created primary SG (eks-cluster-sg-*)
#   node_security_group_id            — module-created node SG (system node group)
#
# Standalone aws_eks_node_group resources (app + GPU tiers) receive only the
# primary cluster SG by default, NOT the module's additional cluster SG.
# Both sets of rules below are required so CoreDNS, kubelet, and pod-to-pod
# traffic work across all node tiers.
resource "aws_security_group_rule" "node_sg_to_cluster_sg" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = module.eks.cluster_security_group_id
  source_security_group_id = module.eks.node_security_group_id
  description              = "Allow all traffic from module-managed node SG to additional cluster SG"
}

resource "aws_security_group_rule" "cluster_sg_to_node_sg" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = module.eks.cluster_security_group_id
  description              = "Allow all traffic from additional cluster SG to module-managed node SG"
}

# Standalone node groups (app + GPU) use the EKS primary cluster SG, not the
# module's additional cluster SG. These rules bridge the primary SG to the
# system node SG so DNS (CoreDNS), kubelet health checks, and pod-to-pod
# traffic work between app/GPU nodes and system nodes.
resource "aws_security_group_rule" "primary_cluster_sg_to_node_sg" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = module.eks.cluster_primary_security_group_id
  description              = "Allow all traffic from EKS primary cluster SG to module-managed node SG"
}

resource "aws_security_group_rule" "node_sg_to_primary_cluster_sg" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = module.eks.cluster_primary_security_group_id
  source_security_group_id = module.eks.node_security_group_id
  description              = "Allow all traffic from module-managed node SG to EKS primary cluster SG"
}

