# Week 5 — Data Layer: Vector Store + Document Store

**Dates:** Mon Aug 3 – Sun Aug 9, 2026
**Objective:** The stateful modules: RDS Postgres with pgvector for embeddings, and an S3 document store with the full compliance posture (versioning, access logging, lifecycle, object lock option). By Sunday both modules pass their tests and a seed script proves vector search works end to end inside the VPC.

## Exit Criteria

- [ ] `modules/vector-store`: encrypted RDS Postgres with pgvector enabled, private-subnet only, IAM auth on
- [ ] `modules/document-store`: S3 bucket set with versioning, SSE-KMS, access logging, public-access block, TLS-only policy
- [ ] Backups: automated RDS backups + snapshot copy pattern; S3 lifecycle + optional object lock (compliance mode documented, governance default)
- [ ] In-VPC proof: seed embeddings, run a similarity query, transcript saved
- [ ] Both module READMEs include data-classification guidance (what CUI handling implies for each setting)

## Workstreams

### 1. Vector store (RDS + pgvector)
- [ ] RDS Postgres 16, instance class variable (demo `db.t4g.medium`, prod guidance table), multi-AZ toggle (default on for prod example, off for minimal)
- [ ] Storage encrypted with week-3 `data` CMK; performance insights KMS-encrypted; deletion protection on by default
- [ ] Network: DB SG allows 5432 from app SG only; no public accessibility (checkov-enforced); private subnet group
- [ ] Auth: IAM database authentication enabled; master credentials via Secrets Manager with rotation lambda toggle; parameter group with `rds.force_ssl = 1`
- [ ] pgvector: enablement via `shared_preload_libraries`/extension — bootstrap SQL shipped + documented (Terraform can't `CREATE EXTENSION`; provide a run-once task pattern)
- [ ] Logging: postgresql + upgrade logs to CloudWatch, KMS-encrypted, retention variable

### 2. Document store (S3)
- [ ] Bucket set: `documents`, `access-logs`, `alb-logs` (week 4's stub swapped to real) — one module, map-driven
- [ ] Versioning on; SSE-KMS with bucket-key optimization; public access block all-true; TLS-only + deny-unencrypted-put bucket policies
- [ ] Access logging: documents bucket logs to access-logs bucket (which logs nowhere — document the standard reasoning)
- [ ] Lifecycle: current-version transitions (IA at 90d) + noncurrent expiration; object lock optional variable with compliance-vs-governance modes explained for retention requirements
- [ ] Inventory + analytics toggles for large-corpus users

### 3. Integration
- [ ] Week-3 IAM tightening: app role scoped to exact bucket ARNs/prefixes and DB resource ids now that they exist
- [ ] Seed script (`scripts/seed-vectors.py`): create table, insert sample embeddings, cosine query — run as one-off ECS task inside the VPC; transcript to `docs/verification/vector-proof.md`
- [ ] Architecture diagram updated: data plane real

### 4. Testing & docs
- [ ] `terraform test`: encryption assertions, no-public-access assertions, SG topology, backup retention ≥ variable floor
- [ ] Module READMEs: usage, classification guidance, cost notes (RDS is the second-biggest demo line item)
- [ ] `docs/adr/006-pgvector-over-opensearch.md`: cost, ops surface, ATO familiarity of RDS — and when OpenSearch/Kendra is the right call instead

## Verification

- checkov RDS/S3 families zero-skip (these families are checkov's strictest — passing clean is the proof point).
- Sandbox apply + seed + query + destroy clean (snapshot-on-destroy behavior verified and documented).
- Restore drill: restore from automated backup to a new instance once, note RTO observed.

## Commit Milestones (4-6 commits)

1. RDS module + encryption + networking
2. IAM auth + secrets + parameter group + pgvector bootstrap
3. S3 module: buckets, policies, logging
4. Lifecycle + object lock + ALB-log swap
5. Seed proof + IAM tightening + ADR-006

## Risks & Notes

- RDS spin-up/teardown is slow — batch sandbox test cycles; don't iterate module interfaces against live RDS.
- Object lock cannot be enabled on existing buckets — the variable must shape bucket creation; call this out loudly in the README (classic irreversible gotcha).
- Rotation lambda in a no-egress VPC needs its own endpoint consideration (Secrets Manager endpoint exists from week 2 — verify the lambda-in-VPC path or document rotation as manual for air-gap mode).
