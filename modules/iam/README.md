# IAM Module — Identity, Authorization & Least-Privilege Roles

This module establishes the **identity and authorization backbone** for a federal LLM deployment: least-privilege IAM roles, permission boundaries, and human role tiers for operations and audit.

## Design Philosophy: Permission Boundaries as Ceilings

The centerpiece of this module is the **permission boundary policy**, a statement-level policy document that acts as a **ceiling** — not a grant. Every role created by this module attaches this boundary, preventing any identity policy from escalating beyond the defined scope.

### Why Boundaries?

Permission boundaries solve the problem of least-privilege administration:
- A role can be granted `ec2:*` in its identity policy (allowing modifications to EC2 resources).
- The boundary permits only `ec2:Describe*` (read-only).
- The **intersection** of the two policies is `ec2:Describe*` — the boundary wins.

This allows developers to reason about **"what could this role ever do?"** without reading every consumer's identity policy. The boundary is the promise; the identity policies are the grants.

### Boundary Structure

The boundary document contains three sections:

1. **ALLOW statements (service ceiling):** Lists every service family the stack can invoke — EC2 Describe, ECS ops, ECR read, CloudWatch Logs, KMS crypto, Secrets Manager, S3, RDS, Bedrock, etc. Resource `"*"` is acceptable here because boundaries are **ceilings**, not grants; the actual scoping happens in identity policies and conditions.

2. **EXPLICIT DENY (boundary escape prevention):**
   - Forbid removal of the boundary itself (`iam:PutRolePermissionsBoundary`, `iam:DeleteRolePermissionsBoundary`).
   - Self-referential deny: Any new role created or policy attached must name THIS boundary as its boundary (prevents creating an unconstrained admin role).

3. **EXPLICIT DENY (high-blast-radius prevention):**
   - Organizations, Account, IAM access-key/login-profile management, KMS key deletion, CloudTrail/Config recorder modification.

Every ALLOW statement includes a `# boundary: ` comment explaining exactly what it permits and what stops further escalation.

### Checkov Skips

Five Checkov checks (CKV_AWS_107, 108, 109, 111, 356) are skipped on the boundary with justifications:
- Boundaries **define** Resource `"*"` as the ceiling; identity policies scope down.
- Credentials exposure, data exfiltration, permissions management, and write actions are all scoped by the intersection with identity policies.

## Role Inventory

| Role | Trust | Identity Policies | Boundary Restrictions |
|------|-------|-------------------|-----------------------|
| **task_execution** | ECS service (`ecs-tasks.amazonaws.com`) | ECR auth token, ECR image pull, CloudWatch Logs write, Secrets read, KMS decrypt | All boundary limits apply |
| **app_task** | ECS service (`ecs-tasks.amazonaws.com`) | Bedrock invoke (scoped to model ARNs), S3 read (scoped to prefixes), RDS IAM auth, KMS decrypt | All boundary limits apply |
| **ci_deploy** (conditional) | var.ci_trust_principal_arns (GitHub OIDC, etc.) | AWS managed ReadOnlyAccess | All boundary limits apply; apply permissions are consumer-specific |
| **platform-admin** (conditional) | var.human_trust_principals (IdP roles) + MFA required | AWS managed PowerUserAccess + IAMReadOnlyAccess | Boundary prevents full admin; human cannot scale resources beyond permission boundary |
| **auditor** (conditional) | var.human_trust_principals + MFA | AWS managed SecurityAudit, CloudWatchLogsReadOnlyAccess, CloudTrailReadOnlyAccess | Read-only visibility into compliance state, logs, and audit trails |
| **developer** (conditional) | var.human_trust_principals + MFA | AWS managed ReadOnlyAccess + scoped inline for ECS deploy-to-nonprod | Deploy-to-nonprod pattern; ECS UpdateService/UpdateTaskSet only on resources tagged Environment = dev |

## Scope Markers

This module includes `TODO(scope): ...` comments indicating where policies will be tightened as consumers (ecs-llm-gateway, vector-store, document-store) are built:

- **ecr_repository_arns**: Defaulted to empty; scoped to container registry in week 4.
- **log_group_arns**: Defaulted to empty; scoped to ECS log groups in week 4.
- **bedrock_model_ids**: Defaulted to empty; supplied by ecs-llm-gateway in week 4.
- **db_resource_ids** / **db_usernames**: Defaulted to empty; supplied by vector-store in week 5.
- **document_bucket_arns** / **document_bucket_read_prefixes**: Defaulted to empty; supplied by document-store in week 5.

Empty-list statements are omitted via `dynamic` blocks (invalid policies with empty resource lists are prevented).

## Usage

```hcl
module "iam" {
  source = "./modules/iam"

  project             = "fedllm"
  environment         = "dev"
  data_classification = "cui"

  # From kms module
  kms_key_arns = {
    data    = module.kms.key_arns["data"]
    logs    = module.kms.key_arns["logs"]
    secrets = module.kms.key_arns["secrets"]
  }

  # Empty defaults; scoped in week 4–5
  ecr_repository_arns                = [] # Supplied by ecs-llm-gateway module
  log_group_arns                     = [] # Supplied by observability module
  bedrock_model_ids                  = [] # Supplied by ecs-llm-gateway module
  document_bucket_arns               = [] # Supplied by document-store module
  document_bucket_read_prefixes      = [] # Supplied by document-store module
  db_resource_ids                    = [] # Supplied by vector-store module
  db_usernames                       = [] # Supplied by vector-store module

  # CI/CD (GitHub Actions OIDC role)
  ci_trust_principal_arns = [
    "arn:aws:iam::123456789012:role/github-actions-oidc"
  ]

  # Human role tiers (from IdP, e.g., Okta)
  human_trust_principals = {
    platform-admin = ["arn:aws:iam::123456789012:role/okta-admin"]
    auditor        = ["arn:aws:iam::123456789012:role/okta-auditor"]
    developer      = ["arn:aws:iam::123456789012:role/okta-developer"]
  }

  tags = {
    Owner = "Platform Engineering"
  }
}

# Outputs
output "task_execution_role_arn" {
  value = module.iam.task_execution_role_arn
}

output "app_task_role_arn" {
  value = module.iam.app_task_role_arn
}

output "human_role_arns" {
  value = module.iam.human_role_arns
}
```

## Testing

All roles have the permission boundary attached; validated by `terraform test`:

```bash
terraform -chdir=modules/iam test
```

Three test suites:
- **boundary_attached.tftest.hcl:** Verifies all created roles have the boundary, correct path, and ARNs match.
- **conditional_creation.tftest.hcl:** Verifies roles are created only when their trust principals are supplied (count/for_each semantics).
- **validation.tftest.hcl:** Validates variable enumerations (environment, data_classification) and full configs.

## Compliance Notes

- **AC-2 (Access Control - Account Management):** IAM role definitions with least-privilege policies and boundaries.
- **AC-3 (Access Control - Enforcement):** Permission boundaries enforce the ceiling; identity policies define the grant.
- **AC-6 (Least Privilege):** All roles scoped to minimal actions; no wildcard actions or resources except in boundaries (documented).

---

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9.0, < 2.0.0 |
| aws | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_iam_policy.permission_boundary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.app_task](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.ci_deploy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.human_tier](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.task_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.app_task](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.developer_deploy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.task_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.admin_iam_readonly](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.admin_power_user](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.auditor_cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.auditor_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.auditor_security](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.ci_deploy_readonly](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.developer_readonly](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.app_task](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.app_task_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.ci_deploy_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.developer_deploy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.human_tier_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.permission_boundary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.task_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.task_execution_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| environment | Deployment environment (dev, staging, prod) | `string` | n/a | yes |
| project | Project name used in resource naming and tags | `string` | n/a | yes |
| bedrock\_inference\_profile\_arns | Optional Bedrock inference profile ARNs for managed services. When empty, the policy statement is omitted. | `list(string)` | `[]` | no |
| bedrock\_model\_ids | List of Bedrock foundation model IDs (e.g., ['anthropic.claude-opus-20250219-v1:0']). ARNs are constructed as arn:{partition}:bedrock:{region}::foundation-model/{id}. When empty, the policy statement is omitted. TODO(scope): supplied by ecs-llm-gateway module in week 4. | `list(string)` | `[]` | no |
| ci\_trust\_principal\_arns | ARNs of CI/CD principals (e.g., GitHub Actions OIDC role) that can assume the ci\_deploy role. When empty, the ci\_deploy role is not created (count = 0). | `list(string)` | `[]` | no |
| data\_classification | Data classification level: public, internal, or cui | `string` | `"cui"` | no |
| db\_resource\_ids | RDS resource IDs for IAM database authentication (e.g., ['db-ABCD1234']). Paired with db\_usernames to construct rds-db:connect ARNs. When empty, the policy statement is omitted. TODO(scope): supplied by vector-store module in week 5. | `list(string)` | `[]` | no |
| db\_usernames | RDS database usernames for IAM auth (parallel list with db\_resource\_ids). When empty, the policy statement is omitted. | `list(string)` | `[]` | no |
| document\_bucket\_arns | S3 bucket ARNs for document store. app\_task role can list and get objects with scoped prefixes. When empty, the policy statement is omitted. TODO(scope): supplied by document-store module in week 5. | `list(string)` | `[]` | no |
| document\_bucket\_read\_prefixes | S3 object prefixes within document buckets that app\_task can read (e.g., ['arn:aws:s3:::bucket/documents/*']). Full ARNs including prefix. When empty, the policy statement is omitted. | `list(string)` | `[]` | no |
| document\_key\_prefixes | Bare S3 key prefixes (e.g., ['documents/']) used in the s3:prefix condition scoping ListBucket. Distinct from document\_bucket\_read\_prefixes, which are object ARNs. When empty, listing is scoped to the named buckets without a prefix condition. | `list(string)` | `[]` | no |
| ecr\_repository\_arns | ECR repository ARNs; task\_execution role can pull from these. When empty, the policy statement is omitted. TODO(scope): tightened in week 4 when container registry exists. | `list(string)` | `[]` | no |
| human\_trust\_principals | Map of role tier names (platform-admin, auditor, developer) to lists of trust principal ARNs (e.g., IdP role ARNs for SSO users). Example: { platform-admin = ["arn:aws:iam::...:role/Admin"], developer = ["arn:aws:iam::...:role/Dev"] }. Tiers not supplied are not created. Empty map → no human roles created. | `map(list(string))` | `{}` | no |
| kms\_key\_arns | KMS key ARNs keyed by domain (data, logs, secrets). Used in IAM policies to scope key operations. | `map(string)` | `{}` | no |
| log\_group\_arns | CloudWatch log group ARNs for ECS task logs. task\_execution role can create streams and write events. When empty, the policy statement is omitted. TODO(scope): tightened in week 4 when log groups exist. | `list(string)` | `[]` | no |
| secret\_arns | Secrets Manager secret ARNs (e.g., gateway API keys). When empty, the policy statement is omitted. TODO(scope): populated when secrets are created. | `list(string)` | `[]` | no |
| tags | Additional tags applied to all taggable resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| app\_task\_role\_arn | ARN of the ECS app task role (Bedrock invoke, database connect, S3 read, KMS decrypt). Consumed by ecs-llm-gateway task definitions. |
| ci\_deploy\_role\_arn | ARN of the CI/CD deployment role (terraform plan/apply). Null if ci\_trust\_principal\_arns is empty. |
| human\_role\_arns | Map of human role ARNs keyed by tier (platform-admin, auditor, developer). Tiers not supplied in var.human\_trust\_principals are not present in the map. |
| permission\_boundary\_arn | ARN of the permission boundary policy applied to all created roles. Defines the ceiling of permitted actions. |
| task\_execution\_role\_arn | ARN of the ECS task execution role (image pull, logs write, secrets read). Consumed by ecs-llm-gateway. |
<!-- END_TF_DOCS -->
