# Week 7 — Compliance Documentation: CONTROLS.md, Threat Model, Air-Gap Guide

**Objective:** The documentation that makes this a *federal* blueprint instead of a hardened AWS stack: a NIST 800-53 rev5 control mapping with per-module implementation statements, a threat model, and the air-gap/GovCloud deployment guide. By Sunday a security assessor could use CONTROLS.md as the skeleton of a system security plan section.

## Exit Criteria

- [ ] `CONTROLS.md`: every module mapped to specific 800-53 rev5 controls with implementation statements, inheritance notes, and gaps stated honestly
- [ ] Control coverage: AC, AU, CM, IA, RA, SC, SI families addressed; each mapping cites the exact Terraform resource/setting that implements it
- [ ] `docs/threat-model.md`: STRIDE-organized, LLM-specific threats included, mitigations traced to modules
- [ ] `docs/airgap-guide.md`: GovCloud deltas + true air-gap (no-AWS) adaptation notes
- [ ] OSCAL component definition generated for the mapped controls (stretch: validates against NIST OSCAL schema)

## Workstreams

### 1. CONTROLS.md
- [ ] Structure: control id → implementation statement → implementing resources (file/resource links) → responsibility (this stack / inherited from AWS / customer) → gaps/notes
- [ ] Harvest week-6 in-code annotations as the starting inventory; fill by family:
  - **AC** (AC-2/3/6): week-3 RBAC matrix, boundaries, IAM DB auth
  - **AU** (AU-2/3/6/9/11/12): CloudTrail, invocation logs, validation, retention, KMS on logs
  - **CM** (CM-2/3/6): Terraform-as-baseline, CI gates, Config drift detection
  - **IA** (IA-2/5): IAM auth paths, secrets rotation posture
  - **RA** (RA-5): checkov/tflint in CI as vulnerability-scanning contribution + its limits
  - **SC** (SC-7/8/12/13/28): no-egress boundary, TLS, KMS management, encryption at rest/transit
  - **SI** (SI-4): alarms, Config rules, flow logs
- [ ] Honest-gaps section: what an ATO still needs (POA&M-style): pen test, contingency plan, media protection, personnel controls — out of scope stated plainly
- [ ] Responsibility column distinguishes AWS-inherited vs stack-implemented vs customer-required — assessors think in exactly these terms

### 2. Threat model
- [ ] STRIDE per plane (network, compute, data, audit, identity) + LLM-specific: prompt injection at gateway, model output exfiltration paths, embedding-store poisoning, prompt-log sensitivity, cost-DoS via token abuse
- [ ] Each threat: mitigations mapped to module settings (or explicit "not mitigated here — see agentic-rag guardrails layer" cross-reference for app-layer threats)
- [ ] Data-flow diagram with trust boundaries (mermaid) — the assessor's first ask

### 3. Air-gap & GovCloud guide
- [ ] GovCloud section: partition ARNs, endpoint/service availability matrix vs the modules, Bedrock-in-GovCloud state, ACM/PCA differences, CloudFront absence irrelevance
- [ ] True air-gap section: what maps (the architecture pattern, gateway abstraction pointing at self-hosted vLLM/Ollama instead of Bedrock) and what doesn't (managed services) — bridges to the agentic-rag Ollama path for the model layer
- [ ] Prerequisites checklist for each deployment mode

### 4. OSCAL (stretch, timeboxed to 1 day)
- [ ] Component-definition JSON for the stack's implemented controls; validate against OSCAL 1.1 schema; note in README that SSP generation can consume it
- [ ] If the timebox blows: ship the mapping table in machine-readable YAML instead, note OSCAL as roadmap

## Verification

- Every implementation statement spot-checked against the actual Terraform (no aspirational mappings — each cites a real resource attribute).
- Cross-reference integrity: every control cited in code annotations appears in CONTROLS.md and vice versa (script it: `scripts/check-control-refs.py`).
- External-reader test: someone with assessor context reads CONTROLS.md cold and lists what's missing — their list should match the honest-gaps section.

## Commit Milestones (4-6 commits)

1. CONTROLS.md skeleton + AC/AU families
2. CM/IA/RA/SC/SI families + gaps section
3. Threat model + trust-boundary diagram
4. Air-gap/GovCloud guide
5. OSCAL component definition (or YAML fallback) + ref-check script

## Risks & Notes

- The credibility risk is *overclaiming*: an assessor reading "AU-9: satisfied" where it's partially satisfied dismisses the whole document. Use "implements", "contributes to", "customer responsibility" precisely.
- This is documentation week — energy dips are real; the writing is the differentiator, budget the same focus as code weeks.
- Keep control text paraphrased or cited by id only (800-53 text is public domain, but the mapping reads cleaner short).
