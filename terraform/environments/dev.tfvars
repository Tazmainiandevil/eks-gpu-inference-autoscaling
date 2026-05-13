# Dev — personal/testing. Keeps costs near zero when idle (~$5-6/day).
# GPU nodes scale to zero when not in use. Karpenter reclaims idle nodes fast.
#
# Node tier sizing rationale:
#   system (t3.large, 8 GB): Karpenter + KEDA + Prometheus + Grafana + Kyverno
#     fit comfortably; t3.medium (4 GB) is too tight when Prometheus peaks.
#   app (t3.medium, 4 GB): ArgoCD + OpenCost + Dragonfly + Pushgateway;
#     t3.small (2 GB) cannot fit ArgoCD alone.

aws_region   = "eu-west-2"
cluster_name = "eks-gpu-demo"
environment  = "dev"

# System node group (Karpenter, Prometheus, KEDA, Kyverno, monitoring)
system_node_group = {
  desired_capacity = 1
  min_capacity     = 1
  max_capacity     = 3
  instance_types   = ["t3.large"]
  capacity_type    = "ON_DEMAND"
}

# App node group (ArgoCD, OpenCost, Dragonfly, Pushgateway, user services)
# Two nodes needed: full platform stack (ArgoCD + Knative + Dragonfly + OpenCost
# + inference) exceeds the 17-pod EKS limit on a single t3.medium.
app_node_group = {
  desired_capacity = 2
  min_capacity     = 1
  max_capacity     = 3
  instance_types   = ["t3.medium"]
  capacity_type    = "ON_DEMAND"
}

gpu_node_group = {
  instance_type = "g4dn.xlarge"
  desired_size  = 0
  min_size      = 0
  max_size      = 2
  taint_key     = "gpu"
  taint_value   = "true"
  taint_effect  = "NO_SCHEDULE"
  spot          = true
}

inference_config = {
  baseline_gpu_nodes = 0   # no always-on GPU cost; Karpenter provisions on demand
}

endpoint_public_access = true   # allows Terraform to run from local machine

# Budget alerts — set your email in terraform/environments/dev.local.tfvars (gitignored):
#   budget_alert_email = "you@example.com"
budget_alert_email     = "your-email@example.com"
budget_daily_limit_usd = "20"
