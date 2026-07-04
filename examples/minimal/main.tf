data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

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

# Document store module: S3 buckets for ALB logs, document storage, and access logs
module "document_store" {
  source = "../../modules/document-store"

  project             = var.project
  environment         = var.environment
  data_classification = "cui"

  # Encryption: use the KMS data key for documents
  data_kms_key_arn = module.kms.key_arns["data"]

  # No object lock in sandbox (see module README for irreversibility warning)

  tags = {
    Example = "minimal"
  }
}

# Vector store module: RDS pgvector database with encryption and IAM auth
module "vector_store" {
  source = "../../modules/vector-store"
  #checkov:skip=CKV_AWS_157: Single-AZ is the documented minimal-demo cost trade-off (~half the RDS spend); the module default is multi_az = true and production compositions keep it.

  project             = var.project
  environment         = var.environment
  data_classification = "cui"

  # Network
  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  app_security_group_id = module.network.app_security_group_id

  # Encryption keys
  data_kms_key_arn    = module.kms.key_arns["data"]
  secrets_kms_key_arn = module.kms.key_arns["secrets"]
  logs_kms_key_arn    = module.kms.key_arns["logs"]

  # Single-AZ for demo; see module README for prod guidance
  multi_az = false

  # Set false (and apply) before terraform destroy
  deletion_protection = var.vector_deletion_protection

  tags = {
    Example = "minimal"
  }
}

# IAM module: roles and policies (week-5 TODO(scope) resolution — role policies now scope to the real gateway resources, vector store, and document store)
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

  # Document store and vector store integration
  document_bucket_arns          = [module.document_store.bucket_arns["documents"]]
  document_bucket_read_prefixes = ["${module.document_store.bucket_arns["documents"]}/documents/*"]
  document_key_prefixes         = ["documents/"]
  db_resource_ids               = [module.vector_store.db_resource_id]
  db_usernames                  = ["app_user"]

  tags = {
    Example = "minimal"
  }
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
  alb_logs_bucket_id         = module.document_store.bucket_ids["alb-logs"]
  enable_deletion_protection = var.gateway_deletion_protection

  tags = {
    Example = "minimal"
  }
}
