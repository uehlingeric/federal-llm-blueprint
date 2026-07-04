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

# KMS key ARNs for encryption operations — passed from kms module
variable "kms_key_arns" {
  type        = map(string)
  description = "KMS key ARNs keyed by domain (data, logs, secrets). Used in IAM policies to scope key operations."
  default     = {}
}

# ECR repository ARNs for task_execution role to pull images
variable "ecr_repository_arns" {
  type        = list(string)
  description = "ECR repository ARNs; task_execution role can pull from these. When empty, the policy statement is omitted. TODO(scope): tightened in week 4 when container registry exists."
  default     = []
}

# CloudWatch log group ARNs for task_execution role to write logs
variable "log_group_arns" {
  type        = list(string)
  description = "CloudWatch log group ARNs for ECS task logs. task_execution role can create streams and write events. When empty, the policy statement is omitted. TODO(scope): tightened in week 4 when log groups exist."
  default     = []
}

# Secrets Manager secret ARNs for task_execution and app_task roles
variable "secret_arns" {
  type        = list(string)
  description = "Secrets Manager secret ARNs (e.g., gateway API keys). When empty, the policy statement is omitted. TODO(scope): populated when secrets are created."
  default     = []
}

# Bedrock model invocation for app_task role
variable "bedrock_model_ids" {
  type        = list(string)
  description = "List of Bedrock foundation model IDs (e.g., ['anthropic.claude-opus-20250219-v1:0']). ARNs are constructed as arn:{partition}:bedrock:{region}::foundation-model/{id}. When empty, the policy statement is omitted. TODO(scope): supplied by ecs-llm-gateway module in week 4."
  default     = []
}

# Bedrock inference profiles (managed embeddings, etc.)
variable "bedrock_inference_profile_arns" {
  type        = list(string)
  description = "Optional Bedrock inference profile ARNs for managed services. When empty, the policy statement is omitted."
  default     = []
}

# S3 document bucket for app_task role
variable "document_bucket_arns" {
  type        = list(string)
  description = "S3 bucket ARNs for document store. app_task role can list and get objects with scoped prefixes. When empty, the policy statement is omitted. TODO(scope): supplied by document-store module in week 5."
  default     = []
}

variable "document_bucket_read_prefixes" {
  type        = list(string)
  description = "S3 object prefixes within document buckets that app_task can read (e.g., ['arn:aws:s3:::bucket/documents/*']). Full ARNs including prefix. When empty, the policy statement is omitted."
  default     = []
}

variable "document_key_prefixes" {
  type        = list(string)
  description = "Bare S3 key prefixes (e.g., ['documents/']) used in the s3:prefix condition scoping ListBucket. Distinct from document_bucket_read_prefixes, which are object ARNs. When empty, listing is scoped to the named buckets without a prefix condition."
  default     = []
}

# RDS database access for app_task role
variable "db_resource_ids" {
  type        = list(string)
  description = "RDS resource IDs for IAM database authentication (e.g., ['db-ABCD1234']). Paired with db_usernames to construct rds-db:connect ARNs. When empty, the policy statement is omitted. TODO(scope): supplied by vector-store module in week 5."
  default     = []
}

variable "db_usernames" {
  type        = list(string)
  description = "RDS database usernames for IAM auth (parallel list with db_resource_ids). When empty, the policy statement is omitted."
  default     = []
}

# CI/CD deployment role trust principals
variable "ci_trust_principal_arns" {
  type        = list(string)
  description = "ARNs of CI/CD principals (e.g., GitHub Actions OIDC role) that can assume the ci_deploy role. When empty, the ci_deploy role is not created (count = 0)."
  default     = []
}

# Human role tiers — map of tier name to list of trust principal ARNs
variable "human_trust_principals" {
  type        = map(list(string))
  description = "Map of role tier names (platform-admin, auditor, developer) to lists of trust principal ARNs (e.g., IdP role ARNs for SSO users). Example: { platform-admin = [\"arn:aws:iam::...:role/Admin\"], developer = [\"arn:aws:iam::...:role/Dev\"] }. Tiers not supplied are not created. Empty map → no human roles created."
  default     = {}
}
