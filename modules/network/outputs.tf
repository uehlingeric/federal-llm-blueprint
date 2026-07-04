output "vpc_id" {
  description = "VPC resource ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "VPC CIDR block (e.g., 10.0.0.0/16)"
  value       = aws_vpc.main.cidr_block
}

output "private_subnet_ids" {
  description = "List of private subnet IDs across all availability zones"
  value       = [for az in local.azs : aws_subnet.private[az].id]
}

output "public_subnet_ids" {
  description = "List of public subnet IDs (empty in no-egress mode)"
  value       = var.enable_public_subnets ? [for az in local.azs : aws_subnet.public[az].id] : []
}

output "private_route_table_ids" {
  description = "List of private route table IDs (one per availability zone)"
  value       = [for az in local.azs : aws_route_table.private[az].id]
}

output "app_security_group_id" {
  description = "Security group ID for ECS tasks and application workloads. Attached to compute resources in other modules."
  value       = aws_security_group.app.id
}

output "endpoint_security_group_id" {
  description = "Security group ID for VPC endpoints. Allows HTTPS from the VPC CIDR."
  value       = aws_security_group.endpoint.id
}

output "interface_endpoint_ids" {
  description = "Map of interface VPC endpoint IDs keyed by service name (e.g., bedrock-runtime, ecr-api, logs, kms, secretsmanager, ecs, sts)"
  value = {
    for service, endpoint in aws_vpc_endpoint.interface : service => endpoint.id
  }
}

output "gateway_endpoint_ids" {
  description = "Map of gateway VPC endpoint IDs keyed by service (s3 always present; dynamodb only if enabled)"
  value = merge(
    { s3 = aws_vpc_endpoint.s3.id },
    var.enable_dynamodb_gateway_endpoint ? { dynamodb = aws_vpc_endpoint.dynamodb[0].id } : {}
  )
}

output "flow_log_group_name" {
  description = "CloudWatch Logs group name for VPC flow logs. Null if flow logs are disabled."
  value       = var.enable_flow_logs ? aws_cloudwatch_log_group.flow_logs[0].name : null
}
