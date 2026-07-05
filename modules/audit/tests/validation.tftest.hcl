mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name   = "us-east-1"
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

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:/mock/group"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::mock-bucket"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }

  mock_resource "aws_iam_service_linked_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig"
    }
  }
}

variables {
  project                           = "fedllm"
  environment                       = "dev"
  data_classification               = "cui"
  tags                              = {}
  logs_kms_key_arn                  = "arn:aws:kms:us-east-1:123456789012:key/12345678-aaaa-bbbb-cccc-dddddddddddd"
  documents_bucket_arn              = "arn:aws:s3:::fedllm-dev-documents-123456789012"
  access_logs_bucket_id             = "fedllm-dev-access-logs-123456789012"
  enable_insights                   = false
  enable_bedrock_invocation_logging = false
  enable_full_content_logging       = false
  trail_log_retention_days          = 365
  bedrock_log_retention_days        = 365
  include_global_resource_types     = true
  config_snapshot_frequency         = "TwentyFour_Hours"
  enable_object_lock                = true
  object_lock_mode                  = "GOVERNANCE"
  object_lock_retention_days        = 30
  audit_log_expiration_days         = 913
  abort_incomplete_multipart_days   = 7
}

run "expect_failure_environment_invalid" {
  command = plan

  variables {
    environment = "production"
  }

  expect_failures = [var.environment]
}

run "expect_failure_trail_retention_invalid" {
  command = plan

  variables {
    trail_log_retention_days = 0
  }

  expect_failures = [var.trail_log_retention_days]
}

run "expect_failure_trail_retention_not_in_allowed_set" {
  command = plan

  variables {
    trail_log_retention_days = 47
  }

  expect_failures = [var.trail_log_retention_days]
}

run "expect_failure_bedrock_retention_invalid" {
  command = plan

  variables {
    bedrock_log_retention_days = 0
  }

  expect_failures = [var.bedrock_log_retention_days]
}

run "expect_failure_bedrock_retention_not_in_allowed_set" {
  command = plan

  variables {
    bedrock_log_retention_days = 47
  }

  expect_failures = [var.bedrock_log_retention_days]
}

run "expect_failure_config_snapshot_frequency_invalid" {
  command = plan

  variables {
    config_snapshot_frequency = "Every_Hour"
  }

  expect_failures = [var.config_snapshot_frequency]
}

run "expect_failure_object_lock_mode_invalid" {
  command = plan

  variables {
    object_lock_mode = "LEGAL_HOLD"
  }

  expect_failures = [var.object_lock_mode]
}

run "expect_failure_object_lock_retention_zero" {
  command = plan

  variables {
    object_lock_retention_days = 0
  }

  expect_failures = [var.object_lock_retention_days]
}

run "expect_failure_audit_log_expiration_zero" {
  command = plan

  variables {
    audit_log_expiration_days = 0
  }

  expect_failures = [var.audit_log_expiration_days]
}

run "expect_failure_abort_incomplete_multipart_zero" {
  command = plan

  variables {
    abort_incomplete_multipart_days = 0
  }

  expect_failures = [var.abort_incomplete_multipart_days]
}

run "expect_failure_data_classification_invalid" {
  command = plan

  variables {
    data_classification = "secret"
  }

  expect_failures = [var.data_classification]
}

run "expect_failure_project_invalid" {
  command = plan

  variables {
    project = "PROJECT_NAME"
  }

  expect_failures = [var.project]
}

run "expect_failure_audit_log_expiration_lte_object_lock_retention" {
  command = plan

  variables {
    object_lock_retention_days = 30
    audit_log_expiration_days  = 30
  }

  expect_failures = [var.audit_log_expiration_days]
}
