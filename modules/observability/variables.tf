variable "project" {
  type        = string
  description = "Project identifier"
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
  description = "Data classification level for tagging"
  default     = "cui"

  validation {
    condition     = contains(["public", "internal", "cui"], var.data_classification)
    error_message = "data_classification must be public, internal, or cui"
  }
}

variable "tags" {
  type        = map(string)
  description = "Additional tags to apply to resources"
  default     = {}
}

variable "logs_kms_key_arn" {
  type        = string
  description = "ARN of the KMS key for encrypting log groups and SNS topic; passed from the kms module's logs key"
}

variable "log_groups" {
  type = map(object({
    retention_in_days = number
  }))
  description = "Log group factory input: map of component names to retention configuration. retention_in_days is mandatory (omitting it is a type error) and must be a finite value from CloudWatch's allowed set; infinite retention is not permitted"
  default     = {}

  validation {
    condition = alltrue([
      for group in var.log_groups :
      contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], group.retention_in_days)
    ])
    error_message = "retention_in_days must be one of: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653. Infinite retention (0) is not permitted; retention is mandatory."
  }
}

variable "alarm_email_addresses" {
  type        = list(string)
  description = "Email addresses for SNS alarm subscriptions. Note: email endpoints require manual confirmation from the subscriber"
  default     = []
}

variable "runbook_url" {
  type        = string
  description = "When set, every alarm carries a RunbookUrl tag pointing to operational runbooks. Must fit the CloudWatch tag-value character set (letters, numbers, spaces, _ . : / = + - @) — notably no # fragment, which PutMetricAlarm rejects at apply time."
  default     = null

  validation {
    condition     = var.runbook_url == null || can(regex("^[A-Za-z0-9 _.:/=+@-]*$", coalesce(var.runbook_url, "")))
    error_message = "runbook_url may only contain characters CloudWatch tag values allow (letters, numbers, spaces, _ . : / = + - @); URL fragments (#...) are rejected by PutMetricAlarm"
  }
}

variable "db_instance_id" {
  type        = string
  description = "RDS database instance identifier. When set, RDS alarms are created; when null, RDS alarms are omitted"
  default     = null
}

variable "rds_cpu_threshold_percent" {
  type        = number
  description = "CloudWatch alarm threshold for RDS CPU utilization (percent)"
  default     = 80
}

variable "rds_free_storage_threshold_bytes" {
  type        = number
  description = "CloudWatch alarm threshold for RDS free storage space (bytes). Default: 10 GiB"
  default     = 10737418240
}

variable "rds_connections_threshold" {
  type        = number
  description = "CloudWatch alarm threshold for RDS database connections. Flat default; tune to instance-class max_connections"
  default     = 100
}

variable "vpc_id" {
  type        = string
  description = "VPC ID for endpoint packet-drop alarms. When set with interface_endpoint_ids, endpoint alarms are created"
  default     = null
}

variable "interface_endpoint_ids" {
  type        = map(string)
  description = "Map of AWS service short names to VPC Endpoint IDs for packet-drop canary alarms. Keys are service names (e.g., 'logs', 'kms'); values are endpoint IDs (e.g., 'vpce-0abc')"
  default     = {}

  validation {
    condition     = length(var.interface_endpoint_ids) == 0 || var.vpc_id != null
    error_message = "interface_endpoint_ids requires vpc_id to be set"
  }
}

variable "cloudtrail_log_group_name" {
  type        = string
  description = "CloudTrail log group name. When set, a metric filter and alarm for CloudTrail tamper detection are created"
  default     = null
}

variable "enable_dashboard" {
  type        = bool
  description = "Whether to create a CloudWatch dashboard for observability"
  default     = true
}

variable "alb_arn_suffix" {
  type        = string
  description = "ALB ARN suffix for dashboard gateway traffic metrics. When set, gateway request/latency/5xx widgets are rendered"
  default     = null
}

variable "target_group_arn_suffix" {
  type        = string
  description = "Target group ARN suffix for dashboard gateway metrics. When set, TargetGroup dimension is added to gateway metric widgets"
  default     = null
}

variable "cluster_name" {
  type        = string
  description = "ECS cluster name for dashboard task health metrics. When set, ECS CPU/memory widgets are rendered"
  default     = null
}

variable "service_name" {
  type        = string
  description = "ECS service name for dashboard task health metrics. When set with cluster_name, ECS health widgets are rendered"
  default     = null
}
