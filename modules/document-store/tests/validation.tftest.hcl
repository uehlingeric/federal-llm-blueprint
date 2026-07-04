mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name = "us-east-1"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_elb_service_account" {
    defaults = {
      id  = "127311923021"
      arn = "arn:aws:iam::127311923021:root"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  project                            = "fedllm"
  environment                        = "dev"
  data_classification                = "cui"
  tags                               = {}
  data_kms_key_arn                   = "arn:aws:kms:us-east-1:123456789012:key/12345678-aaaa-bbbb-cccc-dddddddddddd"
  enable_object_lock                 = false
  object_lock_mode                   = "GOVERNANCE"
  object_lock_retention_days         = 30
  documents_ia_transition_days       = 90
  noncurrent_version_expiration_days = 180
  log_expiration_days                = 90
  abort_incomplete_multipart_days    = 7
  alb_logs_prefix                    = "alb"
  enable_inventory                   = false
  enable_analytics                   = false
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

run "expect_failure_environment_invalid" {
  command = plan

  variables {
    environment = "production"
  }

  expect_failures = [var.environment]
}

run "expect_failure_log_expiration_zero" {
  command = plan

  variables {
    log_expiration_days = 0
  }

  expect_failures = [var.log_expiration_days]
}

run "expect_failure_documents_ia_transition_zero" {
  command = plan

  variables {
    documents_ia_transition_days = 0
  }

  expect_failures = [var.documents_ia_transition_days]
}

run "expect_failure_noncurrent_version_expiration_zero" {
  command = plan

  variables {
    noncurrent_version_expiration_days = 0
  }

  expect_failures = [var.noncurrent_version_expiration_days]
}

run "expect_failure_abort_incomplete_multipart_zero" {
  command = plan

  variables {
    abort_incomplete_multipart_days = 0
  }

  expect_failures = [var.abort_incomplete_multipart_days]
}

run "expect_failure_project_invalid" {
  command = plan

  variables {
    project = "PROJECT_NAME"
  }

  expect_failures = [var.project]
}

run "expect_failure_data_classification_invalid" {
  command = plan

  variables {
    data_classification = "secret"
  }

  expect_failures = [var.data_classification]
}
