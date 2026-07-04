# ADR-003: No-Egress as a Mode, Not a Fork

**Status:** Accepted  
**Date:** 2026-07-04

## Context

The reference architecture supports two deployment postures:
1. **Commercial private:** private VPC with NAT gateway(s), AWS service endpoints, standard internet routing for egress
2. **No-egress (GovCloud/air-gap):** no internet gateway, no NAT, VPC endpoints only, VPC Flow Logs as evidence of containment

These share ~90% of infrastructure code: KMS key policy, IAM role permissions, ECS task definitions, RDS database configuration. The remaining 10% is networking topology: conditional subnet types (public vs. private-endpoint-only), conditional route tables, conditional NAT resources.

Two code-organization antipatterns emerge easily:
- **Long-lived branches** that diverge and drift (the no-egress branch gets slower to merge, fixes don't propagate)
- **Parallel module trees** in one repo (`modules/network-standard`, `modules/network-no-egress`), which drift internally and double the review surface

An ATO requires evidence that both modes are tested and present the same compliance posture.

## Decision

**One codebase with a `no_egress` boolean variable on the network module.** Conditional resources use `count` / `for_each` to create or omit resources based on mode:
- Internet-facing resources (IGW, NAT gateways, EIPs, public subnets, default routes to the IGW) are created only when `no_egress = false` *and* the user explicitly enables them — in no-egress mode their count is 0, so they are absent from the plan, not "present but unused"
- VPC endpoints (Bedrock, S3, ECR, KMS, CloudWatch Logs, Secrets Manager, ECS, STS) exist in **both** modes — they are the primary AWS-service path regardless; `no_egress` removes the internet path, it does not add the endpoint path
- All other modules (KMS, IAM, ECS, database, audit) consume the subnet IDs and security group IDs from network outputs without branching logic; only egress rules on compute security groups differ by mode

**Validation:** A shared `terraform test` suite exercises both modes:
```hcl
# tests/modes.tftest.hcl (illustrative — the real suite lands in week 2)
run "no_egress_mode" {
  command = plan

  variables {
    no_egress = true
  }

  assert {
    condition     = length(aws_internet_gateway.this) == 0
    error_message = "No-egress mode must create zero internet gateways"
  }

  assert {
    condition     = contains(keys(aws_vpc_endpoint.interface), "bedrock-runtime")
    error_message = "Bedrock runtime VPC endpoint must be present"
  }
}

run "standard_mode_with_public_subnets" {
  command = plan

  variables {
    no_egress             = false
    enable_public_subnets = true
  }

  assert {
    condition     = length(aws_internet_gateway.this) == 1
    error_message = "Standard mode with public subnets enabled must create one IGW"
  }
}
```

The test assertions make the architectural property—"in no-egress mode, these resources are absent"—continuously testable and part of CI.

## Consequences

- **Conditional complexity:** The network module has branching logic (mitigated by test assertions and single-module concentration—all conditionals live in `modules/network`, not scattered across eight modules)
- **Variable surface:** The `no_egress` variable is part of the module contract; documentation must be explicit about which downstream modules' variables are inert when `no_egress = true`
- **Review clarity:** A reviewer reading the plan output sees exactly which resources are created; absence is the claim, not "present but unused" (which would require scanning outputs or state to verify)
- **Regional consistency:** Both modes are available in commercial AWS and GovCloud regions

## Alternatives Considered

**Separate repository or long-lived branch fork**  
Rejected. Forks in version control inevitably drift. Security fixes (IAM policy, KMS rotation config) must land twice, and the unmaintained fork eventually becomes a liability. Reference code must be evergreen.

**Two parallel module trees (modules/network-standard, modules/network-no-egress)**  
Rejected. Drift occurs within one repo instead of across repos. Each tree undergoes independent refactoring; bug fixes in one don't automatically propagate to the other. Doubles the testing surface and the code-review checklist burden.

**Terraform workspaces**  
Rejected. Workspaces select state backends, not architecture. A `terraform workspace select no-egress` followed by `terraform apply` would create resources in a different state file—opaque to plan review. The architectural difference must be visible in the plan itself, not hidden in state-selection logic.

**Conditional modules in the root example (no branching in modules/network)**  
Rejected. Pushes conditional logic into the consuming example. Makes network outputs incomplete or context-dependent. Concentrating conditionals in the network module itself is clearer and prevents modules from needing to know about the no-egress posture.
