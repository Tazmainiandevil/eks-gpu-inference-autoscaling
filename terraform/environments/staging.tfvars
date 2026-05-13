# Staging — functional load testing. One warm GPU node, moderate scale-out.
# 2 system nodes for HA, separate app node group for non-GPU workloads.
# (~$50-60/day with 1 baseline GPU node running)

aws_region   = "eu-west-2"
cluster_name = "eks-gpu-staging"
environment  = "staging"

# System node group — separate HA tier for Karpenter, Prometheus, monitoring
system_node_group = {
  desired_capacity = 2
  min_capacity     = 2
  max_capacity     = 4
  instance_types   = ["t3.large"]
  capacity_type    = "ON_DEMAND"
}

# App node group — separate scaling tier for APIs, services, non-GPU workloads
app_node_group = {
  desired_capacity = 1
  min_capacity     = 1
  max_capacity     = 5
  instance_types   = ["t3.medium", "t3.large"]
  capacity_type    = "SPOT"
}

gpu_node_group = {
  instance_type = "g5.xlarge"
  desired_size  = 1
  min_size      = 1
  max_size      = 4
  taint_key     = "gpu"
  taint_value   = "true"
  taint_effect  = "NO_SCHEDULE"
  spot          = false   # ON_DEMAND baseline — spot burst handled by Karpenter
}

inference_config = {
  baseline_gpu_nodes = 1   # one warm ON_DEMAND GPU node always available
}

endpoint_public_access = true   # allows Terraform to run from local machine or CI

# Budget alerts — set your email in terraform/environments/staging.local.tfvars (gitignored):
#   budget_alert_email = "you@example.com"
# Daily limit covers baseline (~$50) + full load (~$80) + 25% headroom.
# Monthly budget is derived automatically as daily × 30 ($3,000).
budget_alert_email     = "your-email@example.com"
budget_daily_limit_usd = "100"
