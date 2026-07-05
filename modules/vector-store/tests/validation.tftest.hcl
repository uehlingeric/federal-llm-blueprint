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

# Base variables for validation tests (overridden per run)
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

run "expect_failure_backup_retention_too_low" {
  command = plan

  variables {
    backup_retention_days = 3
  }

  expect_failures = [var.backup_retention_days]
}

run "expect_failure_backup_retention_too_high" {
  command = plan

  variables {
    backup_retention_days = 40
  }

  expect_failures = [var.backup_retention_days]
}

run "expect_failure_monitoring_interval_invalid" {
  command = plan

  variables {
    monitoring_interval = 7
  }

  expect_failures = [var.monitoring_interval]
}

run "expect_failure_single_subnet" {
  command = plan

  variables {
    private_subnet_ids = ["subnet-11111111"]
  }

  expect_failures = [var.private_subnet_ids]
}

run "expect_failure_max_allocated_not_greater_than_allocated" {
  command = plan

  variables {
    allocated_storage     = 100
    max_allocated_storage = 100
  }

  expect_failures = [var.max_allocated_storage]
}

run "expect_failure_invalid_environment" {
  command = plan

  variables {
    environment = "invalid-env"
  }

  expect_failures = [var.environment]
}

run "expect_failure_invalid_data_classification" {
  command = plan

  variables {
    data_classification = "secret"
  }

  expect_failures = [var.data_classification]
}

run "expect_failure_invalid_log_retention" {
  command = plan

  variables {
    log_retention_days = 45
  }

  expect_failures = [var.log_retention_days]
}

run "expect_failure_invalid_backup_window" {
  command = plan

  variables {
    preferred_backup_window = "invalid"
  }

  expect_failures = [var.preferred_backup_window]
}

run "expect_failure_invalid_maintenance_window" {
  command = plan

  variables {
    preferred_maintenance_window = "invalid"
  }

  expect_failures = [var.preferred_maintenance_window]
}

run "expect_failure_invalid_db_name" {
  command = plan

  variables {
    db_name = "123invalid"
  }

  expect_failures = [var.db_name]
}

run "expect_failure_invalid_master_username" {
  command = plan

  variables {
    master_username = "123invalid"
  }

  expect_failures = [var.master_username]
}
