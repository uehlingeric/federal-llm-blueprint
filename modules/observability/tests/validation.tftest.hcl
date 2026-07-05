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

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-1:123456789012:mock-topic"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-east-1:123456789012:rule/mock-rule"
    }
  }
}

variables {
  project             = "fedllm"
  environment         = "dev"
  data_classification = "cui"
  tags                = {}
  logs_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/12345678-aaaa-bbbb-cccc-dddddddddddd"
}

run "expect_failure_retention_zero" {
  command = plan

  variables {
    log_groups = {
      test = { retention_in_days = 0 }
    }
  }

  expect_failures = [var.log_groups]
}

run "expect_failure_retention_invalid_value" {
  command = plan

  variables {
    log_groups = {
      test = { retention_in_days = 47 }
    }
  }

  expect_failures = [var.log_groups]
}

run "expect_failure_interface_endpoint_ids_without_vpc_id" {
  command = plan

  variables {
    interface_endpoint_ids = {
      logs = "vpce-0abc"
      kms  = "vpce-0def"
    }
    vpc_id = null
  }

  expect_failures = [var.interface_endpoint_ids]
}

run "expect_failure_bad_environment" {
  command = plan

  variables {
    environment = "production"
  }

  expect_failures = [var.environment]
}

run "expect_failure_bad_data_classification" {
  command = plan

  variables {
    data_classification = "secret"
  }

  expect_failures = [var.data_classification]
}
