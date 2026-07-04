provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project            = var.project
      Environment        = var.environment
      ManagedBy          = "terraform"
      DataClassification = "cui"
    }
  }
}

# Temporary KMS key for VPC Flow Logs (week 2 only)
# In production (week 3), this is replaced by modules/kms.
# The key policy permits CloudWatch Logs service to use the key.
resource "aws_kms_key" "flow_logs" {
  description             = "KMS key for VPC flow logs encryption (replaced by modules/kms in week 3)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = data.aws_iam_policy_document.flow_logs_key_policy.json

  tags = {
    Name = "${var.project}-${var.environment}-flow-logs-key"
  }
}

resource "aws_kms_alias" "flow_logs" {
  name          = "alias/${var.project}-${var.environment}-flow-logs"
  target_key_id = aws_kms_key.flow_logs.key_id
}

# Key policy allowing CloudWatch Logs service to encrypt/decrypt for flow logs
data "aws_iam_policy_document" "flow_logs_key_policy" {
  # In a KMS key policy, Resource "*" means "this key" (resource-policy
  # semantics), not "all resources" — these three checks misfire on key
  # policies. The root statement is the documented AWS pattern that keeps
  # the key manageable and lets IAM policies grant access (prevents lockout).
  #checkov:skip=CKV_AWS_109: Resource "*" in a key policy scopes to this key; root statement prevents key lockout
  #checkov:skip=CKV_AWS_111: Resource "*" in a key policy scopes to this key; root statement prevents key lockout
  #checkov:skip=CKV_AWS_356: Resource "*" in a key policy scopes to this key by definition

  statement {
    sid    = "Enable IAM User Permissions"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "Allow CloudWatch Logs"
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

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Network module: VPC, subnets, endpoints, security groups, flow logs
module "network" {
  source = "../../modules/network"

  project              = var.project
  environment          = var.environment
  data_classification  = "cui"
  no_egress            = var.no_egress
  enable_flow_logs     = true
  flow_log_kms_key_arn = aws_kms_key.flow_logs.arn
  vpc_cidr             = "10.0.0.0/16"
  az_count             = 2

  # Standard mode variables (ignored when no_egress = true)
  enable_public_subnets = false
  enable_nat_gateway    = false

  tags = {
    Example = "minimal"
  }
}
