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
