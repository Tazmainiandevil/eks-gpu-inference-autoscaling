output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "system_node_group_name" {
  description = "System node group name (Karpenter, monitoring, platform pods)"
  value       = "system"  # Managed by EKS module
}

output "app_node_group_name" {
  description = "App node group name (general-purpose workloads)"
  value       = aws_eks_node_group.app_node_group.node_group_name
}

output "gpu_node_group_name" {
  description = "GPU node group name (inference workloads, baseline capacity)"
  value       = aws_eks_node_group.gpu_node_group.node_group_name
}

output "karpenter_role_arn" {
  description = "IAM role ARN for the Karpenter service account (Pod Identity association)."
  value       = aws_iam_role.karpenter.arn
}

output "karpenter_interruption_queue_name" {
  description = "SQS queue name for Karpenter spot interruption handling. Set as interruptionQueue in karpenter Helm values."
  value       = aws_sqs_queue.karpenter_interruption.name
}

output "aws_region" {
  value = var.aws_region
}
