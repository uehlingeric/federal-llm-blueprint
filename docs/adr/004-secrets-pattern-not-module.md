# ADR-004: Secrets as Pattern and Policy, Not a Module

**Status:** Accepted  
**Date:** 2026-07-04

## Context

Week-3 architecture includes a secrets capability: Secrets Manager resources (encrypted with the `secrets` domain CMK), resource policies restricting access to specific roles, and injection into ECS task definitions. The week-3 plan noted this component's placement as an open question: should secrets be a standalone `modules/secrets`, embedded in `modules/iam`, or documented as a pattern for consumers to implement?

Three competing pressures:
1. **Code reuse:** Secrets appear in multiple workloads (gateway API key, RDS master password, future third-party integrations).
2. **Abstraction cost:** A `modules/secrets` would wrap a single `aws_secretsmanager_secret` resource + one `aws_secretsmanager_secret_resource_policy`. The abstraction surface (inputs: name, description, kms_key_id, allowed_role_arn; outputs: arn, id) adds interface complexity for what is a trivial resource.
3. **Lifecycle coupling:** Secrets are consumer resources, not platform infrastructure. A module in `modules/` suggests shared infrastructure; in practice, the gateway owns the gateway key, the vector-store owns the RDS master password. Centralizing them breaks the module dependency graph (iam → secrets → kms, instead of each consumer independently depending on kms and iam outputs).

**The test:** Would a senior engineer call `modules/secrets` overengineered? Yes—one resource per secret, each consumer writes ~10 lines of HCL, the pattern enforces itself.

## Decision

**No standalone `modules/secrets`. Instead, the capability is delivered via (a) the kms `secrets` CMK with ViaService conditions, (b) IAM policy statements scoped to secret ARNs (provided in the iam module), and (c) `docs/secrets-handling.md` as the normative pattern.**

Consumers (gateway in week 4, vector-store in week 5) implement secrets by:
1. Creating an `aws_secretsmanager_secret` resource in their module, referencing `var.kms_key_ids["secrets"]`.
2. Attaching a resource policy restricting to their app/task role (example HCL in secrets-handling.md).
3. Referencing the secret ARN in the task definition (for ECS) or rotation configuration (for RDS).

The iam module provides read-scoped statements as helper-policy blocks (to copy into consumer modules if desired):

```hcl
# In iam/outputs.tf (example)
output "policy_statement_secrets_read" {
  description = "Policy statement for reading Secrets Manager secrets; consumer embeds and modifies for specific secret ARNs"
  value = {
    sid       = "ReadSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:{region}:{account}:secret:{project}-*"]
    condition = {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }
}
```

Enforcement via code review and checkov (secret rules) rather than module defaults.

## Consequences

- **Clarity:** Each consumer owns its secrets; no hidden dependency on a shared secrets module.
- **Simplicity:** Consumers copy the pattern from `docs/secrets-handling.md` and write ~10 lines per secret. No module to maintain, document, or version-bump.
- **Scalability:** If secret count grows (5+ secrets) or drift becomes painful (e.g., inconsistent KMS key IDs or role access), revisit this decision and extract a module at that point. For now, boilerplate is acceptable.
- **Enforcement:** Checkov rules detect unencrypted secrets, missing resource policies, and secrets in plaintext in Terraform files. Policy review catches deviations.
- **Consistency:** `docs/secrets-handling.md` is the single source of truth. All secrets follow the same structure, encryption, and injection pattern.

**Revisit trigger:** If the number of secrets exceeds 5 and manual audits show >20% of secrets deviate from the pattern (missing resource policies, wrong KMS key IDs, incorrect role ARNs), extract a module.

## Alternatives Considered

**Standalone `modules/secrets`**  
Rejected. A module wrapping a single resource adds interface overhead without abstraction value. Interface: `aws_secretsmanager_secret` input (name, description, kms_key_id, recovery_window, tags), `aws_secretsmanager_secret_resource_policy` input (principal ARN, allowed actions). Output: secret ARN. The consumer must still write a resource policy block; the module doesn't simplify it. Would increase module surface area (8 modules becomes 9), CI testing burden, and documentation pages. The harm of "module per resource" outweighs the benefit of centralized encryption/policy defaults.

**Embed in `modules/iam`**  
Rejected. IAM's responsibility is access control, not resource creation. Secrets are consumer resources (gateway key, RDS password), not platform IAM infrastructure. Coupling iam to secrets breaks the dependency direction: consumers depend on iam (for role ARNs) and kms (for key IDs), not the reverse. If a consumer's secret is deleted, the iam module remains unchanged—the secret resource is not owned by iam.

**Documented pattern with helper module**  
Considered. A thin `modules/secrets_helper` that exports only policy-statement templates (no resource creation) could be useful for copy-paste. Rejected as too light to justify a module directory. The pattern doc (`docs/secrets-handling.md`) and a policy template in iam outputs are sufficient.

**Terraform modules/local modules**  
Considered. Shipping local modules in `modules/` would avoid needing a registry. Still subject to the same decision: does wrapping `aws_secretsmanager_secret` justify a module? No. The pattern is the point, not the code reuse.
