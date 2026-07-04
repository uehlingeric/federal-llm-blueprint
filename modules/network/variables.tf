variable "project" {
  type        = string
  description = "Project name used in resource naming and tags"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod"
  }
}

variable "data_classification" {
  type        = string
  description = "Data classification level for the VPC: public, internal, or cui"
  default     = "cui"

  validation {
    condition     = contains(["public", "internal", "cui"], var.data_classification)
    error_message = "data_classification must be public, internal, or cui"
  }
}

variable "tags" {
  type        = map(string)
  description = "Additional tags applied to all taggable resources"
  default     = {}
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC (default 10.0.0.0/16)"
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block"
  }
}

variable "az_count" {
  type        = number
  description = "Number of availability zones to span (2 or 3)"
  default     = 2

  validation {
    condition     = contains([2, 3], var.az_count)
    error_message = "az_count must be 2 or 3"
  }
}

variable "no_egress" {
  type        = bool
  description = "Enable no-egress mode: zero IGW/NAT, endpoint-only connectivity. When true, public subnets and NAT gateways are disabled."
  default     = false
}

variable "enable_public_subnets" {
  type        = bool
  description = "Enable public subnets. Forbidden when no_egress = true."
  default     = false

  validation {
    condition     = !(var.no_egress && var.enable_public_subnets)
    error_message = "no_egress = true forbids public subnets; set enable_public_subnets = false"
  }
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Enable NAT gateway for private-to-internet routing. Requires enable_public_subnets = true and no_egress = false."
  default     = false

  validation {
    condition     = !var.enable_nat_gateway || (var.enable_public_subnets && !var.no_egress)
    error_message = "enable_nat_gateway requires enable_public_subnets = true and no_egress = false"
  }
}

variable "interface_endpoints" {
  type        = map(string)
  description = "Interface VPC endpoints to create, keyed by logical name to AWS service suffix (e.g., 'bedrock-runtime' -> 'bedrock-runtime'). Service name is com.amazonaws.{region}.{suffix}. Consumers can add entries (e.g., sagemaker.runtime) without forking the module."
  default = {
    bedrock-runtime       = "bedrock-runtime"
    bedrock-agent-runtime = "bedrock-agent-runtime"
    ecr-api               = "ecr.api"
    ecr-dkr               = "ecr.dkr"
    logs                  = "logs"
    kms                   = "kms"
    secretsmanager        = "secretsmanager"
    ecs                   = "ecs"
    ecs-telemetry         = "ecs-telemetry"
    sts                   = "sts"
  }
}

variable "enable_dynamodb_gateway_endpoint" {
  type        = bool
  description = "Enable DynamoDB gateway endpoint. If true, a gateway endpoint is created and associated with all private route tables."
  default     = false
}

variable "enable_flow_logs" {
  type        = bool
  description = "Enable VPC Flow Logs to CloudWatch Logs with KMS encryption"
  default     = true
}

variable "flow_log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention period for VPC flow logs (days)"
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.flow_log_retention_days)
    error_message = "flow_log_retention_days must be one of the CloudWatch allowed retention periods"
  }
}

variable "flow_log_kms_key_arn" {
  type        = string
  description = "ARN of a KMS customer-managed key (CMK) for encrypting VPC Flow Logs. Required when enable_flow_logs = true. Obtain from modules/kms in week 3, or provide any CMK ARN."
}
