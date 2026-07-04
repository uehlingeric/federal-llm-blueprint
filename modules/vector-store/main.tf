data "aws_partition" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project            = var.project
    Environment        = var.environment
    ManagedBy          = "terraform"
    DataClassification = var.data_classification
  }
}

# DB Subnet Group: associates RDS instance with private subnets
resource "aws_db_subnet_group" "vector" {
  name_prefix = "${local.name_prefix}-vector-"
  subnet_ids  = var.private_subnet_ids
  description = "Subnet group for RDS Postgres vector store in private subnets"

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-vector-subnet-group"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

# RDS Security Group: ingress 5432 from app security group only
resource "aws_security_group" "db" {
  name_prefix = "${local.name_prefix}-vector-db-"
  description = "Security group for RDS Postgres vector store"
  vpc_id      = var.vpc_id

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-vector-db-sg"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

# RDS SG: Ingress on 5432 from app security group only
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id = aws_security_group.db.id

  description                  = "Allow PostgreSQL from app security group"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = var.app_security_group_id

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-vector-db-ingress"
    }
  )
}

# No egress rules on the DB security group: a database initiates no outbound connections.

# DB Parameter Group: PostgreSQL 16 with TLS enforcement
resource "aws_db_parameter_group" "vector" {
  family      = "postgres${var.engine_version}"
  name_prefix = "${local.name_prefix}-vector-"
  description = "Parameter group for RDS Postgres vector store with TLS enforcement"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-vector-pg"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

# CloudWatch Log Group for PostgreSQL logs (pre-created so encryption/retention are controlled)
resource "aws_cloudwatch_log_group" "postgresql" {
  #checkov:skip=CKV_AWS_338: Retention is configurable via var.log_retention_days; default 90 days is appropriate for vector store logs in development environments. Federal deployments set 365+.
  name              = "/aws/rds/instance/${local.name_prefix}-vector/postgresql"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-vector-postgresql-logs"
    }
  )
}

# CloudWatch Log Group for upgrade logs (pre-created so encryption/retention are controlled)
resource "aws_cloudwatch_log_group" "upgrade" {
  #checkov:skip=CKV_AWS_338: Retention is configurable via var.log_retention_days; default 90 days is appropriate for upgrade logs in development environments. Federal deployments set 365+.
  name              = "/aws/rds/instance/${local.name_prefix}-vector/upgrade"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-vector-upgrade-logs"
    }
  )
}

# Enhanced Monitoring IAM Role (count-guarded on monitoring_interval > 0)
# Trust: RDS monitoring service principal (partition-invariant, no region in principal)
data "aws_iam_policy_document" "rds_monitoring_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "rds_monitoring" {
  count              = var.monitoring_interval > 0 ? 1 : 0
  name_prefix        = "${local.name_prefix}-vector-monitoring-"
  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_trust.json
  description        = "Role for RDS enhanced monitoring"

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-vector-monitoring-role"
    }
  )
}

# Comment: Deliberately NOT under the stack permission boundary. This role is assumed by the RDS monitoring service,
# not by stack principals, and the boundary's logs ceiling (no CreateLogGroup) would break RDSOSMetrics delivery.
resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  count      = var.monitoring_interval > 0 ? 1 : 0
  role       = aws_iam_role.rds_monitoring[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# RDS Postgres instance with pgvector support (extension created via bootstrap.sql)
resource "aws_db_instance" "vector" {
  identifier     = "${local.name_prefix}-vector"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.db_name
  port     = 5432
  username = var.master_username

  # RDS-managed master password stored in Secrets Manager with automatic rotation
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.secrets_kms_key_arn

  # IAM database authentication enabled (preferred over password auth; scoped via ARN in app task role)
  iam_database_authentication_enabled = true

  # Storage: gp3 with autoscaling, encrypted with data KMS key
  storage_type          = "gp3"
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_encrypted     = true
  kms_key_id            = var.data_kms_key_arn

  # Network: private subnet group, security group, no public accessibility
  db_subnet_group_name   = aws_db_subnet_group.vector.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  # Parameter group with TLS enforcement
  parameter_group_name = aws_db_parameter_group.vector.name

  # Backups: retention floor 7 days (federal compliance), automated backups kept after deletion
  backup_retention_period  = var.backup_retention_days
  backup_window            = var.preferred_backup_window
  copy_tags_to_snapshot    = true
  delete_automated_backups = false

  # Deletion protection and snapshot handling
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = "${local.name_prefix}-vector-final"

  # CloudWatch Logs: pre-created log groups adopted by RDS
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  depends_on = [
    aws_cloudwatch_log_group.postgresql,
    aws_cloudwatch_log_group.upgrade,
  ]

  # Performance Insights: enabled by default with data KMS key (7-day retention is free tier)
  performance_insights_enabled          = var.enable_performance_insights
  performance_insights_kms_key_id       = var.data_kms_key_arn
  performance_insights_retention_period = 7

  # Monitoring: enhanced monitoring with OS metrics (count-guarded on interval > 0)
  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = var.monitoring_interval > 0 ? aws_iam_role.rds_monitoring[0].arn : null

  # Version management: minor upgrades automatic, major upgrades manual
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false
  apply_immediately           = false
  maintenance_window          = var.preferred_maintenance_window

  # SSL certificate (RDS default CA RSA 2048, GovCloud compatible)
  ca_cert_identifier = "rds-ca-rsa2048-g1"

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-vector"
    }
  )
}
