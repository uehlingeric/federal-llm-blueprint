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

variable "gateway_container_image" {
  type        = string
  description = "LiteLLM container image, digest-pinned (image@sha256:...). In no-egress mode this must be a private ECR image (public registries are unreachable) — see README for the mirror procedure."
}

variable "ecr_repository_arns" {
  type        = list(string)
  description = "ECR repository ARNs holding the mirrored gateway image; grants the task execution role pull access. Required for a real no-egress deployment (see README); empty default keeps plan-only workflows credential-free."
  default     = []
}

variable "certificate_arn" {
  type        = string
  description = "ACM certificate ARN for ALB TLS termination. When null, a self-signed certificate is created (sandbox only)."
  default     = null
}

variable "create_self_signed_cert" {
  type        = bool
  description = "Create a self-signed certificate for the ALB (sandbox only). Set false and supply certificate_arn for production."
  default     = true
}

variable "gateway_deletion_protection" {
  type        = bool
  description = "Deletion protection on the gateway ALB. Set false and apply before terraform destroy (see README teardown procedure)."
  default     = true
}

variable "vector_deletion_protection" {
  type        = bool
  description = "Deletion protection on the vector-store RDS instance. Set false and apply before terraform destroy (see README teardown procedure)."
  default     = true
}
