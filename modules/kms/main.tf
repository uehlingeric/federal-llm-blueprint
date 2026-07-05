data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project            = var.project
    Environment        = var.environment
    ManagedBy          = "terraform"
    DataClassification = var.data_classification
  }
}

# Per-domain KMS CMK
resource "aws_kms_key" "this" {
  for_each = var.domains

  description             = each.value.description
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.key_policy[each.key].json

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-${each.key}"
    }
  )
}

# Per-domain KMS key policy
data "aws_iam_policy_document" "key_policy" {
  for_each = var.domains

  # Statement 1: Enable IAM user permissions (required root access)
  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]

    # These checks misfire on key policies where Resource "*" scopes to this key only
    # (resource-policy semantics, not IAM), and root access is the documented AWS pattern
    # to prevent key lockout and allow IAM policies to grant access.
    #checkov:skip=CKV_AWS_109: Resource "*" in a key policy scopes to this key; root statement prevents key lockout
    #checkov:skip=CKV_AWS_111: Resource "*" in a key policy scopes to this key; root statement prevents key lockout
    #checkov:skip=CKV_AWS_356: Resource "*" in a key policy scopes to this key by definition
  }

  # Statement 2: Key Administration (only when key_admin_principal_arns is non-empty)
  # Admins manage the key but do not have crypto permissions. The action-family
  # wildcards below mirror the AWS-documented key-administrators statement
  # (docs: "Allows key administrators to administer the KMS key") — a justified
  # exception to the no-wildcard-actions rule in docs/conventions.md.
  dynamic "statement" {
    for_each = length(var.key_admin_principal_arns) > 0 ? [1] : []
    content {
      sid    = "KeyAdministration"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = var.key_admin_principal_arns
      }

      actions = [
        "kms:Create*",
        "kms:Describe*",
        "kms:Enable*",
        "kms:List*",
        "kms:Put*",
        "kms:Update*",
        "kms:Revoke*",
        "kms:Disable*",
        "kms:Get*",
        "kms:Delete*",
        "kms:TagResource",
        "kms:UntagResource",
        "kms:ScheduleKeyDeletion",
        "kms:CancelKeyDeletion"
      ]

      resources = ["*"]

      # Admins manage but do NOT perform cryptographic operations (Encrypt, Decrypt, GenerateDataKey).
    }
  }

  # Statement 3a: AllowServiceUse for domains with via_services configured
  # Services use the key via kms:ViaService condition (where applicable).
  dynamic "statement" {
    for_each = length(each.value.via_services) > 0 ? [1] : []
    content {
      sid    = "AllowServiceUse"
      effect = "Allow"

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey"
      ]

      resources = ["*"]

      # Restrict to calls via the specified services and to this account only.
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = [for svc in each.value.via_services : "${svc}.${data.aws_region.current.region}.amazonaws.com"]
      }

      condition {
        test     = "StringEquals"
        variable = "kms:CallerAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }

  # Statement 3b: CreateGrant permissions (only for domains with via_services)
  # Services that need grants to delegate key usage (ECS, RDS, etc.).
  dynamic "statement" {
    for_each = length(each.value.via_services) > 0 ? [1] : []
    content {
      sid    = "AllowCreateGrant"
      effect = "Allow"

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      actions = ["kms:CreateGrant"]

      resources = ["*"]

      condition {
        test     = "Bool"
        variable = "kms:GrantIsForAWSResource"
        values   = ["true"]
      }

      condition {
        test     = "StringEquals"
        variable = "kms:CallerAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }

  # Statement 4: CloudWatch Logs service principal (logs domain only)
  # CloudWatch Logs service requires ArnLike condition on aws:logs:arn for encryption context.
  dynamic "statement" {
    for_each = each.key == "logs" ? [1] : []
    content {
      sid    = "AllowCloudWatchLogs"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
      }

      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:CreateGrant",
        "kms:DescribeKey"
      ]

      resources = ["*"]

      condition {
        test     = "ArnLike"
        variable = "kms:EncryptionContext:aws:logs:arn"
        values   = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"]
      }
    }
  }

  # Statement 5: CloudTrail log-file encryption (logs domain only)
  # Per the CloudTrail KMS docs: GenerateDataKey* gated on the aws:cloudtrail:arn
  # encryption context plus a SourceArn scoped to this account's trails in this
  # region. The trail name is not known to this module, so the trail wildcard is
  # the narrowest expressible scope.
  dynamic "statement" {
    for_each = each.key == "logs" ? [1] : []
    content {
      sid    = "AllowCloudTrailEncrypt"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["cloudtrail.amazonaws.com"]
      }

      actions = [
        "kms:GenerateDataKey*",
        "kms:DescribeKey"
      ]

      resources = ["*"]

      condition {
        test     = "StringLike"
        variable = "kms:EncryptionContext:aws:cloudtrail:arn"
        values   = ["arn:${data.aws_partition.current.partition}:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"]
      }

      condition {
        test     = "ArnLike"
        variable = "aws:SourceArn"
        values   = ["arn:${data.aws_partition.current.partition}:cloudtrail:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:trail/*"]
      }
    }
  }

  # Statement 6: AWS Config delivery-channel encryption (logs domain only)
  # Per the AWS Config KMS docs: Decrypt + GenerateDataKey for the config service
  # principal, gated on SourceAccount (Config uses its service-linked role; the
  # key grant is expressed against the service principal).
  dynamic "statement" {
    for_each = each.key == "logs" ? [1] : []
    content {
      sid    = "AllowConfigDelivery"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["config.amazonaws.com"]
      }

      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey"
      ]

      resources = ["*"]

      condition {
        test     = "StringEquals"
        variable = "AWS:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }

  # Statement 7: CloudWatch alarms and EventBridge publishing to the KMS-encrypted
  # SNS alarm topic (logs domain only). The SNS developer guide's documented
  # pattern for service event sources is GenerateDataKey* + Decrypt with NO
  # source conditions; it explicitly states aws:SourceAccount/aws:SourceArn are
  # NOT supported for EventBridge-to-encrypted-topic KMS calls, and documents no
  # condition keys for the CloudWatch-alarms path. Adding undocumented conditions
  # here fails silently (alarms publish nothing), so the grant is principal-locked
  # only.
  dynamic "statement" {
    for_each = each.key == "logs" ? [1] : []
    content {
      sid    = "AllowSnsAlarmPublishers"
      effect = "Allow"

      principals {
        type = "Service"
        identifiers = [
          "cloudwatch.amazonaws.com",
          "events.amazonaws.com"
        ]
      }

      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey*"
      ]

      resources = ["*"]
    }
  }

  # Statement 8: Bedrock model-invocation log delivery to S3 (logs domain only).
  # The audit bucket's default encryption is SSE-KMS with this key. Statement
  # matches the Bedrock invocation-logging docs' SSE-KMS key policy verbatim:
  # kms:GenerateDataKey with SourceAccount/SourceArn conditions.
  dynamic "statement" {
    for_each = each.key == "logs" ? [1] : []
    content {
      sid    = "AllowBedrockLogDelivery"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["bedrock.amazonaws.com"]
      }

      actions = ["kms:GenerateDataKey"]

      resources = ["*"]

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

# Per-domain KMS alias
resource "aws_kms_alias" "this" {
  for_each = var.domains

  name          = "alias/${local.name_prefix}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}
