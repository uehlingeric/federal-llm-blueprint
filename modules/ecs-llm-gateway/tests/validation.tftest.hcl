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
}

mock_provider "tls" {}

# Base variables for validation tests (overridden per run)
variables {
  project                 = "fedllm"
  environment             = "dev"
  data_classification     = "cui"
  vpc_id                  = "vpc-12345678"
  vpc_cidr                = "10.0.0.0/16"
  private_subnet_ids      = ["subnet-11111111", "subnet-22222222"]
  app_security_group_id   = "sg-appsg12345"
  task_execution_role_arn = "arn:aws:iam::123456789012:role/ecs-task-execution-role"
  app_task_role_arn       = "arn:aws:iam::123456789012:role/ecs-app-task-role"
  logs_kms_key_arn        = "arn:aws:kms:us-east-1:123456789012:key/12345678-aaaa-bbbb-cccc-111111111111"
  secrets_kms_key_arn     = "arn:aws:kms:us-east-1:123456789012:key/12345678-dddd-eeee-ffff-222222222222"
  container_image         = "ghcr.io/berriai/litellm@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  container_port          = 4000
  config_yaml             = "model_list: []"
  alb_logs_bucket_id      = "my-alb-logs-bucket"
  certificate_arn         = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  create_self_signed_cert = false
}

run "expect_failure_image_without_digest" {
  command = plan

  variables {
    container_image = "ghcr.io/berriai/litellm:main-stable"
  }

  expect_failures = [var.container_image]
}

run "expect_failure_both_certificate_options_set" {
  command = plan

  variables {
    certificate_arn         = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    create_self_signed_cert = true
  }

  expect_failures = [var.certificate_arn]
}

run "expect_failure_neither_certificate_option_set" {
  command = plan

  variables {
    certificate_arn         = null
    create_self_signed_cert = false
  }

  expect_failures = [var.certificate_arn]
}

run "expect_failure_single_subnet" {
  command = plan

  variables {
    private_subnet_ids = ["subnet-11111111"]
  }

  expect_failures = [var.private_subnet_ids]
}

run "expect_failure_container_user_root" {
  command = plan

  variables {
    container_user = "root"
  }

  expect_failures = [var.container_user]
}

run "expect_failure_container_user_zero" {
  command = plan

  variables {
    container_user = "0"
  }

  expect_failures = [var.container_user]
}

run "expect_failure_invalid_environment" {
  command = plan

  variables {
    environment = "invalid"
  }

  expect_failures = [var.environment]
}

run "expect_failure_invalid_log_retention" {
  command = plan

  variables {
    log_retention_days = 45
  }

  expect_failures = [var.log_retention_days]
}
