# Contributing to Federal LLM Blueprint

Contributions are welcome. This document outlines expectations for code changes, testing, compliance, and pull requests.

## Development Setup

### Required Tools

- **Terraform**: >= 1.9.0, < 2.0.0 (CI tests against 1.9.8)
- **AWS CLI**: any recent version
- **tflint**: v0.63.1 (pinned in CI)
- **checkov**: 3.3.6 (pinned in CI; includes PyYAML for control-reference checking)
- **terraform-docs**: v0.24.0 (pinned in CI)
- **python3** with PyYAML: required for `make check-controls` and `make oscal-check`

Pin exact tool versions in your local development environment to match CI. The `.github/workflows/ci.yml` file is the source of truth for all versions.

### Initial Setup

```bash
make init
```

This initializes all Terraform directories without a backend (`-backend=false`), creating a plugin cache at `$HOME/.terraform.d/plugin-cache`.

## The Gate: make validate

Before pushing, run:

```bash
make validate
```

This executes the full CI validation gate sequentially:

1. `make fmt-check` — Verify all code is formatted per `terraform fmt`
2. `make tf-validate` — Terraform syntax validation
3. `make tflint` — Linter checks
4. `make checkov` — Security policy checks
5. `make check-controls` — Verify CONTROLS.md, docs/controls.yaml, and code annotations are in sync
6. `make oscal-check` — Verify docs/oscal/component-definition.json is current with controls.yaml
7. `make docs-check` — Verify module READMEs are current (runs `make docs` and fails if changes exist)
8. `make test` — Run all Terraform native tests

All must pass. If any step fails, the gate stops.

## Version Floor and Testing

This repository maintains a **minimum Terraform version of 1.9.0**. The CI pipeline explicitly tests against **1.9.8** to ensure code does not accidentally depend on newer language features (e.g., 1.10+ syntax). Bumping the floor version requires a documented change and review.

To verify your code against the floor:

```bash
terraform -version  # Ensure >= 1.9.0
make validate
```

## Test Conventions

Tests use **Terraform native tests** (terraform test) with mock providers. Key rules:

- **Test Location**: Every module must include a `tests/` directory with `.tftest.hcl` files.
- **Mock Providers**: Use `mock_provider` in test blocks for AWS resources.
- **Mock Defaults**: Policy mock defaults must be literal JSON objects—no function calls (Terraform 1.9 does not support function calls in mock defaults).
- **Example Structure**:

```hcl
run "kms_key_created" {
  command = apply

  assert {
    condition     = aws_kms_key.this["data"].enable_key_rotation == true
    error_message = "KMS key rotation must be enabled"
  }
}
```

See `modules/kms/tests/` and `modules/network/tests/` for reference implementations.

## Checkov Policy

- **No repository-wide skips** in `.checkov.yaml`. Every skip is inline at the resource level.
- **Every skip requires a justification comment**, citing the specific reason:

```hcl
resource "aws_cloudwatch_log_group" "gateway" {
  #checkov:skip=CKV_AWS_338: Retention is configurable via var.log_retention_days; default 90 days is appropriate for gateway logs in development environments. Federal deployments set 365+.
  name              = "/ecs/${local.name_prefix}-gateway"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
}
```

Unjustified skips will be flagged during review.

## Module Documentation

Module READMEs are generated. Do not hand-edit the content between `<!-- BEGIN_TF_DOCS -->` and `<!-- END_TF_DOCS -->` markers.

To regenerate:

```bash
make docs
```

This runs `terraform-docs -c .terraform-docs.yml modules/<name>` for each module, injecting documentation into the README.md file. If you modify variables, outputs, or resource signatures, regenerate docs and commit the changes.

`make docs-check` enforces that committed READMEs are current. CI will fail if you commit code changes without running `make docs`.

## Commit Format

All commits follow **Conventional Commits** format:

```
<type>(<scope>): <imperative subject>

<body explaining the why>

<footer with issue references>
```

### Rules

- **Type**: `feat`, `fix`, `docs`, `test`, `chore`, `ci` (lowercase only)
- **Scope**: Module or document area (e.g., `network`, `kms`, `audit`, `contributing`)
- **Subject**: Imperative mood (not "adds", "added"), ≤ 72 characters, no period
- **Body**: Explain the why, not the what; wrap at 72 characters; optional but encouraged
- **Footer**: Reference related issues with `Closes #123`, `Fixes #456`; optional

### Examples

```
feat(network): add VPC with no-egress endpoint connectivity

Configure private subnets with VPC interface endpoints for Bedrock,
S3, KMS, and other core services. Omit NAT gateway and Internet
Gateway to enforce network isolation.

Closes #42
```

```
fix(kms): correct key-admin statement to exclude cryptographic operations

The key-admin statement previously included Encrypt and Decrypt
permissions. Admins now have management-only access; cryptographic
operations flow through service-account statements.

Fixes #15
```

## Compliance Language Rules

This repository is strict about control-mapping terminology to maintain precision for federal compliance documentation.

**Mandatory language:**
- Controls are **"aligned to"** NIST 800-53 (never "satisfied," "compliant," or "FedRAMP-ready")
- Detective controls **flag** noncompliance (never "prevent")
- The stack **implements**, **contributes to**, or is **inherited from AWS** (never "guarantees")

**Examples of correct phrasing:**
- "The audit module's CloudTrail implementation is aligned to AU-2 Audit Events."
- "AWS Config rules flag noncompliant resources."
- "KMS encryption is inherited from AWS managed service."

**Examples of incorrect phrasing (do not use):**
- "satisfies control AC-2" → "is aligned to control AC-2"
- "This guarantees network isolation" → "This implementation contributes to network isolation"
- "FedRAMP-ready deployment" → "Federal compliance-posture reference architecture"

Changes that touch `CONTROLS.md`, `docs/controls.yaml`, or control annotations in code must keep all three in sync. Run `make check-controls` to verify consistency.

## Contributions Welcome

**In scope:**
- Bug fixes to Terraform code
- Documentation gaps and clarifications
- Additional NIST 800-53 control mappings
- Cost data, performance benchmarks, or operational guidance
- New tests for existing modules
- Security improvements

**Out of scope:**
- Converting this into a fully-packaged ATO submission (it's a reference, not a compliance package)
- Organization-specific policies or environment overrides
- Application-layer guardrails or LLM-specific tuning (see the companion `agentic-rag` project)
- Multi-region active-active failover (single-region reference)

If in doubt, open an issue to discuss before investing effort.

## Code Review Expectations

All pull requests are reviewed for:

1. **Correctness**: Code runs without error; no logic bugs
2. **Compliance**: Changes touching controls maintain terminology rigor
3. **Testing**: New code has tests; tests pass
4. **Documentation**: Docs are generated and current; architectural impact is explained
5. **Style**: Code follows repository conventions (see `docs/conventions.md`)

Reviewers may request changes. Respect the review process—this is a reference architecture and precision matters.

## License

By contributing, you agree that your contributions are licensed under the MIT License (see LICENSE).
