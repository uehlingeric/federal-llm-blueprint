output "kms_key_arns" {
  description = "KMS CMK ARNs from kms module"
  value       = module.kms.key_arns
}

output "kms_key_ids" {
  description = "KMS CMK IDs from kms module"
  value       = module.kms.key_ids
}

output "kms_alias_arns" {
  description = "KMS CMK alias ARNs from kms module"
  value       = module.kms.alias_arns
}

output "vpc_id" {
  description = "VPC ID from network module"
  value       = module.network.vpc_id
}

output "vpc_cidr_block" {
  description = "VPC CIDR from network module"
  value       = module.network.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs from network module"
  value       = module.network.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs from network module (empty in no-egress mode)"
  value       = module.network.public_subnet_ids
}

output "private_route_table_ids" {
  description = "Private route table IDs from network module"
  value       = module.network.private_route_table_ids
}

output "app_security_group_id" {
  description = "App security group ID from network module"
  value       = module.network.app_security_group_id
}

output "endpoint_security_group_id" {
  description = "Endpoint security group ID from network module"
  value       = module.network.endpoint_security_group_id
}

output "interface_endpoint_ids" {
  description = "Interface endpoint IDs from network module"
  value       = module.network.interface_endpoint_ids
}

output "gateway_endpoint_ids" {
  description = "Gateway endpoint IDs from network module"
  value       = module.network.gateway_endpoint_ids
}

output "flow_log_group_name" {
  description = "Flow log CloudWatch group name from network module"
  value       = module.network.flow_log_group_name
}

output "task_execution_role_arn" {
  description = "ECS task execution role ARN from iam module"
  value       = module.iam.task_execution_role_arn
}

output "app_task_role_arn" {
  description = "ECS app task role ARN from iam module"
  value       = module.iam.app_task_role_arn
}

output "permission_boundary_arn" {
  description = "Permission boundary policy ARN from iam module"
  value       = module.iam.permission_boundary_arn
}

output "gateway_url" {
  description = "LLM gateway URL from ecs-llm-gateway module"
  value       = module.gateway.gateway_url
}

output "alb_dns_name" {
  description = "Internal ALB DNS name from ecs-llm-gateway module"
  value       = module.gateway.alb_dns_name
}

output "cluster_arn" {
  description = "ECS cluster ARN from ecs-llm-gateway module"
  value       = module.gateway.cluster_arn
}

output "service_name" {
  description = "ECS service name from ecs-llm-gateway module"
  value       = module.gateway.service_name
}

output "gateway_log_group_name" {
  description = "CloudWatch log group name for gateway container logs from ecs-llm-gateway module"
  value       = module.gateway.log_group_name
}

output "master_key_secret_arn" {
  description = "Secrets Manager secret ARN for gateway master key from ecs-llm-gateway module"
  value       = module.gateway.master_key_secret_arn
}

output "config_parameter_arn" {
  description = "SSM parameter ARN for LiteLLM config from ecs-llm-gateway module"
  value       = module.gateway.config_parameter_arn
}

output "alb_logs_bucket_id" {
  description = "ALB access-logs stub bucket ID (replaced by document-store in week 5)"
  value       = aws_s3_bucket.alb_logs.id
}
