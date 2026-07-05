mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_db_instance" {
    defaults = {
      address     = "fedllm-dev-vector.c1a2b3c4d5e6.us-east-1.rds.amazonaws.com"
      arn         = "arn:aws:rds:us-east-1:123456789012:db:fedllm-dev-vector"
      identifier  = "fedllm-dev-vector"
      resource_id = "db-ABCDEFGHIJKLMNOPQRST"
      master_user_secret = [
        {
          secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fedllm-dev-vector-master-AbCdEf"
        }
      ]
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/fedllm-dev-vector-monitoring-role"
    }
  }
}

variables {
  project                      = "fedllm"
  environment                  = "dev"
  data_classification          = "cui"
  vpc_id                       = "vpc-12345678"
  private_subnet_ids           = ["subnet-11111111", "subnet-22222222", "subnet-33333333"]
  app_security_group_id        = "sg-appsg12345"
  data_kms_key_arn             = "arn:aws:kms:us-east-1:123456789012:key/12345678-aaaa-bbbb-cccc-111111111111"
  secrets_kms_key_arn          = "arn:aws:kms:us-east-1:123456789012:key/12345678-dddd-eeee-ffff-222222222222"
  logs_kms_key_arn             = "arn:aws:kms:us-east-1:123456789012:key/12345678-gggg-hhhh-iiii-333333333333"
  instance_class               = "db.t4g.medium"
  engine_version               = "16"
  allocated_storage            = 20
  max_allocated_storage        = 100
  multi_az                     = true
  db_name                      = "vectordb"
  master_username              = "postgres"
  backup_retention_days        = 7
  deletion_protection          = true
  skip_final_snapshot          = false
  log_retention_days           = 90
  monitoring_interval          = 60
  enable_performance_insights  = true
  preferred_backup_window      = "03:00-04:00"
  preferred_maintenance_window = "sun:04:30-sun:05:30"
}

run "topology_and_backups_checks" {
  command = plan

  # Assert: Subnet group includes both subnets
  assert {
    condition     = length(aws_db_subnet_group.vector.subnet_ids) >= 2
    error_message = "DB subnet group must include at least 2 subnets"
  }

  # Assert: Security group has ingress from app SG on 5432
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.db_from_app.from_port == 5432 &&
      aws_vpc_security_group_ingress_rule.db_from_app.to_port == 5432
    )
    error_message = "SG must have ingress rule on port 5432"
  }

  # Assert: Backup retention is at least 7 days
  assert {
    condition     = aws_db_instance.vector.backup_retention_period >= 7
    error_message = "Backup retention must be at least 7 days (federal minimum)"
  }

  # Assert: multi_az wiring (base variables set true)
  assert {
    condition     = aws_db_instance.vector.multi_az == true
    error_message = "multi_az must be wired through to the instance"
  }

  # Assert: When skip_final_snapshot is false, final snapshot identifier is set
  assert {
    condition     = var.skip_final_snapshot == true || aws_db_instance.vector.final_snapshot_identifier != null
    error_message = "final_snapshot_identifier must be set when skip_final_snapshot is false"
  }

  # Assert: Final snapshot identifier follows naming convention
  assert {
    condition     = can(regex("fedllm-dev-vector-final", aws_db_instance.vector.final_snapshot_identifier))
    error_message = "final_snapshot_identifier must follow naming convention"
  }

  # Assert: Automated backups are kept after deletion
  assert {
    condition     = aws_db_instance.vector.delete_automated_backups == false
    error_message = "Automated backups must be kept after instance deletion"
  }

  # Assert: CloudWatch logs exported
  assert {
    condition     = contains(aws_db_instance.vector.enabled_cloudwatch_logs_exports, "postgresql")
    error_message = "PostgreSQL logs must be exported to CloudWatch"
  }

  assert {
    condition     = contains(aws_db_instance.vector.enabled_cloudwatch_logs_exports, "upgrade")
    error_message = "Upgrade logs must be exported to CloudWatch"
  }

  # Assert: Monitoring role created when interval > 0
  assert {
    condition     = var.monitoring_interval > 0 ? length(aws_iam_role.rds_monitoring) == 1 : length(aws_iam_role.rds_monitoring) == 0
    error_message = "Monitoring role must be created when monitoring_interval > 0"
  }

  # Assert: Monitoring interval is set correctly
  assert {
    condition     = aws_db_instance.vector.monitoring_interval == var.monitoring_interval
    error_message = "Monitoring interval must match variable"
  }

  # Assert: Log group names follow convention
  assert {
    condition     = can(regex("^/aws/rds/instance/fedllm-dev-vector/", aws_cloudwatch_log_group.postgresql.name))
    error_message = "PostgreSQL log group name must follow RDS convention"
  }

  assert {
    condition     = can(regex("^/aws/rds/instance/fedllm-dev-vector/", aws_cloudwatch_log_group.upgrade.name))
    error_message = "Upgrade log group name must follow RDS convention"
  }
}

run "multi_az_false_override" {
  command = plan

  variables {
    multi_az = false
  }

  assert {
    condition     = aws_db_instance.vector.multi_az == false
    error_message = "multi_az override to false (demo composition) must reach the instance"
  }
}

run "monitoring_disabled" {
  command = plan

  variables {
    monitoring_interval = 0
  }

  assert {
    condition     = length(aws_iam_role.rds_monitoring) == 0
    error_message = "Monitoring role must not be created when monitoring_interval is 0"
  }

  assert {
    condition     = aws_db_instance.vector.monitoring_interval == 0
    error_message = "Monitoring interval must be 0 when disabled"
  }
}
