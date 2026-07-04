# ADR-001: ECS Fargate Over EKS for the LLM Gateway

**Status:** Accepted  
**Date:** 2026-07-04

## Context

The LLM gateway (LiteLLM proxy) is a long-running stateful service: persistent client connections, streaming (Server-Sent Events) responses, in-memory rate limiting and budget state. During ATO, an assessor evaluates every control surface; during ops, the team pays a recurring cost in labor and risk for every abstraction layer.

Three compute candidates:
1. **EKS:** Kubernetes control plane + managed nodes + add-ons (CNI, CSI, ingress controller, monitoring)
2. **ECS Fargate:** Managed task scheduling, per-task IAM roles, ALB integration
3. **Lambda:** 15-minute execution limit, cold starts, streaming response payload constraints

The decision constrains downstream module boundaries (network, IAM, observability, audit).

## Decision

**Deploy the LLM gateway on ECS Fargate.** This decision holds through both operational (commercial private) and no-egress (GovCloud/air-gap) modes.

Rationale:

- **ATO surface:** Fargate eliminates the Kubernetes control plane and node AMI patching treadmill. An assessor reviews a single IAM role per task (SI-4, IA-2 enforcement is direct), not a layered RBAC + IAM policy matrix. System Security Plan is smaller and more auditable.
- **Operational surface:** No EKS version upgrade treadmill (monthly patches, compatibility matrix validation); no add-on dependency chasing (CNI updates, CSI driver support, ingress controller CVEs). Task-level isolation (network namespace per task) is hardware-enforced.
- **Least-privilege mapping:** Fargate task-level IAM roles map directly to the module's security architecture: one role per workload, resource-scoped permissions, no shared service account keys. Week-3 IAM module leverages this directly.
- **Cost:** ECS Fargate charges per task-second (no hourly control-plane fee); this reference is single-service, making Fargate cost-optimal.
- **Streaming and state:** ALB + Fargate natively support streaming responses and persistent connections. LiteLLM's in-memory rate-limit state and budget tracking require long-running processes; Lambda's 15-minute cap and cold-start latency are incompatible.

## Consequences

- **Lost:** Kubernetes ecosystem portability (Helm charts, operators) and on-premises K8s deployment path.
- **Mitigated:** The architecture abstraction (gateway pattern) is what ports. Week-7 air-gap guide documents self-hosted alternatives (ECS on EC2, open-source proxies); the CONTROLS.md mapping is independent of compute substrate.
- **Regional:** ECS Fargate is available in all AWS commercial regions and both GovCloud regions (GovCloud-US-West-1, GovCloud-US-East-1).

## Alternatives Considered

**EKS**  
Rejected. ATO surface includes control-plane hardening, node AMI patching, Kubernetes RBAC layer on top of IAM, add-on matrix (CNI compatibility, CSI driver version locks). Operational burden is monthly across a live system. For a reference architecture in federal context, the control-plane-to-workload ratio (1 CP : 1 service) makes Kubernetes overhead unjustifiable.

**EKS Fargate**  
Rejected. Eliminates node management but retains control-plane assessment burden and add-on dependencies.

**Lambda**  
Rejected. Execution model mismatch: 15-minute cap requires task-splitting for long operations; cold starts introduce latency unpredictable to a caller; streaming responses and persistent connection tracking are awkward. Fargate's ALB integration provides HTTP/2 multiplexing and keep-alive semantics that auditors understand.

**EC2 + Auto Scaling Group**  
Rejected. Requires AMI patching (SI-2 assessment surface), capacity management, and instance-level security group rules (easier to misconfigure). Fargate's per-task isolation is simpler.
