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
  description = "ALB access-logs bucket ID from document-store module"
  value       = module.document_store.bucket_ids["alb-logs"]
}

output "document_bucket_ids" {
  description = "Document store bucket IDs by purpose (alb-logs, documents, access-logs)"
  value       = module.document_store.bucket_ids
}

output "document_bucket_arns" {
  description = "Document store bucket ARNs by purpose"
  value       = module.document_store.bucket_arns
}

output "db_endpoint" {
  description = "RDS pgvector database endpoint from vector-store module"
  value       = module.vector_store.db_endpoint
}

output "db_port" {
  description = "RDS database port from vector-store module"
  value       = module.vector_store.db_port
}

output "db_name" {
  description = "RDS database name from vector-store module"
  value       = module.vector_store.db_name
}

output "db_instance_id" {
  description = "RDS instance identifier from vector-store module (used by waiters and ops tooling)"
  value       = module.vector_store.db_instance_id
}

output "db_resource_id" {
  description = "RDS resource ID (for IAM database auth) from vector-store module"
  value       = module.vector_store.db_resource_id
}

output "db_master_secret_arn" {
  description = "Secrets Manager secret ARN for RDS master credentials from vector-store module"
  value       = module.vector_store.master_secret_arn
}

output "db_security_group_id" {
  description = "Security group ID for RDS database from vector-store module"
  value       = module.vector_store.db_security_group_id
}

output "trail_arn" {
  description = "CloudTrail trail ARN from audit module"
  value       = module.audit.trail_arn
}

output "audit_bucket_id" {
  description = "Audit bucket ID (CloudTrail/Config/Bedrock log destination) from audit module"
  value       = module.audit.audit_bucket_id
}

output "audit_log_group_name" {
  description = "CloudTrail CloudWatch log group name from audit module"
  value       = module.audit.audit_log_group_name
}

output "bedrock_log_group_name" {
  description = "Bedrock model-invocation log group name from audit module"
  value       = module.audit.bedrock_log_group_name
}

output "config_recorder_name" {
  description = "AWS Config recorder name from audit module"
  value       = module.audit.config_recorder_name
}

output "alarm_topic_arn" {
  description = "SNS alarm topic ARN from observability module"
  value       = module.observability.alarm_topic_arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard name from observability module"
  value       = module.observability.dashboard_name
}
