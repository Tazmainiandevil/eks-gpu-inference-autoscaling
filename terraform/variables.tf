variable "aws_region" {
  type    = string
  default = "eu-west-2"
}

variable "cluster_name" {
  type    = string
  default = "eks-gpu-cluster"
}

variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string
  default     = "dev"
}

variable "k8s_version" {
  type    = string
  default = "1.35"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnets" {
  type = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnets" {
  type = list(string)
  default = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "system_node_group" {
  description = "System node group (Karpenter, Prometheus, monitoring pods)"
  type = object({
    desired_capacity = number
    min_capacity     = number
    max_capacity     = number
    instance_types   = list(string)
    capacity_type    = string
  })
  # System pods must be guaranteed capacity with taints:
  # - Dev: 1 node is sufficient (cost-optimized)
  # - Production: 2+ nodes for HA
  default = {
    desired_capacity = 1
    min_capacity     = 1
    max_capacity     = 3
    instance_types   = ["t3.medium"]
    capacity_type    = "ON_DEMAND"
  }
}

variable "app_node_group" {
  description = "App node group (general-purpose workloads: APIs, services, data pipelines)"
  type = object({
    desired_capacity = number
    min_capacity     = number
    max_capacity     = number
    instance_types   = list(string)
    capacity_type    = string
  })
  # App nodes scale independently from system and GPU:
  # - Can be mixed spot/on-demand for cost optimization
  # - Scales based on app demand (not GPU)
  # - Dev: minimal (cost), Production: sized for baseline throughput
  default = {
    desired_capacity = 1
    min_capacity     = 1
    max_capacity     = 10
    instance_types   = ["t3.small", "t3.medium", "t3.large"]
    capacity_type    = "ON_DEMAND"
  }
}

variable "gpu_node_group" {
  type = object({
    instance_type = string
    desired_size  = number
    min_size      = number
    max_size      = number
    taint_key     = string
    taint_value   = string
    taint_effect  = string
    spot          = bool
  })
  # desired_size=0 and spot=true keeps costs near zero when GPU nodes are idle.
  # For production set desired_size=1 and spot=false so a warm ON_DEMAND node
  # is always available for low-latency HTTP (Knative) workloads.
  default = {
    instance_type = "g4dn.xlarge"
    desired_size  = 0
    min_size      = 0
    max_size      = 2
    taint_key     = "gpu"
    taint_value   = "true"
    taint_effect  = "NO_SCHEDULE"
    spot          = true
  }
}

variable "endpoint_public_access" {
  description = "Enable public EKS API endpoint. Required when running Terraform from outside the VPC (local machine or CI). Set false only if Terraform runs from within the VPC via bastion or VPN."
  type        = bool
  default     = true
}

variable "inference_config" {
  description = "Controls the GPU managed node group baseline. Other inference tuning (KEDA thresholds, consolidation windows) is owned by the K8s manifests in environments/*/karpenter/ and apps/inference/."
  type = object({
    # Number of always-on ON_DEMAND GPU nodes in the managed node group.
    # 0 = no guaranteed baseline (dev). 1+ = warm nodes for low-latency serving (production).
    baseline_gpu_nodes = number
  })
  default = {
    baseline_gpu_nodes = 0
  }
}

variable "budget_alert_email" {
  description = "Email address to receive AWS Budget alerts. Set in your tfvars file — never commit a real address to git."
  type        = string
  default     = "your-email@example.com"
}

variable "budget_daily_limit_usd" {
  description = "Daily spend limit in USD. Alerts fire at 80% actual and 100% forecast. Default $20 is safe for dev testing."
  type        = string
  default     = "20"
}

