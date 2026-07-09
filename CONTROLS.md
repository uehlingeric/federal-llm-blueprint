# NIST 800-53 Rev5 Control Mapping

## Purpose and Scope

This document maps the Federal LLM Blueprint Terraform stack to NIST SP 800-53 Revision 5 security controls. It is a skeleton for a System Security Plan (SSP) control section and articulates how the deployed infrastructure implements compliance controls.

**Scope:** This mapping covers only the Terraform stack in this repository (eight modules: network, kms, iam, ecs-llm-gateway, vector-store, document-store, audit, observability). It does NOT cover:
- Application layer (LLM model behavior, input validation, output filtering — deployer responsibility)
- Organizational policies (personnel security, awareness/training, contingency planning)
- Deployed-evidence proofs (evidence pending — see docs/verification/)

**Vocabulary (Fixed):**
- **Implements** — the stack's configuration directly provides the control mechanism (cite Terraform resource).
- **Contributes to** — partial; the stack implements part A; the deployer or AWS service provides part B (specify which part is whose).
- **Inherited from AWS** — the AWS managed service provides the mechanism (e.g., KMS HSM physical protection).
- **Customer responsibility** — the deployer must do it; the stack only enables it.

Never use: "satisfies," "complies with," "compliant," "FedRAMP-ready." The stack is "aligned to controls, evidence pending."

**Evidence Status:** Static assertions are enforced in CI (terraform-docs, checkov, tflint, manual code review). Deployed-evidence proofs (execution transcripts) are documented in docs/verification/; evidence collection is TRANSCRIPT PENDING — each proof requires a live deployment and audit-log extraction.

---

## AC — Access Control

### AC-2 — Account Management

**Implementation Statement:**
The Terraform stack defines a structured RBAC model with explicit principal inventory: service roles (task_execution, app_task) assumed by ECS with SourceAccount/SourceArn conditions; an optional ci_deploy role trusting caller-supplied IAM principal ARNs; human role tiers (platform-admin, auditor, developer) assumable only with MFA; and a universal permission boundary that prevents escalation. Every role carries mandatory tags (Project, Environment, ManagedBy, DataClassification) for auditability. Role trust policies enforce conditions: human roles require `aws:MultiFactorAuthPresent = true`; service roles bind to specific AWS services and source accounts. The boundary explicitly denies all access-key and login-profile management (`iam:*AccessKey*`, `iam:*LoginProfile*`), preventing local-user and direct-credential patterns.

**Implementing Resources:**
- `modules/iam/main.tf` — `aws_iam_policy.permission_boundary` — Denies boundary removal (PutRolePermissionsBoundary, DeleteRolePermissionsBoundary), denies local credentials (iam:*AccessKey*, iam:*LoginProfile*), denies escalation (CreateRole, PutRolePolicy, AttachRolePolicy unless the target role carries this boundary). This is the enforcement point for all roles.
- `modules/iam/main.tf` — `aws_iam_role.task_execution` — Service role assumed by ECS (ecs-tasks.amazonaws.com) with SourceAccount condition.
- `modules/iam/main.tf` — `aws_iam_role.app_task` — Service role assumed by ECS with SourceAccount condition.
- `modules/iam/main.tf` — `aws_iam_role.human_tier` — Human role tiers (for_each over platform-admin, auditor, developer), each with trust condition aws:MultiFactorAuthPresent = true.
- `modules/iam/main.tf` — `aws_iam_role.ci_deploy` — Optional CI role trusting caller-supplied IAM principal ARNs; created only when var.ci_trust_principal_arns is non-empty.
- `docs/rbac-model.md` — Principals inventory and role assumption paths.

**Responsibility:** Stack (structure). Customer (IdP configuration, MFA enrollment, role assumption auditing).

**Gaps & Notes:**
The stack enforces structure (roles, boundaries, conditions). The deployer is responsible for configuring federated identity (Identity Center, third-party IdP), MFA device enrollment, and auditing actual role assumption attempts in CloudTrail to detect policy-bypass attempts.

---

### AC-3 — Access Enforcement

**Implementation Statement:**
Access control is enforced via layered mechanisms: (1) IAM role-policy pairs scoped to least-privilege resource ARNs (app_task reads documents from specified prefix, connects to named database users, invokes named Bedrock models); (2) security groups constraining traffic (default SG emptied, gateway service SG accepts the ALB only on the container port, database SG accepts the app SG only); (3) S3 bucket policies denying unencrypted transport and restricting object access; (4) RDS private-subnet isolation with security-group ingress from app tier only; (5) the S3 gateway endpoint policy restricting access to in-account buckets. The permission boundary intersects all identity policies, capping maximum scope. Data-plane access is granular per role.

**Implementing Resources:**
- `modules/iam/main.tf` — `aws_iam_policy.permission_boundary` — Ceiling policy; intersected with every identity policy.
- `modules/iam/main.tf` — `aws_iam_role_policy.app_task` — Identity policy with resource ARN scoping (S3 prefix, RDS user, Bedrock model ARNs).
- `modules/iam/main.tf` — `aws_iam_role_policy.task_execution` — ECR, CloudWatch Logs, Secrets Manager scoping.
- `modules/network/security-groups.tf` — `aws_security_group.app` — Workload SG; egress-only (443 to endpoints/S3, 5432 to VPC CIDR), no ingress rules.
- `modules/ecs-llm-gateway/main.tf` — `aws_vpc_security_group_ingress_rule.service_from_alb` — Gateway service SG accepts the ALB only, on var.container_port (default 4000).
- `modules/network/security-groups.tf` — `aws_security_group.endpoint` — Endpoint SG restricts VPC endpoint access to HTTPS from the VPC CIDR.
- `modules/vector-store/main.tf` — `aws_vpc_security_group_ingress_rule.db_from_app` — Database ingress only from app security group (port 5432).
- `modules/document-store/main.tf` — `aws_s3_bucket_policy.documents` — Deny unencrypted transport; scoped allow for app_task role.
- `modules/audit/main.tf` — `aws_s3_bucket_policy.audit` — Deny unencrypted; allow CloudTrail, Config, Bedrock write.
- `docs/rbac-model.md` — RBAC matrix defining resource scope and conditions per principal.

**Responsibility:** Stack (policies, security groups, bucket policies). Customer (verifying role policies are correctly scoped, auditing API calls).

**Gaps & Notes:**
The stack implements policy-driven enforcement. The deployer must verify identity policies match the application requirements and monitor CloudTrail for unexpected access patterns.

---

### AC-6 — Least Privilege

**Implementation Statement:**
Least privilege is enforced at the permission-boundary level. The boundary explicitly denies: iam:PutRolePermissionsBoundary, iam:DeleteRolePermissionsBoundary (prevents boundary removal); iam:CreateRole, iam:PutRolePolicy, iam:AttachRolePolicy unless the target role carries this boundary (prevents escalation via new roles); iam:*AccessKey*, iam:*LoginProfile* (prevents local credentials); kms:ScheduleKeyDeletion, kms:PutKeyPolicy (prevents key tampering); cloudtrail:StopLogging, cloudtrail:DeleteTrail, config:StopConfigurationRecorder, config:DeleteConfigurationRecorder (prevents audit disable); organizations:*, account:*. Anything outside the enumerated allow-list is implicitly denied: ECS permits describe, update, run, stop (no create/delete); S3 permits object-level read/write/delete (no bucket-policy modification); RDS permits describe and rds-db:connect (no modify). Config rule iam-policy-no-statements-with-admin-access continuously monitors for escalation attempts.

**Implementing Resources:**
- `modules/iam/main.tf` — `aws_iam_policy.permission_boundary` — 8 explicit deny statements prevent boundary removal, privilege escalation, and audit tampering; 17 allow statements enumerate service ceilings (EC2 describe, ECS ops, logs write, KMS crypto, S3 objects, RDS, Bedrock, etc.).
- `modules/audit/main.tf` — `aws_config_config_rule.rules["iam-policy-no-statements-with-admin-access"]` — Flags any IAM policy granting admin (*) permissions; continuous detective check.

**Responsibility:** Stack (boundary policy, Config rule). Customer (reviewing role identity policies, monitoring Config alerts).

**Gaps & Notes:**
The boundary is the enforcement point; it applies to all roles. The deployer must review identity policies to ensure they align with least-privilege and respond to Config noncompliance alerts.

---

### AC-17 — Remote Access

**Implementation Statement:**
Remote access is restricted via network isolation and security groups. The stack deploys a private VPC with no public internet gateway (in no-egress mode) or optional public subnets with NAT gating (standard mode). Default security group is explicitly emptied (no rules), preventing accidental SSH attachment. No security group in the stack carries an SSH rule. Config managed rule restricted-ssh flags any security group permitting unrestricted inbound SSH (0.0.0.0/0) — a detective control, not a preventive one. Remote access to compute (ECS tasks) is via the internal ALB only (HTTPS, port 443). Remote access to database (RDS) is via IAM authentication on the private network only. The permission boundary's STS allow-list contains only sts:AssumeRole and sts:GetCallerIdentity; other federation entry points are outside the ceiling for bounded principals.

**Implementing Resources:**
- `modules/network/main.tf` — `aws_default_security_group.main` — Explicitly emptied (no rules); prevents accidental attachment.
- `modules/network/security-groups.tf` — `aws_security_group.app` — No SSH rule; egress-only workload SG.
- `modules/audit/main.tf` — `aws_config_config_rule.rules["restricted-ssh"]` — Flags any SG permitting inbound SSH from 0.0.0.0/0.
- `modules/iam/main.tf` — `aws_iam_policy.permission_boundary` — STS allow-list limited to sts:AssumeRole and sts:GetCallerIdentity.
- `docs/rbac-model.md` — Role assumption paths (section 3).

**Responsibility:** Stack (network isolation, security groups, Config rule). Customer (corporate perimeter firewall/VPN, Bastion/Session Manager if console access needed, monitoring Config alerts).

**Gaps & Notes:**
The stack enforces network isolation (no public ingress to compute/database). The deployer must configure corporate network integration (VPN, firewall) and monitoring for SSH rule violations.

---

## AU — Audit and Accountability

### AU-2 — Event Logging

**Implementation Statement:**
CloudTrail records all management and data events. Management events capture all AWS control-plane API calls (create, modify, delete) across the account in all regions (multi-region trail enabled). Data events record object-level read/write on the documents S3 bucket (CUI access trail), scoped to that bucket's ARN in the trail's advanced event selector; CloudTrail Insights is a separate cost toggle (var.enable_insights, off by default). Bedrock model-invocation logging records API calls to foundation models (metadata-only by default per ADR-007; full-content capture is configurable). AWS Config records configuration snapshots per var.config_snapshot_frequency (default TwentyFour_Hours). CloudWatch Logs receive CloudTrail events in real-time. The audit trail captures: who (caller principal), what (action, resource, result), when (timestamp), where (source IP).

**Implementing Resources:**
- `modules/audit/main.tf` — `aws_cloudtrail.this` — Multi-region trail with enable_log_file_validation = true. advanced_event_selector for Management (all APIs) and Data (documents S3).
- `modules/audit/main.tf` — `aws_cloudwatch_log_group.trail` — CloudTrail → CloudWatch Logs real-time streaming.
- `modules/audit/main.tf` — `aws_config_configuration_recorder.this` — all_supported = true, all resources recorded.
- `modules/audit/main.tf` — `aws_bedrock_model_invocation_logging_configuration.this` — Bedrock API calls logged (metadata-only default).

**Responsibility:** Stack (event selection, logging infrastructure). Customer (event analysis, alert configuration, deployer-driven content capture via ADR-007).

**Gaps & Notes:**
The stack provides event generation; the deployer configures analysis tools and alerting. Deployer may enable full-content Bedrock logging if required (ADR-007 documents the trade-off).

---

### AU-3 — Content of Audit Records

**Implementation Statement:**
Audit records contain: source principal (AWS account ID, IAM role, federated identity), timestamp (ISO 8601), API action, resources affected (ARNs), result (success/error code), request parameters. CloudTrail records these natively for all AWS API calls. Bedrock invocation logs record: principal, model ID, timestamp, token count (metadata-only default), invocation ID. RDS logs record: user connection, timestamp, query (if enabled). CloudWatch Logs include: log group name, stream, timestamp, message. Records correlate via timestamp and caller identity, enabling end-to-end trails (user assumes role → invokes Bedrock → logs in CloudWatch, all via CloudTrail).

**Implementing Resources:**
- `modules/audit/main.tf` — `aws_cloudtrail.this` — CloudTrail event structure (managementEvents include full API metadata).
- `modules/audit/main.tf` — `aws_bedrock_model_invocation_logging_configuration.this` — Bedrock logs with principal, model, token count.
- `modules/vector-store/main.tf` — `aws_cloudwatch_log_group.postgresql` — RDS logs (pre-created, exported to CloudWatch).
- `modules/observability/main.tf` — `aws_cloudwatch_log_group.this` — Factory for KMS-encrypted application logs.

**Responsibility:** Stack (log structure, integration). Customer (correlation, analysis, SIEM ingestion).

**Gaps & Notes:**
The stack provides log structure; the deployer configures parsers and correlation (examples in audit-walkthrough.md).

---

### AU-6 — Audit Record Review, Analysis, and Reporting

**Implementation Statement:**
CloudWatch Logs Insights provides ad-hoc querying; the observability module provides a dashboard showing trail status, Config noncompliance trends, and alarm activity. CloudTrail console provides event history and API activity views. AWS Config continuously evaluates compliance (10 rules) and emits noncompliance events to EventBridge → SNS alarms. The audit-walkthrough.md document provides example Insights queries for incident investigation. Deployer can add Lambda automation, Athena for long-term queries, or third-party SIEM ingestion.

**Implementing Resources:**
- `docs/verification/audit-walkthrough.md` — Example audit queries and investigation procedures.
- `modules/observability/main.tf` — `aws_cloudwatch_dashboard.this` — Dashboard with Config noncompliance, alarm trends.
- `modules/observability/main.tf` — `aws_cloudwatch_event_rule.config_noncompliant` — Captures Config noncompliance and publishes to SNS.
- `modules/audit/main.tf` — `aws_config_configuration_recorder.this` — Continuous compliance evaluation.

**Responsibility:** Stack (logging, dashboard, Config rules). Customer (analysis tools, alerting, incident response).

**Gaps & Notes:**
The stack provides the data pipeline and basic dashboard; the deployer configures advanced analytics and response automation.

---

### AU-9 — Protection of Audit Information

**Implementation Statement:**
Audit logs are protected via: (1) Encryption at rest: CloudTrail S3, CloudWatch Logs, and Config snapshots use customer-managed KMS keys (separate CMK for logs domain); (2) Encryption in transit: S3 bucket policy denies unencrypted (non-TLS) transport; (3) Integrity: CloudTrail enable_log_file_validation computes SHA-256 hashes; subsequent hashes chain, enabling tamper detection; (4) Immutability: audit S3 bucket supports object lock (module default enabled, GOVERNANCE mode, 30-day default retention — the minimal example disables it for sandbox teardown; enable it for federal deployments); (5) Access control: audit bucket policy restricts write to the CloudTrail, Config, and Bedrock service principals — read access flows through IAM identity policies (e.g., the auditor tier's read-only attachments), not the bucket policy. Observability module provides a metric-filter alarm to detect CloudTrail API tamper attempts (StopLogging, DeleteTrail, UpdateTrail).

**Implementing Resources:**
- `modules/audit/main.tf` — `aws_s3_bucket_server_side_encryption_configuration.audit` — SSE-KMS with logs domain CMK.
- `modules/audit/main.tf` — `aws_s3_bucket_object_lock_configuration.audit` — Object lock (GOVERNANCE mode default, 30-day default retention; both configurable).
- `modules/audit/main.tf` — `aws_cloudtrail.this` — enable_log_file_validation = true (SHA-256 hash chaining).
- `modules/audit/main.tf` — `aws_cloudwatch_log_group.trail` — CloudTrail → CloudWatch with KMS encryption.
- `modules/audit/main.tf` — `aws_s3_bucket_policy.audit` — Deny unencrypted transport; allow service-principal writes only.
- `modules/observability/main.tf` — `aws_cloudwatch_log_metric_filter.trail_tamper` — Matches StopLogging, DeleteTrail, UpdateTrail events in the trail log group.
- `modules/observability/main.tf` — `aws_cloudwatch_metric_alarm.trail_tamper` — Alarms on the tamper metric.
- `modules/kms/main.tf` — `aws_kms_key.this["logs"]` — Logs CMK with rotation enabled.

**Responsibility:** Stack (encryption, object lock, bucket policy, tamper detection). Customer (validating hashes, monitoring alarms, off-site backup, access control on auditor role).

**Gaps & Notes:**
The stack implements protective mechanisms; the deployer validates integrity (`aws cloudtrail validate-logs`; procedure in docs/verification/audit-walkthrough.md) and configures long-term off-site backup.

---

### AU-11 — Audit Record Retention

**Implementation Statement:**
Audit logs are retained per the following default schedule (all values configurable): CloudTrail S3 logs: 913 days default (≈30 months, M-21-31 aligned) via lifecycle expiration (var.audit_log_expiration_days); CloudTrail CloudWatch Logs: 365 days default (var.trail_log_retention_days); AWS Config S3 snapshots: 913 days (same audit bucket lifecycle); AWS Config compliance history: 90 days (Config API limitation). Application/database log retention is a required finite input per log group in the observability module; the minimal example sets 365 days for audit-relevant groups. Versioned-bucket cleanup is handled via noncurrent_version_expiration. M-21-31 guidance: 90 days real-time, 1 year audit, 3 years compliance; the defaults align with 365 days (CWL) and 913 days (S3 archive) — confirm they match your organizational policy.

**Implementing Resources:**
- `modules/audit/main.tf` — `aws_s3_bucket_lifecycle_configuration.audit` — Expiration: 913 days default (audit logs and Config snapshots share bucket); noncurrent version cleanup.
- `modules/audit/main.tf` — `aws_cloudwatch_log_group.trail` — retention_in_days = var.trail_log_retention_days (default 365).
- `modules/audit/main.tf` — `aws_config_delivery_channel.this` — S3 snapshots lifecycle: same bucket (913-day default expiration).
- `modules/observability/main.tf` — `aws_cloudwatch_log_group.this` — Log group factory; retention_in_days is a mandatory finite caller input.

**Responsibility:** Stack (retention configuration). Customer (confirming alignment with policy, long-term archive if needed).

**Gaps & Notes:**
The stack implements retention per M-21-31 baseline; the deployer confirms it matches organizational policy and configures long-term archive (Glacier, off-site) if required.

---

### AU-12 — Audit Record Generation

**Implementation Statement:**
Audit records are generated automatically by: (1) CloudTrail — all AWS API calls (management events, all regions, all principals), typically delivered to S3 within about 15 minutes; (2) CloudTrail data events — S3 object-level reads/writes on documents bucket; (3) AWS Config — configuration snapshots (all resources, all-supported) on change and per snapshot frequency (default TwentyFour_Hours); (4) Bedrock invocation logging — model calls with metadata (token count, principal, timestamp); (5) CloudWatch Logs — application logs (ECS, RDS, KMS, endpoint) with timestamps. No manual intervention required. Delivered records are protected by bucket versioning and, when object lock is enabled, retention-locked; later events (tamper attempts) are independently logged.

**Implementing Resources:**
- `modules/audit/main.tf` — `aws_cloudtrail.this` — Management and data event selectors (automatic, real-time).
- `modules/audit/main.tf` — `aws_config_configuration_recorder.this` — All-supported resources (automatic on change + frequency).
- `modules/audit/main.tf` — `aws_config_configuration_recorder_status.this` — is_enabled = true.
- `modules/audit/main.tf` — `aws_bedrock_model_invocation_logging_configuration.this` — Model calls (automatic).
- `modules/observability/main.tf` — `aws_cloudwatch_log_group.this` — Factory; application code writes logs.

**Responsibility:** Stack (automatic generation infrastructure). Customer (verifying generation by examining logs, ensuring application writes to correct log group).

**Gaps & Notes:**
The stack automates record generation; the deployer verifies by examining CloudTrail console, S3 bucket, and CloudWatch Logs.

---

## CM — Configuration Management

### CM-2 — Baseline Configuration

**Implementation Statement:**
Terraform code is the configuration baseline. All infrastructure is declared in version-controlled modules; no manual console changes are permitted (enforced by git history audit and CI checks). Each module's README documents responsibility and design. Examples (minimal, full-stack) provide tested baselines. Container images are digest-pinned (not :latest). CI actions are pinned to full commit SHAs. Terraform version is pinned to 1.9+. AWS provider pinned to ~6.0. Lock files are committed in examples (reproducibility), not modules (flexibility). Configuration drift is detected via AWS Config (all resources recorded).

**Implementing Resources:**
- `modules/network/main.tf, modules/kms/main.tf, modules/iam/main.tf, modules/ecs-llm-gateway/main.tf, modules/vector-store/main.tf, modules/document-store/main.tf, modules/audit/main.tf, modules/observability/main.tf` — Eight modules define the baseline.
- `examples/minimal/, examples/full-stack/` — Tested baseline compositions with locked provider versions.
- `modules/audit/versions.tf` — Terraform >= 1.9.0, < 2.0.0; AWS provider ~> 6.0 (every module carries the same versions.tf pins).
- `.github/workflows/ci.yml` — Actions pinned to full commit SHAs (no floating tags).

**Responsibility:** Stack (baseline definition, version constraints, examples). Customer (git-based change control, reviewing plans before apply).

**Gaps & Notes:**
The stack provides infrastructure-as-code baseline; the deployer enforces git-based change control and reviews all changes before deployment.

---

### CM-3 — Configuration Change Control

**Implementation Statement:**
Change control flows through git: CI gates run on every push and pull request — terraform fmt/validate, tflint, checkov, tests, and docs-check (terraform-docs must reflect current code). Each commit follows Conventional Commits format (feat, fix, docs, test, chore, ci). The check-controls gate (scripts/check-control-refs.py) validates that control ids annotated in modules/audit/main.tf local.config_rules stay synchronized with CONTROLS.md and docs/controls.yaml and that every cited Terraform resource exists. The oscal-check gate (scripts/generate-oscal.py --check) keeps the generated OSCAL component definition synchronized with docs/controls.yaml. Branch protection and mandatory PR review are GitHub repository settings the deployer enables. Rollback is via git revert (audit trail preserved in CloudTrail).

**Implementing Resources:**
- `.github/workflows/ci.yml` — CI gates (fmt, validate, tflint, checkov, test) block merge until passing.
- `docs/conventions.md` — Conventional Commits format (section "Git Conventions").

**Responsibility:** Stack (CI gates, checks). Customer (branch protection rules, PR review process, responding to CI failures).

**Gaps & Notes:**
The stack enforces automated checks; the deployer configures GitHub branch protection and defines review procedures.

---

### CM-6 — Configuration Settings

**Implementation Statement:**
Configuration settings are monitored by AWS Config. The configuration recorder records all-supported resources (is_enabled = true) and evaluates against 10 managed rules: (1) encrypted-volumes (EBS encrypted), (2) rds-storage-encrypted (RDS encrypted), (3) rds-instance-public-access-check (RDS not public), (4) s3-bucket-public-read-prohibited (S3 no public read), (5) s3-bucket-public-write-prohibited (S3 no public write), (6) s3-bucket-ssl-requests-only (S3 TLS-only), (7) cloud-trail-log-file-validation-enabled (CloudTrail validation on), (8) iam-policy-no-statements-with-admin-access (no IAM *), (9) restricted-ssh (no SSH 0.0.0.0/0), (10) cmk-backing-key-rotation-enabled (key rotation). These rules detect and flag noncompliance on resource change or per snapshot frequency (default TwentyFour_Hours); they do not block changes. EventBridge publishes noncompliance to SNS alarms.

**Implementing Resources:**
- `modules/audit/main.tf` — `aws_config_configuration_recorder.this` — all_supported = true, include_global_resource_types = true.
- `modules/audit/main.tf` — `aws_config_configuration_recorder_status.this` — is_enabled = true.
- `modules/audit/main.tf` — `aws_config_delivery_channel.this` — Snapshots to S3 (delivery_frequency = var.config_snapshot_frequency).
- `modules/audit/main.tf` — `aws_config_config_rule.rules` — All 10 rules (for_each over local.config_rules).
- `modules/observability/main.tf` — `aws_cloudwatch_event_rule.config_noncompliant` — Publishes noncompliance events to SNS.

**Responsibility:** Stack (Config rules, recorder, event publishing). Customer (responding to noncompliance, investigating root cause, remediating via Terraform or AWS Config Remediation).

**Gaps & Notes:**
The stack provides continuous compliance monitoring; the deployer investigates and remediates noncompliance.

---

## IA — Identification and Authentication

### IA-2 — Identification and Authentication (Organizational Users)

**Implementation Statement:**
Multi-factor authentication is enforced on human role assumption via IAM conditions: every human role tier (platform-admin, auditor, developer) has trust policy condition `aws:MultiFactorAuthPresent = true`. Attempts without MFA are denied. Service principals (ECS, CloudTrail, Config, Bedrock) authenticate via service principals with SourceAccount/SourceArn conditions (no MFA required; service-to-service). The optional CI role trusts caller-supplied IAM principal ARNs via sts:AssumeRole (non-interactive, no MFA; an OIDC-federated role can be supplied as the trusted principal). No local users or password credentials are created. RDS uses IAM authentication (temporary tokens) instead of password-based auth.

**Implementing Resources:**
- `modules/iam/main.tf` — `aws_iam_role.human_tier` — Human role tiers (for_each), each with trust condition aws:MultiFactorAuthPresent = true.
- `modules/iam/main.tf` — `aws_iam_role.task_execution` — Service trust: ecs-tasks.amazonaws.com with SourceAccount.
- `modules/iam/main.tf` — `aws_iam_role.app_task` — Service trust: ecs-tasks.amazonaws.com with SourceAccount.
- `modules/iam/main.tf` — `aws_iam_role.ci_deploy` — CI trust: caller-supplied IAM principal ARNs (var.ci_trust_principal_arns).
- `modules/vector-store/main.tf` — `aws_db_instance.vector` — iam_database_authentication_enabled = true.
- `modules/iam/main.tf` — `aws_iam_policy.permission_boundary` — Denies iam:*AccessKey*, iam:*LoginProfile*.
- `docs/rbac-model.md` — Role assumption paths (section 3).

**Responsibility:** Stack (MFA conditions, service principal binding, IAM auth). Customer (MFA device enrollment, IdP federation, auditing role assumption in CloudTrail).

**Gaps & Notes:**
The stack enforces MFA for humans and binds service principals to source accounts; the deployer configures MFA devices and monitors CloudTrail for unauthorized attempts.

---

### IA-5 — Authenticator Management

**Implementation Statement:**
Secrets (credentials) are managed via AWS Secrets Manager with KMS encryption. RDS master password is created by Terraform (manage_master_user_password = true), automatically stored in Secrets Manager, encrypted with the secrets CMK, and rotated automatically by RDS (no Lambda required). Other secrets (gateway API keys, third-party credentials) follow the documented pattern: create secret resource (resource policy restricts read to app_task role), populate value out-of-band (AWS CLI, never Terraform literals), inject into ECS task definition via secrets block (ECS retrieves at launch, value never in state/logs). Secrets are encrypted at rest (KMS) and in transit (TLS); access is logged in CloudTrail (call logged, value not logged). No plaintext secrets in state, git, or logs.

**Implementing Resources:**
- `docs/secrets-handling.md` — Complete pattern: create, populate, inject, rotate (sections 2–4).
- `modules/vector-store/main.tf` — `aws_db_instance.vector` — manage_master_user_password = true (automatic rotation).
- `modules/vector-store/main.tf` — `aws_db_instance.vector` — master_user_secret_kms_key_id = var.secrets_kms_key_arn.
- `modules/kms/main.tf` — `aws_kms_key.this["secrets"]` — Secrets CMK with enable_key_rotation = true.

**Responsibility:** Shared. Stack implements: automatic RDS rotation, encryption, ECS secret injection. Customer is responsible for: populating non-RDS secrets (CLI/console), auditing access (CloudTrail), ensuring application does not log secrets, managing MFA on secret-reader principals.

**Gaps & Notes:**
The stack automates RDS credential rotation; the deployer manages custom secrets and rotation schedules (Lambda pattern documented in secrets-handling.md).

---

## RA — Risk Assessment

### RA-5 — Vulnerability Monitoring and Scanning

**Implementation Statement:**
Static vulnerability scanning is integrated into CI: (1) checkov scans Terraform for security violations (CKV_AWS_* checks); (2) tflint lints Terraform syntax and detects unsafe patterns. Both are required gates — CI fails on violations (unless explicitly skipped with justification). Scans cover: resource hardening (encryption, logging, public-access blocks), IAM policy overprivilege, network isolation, KMS policies. Scans do NOT cover: runtime vulnerabilities (container image scanning deployer responsibility), penetration testing, source-code SAST.

**Implementing Resources:**
- `.github/workflows/ci.yml` — checkov and tflint jobs (mandatory gates).
- `docs/conventions.md` — Checkov skip policy (section "Checkov Skip Policy") — inline justifications required.

**Responsibility:** Stack (static IaC scanning gates). Customer must add: container image scanning (ECR, Trivy, Snyk), application SAST (SonarQube, GitHub Advanced Security), penetration testing.

**Gaps & Notes:**
The stack provides static IaC scanning; the deployer must add runtime and application-layer scanning as part of ATO process.

---

## SC — System and Communications Protection

### SC-7 — Boundary Protection

**Implementation Statement:**
Network boundary is enforced via: (1) VPC with private-subnet-only architecture (no public subnets, no IGW in no-egress mode); (2) VPC endpoints for the required AWS services (including Bedrock, S3, ECR, KMS, CloudWatch Logs, Secrets Manager, ECS, STS) with private DNS resolution; (3) security groups: default SG explicitly emptied, gateway service SG allows ALB ingress only (var.container_port, default 4000), database SG allows app ingress only (port 5432), workload app SG is egress-only; (4) flow logs to CloudWatch (KMS-encrypted); (5) S3 bucket policies deny unencrypted transport; (6) Config rule restricted-ssh flags SSH 0.0.0.0/0 (detective). In standard mode, public subnets and a single NAT gateway are optional. In no-egress mode, zero NAT/IGW. No workload has direct internet access.

**Implementing Resources:**
- `modules/network/main.tf` — `aws_vpc.main` — enable_dns_hostnames = true, enable_dns_support = true (endpoint DNS resolution).
- `modules/network/main.tf` — `aws_subnet.private` — map_public_ip_on_launch = false.
- `modules/network/main.tf` — `aws_default_security_group.main` — Explicitly emptied (no rules).
- `modules/network/security-groups.tf` — `aws_security_group.app` — Egress-only workload SG (443 to endpoints/S3, 5432 to VPC CIDR).
- `modules/ecs-llm-gateway/main.tf` — `aws_vpc_security_group_ingress_rule.service_from_alb` — Gateway service ingress from ALB only.
- `modules/vector-store/main.tf` — `aws_vpc_security_group_ingress_rule.db_from_app` — Database ingress from app SG only (port 5432).
- `modules/document-store/main.tf` — `aws_s3_bucket_policy.documents` — Deny aws:SecureTransport = false.
- `modules/audit/main.tf` — `aws_s3_bucket_policy.audit` — Deny unencrypted transport.
- `modules/audit/main.tf` — `aws_config_config_rule.rules["restricted-ssh"]` — Flags SSH open to 0.0.0.0/0.

**Responsibility:** Stack (VPC, security groups, bucket policies, Config rule). Customer (endpoint policy validation, flow log monitoring, network topology confirmation).

**Gaps & Notes:**
The stack provides network isolation infrastructure; the deployer validates endpoint policies and monitors flow logs for anomalies (query examples in audit-walkthrough.md).

---

### SC-8 — Transmission Confidentiality and Integrity

**Implementation Statement:**
All data in transit is encrypted via TLS. (1) ALB listener enforces HTTPS (port 443, TLS termination, cleartext backend within private subnets only); (2) RDS force_ssl = 1 enforces TLS on all connections; (3) S3 bucket policies deny requests with aws:SecureTransport = false; (4) Secrets Manager and KMS use TLS (AWS service default); (5) VPC endpoints use private IPs (no internet). The ALB certificate is either a caller-supplied ACM certificate (var.certificate_arn; ACM Private CA recommended for internal ALBs) or a module-generated self-signed certificate (sandbox only) — exactly one must be set.

**Implementing Resources:**
- `modules/ecs-llm-gateway/main.tf` — `aws_lb_listener.https` — HTTPS listener (port 443, protocol = "HTTPS").
- `modules/vector-store/main.tf` — `aws_db_parameter_group.vector` — parameter rds.force_ssl = 1.
- `modules/document-store/main.tf` — `aws_s3_bucket_policy.documents` — Deny condition on aws:SecureTransport = false.
- `modules/audit/main.tf` — `aws_s3_bucket_policy.audit` — Deny unencrypted transport.

**Responsibility:** Stack (TLS configuration, bucket policies). Customer (TLS certificate management, rotation, monitoring).

**Gaps & Notes:**
The stack enforces TLS; the deployer installs valid certificates and rotates them before expiration.

---

### SC-8(1) — Cryptographic Protection

**Implementation Statement:**
Cryptographic mechanisms (TLS 1.2+) protect confidentiality and integrity in transit. ALB enforces HTTPS (TLS termination). RDS enforces TLS (force_ssl = 1). S3 bucket policies enforce TLS-only access. AWS service APIs use TLS by default. Config rule s3-bucket-ssl-requests-only validates S3 TLS enforcement. VPC endpoints keep traffic on the AWS backbone (no internet exposure).

**Implementing Resources:**
- `modules/ecs-llm-gateway/main.tf` — `aws_lb_listener.https` — TLS termination.
- `modules/vector-store/main.tf` — `aws_db_parameter_group.vector` — rds.force_ssl = 1.
- `modules/audit/main.tf` — `aws_config_config_rule.rules["s3-bucket-ssl-requests-only"]` — Config rule validates S3 TLS.
- `modules/document-store/main.tf` — `aws_s3_bucket_policy.documents` — Deny non-TLS.

**Responsibility:** Stack (TLS enforcement, Config rule). Customer (TLS version verification, downgrade monitoring).

**Gaps & Notes:**
The stack enforces TLS 1.2+; the deployer monitors for any TLS downgrade attempts in CloudTrail.

---

### SC-12 — Cryptographic Key Establishment and Management

**Implementation Statement:**
Cryptographic keys are customer-managed AWS KMS CMKs (not AWS-managed). Three separate domains: data (EBS, RDS, S3 documents), logs (CloudTrail, Config, CloudWatch, SNS), secrets (Secrets Manager, RDS managed password). Key policies follow least-privilege: data-plane service use is scoped via kms:ViaService conditions per domain; audit-plane service statements carry the conditions AWS documents for each service (CloudTrail EncryptionContext + SourceArn, Config SourceAccount, Bedrock SourceAccount/SourceArn), while the CloudWatch-alarms and EventBridge statements on the logs key are deliberately condition-free because condition support there is undocumented and fails silently (rationale in module comments). Key rotation is enabled automatically (enable_key_rotation = true). Key deletion is prevented by the boundary (deny kms:ScheduleKeyDeletion, kms:PutKeyPolicy). Key grants are created dynamically by AWS services for ViaService-scoped domains.

**Implementing Resources:**
- `modules/kms/main.tf` — `aws_kms_key.this` — enable_key_rotation = true (automatic annual rotation).
- `modules/kms/main.tf` — `aws_kms_key.this["data"]` — Data domain CMK.
- `modules/kms/main.tf` — `aws_kms_key.this["logs"]` — Logs domain CMK.
- `modules/kms/main.tf` — `aws_kms_key.this["secrets"]` — Secrets domain CMK.
- `modules/kms/main.tf` — `aws_kms_alias.this` — Aliases for reference.
- `modules/audit/main.tf` — `aws_config_config_rule.rules["cmk-backing-key-rotation-enabled"]` — Config rule validates rotation.
- `modules/iam/main.tf` — `aws_iam_policy.permission_boundary` — Denies key deletion/policy tampering.

**Responsibility:** Stack (CMK creation, rotation, key policies, Config rule). Customer (auditing key policy changes, monitoring rotation dates).

**Gaps & Notes:**
The stack manages automatic key rotation; the deployer audits key changes in CloudTrail and archives old keys if required.

---

### SC-13 — Cryptographic Protection

**Implementation Statement:**
Cryptographic algorithms are AWS-managed and AES-256-based. KMS CMKs use AES-256 for all envelope encryption (S3 via sse_algorithm = "aws:kms"; RDS, CloudWatch Logs, and SNS via KMS key references). TLS 1.2+ provides symmetric encryption for transit. The stack does not expose algorithm selection; AWS defaults (AES-256 symmetric, 256-bit keys) are enforced.

**Implementing Resources:**
- `modules/document-store/main.tf` — `aws_s3_bucket_server_side_encryption_configuration.documents` — sse_algorithm = aws:kms (AES-256).
- `modules/audit/main.tf` — `aws_s3_bucket_server_side_encryption_configuration.audit` — sse_algorithm = aws:kms (AES-256).
- `modules/vector-store/main.tf` — `aws_db_instance.vector` — storage_encrypted = true (AES-256 via KMS).
- `modules/observability/main.tf` — `aws_sns_topic.alarms` — kms_master_key_id (AES-256).
- `modules/observability/main.tf` — `aws_cloudwatch_log_group.this` — kms_key_id (AES-256).

**Responsibility:** Stack (algorithm enforcement via AWS services). Customer (none; AWS handles cryptography).

**Gaps & Notes:**
None. AWS manages cryptographic implementation; no deployer action required.

---

### SC-28 — Protection of Information at Rest

**Implementation Statement:**
All information at rest is encrypted. (1) EBS volumes are encrypted via the data CMK (Config rule encrypted-volumes flags unencrypted volumes). (2) RDS storage is encrypted via the data CMK (storage_encrypted = true, Config rule rds-storage-encrypted flags noncompliance). (3) The documents and audit buckets use SSE-KMS with customer-managed keys; the S3 access-log and ALB-log buckets use SSE-S3 (AES-256) because the S3 and ELB log-delivery services do not support customer-managed KMS keys. (4) CloudWatch Logs are encrypted with the logs CMK. (5) Secrets Manager values are encrypted with the secrets CMK. (6) Snapshots of encrypted resources are encrypted with the same key. No plaintext data is stored.

**Implementing Resources:**
- `modules/audit/main.tf` — `aws_config_config_rule.rules["encrypted-volumes"]` — Flags unencrypted EBS volumes.
- `modules/audit/main.tf` — `aws_config_config_rule.rules["rds-storage-encrypted"]` — Flags unencrypted RDS storage.
- `modules/document-store/main.tf` — `aws_s3_bucket_server_side_encryption_configuration.documents` — SSE-KMS with data CMK.
- `modules/document-store/main.tf` — `aws_s3_bucket_server_side_encryption_configuration.access_logs` — SSE-S3 (AES-256; log delivery does not support CMKs).
- `modules/audit/main.tf` — `aws_s3_bucket_server_side_encryption_configuration.audit` — SSE-KMS.
- `modules/vector-store/main.tf` — `aws_db_instance.vector` — storage_encrypted = true with data CMK.
- `modules/observability/main.tf` — `aws_cloudwatch_log_group.this` — kms_key_id.

**Responsibility:** Stack (encryption configuration, Config rules). Customer (key rotation monitoring, key archival).

**Gaps & Notes:**
The stack enforces encryption at rest via KMS; the deployer monitors key operations in CloudTrail.

---

### SC-28(1) — Cryptographic Protection

**Implementation Statement:**
Customer-managed KMS CMKs provide cryptographic protection. (1) EBS volumes use AES-256 (Config rule flags absence). (2) RDS storage uses AES-256; encryption is mandatory (no option to disable). (3) S3 buckets use AES-256; default encryption configuration prevents unencrypted uploads. (4) Backup snapshots inherit encryption from parent. (5) Encryption key material is never exposed to application layer.

**Implementing Resources:**
- `modules/kms/main.tf` — `aws_kms_key.this["data"]` — Data domain CMK (AES-256, rotation enabled).
- `modules/audit/main.tf` — `aws_config_config_rule.rules["encrypted-volumes"]` — Validates volume encryption.
- `modules/audit/main.tf` — `aws_config_config_rule.rules["rds-storage-encrypted"]` — Validates RDS encryption.
- `modules/document-store/main.tf` — `aws_s3_bucket_server_side_encryption_configuration.documents` — Mandatory SSE-KMS.
- `modules/vector-store/main.tf` — `aws_db_instance.vector` — storage_encrypted = true (mandatory).

**Responsibility:** Stack (cryptographic enforcement). Customer (none; AWS handles crypto).

**Gaps & Notes:**
None. AWS ensures AES-256 encryption for all data at rest.

---

## SI — System and Information Integrity

### SI-4 — System Monitoring

**Implementation Statement:**
System monitoring is provided by: (1) CloudTrail — logs all API calls (management and data events); (2) AWS Config — continuously evaluates compliance against 10 managed rules, emits noncompliance events to EventBridge → SNS alarms; (3) CloudWatch Alarms — the observability module monitors RDS CPU/connections/storage, endpoint packet drops, CloudTrail tamper attempts, and Config noncompliance, while the gateway module self-instruments ALB target health, 5xx rate, latency p95, and running task count; (4) VPC Flow Logs — capture network traffic (accept/reject) to CloudWatch Logs (KMS-encrypted), enabling anomaly detection; (5) CloudWatch Logs Insights — ad-hoc querying of logs. No runtime container scanning or IDS is included (deployer adds ECR image scanning).

**Implementing Resources:**
- `modules/audit/main.tf` — `aws_cloudtrail.this` — Continuous API logging.
- `modules/audit/main.tf` — `aws_config_configuration_recorder.this` — Continuous compliance evaluation.
- `modules/audit/main.tf` — `aws_config_config_rule.rules` — All 10 managed rules.
- `modules/network/flow-logs.tf` — `aws_flow_log.vpc` — VPC Flow Logs to CloudWatch (KMS-encrypted).
- `modules/observability/main.tf` — `aws_cloudwatch_metric_alarm.rds_cpu` — RDS CPU alarm.
- `modules/observability/main.tf` — `aws_cloudwatch_metric_alarm.rds_connections` — RDS connection alarm.
- `modules/observability/main.tf` — `aws_cloudwatch_event_rule.config_noncompliant` — Config noncompliance events.
- `modules/observability/main.tf` — `aws_cloudwatch_metric_alarm.trail_tamper` — CloudTrail tamper detection.
- `modules/ecs-llm-gateway/main.tf` — `aws_cloudwatch_metric_alarm.latency_p95` — Gateway latency alarm (one of four self-instrumented gateway alarms).

**Responsibility:** Stack (monitoring infrastructure, rules, alarms). Customer (configuring SIEM, response automation, ECR/container scanning).

**Gaps & Notes:**
The stack provides comprehensive monitoring; the deployer must configure container image scanning (ECR, Trivy, Snyk) and response automation (Lambda, Step Functions).

---

## Honest Gaps and POA&M

The following controls or aspects are NOT implemented by this stack and are Customer Responsibility:

- **CP (Contingency Planning):** Disaster recovery (backup snapshots, failover), business continuity procedures — template and testing procedures are deployer responsibility.
- **IR (Incident Response):** Incident response procedures, forensics, eradication, recovery — deployer must define procedures and automation.
- **MP (Media Protection):** Physical media destruction (not applicable to cloud; AWS handles), secure disposal — AWS data-center responsibility.
- **PE (Physical and Environmental Protection):** Physical security, environmental controls, facility access — AWS data-center responsibility (inherited from AWS); customer documents via AWS Artifact.
- **PS (Personnel Security):** Background checks, security training, access termination procedures — organizational responsibility.
- **AT (Awareness and Training):** Security awareness training for staff — organizational responsibility; this stack enables but does not implement.
- **Deployed-Evidence Proofs:** CloudTrail logs, Config compliance reports, and verification transcripts are PENDING — each proof requires a live deployment and log extraction. See `docs/verification/` for example procedures.
- **Penetration Testing:** Not in scope for Terraform stack; required as part of ATO process.
- **Container Image Scanning:** Runtime vulnerability scanning (ECR, Trivy, Snyk) — deployer must integrate.
- **Application Layer Controls:** Input validation, output encoding, API rate limiting, DLP — application (LLM gateway) responsibility.
- **Organizational Policies:** Change advisory boards, SLAs, cost controls — organizational responsibility.

---

## How to Use This Document

1. **For an SSP:** This document is a skeleton; copy the control statements and implementing resources into your System Security Plan. SSP tooling that consumes OSCAL can ingest the same mapping from `docs/oscal/component-definition.json`, an OSCAL 1.1.3 component definition generated from `docs/controls.yaml` (`make oscal`; validated against the NIST OSCAL component-definition schema).
2. **For ATO:** Deployer must provide deployed-evidence proofs (see docs/verification/ for examples). Each control requires a transcript showing the evidence (CloudTrail log, Config rule compliance, etc.).
3. **For Audits:** Reference the YAML file (`docs/controls.yaml`) and each Terraform resource path to verify implementation. Spot-check: run grep to confirm each cited resource exists.
4. **For Maintenance:** If you modify Terraform code (e.g., add a new Config rule, change KMS key policy), update the mapping to reflect the change. `make check-controls` (scripts/check-control-refs.py) enforces consistency between code annotations, this document, and docs/controls.yaml in CI; `make oscal-check` (scripts/generate-oscal.py --check) enforces that the generated OSCAL component definition stays current.

---

## References

- NIST SP 800-53 Revision 5: https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final
- NIST SP 800-53 Control Catalog: https://csrc.nist.gov/projects/security-and-privacy-controls/sp800-53-rev-5
- OMB M-21-31 (Log Retention): https://www.whitehouse.gov/wp-content/uploads/2021/08/M-21-31.pdf
- `docs/rbac-model.md` — RBAC principals and matrix
- `docs/secrets-handling.md` — Secrets lifecycle and patterns
- `docs/architecture.md` — Architecture overview and module responsibilities
- `docs/conventions.md` — Repository conventions and IAM policy style
- `docs/verification/` — Deployed-evidence proof procedures
- `docs/adr/` — Architecture Decision Records (ADR-001 through ADR-007)
