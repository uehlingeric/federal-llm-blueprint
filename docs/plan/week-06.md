# Week 6 — Audit & Observability: CloudTrail, Config, Alarms

**Objective:** The plane that makes the stack *auditable* rather than just secure: CloudTrail with integrity validation, AWS Config rules mirroring the repo's own standards, centralized encrypted logging, and an alarm baseline. By Sunday an auditor-persona walkthrough can answer "who did what, when, to which resource" from deployed evidence.

## Exit Criteria

- [ ] `modules/audit`: CloudTrail (multi-region, log-file validation, KMS-encrypted, S3 + CloudWatch destinations) + AWS Config recorder with managed rule set
- [ ] `modules/observability`: log-group factory (KMS + retention enforced), alarm baseline, SNS topic pattern, dashboard
- [ ] Config rules encode the repo's own claims (encrypted volumes, no public S3, SG hygiene, IAM boundary presence) — the stack audits itself
- [ ] Auditor walkthrough documented: three real questions answered from CloudTrail/Config evidence with CLI transcripts
- [ ] Bedrock model-invocation logging enabled and documented (who prompted what — the LLM-specific audit story)

## Workstreams

### 1. CloudTrail
- [ ] Trail: multi-region, global service events, log file validation on; S3 destination in document-store pattern bucket (object lock governance mode) + CloudWatch Logs for live queries
- [ ] KMS-encrypted with `logs` CMK; trail bucket policy locked to CloudTrail service with source-arn condition
- [ ] Data events: S3 object-level on the documents bucket (read+write) — the CUI access trail; cost implications documented
- [ ] Insights events toggle (cost-flagged, default off)

### 2. AWS Config
- [ ] Recorder + delivery channel (S3, KMS); recording strategy: all supported + global resources in one region only (cost note)
- [ ] Managed rules mapped to repo standards: `encrypted-volumes`, `rds-storage-encrypted`, `rds-instance-public-access-check`, `s3-bucket-public-read/write-prohibited`, `s3-bucket-ssl-requests-only`, `cloud-trail-log-file-validation-enabled`, `iam-policy-no-statements-with-admin-access`, `restricted-ssh`, `cmk-backing-key-rotation-enabled`
- [ ] Each rule annotated in code with the 800-53 control it evidences (week 7 harvests these annotations)
- [ ] Conformance-pack packaging as a stretch; plain rules are the committed scope

### 3. LLM-specific audit
- [ ] Bedrock invocation logging: model invocation logs → CloudWatch/S3 (KMS) — prompt/response capture posture documented (full capture vs metadata-only variable; CUI implications of storing prompts spelled out)
- [ ] Gateway (LiteLLM) request logging shipped to a dedicated log group; correlation guidance: ALB request id ↔ gateway log ↔ Bedrock invocation log — `docs/audit-correlation.md` with a worked trace

### 4. Observability baseline
- [ ] Log-group factory: name-standardized, KMS mandatory, retention mandatory (no infinite-retention defaults)
- [ ] Alarms: gateway 5xx + latency p95, ECS task restarts, RDS CPU/storage/connections, endpoint packet drops (no-egress canary), Config noncompliance events, CloudTrail-stopped
- [ ] SNS topic (KMS) + subscription variables; runbook-link tag on every alarm
- [ ] CloudWatch dashboard: gateway traffic/latency/errors, task health, DB vitals, compliance status widget

### 5. Auditor walkthrough
- [ ] `docs/verification/audit-walkthrough.md`: (1) "Who accessed document X?" via S3 data events; (2) "What model invocations happened yesterday and by which role?"; (3) "Prove encryption posture didn't drift" via Config timeline — CLI transcripts for each

## Verification

- Deploy full stack in sandbox; intentionally violate a rule (create an unencrypted test volume) → Config flags noncompliant → alarm fires → evidence in walkthrough doc.
- checkov + tflint clean; `terraform test` assertions for trail validation/encryption/retention floors.
- Log-group factory rejects (via validation) a module call with no retention set.

## Commit Milestones (4-6 commits)

1. CloudTrail module + bucket policy + data events
2. Config recorder + annotated rule set
3. Bedrock invocation logging + correlation doc
4. Log factory + alarms + dashboard
5. Auditor walkthrough with transcripts

## Risks & Notes

- Config + CloudTrail data events are the sneaky cost drivers — every toggle carries an in-code cost comment; week 8's cost doc depends on honesty here.
- Storing prompts is a *policy* decision, not a technical one — present both postures; defaulting to metadata-only is the defensible reference choice.
- This week + week 7 are the repo's moat: infra repos are common; infra that demonstrates its own auditability is not.
