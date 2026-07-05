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
  project               = "fedllm"
  environment           = "dev"
  data_classification   = "cui"
  tags                  = {}
  logs_kms_key_arn      = "arn:aws:kms:us-east-1:123456789012:key/12345678-aaaa-bbbb-cccc-dddddddddddd"
  alarm_email_addresses = ["ops@example.com", "security@example.com"]
  log_groups = {
    gateway = { retention_in_days = 365 }
    app     = { retention_in_days = 90 }
  }
}

run "topic_and_factory_check" {
  command = apply

  # SNS topic kms_master_key_id must match logs_kms_key_arn
  assert {
    condition     = aws_sns_topic.alarms.kms_master_key_id == var.logs_kms_key_arn
    error_message = "SNS topic must use logs_kms_key_arn for encryption"
  }

  # Subscription count must match alarm_email_addresses input
  assert {
    condition     = length(aws_sns_topic_subscription.alarm_emails) == length(var.alarm_email_addresses)
    error_message = "SNS subscriptions count must match alarm_email_addresses"
  }

  # Factory: verify log group names
  assert {
    condition     = aws_cloudwatch_log_group.this["gateway"].name == "/aws/fedllm-dev/gateway"
    error_message = "Gateway log group name must be /aws/fedllm-dev/gateway"
  }

  assert {
    condition     = aws_cloudwatch_log_group.this["app"].name == "/aws/fedllm-dev/app"
    error_message = "App log group name must be /aws/fedllm-dev/app"
  }

  # Factory: verify retention values
  assert {
    condition     = aws_cloudwatch_log_group.this["gateway"].retention_in_days == 365
    error_message = "Gateway log group retention must be 365 days"
  }

  assert {
    condition     = aws_cloudwatch_log_group.this["app"].retention_in_days == 90
    error_message = "App log group retention must be 90 days"
  }

  # Factory: verify KMS encryption on all log groups
  assert {
    condition = alltrue([
      for group in aws_cloudwatch_log_group.this :
      group.kms_key_id == var.logs_kms_key_arn
    ])
    error_message = "All log groups must be encrypted with logs_kms_key_arn"
  }
}
