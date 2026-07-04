data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_elb_service_account" "main" {}

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

locals {
  bedrock_model_id              = "anthropic.claude-sonnet-4-5-20250929-v1:0"
  bedrock_inference_profile_id  = "us.anthropic.claude-sonnet-4-5-20250929-v1:0" # us. geo prefix is the commercial-partition cross-region profile; GovCloud uses "us-gov."
  bedrock_inference_profile_arn = "arn:${data.aws_partition.current.partition}:bedrock:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:inference-profile/${local.bedrock_inference_profile_id}"
  # Gateway config (stored as an SSM SecureString by the gateway module, per ADR-005).
  # Must contain no secret values: the master key is injected separately from Secrets
  # Manager as LITELLM_MASTER_KEY. The rpm / max_budget lines are the sandbox
  # cost-control baseline — see README "Cost controls".
  litellm_config = templatefile("${path.module}/litellm.yaml.tpl", {
    bedrock_inference_profile_id = local.bedrock_inference_profile_id
    region                       = data.aws_region.current.region
  })
}

# KMS module: customer-managed CMKs for data, logs, and secrets
module "kms" {
  source = "../../modules/kms"

  project             = var.project
  environment         = var.environment
  data_classification = "cui"

  tags = {
    Example = "minimal"
  }
}

# Network module: VPC, subnets, endpoints, security groups, flow logs
module "network" {
  source = "../../modules/network"

  project              = var.project
  environment          = var.environment
  data_classification  = "cui"
  no_egress            = var.no_egress
  enable_flow_logs     = true
  flow_log_kms_key_arn = module.kms.key_arns["logs"]
  vpc_cidr             = "10.0.0.0/16"
  az_count             = 2

  # Standard mode variables (ignored when no_egress = true)
  enable_public_subnets = false
  enable_nat_gateway    = false

  tags = {
    Example = "minimal"
  }
}

# IAM module: roles and policies (week-3 TODO(scope) tightening — role policies now scope to the real gateway resources)
module "iam" {
  source = "../../modules/iam"

  project                        = var.project
  environment                    = var.environment
  data_classification            = "cui"
  kms_key_arns                   = module.kms.key_arns
  log_group_arns                 = [module.gateway.log_group_arn]
  secret_arns                    = [module.gateway.master_key_secret_arn]
  ssm_parameter_arns             = [module.gateway.config_parameter_arn]
  ecr_repository_arns            = var.ecr_repository_arns
  bedrock_model_ids              = [local.bedrock_model_id]
  bedrock_inference_profile_arns = [local.bedrock_inference_profile_arn]

  tags = {
    Example = "minimal"
  }
}

# ALB logs S3 bucket (temporary stub — replaced by the document-store module in week 5)
resource "aws_s3_bucket" "alb_logs" {
  #checkov:skip=CKV_AWS_145: ELB access-log delivery supports ONLY SSE-S3; SSE-KMS (any key) is rejected by the log-delivery service. AWS platform constraint, not a shortcut.
  #checkov:skip=CKV_AWS_18: Sandbox ALB access-log stub, replaced by the document-store module (with access logging) in week 5. Logging the log bucket adds no value for a stub.
  #checkov:skip=CKV_AWS_144: Single-region sandbox stub; cross-region replication is a document-store (week 5) concern.
  #checkov:skip=CKV2_AWS_62: No consumer for bucket event notifications; stub is replaced by the document-store module in week 5.
  bucket = "${var.project}-${var.environment}-alb-logs-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name    = "${var.project}-${var.environment}-alb-logs"
    Example = "minimal"
  }
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3, deliberately not SSE-KMS: ELB access-log delivery rejects KMS-encrypted
# destinations (AWS platform constraint) — see the CKV_AWS_145 skip on the bucket.
resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-alb-logs"
    status = "Enabled"

    expiration {
      days = 90
    }
  }

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid    = "AllowELBServicePutObject"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.main.arn]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
  }

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
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = data.aws_iam_policy_document.alb_logs.json
}

# ECS LLM Gateway module: Fargate service + internal ALB serving OpenAI-compatible
# completions from Bedrock. The iam <-> gateway mutual references are resource-acyclic:
# gateway's log group/secret/parameter feed iam's role *policies*, while the task
# definition consumes iam's role ARNs (roles are created before their policies).
module "gateway" {
  source = "../../modules/ecs-llm-gateway"

  project                    = var.project
  environment                = var.environment
  data_classification        = "cui"
  vpc_id                     = module.network.vpc_id
  vpc_cidr                   = module.network.vpc_cidr_block
  private_subnet_ids         = module.network.private_subnet_ids
  app_security_group_id      = module.network.app_security_group_id
  task_execution_role_arn    = module.iam.task_execution_role_arn
  app_task_role_arn          = module.iam.app_task_role_arn
  logs_kms_key_arn           = module.kms.key_arns["logs"]
  secrets_kms_key_arn        = module.kms.key_arns["secrets"]
  container_image            = var.gateway_container_image
  config_yaml                = local.litellm_config
  certificate_arn            = var.certificate_arn
  create_self_signed_cert    = var.create_self_signed_cert
  alb_logs_bucket_id         = aws_s3_bucket.alb_logs.id
  enable_deletion_protection = var.gateway_deletion_protection

  tags = {
    Example = "minimal"
  }
}
