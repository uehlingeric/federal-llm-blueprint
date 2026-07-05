output "alarm_topic_arn" {
  description = "ARN of the SNS topic for alarm notifications"
  value       = aws_sns_topic.alarms.arn
}

output "log_group_arns" {
  description = "ARNs of created log groups, keyed by component"
  value = {
    for k, g in aws_cloudwatch_log_group.this : k => g.arn
  }
}

output "dashboard_name" {
  description = "Name of the CloudWatch dashboard; null if enable_dashboard is false"
  value       = var.enable_dashboard ? aws_cloudwatch_dashboard.this[0].dashboard_name : null
}
