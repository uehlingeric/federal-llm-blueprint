variable "project" {
  type        = string
  description = "Project name used in resource naming and tags"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project))
    error_message = "project must contain only lowercase letters, numbers, and hyphens"
  }
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
  description = "Data classification level: public, internal, or cui"
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

variable "vpc_id" {
  type        = string
  description = "VPC ID in which to launch the ECS service (from network module)"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block; used to configure ALB ingress rules for internal clients"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "List of private subnet IDs for ECS tasks and ALB placement; must span at least 2 AZs"

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "private_subnet_ids must contain at least 2 subnets"
  }
}

variable "app_security_group_id" {
  type        = string
  description = "Security group ID for application workloads (from network module); attached to ECS tasks alongside module-created service SG"
}

variable "task_execution_role_arn" {
  type        = string
  description = "ARN of the ECS task execution role (from iam module); grants ECR pull and CloudWatch logs write"
}

variable "app_task_role_arn" {
  type        = string
  description = "ARN of the ECS app task role (from iam module); grants Bedrock, Secrets Manager, and database access"
}

variable "logs_kms_key_arn" {
  type        = string
  description = "ARN of the KMS CMK for encrypting CloudWatch Logs (from kms module, logs domain)"
}

variable "secrets_kms_key_arn" {
  type        = string
  description = "ARN of the KMS CMK for encrypting Secrets Manager and SSM Parameter Store (from kms module, secrets domain)"
}

variable "container_image" {
  type        = string
  description = "Digest-pinned container image for LiteLLM (e.g., 'ghcr.io/berriai/litellm@sha256:abc123...'). Must contain '@sha256:' to enforce reproducible deployments."

  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}", var.container_image))
    error_message = "container_image must be digest-pinned in the format 'registry/image@sha256:64-hex-chars' to ensure reproducible deployments"
  }
}

variable "container_port" {
  type        = number
  description = "Port on which the container listens (default 4000, typical for LiteLLM)"
  default     = 4000
}

variable "container_user" {
  type        = string
  description = "Non-root user ID for container execution (default 1000); must not be '0' or 'root'"
  default     = "1000"

  validation {
    condition     = var.container_user != "0" && var.container_user != "root"
    error_message = "container_user must not be '0' or 'root' for security hardening"
  }
}

variable "task_cpu" {
  type        = number
  description = "ECS Fargate task CPU units (256, 512, 1024, 2048, 4096; default 1024)"
  default     = 1024
}

variable "task_memory" {
  type        = number
  description = "ECS Fargate task memory in MB (512, 1024, 2048, 3072, 4096, etc.; default 2048)"
  default     = 2048
}

variable "desired_count" {
  type        = number
  description = "Initial desired number of ECS tasks; autoscaling ignores this after deployment (lifecycle ignore_changes)"
  default     = 1
}

variable "config_yaml" {
  type        = string
  description = "LiteLLM proxy config YAML stored in SSM Parameter Store. Must not contain secret values (e.g., API keys); the master key is injected separately from Secrets Manager."
}

variable "master_key_secret_arn" {
  type        = string
  description = "ARN of existing Secrets Manager secret holding the LiteLLM master key. When null, the module creates an empty secret shell (value populated out-of-band per docs/secrets-handling.md)."
  default     = null
}

variable "certificate_arn" {
  type        = string
  description = "ARN of an existing ACM certificate for ALB HTTPS listener. Exactly one of certificate_arn or create_self_signed_cert must be set. Default null (use create_self_signed_cert)."
  default     = null

  validation {
    condition     = (var.certificate_arn != null) != var.create_self_signed_cert
    error_message = "Exactly one of certificate_arn or create_self_signed_cert must be set; they are mutually exclusive"
  }
}

variable "create_self_signed_cert" {
  type        = bool
  description = "Create a self-signed certificate for HTTPS (sandbox only; private key stored in Terraform state). Exactly one of certificate_arn or create_self_signed_cert must be set."
  default     = false
}

variable "alb_logs_bucket_id" {
  type        = string
  description = "S3 bucket ID for ALB access logs (must be created externally; module never creates the bucket)"
}

variable "enable_fargate_spot" {
  type        = bool
  description = "Enable ECS Fargate Spot capacity provider (cost optimization; nonprod only)"
  default     = false
}

variable "enable_execute_command" {
  type        = bool
  description = "Enable ECS Exec for interactive task debugging. WARNING: Opens an interactive shell channel into tasks — has AU/audit implications. Leave false in assessed environments."
  default     = false
}

variable "enable_deletion_protection" {
  type        = bool
  description = "Enable deletion protection on the ALB (prevents accidental destroy; set false then apply before destroying)"
  default     = true
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention period in days (must be a valid CloudWatch retention value)"
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of the CloudWatch allowed retention periods: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653"
  }
}

variable "min_capacity" {
  type        = number
  description = "Minimum number of ECS tasks for autoscaling (default 1 for demo; prod should be 2+)"
  default     = 1
}

variable "max_capacity" {
  type        = number
  description = "Maximum number of ECS tasks for autoscaling (default 3)"
  default     = 3
}

variable "cpu_target_value" {
  type        = number
  description = "Target CPU utilization percentage for autoscaling (default 60)"
  default     = 60
}

variable "request_count_target" {
  type        = number
  description = "Target request count per ECS task for autoscaling (default 100)"
  default     = 100
}

variable "alarm_topic_arn" {
  type        = string
  description = "SNS topic ARN for CloudWatch alarm notifications. When null, alarms are created but not wired to any topic."
  default     = null
}
