output "db_endpoint" {
  description = "RDS Postgres endpoint hostname (hostname only, not endpoint:port)"
  value       = aws_db_instance.vector.address
}

output "db_port" {
  description = "RDS Postgres port (5432)"
  value       = aws_db_instance.vector.port
}

output "db_security_group_id" {
  description = "Security group ID for the RDS instance"
  value       = aws_security_group.db.id
}

output "db_instance_arn" {
  description = "ARN of the RDS instance"
  value       = aws_db_instance.vector.arn
}

output "db_instance_id" {
  description = "RDS instance identifier"
  value       = aws_db_instance.vector.identifier
}

output "db_resource_id" {
  description = "RDS DbiResourceId (used in rds-db:connect IAM auth ARNs for app_user access)"
  value       = aws_db_instance.vector.resource_id
}

output "master_secret_arn" {
  description = "ARN of the Secrets Manager secret containing RDS-managed master user credentials"
  value       = aws_db_instance.vector.master_user_secret[0].secret_arn
}

output "db_name" {
  description = "Initial database name"
  value       = aws_db_instance.vector.db_name
}
