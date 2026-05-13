# Production — 400+ RPS near-real-time inference with 40GB models.
# HA architecture: 3 system nodes, 2+ app nodes, 4 always-on p4d nodes.
# Karpenter spot pool handles burst. Dragonfly distributes 40GB image pulls.
# (~$110+/hr under load, ~$90/hr baseline)

aws_region   = "eu-west-2"
cluster_name = "eks-gpu-prod"
environment  = "production"

# System node group — HA tier (3 nodes) for Karpenter, Prometheus, kyverno, monitoring
system_node_group = {
  desired_capacity = 3
  min_capacity     = 3
  max_capacity     = 6
  instance_types   = ["m6i.large"]
  capacity_type    = "ON_DEMAND"
}

# App node group — baseline tier (2+ nodes) for services, APIs, data pipelines
app_node_group = {
  desired_capacity = 2
  min_capacity     = 2
  max_capacity     = 10
  instance_types   = ["m6i.large", "m6i.xlarge"]
  capacity_type    = "ON_DEMAND"
}

gpu_node_group = {
  # p4d.24xlarge: 8× A100 40GB, ~$32/hr ON_DEMAND — production baseline.
  # p4de.24xlarge: 8× A100 80GB, ~$41/hr — upgrade path for >40GB models; add to Karpenter
  #   NodePool burst list (environments/production/karpenter/) rather than managed node group.
  # p5/p5en.48xlarge: 8× H100 80GB — NOT available in eu-west-2; requires region change
  #   to us-east-1 or us-west-2.
  instance_type = "p4d.24xlarge"
  desired_size  = 4
  min_size      = 4
  max_size      = 8
  taint_key     = "gpu"
  taint_value   = "true"
  taint_effect  = "NO_SCHEDULE"
  spot          = false   # ON_DEMAND baseline — spot interruption would drop warm model
}

inference_config = {
  baseline_gpu_nodes = 4   # four warm ON_DEMAND p4d nodes; spot burst handled by Karpenter
}

endpoint_public_access = false  # production: Terraform must run from within VPC (CI runner, bastion, or VPN)

# Budget alerts — set your email in terraform/environments/production.local.tfvars (gitignored):
#   budget_alert_email = "ops@example.com"
# Daily limit covers 4× p4d.24xlarge baseline (~$2,200/day) + Karpenter burst headroom.
# Monthly budget is derived automatically as daily × 30 ($90,000).
# For finer-grained alerting, consider additional notifications in budgets.tf at 50% and 90%.
budget_alert_email     = "your-email@example.com"
budget_daily_limit_usd = "3000"
