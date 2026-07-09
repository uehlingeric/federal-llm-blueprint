# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**Note:** This project is in pre-1.0 phase. Until 1.0.0 is released, minor version changes (`0.x.y`) may introduce breaking changes to module interfaces. See [CONTRIBUTING.md](CONTRIBUTING.md) for version-floor guarantees.

## [Unreleased]

## [0.1.0] - Unreleased

### Added

#### Terraform Modules (8 total)

- **kms**: Customer-managed KMS keys partitioned by domain (data, logs, secrets) with automatic rotation, least-privilege key policies, and partition awareness (no hard-coded ARNs or service principals)
- **network**: Private-VPC architecture with 2–3 availability zones, no-egress mode (zero IGW/NAT, all traffic via VPC endpoints), flow logs, security groups for app and endpoints
- **iam**: Task execution role (ECR pull, CloudWatch logs), app task role (scoped Bedrock invocation, database, S3 access), optional CI deploy role, human role tiers (platform-admin, auditor, developer) with MFA enforcement, universal permission boundary
- **ecs-llm-gateway**: ECS Fargate cluster, hardened task definition (non-root, read-only filesystem), LiteLLM container (digest-pinned), internal ALB with TLS, health checks, CPU and request-count autoscaling
- **vector-store**: RDS PostgreSQL 16 with pgvector extension, customer-managed encryption, IAM database authentication, RDS-managed secret rotation, private-subnet-only, security-group ingress scoped to app tier
- **document-store**: S3 bucket suite (documents, access logs, ALB logs) with versioning, SSE-KMS encryption, public-access block, TLS-only policies, optional object lock for compliance-mode retention
- **audit**: CloudTrail with log-file validation and multi-region recording, AWS Config recorder with managed rule set aligned to 800-53 controls, Bedrock model-invocation logging (metadata-only by default)
- **observability**: Log-group factory (KMS-mandatory, retention policies), platform alarm baseline (RDS health, endpoint connectivity, CloudTrail tampering), Config-noncompliance EventBridge notifications, SNS topic, CloudWatch dashboard

#### Compositions (2 examples)

- **examples/minimal**: Sandbox cost profile demonstrating core modules in a no-egress configuration
- **examples/full-stack**: Production-shaped profile with full audit, observability, and cost-modeling documentation

#### Testing & CI (120 tests)

- Terraform native tests (terraform test) with mock_provider patterns across all 8 modules
- CI pipeline gates: terraform fmt, terraform validate, tflint, checkov (no repo-wide skips; every skip inline-justified), terraform-docs drift detection, control-reference consistency check, OSCAL freshness check
- Test floor: Terraform 1.9.8 (ensures code does not accidentally require 1.10+ features)

#### Compliance Documentation

- **CONTROLS.md**: 24 NIST SP 800-53 Revision 5 controls (AC, AU, CM, IA, RA, SC, SI) with implementation statements, resource citations, and responsibility split (stack vs. customer)
- **docs/controls.yaml**: Machine-readable control mapping for tooling and SSP generation
- **docs/oscal/component-definition.json**: OSCAL 1.1.3 component definition generated deterministically from controls.yaml (`scripts/generate-oscal.py`), freshness-checked in CI
- **docs/threat-model.md**: STRIDE threat model across five operational planes (network, identity/crypto, compute, data, audit/observability)
- **docs/airgap-guide.md**: AWS GovCloud and air-gap deployment runbook with no-egress verification steps
- **docs/audit-correlation.md**: Audit trail correlation guide for Bedrock, RDS, S3, CloudTrail, and Config events
- **docs/rbac-model.md** and **docs/secrets-handling.md**: Human role tiers and secrets lifecycle patterns
- **docs/verification/**: Executable proof procedures (no-egress, gateway, vector store, audit walkthrough)

#### Architecture Decision Records (ADRs)

- **docs/adr/001-ecs-fargate-over-eks.md**: ECS Fargate over EKS for the LLM gateway
- **docs/adr/002-state-strategy.md**: Local state for examples, documented remote pattern for production
- **docs/adr/003-no-egress-as-mode-not-fork.md**: Network isolation as a mode, not a separate fork
- **docs/adr/004-secrets-pattern-not-module.md**: Secrets as pattern and policy, not a module
- **docs/adr/005-config-injection-via-ssm.md**: Config injection via SSM parameter + ECS secrets + entrypoint materialization
- **docs/adr/006-pgvector-over-opensearch.md**: pgvector on RDS Postgres for the vector store
- **docs/adr/007-prompt-capture-posture.md**: Metadata-only prompt capture by default

#### Utilities

- **scripts/seed-vectors.py**: pgvector bootstrap proof — creates the embeddings table with an HNSW index, seeds deterministic sample vectors, runs a cosine-similarity query
- **scripts/check-control-refs.py**: CI tool validating CONTROLS.md, docs/controls.yaml, and code annotation consistency
- **scripts/generate-oscal.py**: Deterministic OSCAL component-definition generator with `--check` freshness mode
- **scripts/verify-teardown.sh**: Post-destroy verification script detecting billable residue (undeleted KMS keys, snapshots, orphaned ENIs, log groups)

#### Repository Standards

- **docs/conventions.md**: Resource naming, tagging, IAM policy patterns, version pinning, partition safety, Checkov skip discipline
- **docs/architecture.md**: Five-plane design, module responsibility matrix, interface contracts, no-egress mode invariants, data flows with sequence diagrams, state strategy
- **CONTRIBUTING.md**: Development setup, CI gate explanation, test conventions, commit format, compliance-language rules
- **SECURITY.md**: Vulnerability reporting via GitHub private vulnerability reporting, supported-version policy, scope boundaries
- **README.md**: Positioning, architecture diagram, control-coverage summary, quickstart, module table

[0.1.0]: https://github.com/uehlingeric/federal-llm-blueprint/releases/tag/v0.1.0
