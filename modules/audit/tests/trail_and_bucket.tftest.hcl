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

run "trail_and_bucket_checks" {
  command = apply

  # CloudTrail: multi-region, global events, log-file validation
  assert {
    condition     = aws_cloudtrail.this.is_multi_region_trail == true
    error_message = "Trail must be multi-region"
  }

  assert {
    condition     = aws_cloudtrail.this.include_global_service_events == true
    error_message = "Trail must include global service events"
  }

  assert {
    condition     = aws_cloudtrail.this.enable_log_file_validation == true
    error_message = "Trail must have log-file validation enabled"
  }

  assert {
    condition     = aws_cloudtrail.this.kms_key_id == var.logs_kms_key_arn
    error_message = "Trail must use the logs KMS key"
  }

  assert {
    condition     = aws_cloudtrail.this.s3_key_prefix == "cloudtrail"
    error_message = "Trail must use cloudtrail/ prefix"
  }

  assert {
    condition     = aws_cloudtrail.this.enable_logging == true
    error_message = "Trail must have logging enabled"
  }

  # Advanced event selectors: management + documents data events
  assert {
    condition = anytrue([
      for sel in aws_cloudtrail.this.advanced_event_selector :
      anytrue([
        for fs in sel.field_selector :
        fs.field == "eventCategory" && contains(fs.equals, "Management")
      ])
    ])
    error_message = "Trail must have a management event selector"
  }

  assert {
    condition = anytrue([
      for sel in aws_cloudtrail.this.advanced_event_selector :
      anytrue([
        for fs in sel.field_selector :
        fs.field == "resources.ARN" && length(fs.starts_with) > 0 && strcontains(fs.starts_with[0], var.documents_bucket_arn)
      ])
    ])
    error_message = "Trail must have documents bucket ARN in a data event selector"
  }

  # Insight selectors: empty by default
  assert {
    condition     = length(aws_cloudtrail.this.insight_selector) == 0
    error_message = "Insight selectors must be empty by default"
  }

  # S3 Bucket: encryption with logs KMS key
  assert {
    condition = anytrue([
      for rule in aws_s3_bucket_server_side_encryption_configuration.audit.rule :
      anytrue([
        for d in rule.apply_server_side_encryption_by_default :
        d.sse_algorithm == "aws:kms" && d.kms_master_key_id == var.logs_kms_key_arn
      ]) && rule.bucket_key_enabled
    ])
    error_message = "Audit bucket must use SSE-KMS with logs key and bucket_key_enabled"
  }

  # Versioning
  assert {
    condition = anytrue([
      for cfg in aws_s3_bucket_versioning.audit.versioning_configuration :
      cfg.status == "Enabled"
    ])
    error_message = "Audit bucket must have versioning enabled"
  }

  # Public access block
  assert {
    condition     = aws_s3_bucket_public_access_block.audit.block_public_acls == true && aws_s3_bucket_public_access_block.audit.block_public_policy == true && aws_s3_bucket_public_access_block.audit.ignore_public_acls == true && aws_s3_bucket_public_access_block.audit.restrict_public_buckets == true
    error_message = "Audit bucket must have all four public-access-block settings enabled"
  }

  # Server access logging
  assert {
    condition     = aws_s3_bucket_logging.audit.target_bucket == var.access_logs_bucket_id
    error_message = "Audit bucket must log to the access-logs bucket"
  }

  assert {
    condition     = aws_s3_bucket_logging.audit.target_prefix == "audit/"
    error_message = "Audit bucket logging must use audit/ prefix"
  }

  # Object lock
  assert {
    condition     = aws_s3_bucket.audit.object_lock_enabled == true && length(aws_s3_bucket_object_lock_configuration.audit) == 1
    error_message = "Audit bucket must have object lock enabled by default"
  }

  # Lifecycle expiration
  assert {
    condition = anytrue([
      for rule in aws_s3_bucket_lifecycle_configuration.audit.rule :
      rule.id == "expire-audit-logs" && rule.expiration[0].days == var.audit_log_expiration_days
    ])
    error_message = "Audit bucket lifecycle must expire logs after audit_log_expiration_days"
  }
}

run "trail_and_bucket_insights_disabled_by_default" {
  command = plan

  # Baseline: insights disabled
  assert {
    condition     = length(aws_cloudtrail.this.insight_selector) == 0
    error_message = "Insights must be empty by default (enable_insights=false)"
  }
}

run "trail_and_bucket_insights_enabled" {
  command = apply

  variables {
    enable_insights = true
  }

  # Enable insights: both types present
  assert {
    condition = anytrue([
      for sel in aws_cloudtrail.this.insight_selector :
      sel.insight_type == "ApiCallRateInsight"
      ]) && anytrue([
      for sel in aws_cloudtrail.this.insight_selector :
      sel.insight_type == "ApiErrorRateInsight"
    ])
    error_message = "Trail must have both ApiCallRateInsight and ApiErrorRateInsight when enable_insights=true"
  }
}
