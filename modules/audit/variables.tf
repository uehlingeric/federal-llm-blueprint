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
  description = "Deployment environment"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod"
  }
}

variable "data_classification" {
  type        = string
  default     = "cui"
  description = "Data classification level"

  validation {
    condition     = contains(["public", "internal", "cui"], var.data_classification)
    error_message = "data_classification must be public, internal, or cui"
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags to apply to resources"
}

variable "logs_kms_key_arn" {
  type        = string
  description = "ARN of the KMS key used to encrypt CloudTrail, CloudWatch Logs, Config snapshots, and the audit bucket"
}

variable "documents_bucket_arn" {
  type        = string
  description = "ARN of the documents bucket (used to scope CloudTrail S3 data events)"
}

variable "access_logs_bucket_id" {
  type        = string
  description = "ID of the S3 bucket for receiving audit bucket server access logs"
}

variable "enable_insights" {
  type        = bool
  default     = false
  description = "Enable CloudTrail Insights (adds per-event analysis charges)"
}

variable "enable_bedrock_invocation_logging" {
  type        = bool
  default     = true
  description = "Enable Bedrock model-invocation logging. WARNING: This is a regional SINGLETON configuration (one per account per region). Enabling here overwrites any existing configuration in the region."
}

variable "enable_full_content_logging" {
  type        = bool
  default     = false
  description = "When false, only invocation metadata (model id, timestamps, token counts, identity) is logged; prompt/response bodies are excluded. See ADR-007 (docs/adr/007-prompt-capture-posture.md)"
}

variable "trail_log_retention_days" {
  type        = number
  default     = 365
  description = "CloudTrail log retention in CloudWatch (days). Must be in CloudWatch allowed set. Default 365 implements M-21-31 12-month active retention."

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.trail_log_retention_days)
    error_message = "trail_log_retention_days must be in CloudWatch allowed set: [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653]"
  }
}

variable "bedrock_log_retention_days" {
  type        = number
  default     = 365
  description = "Bedrock model-invocation log retention in CloudWatch (days). Must be in CloudWatch allowed set. Default 365 implements M-21-31 12-month active retention."

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.bedrock_log_retention_days)
    error_message = "bedrock_log_retention_days must be in CloudWatch allowed set: [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653]"
  }
}

variable "include_global_resource_types" {
  type        = bool
  default     = true
  description = "Include global resource types (IAM, etc.) in Config recording. Enable in exactly ONE region per account to avoid duplicate configuration items."
}

variable "config_snapshot_frequency" {
  type        = string
  default     = "TwentyFour_Hours"
  description = "AWS Config snapshot delivery frequency"

  validation {
    condition     = contains(["One_Hour", "Three_Hours", "Six_Hours", "Twelve_Hours", "TwentyFour_Hours"], var.config_snapshot_frequency)
    error_message = "config_snapshot_frequency must be One_Hour, Three_Hours, Six_Hours, Twelve_Hours, or TwentyFour_Hours"
  }
}

variable "enable_object_lock" {
  type        = bool
  default     = true
  description = "Enable S3 Object Lock on the audit bucket (prevents deletion and shortening of retention periods)"
}

variable "object_lock_mode" {
  type        = string
  default     = "GOVERNANCE"
  description = "S3 Object Lock retention mode (GOVERNANCE or COMPLIANCE)"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.object_lock_mode)
    error_message = "object_lock_mode must be GOVERNANCE or COMPLIANCE"
  }
}

variable "object_lock_retention_days" {
  type        = number
  default     = 30
  description = "S3 Object Lock default retention period (days)"

  validation {
    condition     = var.object_lock_retention_days > 0
    error_message = "object_lock_retention_days must be greater than 0"
  }
}

variable "audit_log_expiration_days" {
  type        = number
  default     = 913
  description = "Audit bucket log expiration (days). Default 913 implements M-21-31 ≈12 months active + 18 months cold. Must be > object_lock_retention_days."

  validation {
    condition     = var.audit_log_expiration_days > 0
    error_message = "audit_log_expiration_days must be greater than 0"
  }

  # Cross-variable validation (Terraform >= 1.9): expiring objects still under
  # object-lock retention would silently fail lifecycle deletes.
  validation {
    condition     = var.audit_log_expiration_days > var.object_lock_retention_days
    error_message = "audit_log_expiration_days must be greater than object_lock_retention_days"
  }
}

variable "abort_incomplete_multipart_days" {
  type        = number
  default     = 7
  description = "Abort incomplete multipart uploads after (days)"

  validation {
    condition     = var.abort_incomplete_multipart_days > 0
    error_message = "abort_incomplete_multipart_days must be greater than 0"
  }
}

variable "force_destroy" {
  type        = bool
  description = "Allow terraform destroy to empty the audit bucket (all object versions) first. Sandbox teardown aid — CloudTrail/Config deliver continuously, so destroy reliably fails without it. Production keeps false; incompatible with the intent of object lock."
  default     = false
}
