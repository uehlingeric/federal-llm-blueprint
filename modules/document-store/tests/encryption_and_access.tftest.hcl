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

# Mocked apply so computed cross-references (bucket ids feeding logging targets)
# resolve to concrete values — same pattern as ecs-llm-gateway hardening test.
run "encryption_and_access_checks" {
  command = apply

  # Documents bucket: SSE-KMS with the data CMK and bucket keys enabled
  assert {
    condition = anytrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.documents.rule :
      anytrue([
        for d in r.apply_server_side_encryption_by_default :
        d.sse_algorithm == "aws:kms" && d.kms_master_key_id == var.data_kms_key_arn
      ]) && r.bucket_key_enabled
    ])
    error_message = "Documents bucket must default to SSE-KMS with the data CMK and bucket_key_enabled"
  }

  # Log buckets: SSE-S3 (AES256) — S3/ELB log delivery reject SSE-KMS targets
  assert {
    condition = anytrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.access_logs.rule :
      anytrue([for d in r.apply_server_side_encryption_by_default : d.sse_algorithm == "AES256"])
    ])
    error_message = "Access-logs bucket must default to SSE-S3 (AES256)"
  }

  assert {
    condition = anytrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.alb_logs.rule :
      anytrue([for d in r.apply_server_side_encryption_by_default : d.sse_algorithm == "AES256"])
    ])
    error_message = "ALB-logs bucket must default to SSE-S3 (AES256)"
  }

  # Public access block: all four settings true on all three buckets
  assert {
    condition = alltrue([
      for pab in [
        aws_s3_bucket_public_access_block.documents,
        aws_s3_bucket_public_access_block.access_logs,
        aws_s3_bucket_public_access_block.alb_logs,
      ] :
      pab.block_public_acls && pab.block_public_policy && pab.ignore_public_acls && pab.restrict_public_buckets
    ])
    error_message = "All three buckets must have all four public-access-block settings enabled"
  }

  # Versioning enabled on all three buckets
  assert {
    condition = alltrue([
      for v in [
        aws_s3_bucket_versioning.documents,
        aws_s3_bucket_versioning.access_logs,
        aws_s3_bucket_versioning.alb_logs,
      ] :
      anytrue([for c in v.versioning_configuration : c.status == "Enabled"])
    ])
    error_message = "All three buckets must have versioning enabled"
  }

  # Documents server-access logging targets the access-logs bucket under documents/
  assert {
    condition     = aws_s3_bucket_logging.documents.target_bucket == aws_s3_bucket.access_logs.id
    error_message = "Documents bucket must log to the access-logs bucket"
  }

  assert {
    condition     = aws_s3_bucket_logging.documents.target_prefix == "documents/"
    error_message = "Documents access logging must use the documents/ prefix"
  }

  # Object lock stays off by default (no lock configuration resource)
  assert {
    condition     = aws_s3_bucket.documents.object_lock_enabled == false && length(aws_s3_bucket_object_lock_configuration.documents) == 0
    error_message = "Object lock must be disabled by default"
  }
}
