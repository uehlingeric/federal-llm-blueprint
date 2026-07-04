# ADR-002: State Strategy—Local Examples, Documented Remote Pattern

**Status:** Accepted  
**Date:** 2026-07-04

## Context

Terraform state contains sensitive values: resource ARNs, endpoint addresses, KMS key IDs, and potentially secret metadata (RDS master user ARNs, service-linked role assumptions). State is also a critical consistency mechanism: `terraform plan` against stale state invites drift and race conditions.

This is a *public reference architecture.* A user cloning the repo cannot be assumed to have a pre-provisioned S3 backend bucket or Terraform Cloud account. Hardcoding a backend in example modules breaks `terraform init` on clone and violates the "works immediately" principle for reference code.

Yet production deployments require remote state with locking and encryption—a documented expectation in an ATO context where state is CUI-adjacent.

## Decision

**Examples ship with local state (default) and a commented remote-state block; the documented production pattern is S3 + Terraform ≥1.10 lockfile.**

Example module structure:
```hcl
terraform {
  required_version = "~> 1.10"
  # Uncomment for production. See PRODUCTION_STATE.md for bucket setup.
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "federal-llm-blueprint/terraform.tfstate"
  #   region         = "us-west-2"
  #   encrypt        = true
  #   use_lockfile   = true
  # }
}
```

Production pattern (documented in `docs/PRODUCTION_STATE.md`):
- **S3 bucket:** versioning enabled, SSE-KMS with dedicated CMK, public-access block all-deny, TLS-only bucket policy, CloudTrail access logging
- **Locking:** `use_lockfile = true` (Terraform ≥1.10, S3-native, no DynamoDB table required)
- **GovCloud:** Pattern works identically; use `aws-us-gov` partition ARNs in bucket policy
- **State classification:** Treat as CUI when the stack manages CUI workloads; log all `terraform apply` invocations to CloudTrail

## Consequences

- Users can `terraform init && terraform apply` immediately after cloning for sandbox/demo purposes.
- Users *must* uncomment and configure the backend before production use—this is documented and enforced by code review checklist.
- CI/CD systems never touch state; `terraform plan -out` writes to local `.tfplan` for review; apply is manual (or requires human approval via `settings.json` hook).
- State drift is the deployer's responsibility to detect and correct (weekly `terraform plan` runs logged to audit).

## Alternatives Considered

**Terraform Cloud / HCP Terraform**  
Viable for commercial users but rejected as the default. Introduces external SaaS dependency (TF API, registry) and contradicts the no-egress posture documented in week-7 air-gap guide. Recommended as an option for teams with existing TFE/TFC licensing.

**DynamoDB table locking**  
Legacy pattern pre-Terraform 1.10. S3 lockfile is simpler (no additional DynamoDB table, no Lambda for cleanup, no cross-region replication). Documented only as an alternative for Terraform <1.10 users.

**Force a backend module**  
Rejected. Creates chicken-and-egg problem: how does a new user initialize the backend module on first apply? Would require terragrunt or manual script orchestration, violating the "works on clone" principle.

**Encrypted local state in VCS**  
Rejected. State must be rotatable; VCS commits are immutable. Sensitive values would be in git history forever.
