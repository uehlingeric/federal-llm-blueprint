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

variable "data_kms_key_arn" {
  type        = string
  description = "ARN of the KMS CMK for encrypting documents bucket (from kms module, data domain)"
}

variable "enable_object_lock" {
  type        = bool
  description = "IRREVERSIBLE: Enable object lock on documents bucket. CRITICAL: Can only be enabled at bucket creation; changing this after creation forces bucket replacement. Object lock prevents object deletion/overwrite for a retention period. Choose GOVERNANCE for bypassable retention or COMPLIANCE for unbypassable retention (even by root). Use only for regulatory retention requirements like SEC 17a-4. Default GOVERNANCE is safe for development; COMPLIANCE should be deliberate for production retention policies."
  default     = false
}

variable "object_lock_mode" {
  type        = string
  description = "Object lock retention mode: GOVERNANCE (bypassable with s3:BypassGovernanceRetention) or COMPLIANCE (unbypassable). GOVERNANCE is the safe default for most use cases; COMPLIANCE is unbypassable even by root until retention expires."
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.object_lock_mode)
    error_message = "object_lock_mode must be GOVERNANCE or COMPLIANCE"
  }
}

variable "object_lock_retention_days" {
  type        = number
  description = "Number of days to retain objects when object lock is enabled. Minimum 1 day."
  default     = 30

  validation {
    condition     = var.object_lock_retention_days >= 1
    error_message = "object_lock_retention_days must be at least 1"
  }
}

variable "documents_ia_transition_days" {
  type        = number
  description = "Number of days before transitioning documents from STANDARD to STANDARD_IA storage class. Default 90 balances cost optimization against retrieval frequency."
  default     = 90

  validation {
    condition     = var.documents_ia_transition_days >= 1
    error_message = "documents_ia_transition_days must be at least 1"
  }
}

variable "noncurrent_version_expiration_days" {
  type        = number
  description = "Number of days before expiring noncurrent document versions. Default 180 supports compliance retention and accidental-deletion recovery."
  default     = 180

  validation {
    condition     = var.noncurrent_version_expiration_days >= 1
    error_message = "noncurrent_version_expiration_days must be at least 1"
  }
}

variable "log_expiration_days" {
  type        = number
  description = "Number of days before expiring logs in access-logs and alb-logs buckets. Default 90."
  default     = 90

  validation {
    condition     = var.log_expiration_days >= 1
    error_message = "log_expiration_days must be at least 1"
  }
}

variable "abort_incomplete_multipart_days" {
  type        = number
  description = "Number of days before aborting incomplete multipart uploads. Default 7 limits storage waste from failed uploads."
  default     = 7

  validation {
    condition     = var.abort_incomplete_multipart_days >= 1
    error_message = "abort_incomplete_multipart_days must be at least 1"
  }
}

variable "alb_logs_prefix" {
  type        = string
  description = "S3 prefix under which ELB/ALB writes access logs. Default 'alb'. Used to construct the bucket policy resource pattern for ELB log delivery."
  default     = "alb"
}

variable "additional_logging_prefixes" {
  type        = list(string)
  description = "Additional access-logs bucket prefixes that S3 server-access-log delivery may write to, beyond the built-in 'documents' prefix. Compositions pass the target prefixes other modules use for aws_s3_bucket_logging into this bucket (e.g. [\"audit\"] for the audit module's bucket logging). Bare prefix names without slashes."
  default     = []

  validation {
    condition     = alltrue([for p in var.additional_logging_prefixes : can(regex("^[a-z0-9-]+$", p))])
    error_message = "additional_logging_prefixes entries must be bare lowercase prefix names (letters, numbers, hyphens; no slashes)"
  }
}

variable "enable_inventory" {
  type        = bool
  description = "Enable weekly CSV inventory of documents bucket contents. Inventory is written to access-logs bucket under 'inventory/' prefix. Useful for compliance audits and storage cost analysis. Default false."
  default     = false
}

variable "enable_analytics" {
  type        = bool
  description = "Enable storage-class analysis on documents bucket. Generates daily analytics report (sample rate configurable by AWS). Useful for cost optimization. Default false."
  default     = false
}
