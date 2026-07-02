# Week 8 — Launch: Full-Stack Example, Cost Doc, v0.1.0 Public

**Dates:** Mon Aug 24 – Sun Aug 30, 2026
**Objective:** Ship it. The full-stack example deploys everything — network through audit — with agentic-rag as the running workload, a documented cost picture, a README rewritten for the 2-minute reviewer, and the repo flipped public alongside agentic-rag as the pair of pinned flagships.

## Exit Criteria

- [ ] `examples/full-stack`: one `terraform apply` deploys network + kms + iam + gateway + data + audit + observability + the agentic-rag container answering cited questions in the no-egress VPC
- [ ] `docs/costs.md`: measured (not estimated) monthly run-rate for minimal and full-stack, itemized, with the expensive toggles flagged
- [ ] README passes the 2-minute test; CONTROLS.md linked above the fold
- [ ] v0.1.0 tagged and public; pinned second (after agentic-rag); profile README updated
- [ ] Clean-account deployment test: fresh AWS account, prerequisites doc followed verbatim, stack live in under 45 minutes

## Workstreams

### 1. Full-stack example
- [ ] Compose all modules with production-shaped defaults; single tfvars for the demo profile
- [ ] Workload: agentic-rag image (from its week-7 Docker work) as an ECS service behind the gateway, hitting Bedrock through VPC endpoints, pgvector as its vector store — the two repos prove each other
- [ ] Ingestion path for the NIST corpus inside the VPC (one-off task pattern from week 5)
- [ ] End-to-end proof: in-VPC `POST /ask` returns a cited answer; transcript + architecture-with-request-path diagram in `docs/verification/full-stack-proof.md`
- [ ] `examples/minimal` re-verified against final module interfaces (drift check)

### 2. Cost documentation
- [ ] Run full-stack for a measured window; Cost Explorer export → `docs/costs.md`: per-service itemization, minimal vs full-stack, the four expensive toggles (endpoints count, Config data events, multi-AZ RDS, PCA) with cheap-mode alternatives
- [ ] Teardown verification: `terraform destroy` leaves nothing billable (orphaned ENI/snapshot/log-group sweep script: `scripts/verify-teardown.sh`)

### 3. README rewrite (2-minute reviewer test)
- [ ] Above the fold: positioning line, badge row (standard set + CI badge), architecture mermaid, control-coverage summary table (families × module count), link to CONTROLS.md
- [ ] Then: what-this-is/isn't (reference architecture, not an ATO), quickstart with prerequisites, module table, cost summary, threat model + air-gap guide links
- [ ] Matches repo standard structure; deliberate cross-link block with agentic-rag ("the workload this deploys" / "the infrastructure this runs on")

### 4. Release hygiene
- [ ] `gitleaks` full-history scan; no account ids/ARNs from the sandbox in committed docs (scrub transcripts — replace with `123456789012`)
- [ ] tflint/checkov/fmt/docs gates green; every module README terraform-docs-current
- [ ] CONTRIBUTING.md, SECURITY.md, issue templates; CHANGELOG.md; Dependabot for GitHub Actions + Terraform providers
- [ ] Tag v0.1.0 + release notes (what/why/control-coverage headline)

### 5. Launch
- [ ] Flip public; logged-out link/badge/diagram check
- [ ] Pins: agentic-rag #1, federal-llm-blueprint #2, MCP servers after
- [ ] Profile README Open Source table: add both flagships with one-liners; consider a "Flagship" table section above the tools
- [ ] Topics: `terraform`, `aws-govcloud`, `nist-800-53`, `fedramp`, `llm`, `bedrock`, `infrastructure-as-code`, `compliance`
- [ ] Post-launch watch: first-week issues triage; good-first-issues from the honest-gaps list

## Verification

- Fresh-account test executed start to finish from README + prerequisites only — timed; every friction point either fixed or documented.
- Destroy + sweep script confirms zero residual cost 24h later.
- A reviewer clicking only README → CONTROLS.md → one module README gets the complete story (the actual browsing path of a technical interviewer).

## Commit Milestones (4-6 commits)

1. Full-stack example + workload integration
2. End-to-end proof + cost doc + teardown script
3. README rewrite + cross-links
4. Release hygiene + scrubbed transcripts
5. v0.1.0 + post-flip fixes

## Risks & Notes

- The agentic-rag dependency is real: its Docker interface must be stable by its week 7. If it slips, the fallback workload is LiteLLM-gateway-only with the seed-script proof — still a complete story, swap the RAG workload in post-launch.
- Same rule as the sibling repo: **delay the flip, not the quality.** Two strong launches a week late beat two shaky ones on schedule.
- After launch: the pair becomes the top of the profile — retire the "one-day burst" era by keeping a small, steady issue/PR cadence on both.
