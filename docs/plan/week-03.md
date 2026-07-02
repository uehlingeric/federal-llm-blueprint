# Week 3 — Security Core: KMS, IAM/RBAC, Secrets

**Dates:** Mon Jul 20 – Sun Jul 26, 2026
**Objective:** The encryption and identity backbone every other module consumes: customer-managed KMS keys with rotation, least-privilege IAM roles with permission boundaries, and a secrets pattern. By Sunday, checkov's IAM/KMS rule families pass with zero skips and the RBAC model is documented as a table a security reviewer could assess.

## Exit Criteria

- [ ] `modules/kms`: per-domain CMKs (data, logs, secrets) with rotation, aliases, and least-privilege key policies
- [ ] `modules/iam`: task execution/app roles, CI role pattern, human role tiers — all with permission boundaries attached
- [ ] No wildcard actions or resources anywhere except documented, justified cases (target: zero)
- [ ] `docs/rbac-model.md`: who/what can do which action on which resource, as a matrix
- [ ] Secrets pattern implemented and documented (Secrets Manager, KMS-encrypted, no secrets in state where avoidable)

## Workstreams

### 1. KMS module
- [ ] CMK set as a map: `data`, `logs`, `secrets` (extensible); rotation enabled; deletion window 30 days; multi-alias support
- [ ] Key policies: split key-admin vs key-user; no `kms:*` to account root shortcut beyond the required enable-IAM statement (documented why that statement exists — reviewers ask)
- [ ] Grants pattern for service integration (ECS, RDS, S3, CloudWatch) — least-privilege `via` conditions where applicable
- [ ] Outputs shaped for consumer modules: key arns/aliases keyed by domain

### 2. IAM module
- [ ] Roles: `task_execution` (pull image, write logs — nothing else), `app_task` (scoped to named resources: specific bucket prefixes, specific key ids, Bedrock invoke on named model ARNs), `ci_deploy` (plan/apply boundaries)
- [ ] Human tiers: `platform-admin`, `auditor` (read-only + log access), `developer` (deploy to nonprod pattern) — shipped as assumable role definitions with trust policy variables
- [ ] Permission boundary policy applied to all created roles — the ceiling nobody escalates past; boundary contents documented line by line
- [ ] Access-analyzer-friendly: no `NotAction`, no `Resource: "*"` on write actions

### 3. Secrets pattern
- [ ] Secrets Manager secrets module-let (inside iam or standalone `modules/secrets` — decide, ADR-004): KMS-encrypted, rotation-ready structure, resource policies restricting to app role
- [ ] Pattern for LLM API keys (for non-Bedrock providers in hybrid configs): stored once, injected into ECS as `secrets` (never env in task def plaintext, never in tf state as literals — `ephemeral`/write-only pattern where provider supports it)
- [ ] `docs/secrets-handling.md`: lifecycle, rotation posture, what never touches state

### 4. RBAC documentation
- [ ] `docs/rbac-model.md`: matrix — principal × action-class × resource-scope × condition; maps ahead to AC-2/AC-3/AC-6 (week 7 will cite it)
- [ ] Diagram: role assumption paths (human → tier role → boundary; service → task role)

## Verification

- checkov IAM + KMS families: zero failures, zero skips.
- `terraform test`: assertions that every role has the boundary attached, no policy contains `"Action": "*"`, all CMKs have rotation on.
- Peer-review pass: read every policy doc line asking "could this be narrower?" — record outcomes in PR.

## Commit Milestones (4-6 commits)

1. KMS module + key policies + tests
2. Service roles + boundaries
3. Human role tiers + trust policies
4. Secrets pattern + handling doc
5. RBAC model doc + ADR-004

## Risks & Notes

- Least-privilege written *before* the consuming workloads exist (weeks 4-5) — expect a tightening pass then; leave `TODO(scope)` markers rather than pre-widening.
- Permission boundaries are the interview-grade detail here; the doc explaining *why* is worth as much as the code.
- Bedrock model-invocation ARNs differ by partition/region — parameterize model ids, never hardcode ARNs.
