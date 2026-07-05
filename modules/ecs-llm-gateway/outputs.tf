output "alb_dns_name" {
  description = "Internal ALB DNS name (for in-VPC client requests)"
  value       = aws_lb.gateway.dns_name
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer"
  value       = aws_lb.gateway.arn
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix (LoadBalancer dimension for CloudWatch metrics; consumed by observability dashboard)"
  value       = aws_lb.gateway.arn_suffix
}

output "target_group_arn_suffix" {
  description = "Target group ARN suffix (TargetGroup dimension for CloudWatch metrics; consumed by observability dashboard)"
  value       = aws_lb_target_group.gateway.arn_suffix
}

output "alb_security_group_id" {
  description = "Security group ID for the ALB"
  value       = aws_security_group.alb.id
}

output "cluster_arn" {
  description = "ARN of the ECS cluster"
  value       = aws_ecs_cluster.gateway.arn
}

output "cluster_name" {
  description = "Name of the ECS cluster (ClusterName dimension for CloudWatch metrics; consumed by observability dashboard)"
  value       = aws_ecs_cluster.gateway.name
}

output "service_name" {
  description = "Name of the ECS service"
  value       = aws_ecs_service.gateway.name
}

output "gateway_url" {
  description = "Gateway HTTPS URL (constructed from ALB DNS name)"
  value       = "https://${aws_lb.gateway.dns_name}"
}

output "log_group_name" {
  description = "CloudWatch log group name for gateway container logs"
  value       = aws_cloudwatch_log_group.gateway.name
}

output "log_group_arn" {
  description = "CloudWatch log group ARN for gateway container logs"
  value       = aws_cloudwatch_log_group.gateway.arn
}

output "master_key_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the LiteLLM master key (either provided or created by module)"
  value       = local.master_key_secret_arn
}

output "config_parameter_arn" {
  description = "ARN of the SSM Parameter Store SecureString holding the LiteLLM config YAML"
  value       = aws_ssm_parameter.litellm_config.arn
}
