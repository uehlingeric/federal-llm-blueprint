output "task_execution_role_arn" {
  description = "ARN of the ECS task execution role (image pull, logs write, secrets read). Consumed by ecs-llm-gateway."
  value       = aws_iam_role.task_execution.arn
}

output "app_task_role_arn" {
  description = "ARN of the ECS app task role (Bedrock invoke, database connect, S3 read, KMS decrypt). Consumed by ecs-llm-gateway task definitions."
  value       = aws_iam_role.app_task.arn
}

output "ci_deploy_role_arn" {
  description = "ARN of the CI/CD deployment role (terraform plan/apply). Null if ci_trust_principal_arns is empty."
  value       = try(aws_iam_role.ci_deploy[0].arn, null)
}

output "human_role_arns" {
  description = "Map of human role ARNs keyed by tier (platform-admin, auditor, developer). Tiers not supplied in var.human_trust_principals are not present in the map."
  value = {
    for tier, role in aws_iam_role.human_tier : tier => role.arn
  }
}

output "permission_boundary_arn" {
  description = "ARN of the permission boundary policy applied to all created roles. Defines the ceiling of permitted actions."
  value       = aws_iam_policy.permission_boundary.arn
}
