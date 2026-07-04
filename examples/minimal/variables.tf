variable "project" {
  type        = string
  description = "Project name"
  default     = "fedllm"
}

variable "environment" {
  type        = string
  description = "Environment (dev, staging, prod)"
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod"
  }
}

variable "no_egress" {
  type        = bool
  description = "Enable no-egress mode (zero IGW/NAT, endpoint-only connectivity)"
  default     = true
}

variable "region" {
  type        = string
  description = "AWS region"
  default     = "us-east-1"
}
