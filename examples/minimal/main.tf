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
