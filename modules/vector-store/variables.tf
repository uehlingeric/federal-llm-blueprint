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
  description = "VPC ID in which to launch the RDS instance (from network module)"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "List of private subnet IDs for RDS placement; must span at least 2 AZs"

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "private_subnet_ids must contain at least 2 subnets"
  }
}

variable "app_security_group_id" {
  type        = string
  description = "Security group ID for application workloads (from network module); used as ingress source for RDS database security group"
}

variable "data_kms_key_arn" {
  type        = string
  description = "ARN of the KMS CMK for encrypting RDS storage and performance insights (from kms module, data domain)"
}

variable "secrets_kms_key_arn" {
  type        = string
  description = "ARN of the KMS CMK for encrypting RDS-managed master user secret in Secrets Manager (from kms module, secrets domain)"
}

variable "logs_kms_key_arn" {
  type        = string
  description = "ARN of the KMS CMK for encrypting CloudWatch Logs (from kms module, logs domain)"
}

variable "instance_class" {
  type        = string
  description = "RDS instance class (default db.t4g.medium; ~$60/mo single-AZ, suitable for demo workloads; prod: r6g classes with multi_az = true recommended)"
  default     = "db.t4g.medium"
}

variable "engine_version" {
  type        = string
  description = "PostgreSQL major version (default 16; minor upgrades applied automatically)"
  default     = "16"

  validation {
    condition     = can(regex("^[0-9]+$", var.engine_version))
    error_message = "engine_version must be a major version only (e.g., \"16\") — the parameter group family is constructed as postgres{version} and a minor version would break it"
  }
}

variable "allocated_storage" {
  type        = number
  description = "Initial allocated storage in GiB (default 20; demo sizing)"
  default     = 20

  validation {
    condition     = var.allocated_storage >= 20
    error_message = "allocated_storage must be at least 20 GiB"
  }
}

variable "max_allocated_storage" {
  type        = number
  description = "Maximum allocated storage for autoscaling in GiB (default 100; must exceed allocated_storage)"
  default     = 100

  validation {
    condition     = var.max_allocated_storage > var.allocated_storage
    error_message = "max_allocated_storage must be greater than allocated_storage for storage autoscaling to work"
  }
}

variable "multi_az" {
  type        = bool
  description = "Enable Multi-AZ deployment for high availability (default true for production-readiness; set to false only for minimal demo)"
  default     = true
}

variable "db_name" {
  type        = string
  description = "Initial database name (default vectordb)"
  default     = "vectordb"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_]*$", var.db_name))
    error_message = "db_name must be a valid PostgreSQL identifier (lowercase letters, numbers, underscores; start with letter or underscore)"
  }
}

variable "master_username" {
  type        = string
  description = "Master database user (default postgres)"
  default     = "postgres"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_]*$", var.master_username))
    error_message = "master_username must be a valid PostgreSQL identifier"
  }
}

variable "backup_retention_days" {
  type        = number
  description = "Automated backup retention period in days (minimum 7 enforced for federal compliance; default 7)"
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 7 and 35 (federal minimum 7 days; adjust retention before reduce)"
  }
}

variable "deletion_protection" {
  type        = bool
  description = "Enable deletion protection (default true; prevents accidental instance deletion)"
  default     = true
}

variable "skip_final_snapshot" {
  type        = bool
  description = "Skip final snapshot on destroy (default false; when false, a final snapshot {identifier}-final is taken on instance deletion)"
  default     = false
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention period in days (must be a valid CloudWatch retention value; default 90)"
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of the CloudWatch allowed retention periods: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653"
  }
}

variable "monitoring_interval" {
  type        = number
  description = "Enhanced monitoring interval in seconds (default 60; must be 0, 1, 5, 10, 15, 30, or 60; 0 disables enhanced monitoring and the monitoring role)"
  default     = 60

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "monitoring_interval must be one of: 0 (disabled), 1, 5, 10, 15, 30, or 60"
  }
}

variable "enable_performance_insights" {
  type        = bool
  description = "Enable Performance Insights (default true; provides database performance visibility)"
  default     = true
}

variable "preferred_backup_window" {
  type        = string
  description = "Preferred backup window in HH:MM-HH:MM UTC format (default 03:00-04:00)"
  default     = "03:00-04:00"

  validation {
    condition     = can(regex("^\\d{2}:\\d{2}-\\d{2}:\\d{2}$", var.preferred_backup_window))
    error_message = "preferred_backup_window must be in HH:MM-HH:MM format (e.g., 03:00-04:00)"
  }
}

variable "preferred_maintenance_window" {
  type        = string
  description = "Preferred maintenance window in ddd:HH:MM-ddd:HH:MM UTC format (default sun:04:30-sun:05:30)"
  default     = "sun:04:30-sun:05:30"

  validation {
    condition     = can(regex("^[a-z]{3}:\\d{2}:\\d{2}-[a-z]{3}:\\d{2}:\\d{2}$", var.preferred_maintenance_window))
    error_message = "preferred_maintenance_window must be in ddd:HH:MM-ddd:HH:MM format (e.g., sun:04:30-sun:05:30)"
  }
}
