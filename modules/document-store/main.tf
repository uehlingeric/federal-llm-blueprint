data "aws_caller_identity" "current" {}
data "aws_elb_service_account" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project            = var.project
    Environment        = var.environment
    ManagedBy          = "terraform"
    DataClassification = var.data_classification
  }

  documents_bucket_name   = "${local.name_prefix}-documents-${data.aws_caller_identity.current.account_id}"
  access_logs_bucket_name = "${local.name_prefix}-access-logs-${data.aws_caller_identity.current.account_id}"
  alb_logs_bucket_name    = "${local.name_prefix}-alb-logs-${data.aws_caller_identity.current.account_id}"
}

# ============================================================================
# Documents Bucket: SSE-KMS with data key + versioning + object lock (opt)
# ============================================================================

resource "aws_s3_bucket" "documents" {
  #checkov:skip=CKV_AWS_144: Single-region reference architecture; cross-region replication is a deployment decision documented in the module README.
  #checkov:skip=CKV2_AWS_62: No bucket event notification consumers exist; audit trail provided by CloudTrail data events (week-6 audit module).
  bucket = local.documents_bucket_name

  # Object lock must be declared at creation; the retention rule itself is the
  # count-guarded aws_s3_bucket_object_lock_configuration below.
  object_lock_enabled = var.enable_object_lock

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = local.documents_bucket_name
    }
  )
}

resource "aws_s3_bucket_versioning" "documents" {
  bucket = aws_s3_bucket.documents.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.data_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "documents" {
  bucket = aws_s3_bucket.documents.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "documents" {
  bucket = aws_s3_bucket.documents.id

  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "documents/"
}

resource "aws_s3_bucket_lifecycle_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  rule {
    id     = "documents-ia-transition"
    status = "Enabled"

    filter {}

    transition {
      days          = var.documents_ia_transition_days
      storage_class = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_days
    }
  }
}

resource "aws_s3_bucket_object_lock_configuration" "documents" {
  count = var.enable_object_lock ? 1 : 0

  bucket = aws_s3_bucket.documents.id

  rule {
    default_retention {
      mode = var.object_lock_mode
      days = var.object_lock_retention_days
    }
  }
}

resource "aws_s3_bucket_inventory" "documents" {
  count = var.enable_inventory ? 1 : 0

  bucket = aws_s3_bucket.documents.id
  name   = "documents-weekly-inventory"

  included_object_versions = "Current"

  schedule {
    frequency = "Weekly"
  }

  destination {
    bucket {
      format     = "CSV"
      bucket_arn = aws_s3_bucket.access_logs.arn
      prefix     = "inventory/"

      encryption {
        sse_kms {
          key_id = var.data_kms_key_arn
        }
      }
    }
  }

  optional_fields = ["Size", "StorageClass", "LastModifiedDate", "ETag", "IsMultipartUploaded", "ReplicationStatus"]

  depends_on = [aws_s3_bucket_public_access_block.documents]
}

resource "aws_s3_bucket_analytics_configuration" "documents" {
  count = var.enable_analytics ? 1 : 0

  bucket = aws_s3_bucket.documents.id
  name   = "documents-storage-class-analysis"

  storage_class_analysis {
    data_export {
      output_schema_version = "V_1"

      destination {
        s3_bucket_destination {
          bucket_arn = aws_s3_bucket.access_logs.arn
          prefix     = "analytics/"
        }
      }
    }
  }
}

# ============================================================================
# Access Logs Bucket: SSE-S3 (platform constraint: S3 log delivery no SSE-KMS)
# ============================================================================

resource "aws_s3_bucket" "access_logs" {
  #checkov:skip=CKV_AWS_145: S3 server-access-log delivery does NOT support SSE-KMS target buckets. AWS platform constraint: ELB/ALB/S3 log-delivery services reject KMS-encrypted destinations. SSE-S3 (AES256) is the only supported encryption for log buckets receiving aws:logging.s3.amazonaws.com writes.
  #checkov:skip=CKV_AWS_18: Access logs bucket exists to store logs from documents and ALB; logging this bucket would create infinite recursion. The documents bucket (above) has comprehensive access logging and encryption; audit of access to this logs bucket is provided by CloudTrail data events (week-6 audit module). Standard logs-of-logs termination reasoning applies: finite regress requires audit trail delegation to higher-level service (CloudTrail data events).
  #checkov:skip=CKV_AWS_144: Single-region reference architecture; cross-region replication is a deployment decision documented in the module README.
  #checkov:skip=CKV2_AWS_62: No bucket event notification consumers exist; audit trail provided by CloudTrail data events (week-6 audit module).
  bucket = local.access_logs_bucket_name

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = local.access_logs_bucket_name
    }
  )
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_expiration_days
    }
  }

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_days
    }
  }
}

# ============================================================================
# ALB Logs Bucket: SSE-S3 (ELB log delivery constraint)
# ============================================================================

resource "aws_s3_bucket" "alb_logs" {
  #checkov:skip=CKV_AWS_145: ELB/ALB access-log delivery supports ONLY SSE-S3 (AES256); any SSE-KMS target (regardless of key) is rejected by the log-delivery service. AWS platform constraint, not a security shortcut.
  #checkov:skip=CKV_AWS_18: ALB logs bucket is a log destination; logging itself would create infinite recursion. Audit trail for this bucket is provided by CloudTrail data events (week-6 audit module). Standard logs-of-logs termination reasoning applies.
  #checkov:skip=CKV_AWS_144: Single-region reference architecture; cross-region replication is a deployment decision documented in the module README.
  #checkov:skip=CKV2_AWS_62: No bucket event notification consumers exist; audit trail provided by CloudTrail data events (week-6 audit module).
  bucket = local.alb_logs_bucket_name

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = local.alb_logs_bucket_name
    }
  )
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_expiration_days
    }
  }

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_days
    }
  }
}

# ============================================================================
# Bucket Policies: TLS-only deny + service principals
# ============================================================================

# Documents bucket: TLS-only + SSE-KMS enforcement
data "aws_iam_policy_document" "documents" {
  statement {
    sid    = "DenyUnencryptedTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.documents.arn,
      "${aws_s3_bucket.documents.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Downgrade denies fire only when the header is PRESENT and wrong (Null = false).
  # A PutObject with no encryption headers gets the bucket default (SSE-KMS with the
  # data CMK) and must NOT be denied; StringNotEquals alone matches absent keys.
  statement {
    sid    = "DenyExplicitlyUnencryptedPutObject"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.documents.arn}/*"]

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid    = "DenyWrongKmsKey"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.documents.arn}/*"]

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = ["false"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [var.data_kms_key_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "documents" {
  bucket = aws_s3_bucket.documents.id
  policy = data.aws_iam_policy_document.documents.json
}

# Access logs bucket: TLS-only + allow S3 logging service
data "aws_iam_policy_document" "access_logs" {
  statement {
    sid    = "DenyUnencryptedTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.access_logs.arn,
      "${aws_s3_bucket.access_logs.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AllowS3LoggingServicePutObject"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.access_logs.arn}/documents/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # Inventory and storage-class-analysis exports are delivered by s3.amazonaws.com
  # (a different principal than server-access-log delivery), scoped to their prefixes
  # and to exports originating from the documents bucket in this account.
  statement {
    sid    = "AllowS3InventoryAndAnalyticsExport"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.access_logs.arn}/inventory/*",
      "${aws_s3_bucket.access_logs.arn}/analytics/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.documents.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  policy = data.aws_iam_policy_document.access_logs.json
}

# ALB logs bucket: TLS-only + allow ELB service
data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid    = "DenyUnencryptedTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.alb_logs.arn,
      "${aws_s3_bucket.alb_logs.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AllowELBServicePutObject"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.current.arn]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/${var.alb_logs_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = data.aws_iam_policy_document.alb_logs.json
}
