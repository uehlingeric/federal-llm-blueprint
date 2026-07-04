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

run "lifecycle_defaults" {
  command = plan

  # Documents: STANDARD_IA transition and noncurrent-version expiration wired to variables
  assert {
    condition = anytrue([
      for r in aws_s3_bucket_lifecycle_configuration.documents.rule :
      anytrue([
        for t in r.transition :
        t.days == var.documents_ia_transition_days && t.storage_class == "STANDARD_IA"
      ])
    ])
    error_message = "Documents lifecycle must transition to STANDARD_IA at documents_ia_transition_days"
  }

  assert {
    condition = anytrue([
      for r in aws_s3_bucket_lifecycle_configuration.documents.rule :
      anytrue([
        for n in r.noncurrent_version_expiration :
        n.noncurrent_days == var.noncurrent_version_expiration_days
      ])
    ])
    error_message = "Documents lifecycle must expire noncurrent versions at noncurrent_version_expiration_days"
  }

  # Both log buckets expire logs at log_expiration_days
  assert {
    condition = alltrue([
      for lc in [
        aws_s3_bucket_lifecycle_configuration.access_logs,
        aws_s3_bucket_lifecycle_configuration.alb_logs,
      ] :
      anytrue([
        for r in lc.rule :
        anytrue([for e in r.expiration : e.days == var.log_expiration_days])
      ])
    ])
    error_message = "Log buckets must expire objects at log_expiration_days"
  }

  # All three buckets abort incomplete multipart uploads
  assert {
    condition = alltrue([
      for lc in [
        aws_s3_bucket_lifecycle_configuration.documents,
        aws_s3_bucket_lifecycle_configuration.access_logs,
        aws_s3_bucket_lifecycle_configuration.alb_logs,
      ] :
      anytrue([
        for r in lc.rule :
        anytrue([
          for a in r.abort_incomplete_multipart_upload :
          a.days_after_initiation == var.abort_incomplete_multipart_days
        ])
      ])
    ])
    error_message = "All buckets must abort incomplete multipart uploads at abort_incomplete_multipart_days"
  }

  # Inventory/analytics stay off by default
  assert {
    condition     = length(aws_s3_bucket_inventory.documents) == 0 && length(aws_s3_bucket_analytics_configuration.documents) == 0
    error_message = "Inventory and analytics must be disabled by default"
  }
}

run "object_lock_enabled" {
  command = plan

  variables {
    enable_object_lock = true
  }

  assert {
    condition     = aws_s3_bucket.documents.object_lock_enabled == true
    error_message = "enable_object_lock must set object_lock_enabled on the documents bucket"
  }

  assert {
    condition = anytrue([
      for r in aws_s3_bucket_object_lock_configuration.documents[0].rule :
      anytrue([
        for d in r.default_retention :
        d.mode == var.object_lock_mode && d.days == var.object_lock_retention_days
      ])
    ])
    error_message = "Object lock configuration must use the configured mode and retention days"
  }
}

run "inventory_enabled_plan_succeeds" {
  command = plan

  variables {
    enable_inventory = true
  }

  assert {
    condition     = length(aws_s3_bucket_inventory.documents) == 1
    error_message = "enable_inventory must create the inventory configuration"
  }
}

run "analytics_enabled_plan_succeeds" {
  command = plan

  variables {
    enable_analytics = true
  }

  assert {
    condition     = length(aws_s3_bucket_analytics_configuration.documents) == 1
    error_message = "enable_analytics must create the analytics configuration"
  }
}

run "all_optional_features_enabled" {
  command = plan

  variables {
    enable_object_lock = true
    enable_inventory   = true
    enable_analytics   = true
  }
}
