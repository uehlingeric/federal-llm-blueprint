data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix       = "${var.project}-${var.environment}"
  audit_bucket_name = "${local.name_prefix}-audit-logs-${data.aws_caller_identity.current.account_id}"
  trail_name        = "${local.name_prefix}-trail"
  # Trail ARN is constructed (not a resource attribute) because the bucket policy
  # and CloudTrail-to-CloudWatch role trust policy must exist BEFORE the trail is created —
  # CloudTrail validates them at creation.
  trail_arn = "arn:${data.aws_partition.current.partition}:cloudtrail:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:trail/${local.trail_name}"

  common_tags = {
    Project            = var.project
    Environment        = var.environment
    ManagedBy          = "terraform"
    DataClassification = var.data_classification
  }
}

# ============================================================================
# Audit Bucket: SSE-KMS with object lock, versioning, and access logging
# ============================================================================

resource "aws_s3_bucket" "audit" {
  #checkov:skip=CKV_AWS_144: Single-region reference architecture; cross-region replication is a deployment decision.
  #checkov:skip=CKV2_AWS_62: No event-notification consumers exist; this bucket is a log-delivery destination. Enabling CloudTrail data events on it would recurse. Tamper evidence comes from object lock + log-file validation.
  bucket              = local.audit_bucket_name
  object_lock_enabled = var.enable_object_lock

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = local.audit_bucket_name
    }
  )
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.logs_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

# CloudTrail and Config log delivery DO support SSE-KMS destinations, unlike
# S3 server-access-log / ELB delivery — the logs CMK encrypts the bucket and
# every delivery into it.

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket = aws_s3_bucket.audit.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "audit" {
  bucket = aws_s3_bucket.audit.id

  target_bucket = var.access_logs_bucket_id
  target_prefix = "audit/"
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "expire-audit-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.audit_log_expiration_days
    }

    # Versioned bucket: expiration only creates delete markers; without this,
    # noncurrent versions accumulate indefinitely.
    noncurrent_version_expiration {
      noncurrent_days = var.audit_log_expiration_days
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

resource "aws_s3_bucket_object_lock_configuration" "audit" {
  count = var.enable_object_lock ? 1 : 0

  bucket = aws_s3_bucket.audit.id

  rule {
    default_retention {
      mode = var.object_lock_mode
      days = var.object_lock_retention_days
    }
  }
}

# ============================================================================
# Audit Bucket Policy: CloudTrail, Config, and Bedrock write access
# ============================================================================

data "aws_iam_policy_document" "audit_bucket" {
  statement {
    sid    = "DenyUnencryptedTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.audit.arn,
      "${aws_s3_bucket.audit.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.audit.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/cloudtrail/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid    = "AWSConfigBucketPermissionsCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.audit.arn]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "AWSConfigBucketExistenceCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.audit.arn]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "AWSConfigWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/config/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  dynamic "statement" {
    for_each = var.enable_bedrock_invocation_logging ? [1] : []
    content {
      sid    = "AWSBedrockLogsWrite"
      effect = "Allow"
      principals {
        type        = "Service"
        identifiers = ["bedrock.amazonaws.com"]
      }
      actions = ["s3:PutObject"]
      # Wider than the documented AWSLogs/{account}/BedrockModelInvocationLogs/*
      # example: large-data delivery writes oversize payloads under a separate
      # data prefix within the key_prefix, and the docs don't pin its shape.
      # SourceAccount + SourceArn still constrain the writer.
      resources = ["${aws_s3_bucket.audit.arn}/bedrock/*"]

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }

      condition {
        test     = "ArnLike"
        variable = "aws:SourceArn"
        values   = ["arn:${data.aws_partition.current.partition}:bedrock:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"]
      }
    }
  }
}

# NO SSE-downgrade-deny statements here (unlike the documents bucket) —
# CloudTrail/Config/Bedrock set their own encryption context; denies keyed on
# client headers would break service delivery. Default bucket encryption +
# per-service KMS cover at-rest protection.

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = data.aws_iam_policy_document.audit_bucket.json
}

# ============================================================================
# CloudTrail → CloudWatch Logs
# ============================================================================

resource "aws_cloudwatch_log_group" "trail" {
  name              = "/aws/${local.name_prefix}/cloudtrail"
  retention_in_days = var.trail_log_retention_days
  kms_key_id        = var.logs_kms_key_arn

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-cloudtrail-logs"
    }
  )
}

data "aws_iam_policy_document" "cloudtrail_to_cwl_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

resource "aws_iam_role" "cloudtrail_to_cwl" {
  name_prefix        = "${local.name_prefix}-cloudtrail-logs-"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_to_cwl_trust.json
  description        = "Role for CloudTrail to deliver logs to CloudWatch Logs"

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-cloudtrail-logs"
    }
  )
}

data "aws_iam_policy_document" "cloudtrail_cwl_policy" {
  statement {
    sid    = "CloudTrailCreateLogStream"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.trail.arn}:log-stream:*"]
  }
}

resource "aws_iam_role_policy" "cloudtrail_cwl_policy" {
  name_prefix = "${local.name_prefix}-cloudtrail-cwl-"
  role        = aws_iam_role.cloudtrail_to_cwl.id
  policy      = data.aws_iam_policy_document.cloudtrail_cwl_policy.json
}

# Service-assumed role deliberately OUTSIDE the iam-module permission boundary:
# it is assumed by cloudtrail.amazonaws.com, not by workload identities, and the
# boundary does not ceiling logs delivery (enhanced-monitoring precedent in
# vector-store).

# ============================================================================
# CloudTrail
# ============================================================================

resource "aws_cloudtrail" "this" {
  #checkov:skip=CKV_AWS_252: SNS notifications are noise; trail health is monitored by CloudTrail-tamper metric-filter alarm in the observability module.
  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.audit.id
  s3_key_prefix                 = "cloudtrail"
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = var.logs_kms_key_arn
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.trail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail_to_cwl.arn
  enable_logging                = true

  depends_on = [aws_s3_bucket_policy.audit]

  # Management events: all control plane API calls
  advanced_event_selector {
    name = "Management events"
    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  # Data events: object-level read/write on documents bucket (CUI access trail)
  # Data events bill per event recorded (cost toggle).
  advanced_event_selector {
    name = "Documents bucket object-level events"
    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }
    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }
    field_selector {
      field       = "resources.ARN"
      starts_with = ["${var.documents_bucket_arn}/"]
    }
  }

  # CloudTrail Insights: per-event analysis charges (cost toggle).
  dynamic "insight_selector" {
    for_each = var.enable_insights ? [1] : []
    content {
      insight_type = "ApiCallRateInsight"
    }
  }

  dynamic "insight_selector" {
    for_each = var.enable_insights ? [1] : []
    content {
      insight_type = "ApiErrorRateInsight"
    }
  }

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = local.trail_name
    }
  )
}

# ============================================================================
# AWS Config
# ============================================================================

resource "aws_iam_service_linked_role" "config" {
  aws_service_name = "config.amazonaws.com"
}

resource "aws_config_configuration_recorder" "this" {
  name     = "${local.name_prefix}-config"
  role_arn = aws_iam_service_linked_role.config.arn
  recording_group {
    all_supported                 = true
    include_global_resource_types = var.include_global_resource_types
  }

  # Cost comment: the recorder bills per configuration item recorded.
}

resource "aws_config_delivery_channel" "this" {
  name           = "${local.name_prefix}-config"
  s3_bucket_name = aws_s3_bucket.audit.id
  s3_key_prefix  = "config"
  s3_kms_key_arn = var.logs_kms_key_arn

  snapshot_delivery_properties {
    delivery_frequency = var.config_snapshot_frequency
  }

  depends_on = [
    aws_config_configuration_recorder.this,
    aws_s3_bucket_policy.audit,
  ]
}

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.this]
}

# 800-53 annotations are in local.config_rules (harvested by the week-7 compliance mapping).
locals {
  config_rules = {
    encrypted-volumes = {
      identifier  = "ENCRYPTED_VOLUMES"
      controls    = ["SC-28", "SC-28(1)"]
      description = "Aligns to NIST 800-53 SC-28, SC-28(1): Encrypts EBS volumes at rest with customer-managed keys."
    }
    rds-storage-encrypted = {
      identifier  = "RDS_STORAGE_ENCRYPTED"
      controls    = ["SC-28(1)"]
      description = "Aligns to NIST 800-53 SC-28(1): Encrypts RDS database storage at rest with customer-managed keys."
    }
    rds-instance-public-access-check = {
      identifier  = "RDS_INSTANCE_PUBLIC_ACCESS_CHECK"
      controls    = ["AC-3", "SC-7"]
      description = "Aligns to NIST 800-53 AC-3, SC-7: Prevents public accessibility of RDS instances; enforces private network isolation."
    }
    s3-bucket-public-read-prohibited = {
      identifier  = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
      controls    = ["AC-3", "SC-7"]
      description = "Aligns to NIST 800-53 AC-3, SC-7: Prevents public read access to S3 buckets; enforces access control."
    }
    s3-bucket-public-write-prohibited = {
      identifier  = "S3_BUCKET_PUBLIC_WRITE_PROHIBITED"
      controls    = ["AC-3", "SC-7"]
      description = "Aligns to NIST 800-53 AC-3, SC-7: Prevents public write access to S3 buckets; enforces data integrity."
    }
    s3-bucket-ssl-requests-only = {
      identifier  = "S3_BUCKET_SSL_REQUESTS_ONLY"
      controls    = ["SC-8", "SC-8(1)"]
      description = "Aligns to NIST 800-53 SC-8, SC-8(1): Encrypts S3 traffic in transit with TLS; enforces confidentiality."
    }
    cloud-trail-log-file-validation-enabled = {
      identifier  = "CLOUD_TRAIL_LOG_FILE_VALIDATION_ENABLED"
      controls    = ["AU-9"]
      description = "Aligns to NIST 800-53 AU-9: Enables CloudTrail log-file validation; enforces log integrity and tamper evidence."
    }
    iam-policy-no-statements-with-admin-access = {
      identifier  = "IAM_POLICY_NO_STATEMENTS_WITH_ADMIN_ACCESS"
      controls    = ["AC-6"]
      description = "Aligns to NIST 800-53 AC-6: Prevents overly-permissive IAM policies; enforces least-privilege."
    }
    restricted-ssh = {
      identifier  = "INCOMING_SSH_DISABLED"
      controls    = ["SC-7", "AC-17"]
      description = "Aligns to NIST 800-53 SC-7, AC-17: Disables unrestricted inbound SSH; enforces remote access boundaries."
    }
    cmk-backing-key-rotation-enabled = {
      identifier  = "CMK_BACKING_KEY_ROTATION_ENABLED"
      controls    = ["SC-12"]
      description = "Aligns to NIST 800-53 SC-12: Enables automatic KMS key rotation; enforces key management practices."
    }
  }
}

resource "aws_config_config_rule" "rules" {
  for_each = local.config_rules

  name = "${local.name_prefix}-${each.key}"
  source {
    owner             = "AWS"
    source_identifier = each.value.identifier
  }
  description = each.value.description
  depends_on  = [aws_config_configuration_recorder_status.this]

  tags = merge(
    local.common_tags,
    var.tags,
    {
      # Space-separated, enhancement ids in the dotted OSCAL form (SC-8.1,
      # not SC-8(1)): PutConfigRule validates tag values against the
      # restricted AWS charset (letters, numbers, spaces, _ . : / = + - @),
      # rejecting both commas and parentheses with
      # InvalidParameterValueException
      Nist80053Controls = join(" ", [for c in each.value.controls : replace(replace(c, "(", "."), ")", "")])
    }
  )
}

# ============================================================================
# Bedrock Model-Invocation Logging (count-guarded)
# ============================================================================

resource "aws_cloudwatch_log_group" "bedrock" {
  count             = var.enable_bedrock_invocation_logging ? 1 : 0
  name              = "/aws/${local.name_prefix}/bedrock-invocations"
  retention_in_days = var.bedrock_log_retention_days
  kms_key_id        = var.logs_kms_key_arn

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-bedrock-invocations"
    }
  )
}

data "aws_iam_policy_document" "bedrock_logging_trust" {
  count = var.enable_bedrock_invocation_logging ? 1 : 0

  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:bedrock:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "bedrock_logging" {
  count              = var.enable_bedrock_invocation_logging ? 1 : 0
  name_prefix        = "${local.name_prefix}-bedrock-logging-"
  assume_role_policy = data.aws_iam_policy_document.bedrock_logging_trust[0].json
  description        = "Role for Bedrock to deliver model-invocation logs to CloudWatch Logs and S3"

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-bedrock-logging"
    }
  )
}

data "aws_iam_policy_document" "bedrock_logging_policy" {
  count = var.enable_bedrock_invocation_logging ? 1 : 0

  statement {
    sid    = "BedrockCreateLogStream"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    # Bedrock writes invocation logs to exactly this stream name (documented in
    # the invocation-logging setup guide) — no wildcard needed.
    resources = ["${aws_cloudwatch_log_group.bedrock[0].arn}:log-stream:aws/bedrock/modelinvocations"]
  }
}

resource "aws_iam_role_policy" "bedrock_logging_policy" {
  count       = var.enable_bedrock_invocation_logging ? 1 : 0
  name_prefix = "${local.name_prefix}-bedrock-logging-"
  role        = aws_iam_role.bedrock_logging[0].id
  policy      = data.aws_iam_policy_document.bedrock_logging_policy[0].json
}

# Service-assumed role deliberately OUTSIDE the iam-module permission boundary:
# it is assumed by bedrock.amazonaws.com, not by workload identities, and the
# boundary does not ceiling logs delivery.

resource "aws_bedrock_model_invocation_logging_configuration" "this" {
  count = var.enable_bedrock_invocation_logging ? 1 : 0

  logging_config {
    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.bedrock[0].name
      role_arn       = aws_iam_role.bedrock_logging[0].arn

      large_data_delivery_s3_config {
        bucket_name = aws_s3_bucket.audit.id
        key_prefix  = "bedrock"
      }
    }

    # Default: metadata-only (prompt/response bodies excluded).
    # Set enable_full_content_logging to true to capture full payloads.
    # See ADR-007 (docs/adr/007-prompt-capture-posture.md).
    text_data_delivery_enabled      = var.enable_full_content_logging
    image_data_delivery_enabled     = var.enable_full_content_logging
    embedding_data_delivery_enabled = var.enable_full_content_logging
    video_data_delivery_enabled     = var.enable_full_content_logging
  }
}
