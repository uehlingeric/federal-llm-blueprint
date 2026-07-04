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

variable "domains" {
  type = map(object({
    description  = string
    via_services = optional(list(string), [])
  }))
  description = "KMS domains (data, logs, secrets) with descriptions and optional service-binding conditions. via_services are AWS service prefixes composed as '{svc}.{region}.amazonaws.com' in kms:ViaService conditions."
  default = {
    data = {
      description  = "Data at rest: RDS storage, S3 objects, EBS"
      via_services = ["s3", "rds"]
    }
    logs = {
      description  = "CloudWatch log groups, CloudTrail, flow logs"
      via_services = ["logs"]
    }
    secrets = {
      description  = "Secrets Manager secrets"
      via_services = ["secretsmanager"]
    }
  }
}

variable "deletion_window_in_days" {
  type        = number
  description = "KMS key deletion window (7-30 days)"
  default     = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days must be between 7 and 30"
  }
}

variable "key_admin_principal_arns" {
  type        = list(string)
  description = "ARNs of principals granted KMS key admin permissions (Create*, Describe*, Enable*, List*, Put*, Update*, Revoke*, Disable*, Get*, Delete, TagResource, UntagResource, ScheduleKeyDeletion, CancelKeyDeletion). When empty, the admin statement is omitted and root account access is the only admin path."
  default     = []
}
