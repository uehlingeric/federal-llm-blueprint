variable "project" {
  type        = string
  description = "Project name"
  default     = "fedllm"
}

variable "environment" {
  type        = string
  description = "Environment (dev, staging, prod)"
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod"
  }
}

variable "region" {
  type        = string
  description = "AWS region"
  default     = "us-east-1"
}

variable "az_count" {
  type        = number
  description = "Availability zones to span. Full-stack default is 3; each interface endpoint bills per AZ (see docs/costs.md)."
  default     = 3
}

variable "bedrock_model_id" {
  type        = string
  description = "Bedrock foundation model ID the gateway serves (must be enabled for the account)."
  default     = "anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "bedrock_inference_profile_id" {
  type        = string
  description = "Cross-region inference profile ID for the model. The us. geo prefix is the commercial-partition profile; GovCloud uses us-gov. (see docs/airgap-guide.md)."
  default     = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "gateway_model_name" {
  type        = string
  description = "Model name the gateway exposes on its OpenAI-compatible API (the model field clients send)."
  default     = "claude-sonnet-4-5"
}

variable "gateway_container_image" {
  type        = string
  description = "LiteLLM container image, digest-pinned (image@sha256:...). In no-egress mode this must be a private ECR image (public registries are unreachable) — see README for the mirror procedure."
}

variable "ecr_repository_arns" {
  type        = list(string)
  description = "ECR repository ARNs holding mirrored images (gateway, one-off task images); grants the task execution role pull access. Required for a real no-egress deployment (see README); empty default keeps plan-only workflows credential-free."
  default     = []
}

variable "certificate_arn" {
  type        = string
  description = "ACM certificate ARN for ALB TLS termination (production: private PKI / ACM Private CA — see docs/costs.md for the PCA cost note). When null, a self-signed certificate is created."
  default     = null
}

variable "create_self_signed_cert" {
  type        = bool
  description = "Create a self-signed certificate for the ALB (demo only). Set false and supply certificate_arn for production."
  default     = false
}

variable "gateway_desired_count" {
  type        = number
  description = "Gateway tasks running at steady state (2+ spans multiple AZs behind the ALB)."
  default     = 2
}

variable "enable_object_lock" {
  type        = bool
  description = "S3 Object Lock on the documents and audit buckets (production default). Irreversible once a bucket is created with it; the demo profile disables it so terraform destroy can complete — see README teardown."
  default     = true
}

variable "enable_cloudtrail_insights" {
  type        = bool
  description = "CloudTrail Insights anomaly detection. A per-event-analyzed cost toggle (see docs/costs.md)."
  default     = false
}

variable "alarm_email_addresses" {
  type        = list(string)
  description = "Email endpoints subscribed to the alarm SNS topic."
  default     = []
}

variable "human_trust_principals" {
  type        = map(list(string))
  description = "Human role tiers (platform-admin, auditor, developer) to trust principal ARNs, e.g. IdP role ARNs for SSO users. Empty map creates no human roles."
  default     = {}
}

variable "ci_trust_principal_arns" {
  type        = list(string)
  description = "IAM principal ARNs trusted to assume the CI deploy role. Empty list skips the role."
  default     = []
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

variable "force_destroy_buckets" {
  type        = bool
  description = "Allow destroy to empty the S3 buckets (all versions) first. Demo teardown aid; production keeps false."
  default     = false
}
