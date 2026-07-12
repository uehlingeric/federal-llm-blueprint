# Week 2 — Network Module: VPC, Endpoints, No-Egress Mode

**Objective:** The module everything else sits inside. A VPC with private-subnet architecture, the full set of VPC interface/gateway endpoints an LLM stack needs, and a provable `no_egress` mode — no IGW, no NAT, endpoint-only connectivity. By Sunday the minimal example applies cleanly and the no-egress claim is demonstrated, not asserted.

## Exit Criteria

- [ ] `modules/network` applies in both modes: standard-private and `no_egress = true`
- [ ] No-egress mode creates zero IGW/NAT resources and all required endpoints — verified by plan-snapshot tests
- [ ] Endpoint set covers: Bedrock (runtime + agent), S3 (gateway), ECR (api + dkr), CloudWatch Logs, KMS, Secrets Manager, ECS/ECS-telemetry, STS
- [ ] Flow logs on by default, encrypted, to CloudWatch with retention
- [ ] Egress proof documented: test instance in no-egress VPC — S3-via-endpoint succeeds, internet fails

## Workstreams

### 1. Core VPC
- [ ] VPC with configurable CIDR; private subnets across 2-3 AZs; optional public subnets only when `no_egress = false` and explicitly enabled
- [ ] Conditional IGW/NAT creation — `no_egress = true` makes their count 0 (not "unused but present")
- [ ] DNS support/hostnames enabled (endpoint private DNS requires it); DHCP options documented
- [ ] Flow logs: CloudWatch destination, KMS-encrypted, `flow_log_retention_days` variable (default 90 — AU-family friendly)

### 2. VPC endpoints
- [ ] Interface endpoints with dedicated security group (443 from VPC CIDR only); private DNS on
- [ ] Endpoint list as a map variable with sane defaults so consumers can add (e.g., SageMaker Runtime) without forking
- [ ] Gateway endpoints: S3 (+ DynamoDB optional) with route-table association
- [ ] Endpoint policies: default restrictive templates (S3 endpoint scoped to in-account buckets) — documented as a starting point, not gospel
- [ ] GovCloud note per endpoint: service availability differences called out in module README

### 3. Security groups
- [ ] Baseline SGs exported for consumers: `app_sg` (egress to endpoints + DB only in no-egress mode), `endpoint_sg`
- [ ] No default-open egress in no-egress mode — explicit rules only; standard mode documents the difference

### 4. Testing & docs
- [ ] `terraform test` (native) : plan-assertion tests — no-egress mode: assert 0 IGW, 0 NAT, N endpoints; standard: assert expected routes
- [ ] Minimal example updated to consume the module in both modes (tfvars toggle)
- [ ] One real apply in a sandbox account; egress-proof procedure written up in `docs/verification/no-egress-proof.md` with CLI transcript
- [ ] Module README: usage, both modes, endpoint matrix, GovCloud caveats

## Verification

- CI: fmt/validate/tflint/checkov green; checkov network rules (no 0.0.0.0/0 ingress, flow logs on) pass without skips.
- `terraform test` suite green in CI (plan-only, no credentials).
- Sandbox apply + destroy clean (no orphaned ENIs from endpoints — known teardown gotcha, document it).

## Commit Milestones (4-6 commits)

1. VPC core + conditional IGW/NAT
2. Interface + gateway endpoints + policies
3. Security group baseline
4. terraform test suite
5. Egress proof doc + module README

## Risks & Notes

- Interface endpoints ≈ $7-8/month each — the biggest line item in the demo cost. Note in cost tracking now (week 8 doc needs it); minimal example uses the smallest viable endpoint set.
- Bedrock endpoint availability varies by region — pin examples to us-east-1/us-gov-west-1 equivalents and document.
- The egress proof is the week's headline artifact: "no-egress" as a tested property differentiates this repo from every diagram-only reference.
