# Repository Conventions

This document defines the normative standards for infrastructure code, policy artifacts, and operations in this repository. All contributions MUST adhere to these conventions.

## Resource Naming

All AWS resources follow a three-part naming pattern:

```
{project}-{environment}-{component}
```

Implementation in Terraform modules uses a consistent local value:

```hcl
locals {
  name_prefix = "${var.project}-${var.environment}"
}
```

Component names are hyphenated and lowercase (e.g., `llm-gateway`, `vector-db`, `doc-store`). The full resource name is typically constructed as `"${local.name_prefix}-${component}"`.

## Mandatory Tags

Every taggable AWS resource MUST carry the following tags:

- **Project**: Project identifier (inherited from `var.project`)
- **Environment**: Environment name—dev, staging, prod (inherited from `var.environment`)
- **ManagedBy**: Always set to `"terraform"`
- **DataClassification**: Classification level—public, internal, confidential, restricted

Modules accept a `var.tags` map for additional user-supplied tags. Modules construct the final tag map using `merge()`:

```hcl
locals {
  common_tags = {
    Project            = var.project
    Environment        = var.environment
    ManagedBy          = "terraform"
    DataClassification = var.data_classification
  }
}

# On each taggable resource:
#   tags = merge(local.common_tags, var.tags)
```

Root modules additionally configure provider `default_tags` to apply the mandatory set to all resources without explicit tag blocks.

## Variables

Variables MUST follow these rules:

- **Naming**: snake_case only
- **Type Declaration**: `type` REQUIRED on every variable (tflint-enforced)
- **Description**: `description` REQUIRED on every variable (tflint-enforced)
- **Validation**: Enumerated values (e.g., environment, region) MUST use `validation` blocks
- **Boolean Prefixes**: Boolean variables use `enable_` or `create_` prefix (e.g., `enable_flow_logs`, `create_nat_gateway`)
- **Defaults**: Required inputs have no default value; optional inputs provide sensible defaults with rationale in the description
- **Secrets**: Never pass secrets as plain variables when a data-source or ephemeral-credential pattern exists; use AWS Secrets Manager or credential-provider patterns instead

Example validation block for enumerated values:

```hcl
variable "environment" {
  type        = string
  description = "Deployment environment"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod"
  }
}
```

## Outputs

Outputs MUST follow these rules:

- **Description**: `description` REQUIRED on every output (tflint-enforced)
- **Naming Conventions**:
  - Resource IDs: `_id` suffix (e.g., `vpc_id`, `cluster_id`)
  - ARNs: `_arn` suffix (e.g., `role_arn`, `bucket_arn`)
  - Names: `_name` suffix (e.g., `bucket_name`, `role_name`)
- **Collections**: When consumers select by key (e.g., by domain or service), export as maps keyed by domain, not positional lists

Example—exporting by service:

```hcl
output "key_ids" {
  description = "KMS key IDs by domain"
  value = {
    data    = aws_kms_key.data.id
    logs    = aws_kms_key.logs.id
    secrets = aws_kms_key.secrets.id
  }
}
```

## Version Pinning

Terraform code is pinned to specific version bands to prevent silent breaking changes:

- **Terraform Runtime**: `>= 1.9.0, < 2.0.0` in all modules and examples
- **AWS Provider**: `~> 6.0` (allows patch bumps, prevents minor-version drift)
- **CI Testing**: CI runs the exact floor version (1.9.8) so code accidentally using newer language features fails the build; bumping the floor is an explicit reviewed change
- **GitHub Actions**: All actions pinned to full commit SHAs with a trailing version comment (e.g., `actions/checkout@9c091bb2... # v7.0.0`)
- **Container Images**: Pinned by digest, never `:latest`; digest pins ensure reproducible deployments
- **Terraform Plugins and Tools**: tflint plugins and other Terraform tooling pinned to exact versions in CI and development configs

## Partition and Account Safety

Code MUST work across AWS partitions (standard, GovCloud, China) and never assume a single account:

- **ARN Construction**: Never hardcode `arn:aws:`. Always use `data.aws_partition.current.partition`:

```hcl
arn = "arn:${data.aws_partition.current.partition}:service:region:account:resource"
```

- **Account IDs**: Never hardcode account IDs. Always use `data.aws_caller_identity.current.account_id`
- **Regions**: Region is always a module variable, never hardcoded; passed explicitly to provider configuration
- **Documentation Examples**: Transcripts and documentation use the placeholder account ID `123456789012`

## Module File Layout

Every module MUST contain:

- **main.tf**: Resource definitions (or split into purpose-named files for large modules)
- **variables.tf**: All variable declarations (never split)
- **outputs.tf**: All output declarations (never split)
- **versions.tf**: Provider and version constraints (never split)
- **README.md**: Module documentation with terraform-docs injection markers

Large modules MAY split resources into purpose-named files (e.g., `endpoints.tf`, `flow-logs.tf`, `security.tf`) but the four core files are fixed. README body above the injection markers is hand-written; content between `<!-- BEGIN_TF_DOCS -->` and `<!-- END_TF_DOCS -->` is generated (`make docs`) and CI fails if stale.

## IAM Policy Style

IAM policies MUST follow these rules:

- **Representation**: Use `data.aws_iam_policy_document` exclusively; no heredoc or `jsonencode()` inline policies
- **Negation**: No `NotAction` blocks
- **Wildcard Resources**: `Resource: "*"` is forbidden on write (modify, delete, create) actions; read-only actions may use wildcard resources with justification comments
- **Exceptions**: Every exception to least-privilege MUST have an inline comment explaining the business requirement

Example:

```hcl
data "aws_iam_policy_document" "app_task" {
  statement {
    sid     = "ReadDocuments"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    # Scoped to the documents bucket and prefix — never a bucket wildcard
    resources = ["${var.documents_bucket_arn}/${var.documents_prefix}*"]
  }

  statement {
    sid     = "ConnectVectorStore"
    effect  = "Allow"
    actions = ["rds-db:connect"]
    # IAM database auth, scoped to one DB user on one instance
    resources = [
      "arn:${data.aws_partition.current.partition}:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${var.db_resource_id}/${var.db_username}"
    ]
  }
}
```

## Checkov Skip Policy

Security control skips are handled at the resource level:

- **No Repo-Wide Skips**: The `.checkov.yaml` file contains no global skips
- **Inline Skips Only**: Individual resources use inline skip comments with justification:

```hcl
resource "aws_s3_bucket" "documents" {
  bucket = local.bucket_name
  #checkov:skip=CKV_AWS_18: Logging configured separately in aws_s3_bucket_logging
  #checkov:skip=CKV_AWS_20: Public access block enforced via separate resource

  # ... rest of configuration
}
```

Each skip cites the specific reason why the control is not applicable to this resource.

## Lock Files

Terraform lock files are committed selectively:

- **Examples**: Lock files REQUIRED in `examples/minimal` and `examples/full-stack` to provide reproducible deployments
- **Modules**: Lock files are NEVER committed in `modules/*`; modules are meant to be flexible, and lock files would pin consumers

## Git Conventions

All commits follow Conventional Commits format:

```
<type>(<scope>): <subject>
<blank line>
<body>
<blank line>
<footer>
```

Rules:

- **Type**: `feat`, `fix`, `docs`, `test`, `chore`, `ci` (lowercase)
- **Scope**: Module or document area (e.g., `network`, `kms`, `conventions`, `audit`)
- **Subject**: Imperative mood, ≤ 72 characters, no period
- **Body**: Explain the why, not the what; wrap at 72 characters
- **Footer**: Reference related issues (e.g., `Closes #123`)

Example:

```
feat(network): Add VPC with no-egress endpoint connectivity

Configure private subnets with VPC interface endpoints for Bedrock,
S3, KMS, and other core services. Omit NAT gateway and Internet
Gateway to enforce network isolation.

Closes #42
```

### State Strategy

The state strategy and deployment patterns for consumers are documented in a separate architecture decision record (ADR-002).
