# Week 1 — Foundations: Standards, Skeleton, CI, Architecture Doc

**Dates:** Mon Jul 6 – Sun Jul 12, 2026
**Objective:** Every structural decision made and enforced before any real infrastructure code: module conventions, tagging/naming standards, state strategy, CI gates, and the architecture document that the next seven weeks implement. By Sunday, an empty-but-valid module skeleton passes a CI pipeline that would fail bad code.

## Exit Criteria

- [ ] Repo skeleton: 8 module directories + 2 example directories, each `terraform validate`-clean
- [ ] CI enforces: `terraform fmt -check`, `validate`, `tflint`, `checkov`, `terraform-docs` freshness — a deliberately bad PR fails all gates (tested)
- [ ] `docs/architecture.md` v1: diagram, module boundaries, data flows, no-egress mode definition
- [ ] Conventions doc: naming, tagging, variable/output style, version pinning policy
- [ ] ADRs for the three structural decisions committed

## Workstreams

### 1. Repo structure & conventions
- [ ] Layout: `modules/{network,kms,iam,ecs-llm-gateway,vector-store,document-store,audit,observability}`, `examples/{minimal,full-stack}`, `docs/`, `policies/`
- [ ] Per-module standard: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `README.md` (terraform-docs generated)
- [ ] `docs/conventions.md`: resource naming (`{project}-{env}-{component}`), mandatory tag set (`Project`, `Environment`, `ManagedBy`, `DataClassification`), variable naming, description-required rule
- [ ] Terraform ≥1.9 pinned; AWS provider `~> 6.0`; all module versions pinned exactly

### 2. CI pipeline
- [ ] GitHub Actions: fmt-check, validate (all modules + examples via matrix), tflint with ruleset config, checkov with a documented-skips policy (every skip needs a justification comment)
- [ ] terraform-docs: CI fails if module READMEs are stale (docs generated ≠ committed)
- [ ] Negative test: commit a deliberately non-compliant module on a branch, confirm every gate trips, record in PR description
- [ ] PR template: checklist including "controls impact" line (feeds week 7)

### 3. Architecture document
- [ ] `docs/architecture.md`: mermaid diagram (network, compute, data, audit planes), module dependency graph, no-egress mode semantics (what is reachable, what is provably not)
- [ ] Interface contracts between modules: what network outputs (subnet ids, endpoint SGs) other modules consume — prevents week 4-6 rework
- [ ] Out-of-scope list (honest): multi-region, DR, IL5+ specifics, SCIF physical controls

### 4. Decision records
- [ ] `docs/adr/001-ecs-fargate-over-eks.md` — operational surface, ATO story, and why not Lambda for gateway workloads
- [ ] `docs/adr/002-state-strategy.md` — S3 + DynamoDB locking pattern documented for users; examples ship with local-state default and a commented remote-state block (a public reference can't assume their bucket)
- [ ] `docs/adr/003-no-egress-as-mode-not-fork.md` — one codebase, `no_egress` variable, endpoint-only paths

## Verification

- Clean clone → `make validate` (wraps fmt/validate/tflint/checkov across all modules) passes.
- The negative-test branch demonstrates each CI gate failing for its own reason.
- A colleague-level reader can state each module's responsibility from `architecture.md` alone.

## Commit Milestones (4-6 commits)

1. Skeleton + conventions doc
2. CI pipeline + tflint/checkov configs
3. Negative-test proof + PR template
4. Architecture doc + interface contracts
5. ADRs 001-003

## Risks & Notes

- Resist writing real resources this week — skeleton discipline now is what makes weeks 2-6 reviewable independently.
- Checkov and tflint rule tuning can eat days; timebox to defaults + documented skips, refine as real modules land.
- GovCloud partition differences (ARNs `aws-us-gov`, service availability) — note in conventions now: never hardcode partition, use `data.aws_partition`.
