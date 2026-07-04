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
      json = jsonencode({
        Version   = "2012-10-17"
        Statement = []
      })
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
  private_subnet_ids           = ["subnet-11111111", "subnet-22222222"]
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

run "encryption_and_hardening_checks" {
  command = plan

  # Assert: Storage is encrypted with the data KMS key
  assert {
    condition     = aws_db_instance.vector.storage_encrypted == true
    error_message = "RDS storage must be encrypted"
  }

  assert {
    condition     = aws_db_instance.vector.kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/12345678-aaaa-bbbb-cccc-111111111111"
    error_message = "RDS storage must be encrypted with the data KMS key"
  }

  # Assert: RDS-managed master password enabled
  assert {
    condition     = aws_db_instance.vector.manage_master_user_password == true
    error_message = "RDS-managed master user password must be enabled"
  }

  assert {
    condition     = aws_db_instance.vector.master_user_secret_kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/12345678-dddd-eeee-ffff-222222222222"
    error_message = "Master user secret must be encrypted with the secrets KMS key"
  }

  # Assert: IAM database authentication enabled
  assert {
    condition     = aws_db_instance.vector.iam_database_authentication_enabled == true
    error_message = "IAM database authentication must be enabled"
  }

  # Assert: No public accessibility
  assert {
    condition     = aws_db_instance.vector.publicly_accessible == false
    error_message = "RDS instance must not be publicly accessible"
  }

  # Assert: Deletion protection enabled by default
  assert {
    condition     = aws_db_instance.vector.deletion_protection == true
    error_message = "Deletion protection must be enabled"
  }

  # Assert: Parameter group contains TLS enforcement
  assert {
    condition = length([
      for p in aws_db_parameter_group.vector.parameter :
      p if p.name == "rds.force_ssl" && p.value == "1"
    ]) == 1
    error_message = "Parameter group must enforce TLS with rds.force_ssl = 1"
  }

  # Assert: Performance Insights enabled with data KMS key
  assert {
    condition     = aws_db_instance.vector.performance_insights_enabled == true
    error_message = "Performance Insights must be enabled"
  }

  assert {
    condition     = aws_db_instance.vector.performance_insights_kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/12345678-aaaa-bbbb-cccc-111111111111"
    error_message = "Performance Insights must use the data KMS key"
  }

  # Assert: CloudWatch log groups encrypted with logs KMS key
  assert {
    condition     = aws_cloudwatch_log_group.postgresql.kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/12345678-gggg-hhhh-iiii-333333333333"
    error_message = "PostgreSQL log group must be encrypted with the logs KMS key"
  }

  assert {
    condition     = aws_cloudwatch_log_group.upgrade.kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/12345678-gggg-hhhh-iiii-333333333333"
    error_message = "Upgrade log group must be encrypted with the logs KMS key"
  }

  # Assert: Log groups have correct retention
  assert {
    condition     = aws_cloudwatch_log_group.postgresql.retention_in_days == 90
    error_message = "PostgreSQL log group must have correct retention"
  }

  assert {
    condition     = aws_cloudwatch_log_group.upgrade.retention_in_days == 90
    error_message = "Upgrade log group must have correct retention"
  }

  # Assert: CA certificate is RDS-standard (GovCloud compatible)
  assert {
    condition     = aws_db_instance.vector.ca_cert_identifier == "rds-ca-rsa2048-g1"
    error_message = "CA certificate must be rds-ca-rsa2048-g1 for compatibility"
  }
}
