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
  enable_bedrock_invocation_logging = true
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

run "config_and_bedrock_checks" {
  command = apply

  # Config recorder: all_supported + global resources
  assert {
    condition     = aws_config_configuration_recorder.this.recording_group[0].all_supported == true
    error_message = "Config recorder must have all_supported enabled"
  }

  assert {
    condition     = aws_config_configuration_recorder.this.recording_group[0].include_global_resource_types == var.include_global_resource_types
    error_message = "Config recorder must respect include_global_resource_types"
  }

  # Config delivery channel: S3 KMS key set
  assert {
    condition     = aws_config_delivery_channel.this.s3_kms_key_arn == var.logs_kms_key_arn
    error_message = "Config delivery channel must use logs KMS key"
  }

  # Config rules: exactly 10 rules
  assert {
    condition     = length(aws_config_config_rule.rules) == 10
    error_message = "Must have exactly 10 Config rules"
  }

  # Config rules: every description starts with "Aligns to NIST 800-53"
  assert {
    condition = alltrue([
      for rule in aws_config_config_rule.rules :
      startswith(rule.description, "Aligns to NIST 800-53")
    ])
    error_message = "Every Config rule description must start with 'Aligns to NIST 800-53'"
  }

  # Config rules: spot-check source identifiers
  assert {
    condition = anytrue([
      for rule in aws_config_config_rule.rules :
      rule.source[0].source_identifier == "ENCRYPTED_VOLUMES"
    ])
    error_message = "Must have encrypted-volumes rule"
  }

  assert {
    condition = anytrue([
      for rule in aws_config_config_rule.rules :
      rule.source[0].source_identifier == "S3_BUCKET_SSL_REQUESTS_ONLY"
    ])
    error_message = "Must have s3-bucket-ssl-requests-only rule"
  }

  # Bedrock logging: enabled by default, metadata-only
  assert {
    condition     = length(aws_cloudwatch_log_group.bedrock) == 1
    error_message = "Bedrock log group must be created when enable_bedrock_invocation_logging=true"
  }

  assert {
    condition = anytrue([
      for cfg in aws_bedrock_model_invocation_logging_configuration.this :
      cfg.logging_config[0].text_data_delivery_enabled == false && cfg.logging_config[0].image_data_delivery_enabled == false && cfg.logging_config[0].embedding_data_delivery_enabled == false
    ])
    error_message = "Bedrock logging must be metadata-only by default (enable_full_content_logging=false)"
  }
}

run "bedrock_full_content_logging" {
  command = apply

  variables {
    enable_bedrock_invocation_logging = true
    enable_full_content_logging       = true
  }

  # Enable full content: delivery flags flip
  assert {
    condition = anytrue([
      for cfg in aws_bedrock_model_invocation_logging_configuration.this :
      cfg.logging_config[0].text_data_delivery_enabled == true && cfg.logging_config[0].image_data_delivery_enabled == true && cfg.logging_config[0].embedding_data_delivery_enabled == true
    ])
    error_message = "Bedrock logging must deliver full content when enable_full_content_logging=true"
  }
}

run "bedrock_disabled" {
  command = plan

  variables {
    enable_bedrock_invocation_logging = false
  }

  # Disable bedrock: no resources created
  assert {
    condition     = length(aws_cloudwatch_log_group.bedrock) == 0 && length(aws_bedrock_model_invocation_logging_configuration.this) == 0
    error_message = "Bedrock resources must not be created when enable_bedrock_invocation_logging=false"
  }
}
