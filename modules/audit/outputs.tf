output "trail_arn" {
  description = "ARN of the CloudTrail"
  value       = aws_cloudtrail.this.arn
}

output "config_recorder_name" {
  description = "Name of the AWS Config configuration recorder"
  value       = aws_config_configuration_recorder.this.name
}

output "audit_log_group_name" {
  description = "Name of the CloudTrail CloudWatch Logs group"
  value       = aws_cloudwatch_log_group.trail.name
}

output "audit_bucket_id" {
  description = "ID of the audit bucket"
  value       = aws_s3_bucket.audit.id
}

output "audit_bucket_arn" {
  description = "ARN of the audit bucket"
  value       = aws_s3_bucket.audit.arn
}

output "bedrock_log_group_name" {
  description = "Name of the Bedrock model-invocation CloudWatch Logs group (null if disabled)"
  value       = var.enable_bedrock_invocation_logging ? aws_cloudwatch_log_group.bedrock[0].name : null
}
