# Week 4 — Compute: ECS Fargate LLM Gateway

**Dates:** Mon Jul 27 – Sun Aug 2, 2026
**Objective:** The compute pattern: an ECS Fargate service running an LLM gateway (LiteLLM proxy as reference container) behind an internal ALB, hardened to the level a federal reviewer expects. By Sunday the minimal example serves an OpenAI-compatible completion endpoint inside the no-egress VPC via Bedrock.

## Exit Criteria

- [ ] `modules/ecs-llm-gateway` deploys cluster, service, task, internal ALB in the week-2 network
- [ ] Gateway answers `POST /v1/chat/completions` inside the VPC, routing to Bedrock through the VPC endpoint — proven in the no-egress sandbox
- [ ] Task hardening complete: non-root, read-only root FS, no privileged, minimal task role from week 3, exec disabled by default
- [ ] Autoscaling on CPU + request count; healthchecks correct (ALB + container)
- [ ] Logs to KMS-encrypted CloudWatch group with retention; container image digest-pinned

## Workstreams

### 1. ECS core
- [ ] Cluster (Container Insights on), capacity providers Fargate + Fargate Spot toggle (Spot documented as nonprod-only)
- [ ] Task definition: LiteLLM container, digest-pinned; CPU/memory variables with sane defaults; `readonlyRootFilesystem`, `user: non-root`, no `privileged`, tmpfs for scratch
- [ ] Service: private subnets, week-3 roles, SG allowing only ALB ingress; `enable_execute_command` variable default false (and its AU implications documented)
- [ ] Deployment: circuit breaker + rollback on; min/max healthy percent tuned for single-task demo and multi-task prod values documented

### 2. Load balancer
- [ ] Internal ALB, private subnets; HTTPS listener with ACM cert (private CA variable for full no-egress; self-signed documented for sandbox); HTTP disabled
- [ ] Target group: health check on gateway `/health/liveliness`; deregistration delay tuned
- [ ] Access logs to the document-store-pattern S3 bucket (week 5 dependency — stub bucket this week, swap next)

### 3. Gateway configuration
- [ ] LiteLLM config: Bedrock models (Claude via Bedrock primary), model allowlist, key-auth on the proxy (master key from Secrets Manager via week-3 pattern)
- [ ] Config injection: SSM parameter or baked config file — decide and record ADR-005 (leaning SSM: config changes without image rebuild, auditable)
- [ ] Rate/budget limits configured at the proxy — cost-control story documented

### 4. Autoscaling & alarms
- [ ] Target-tracking: CPU 60%, ALBRequestCountPerTarget; scale-in cooldown conservative
- [ ] Baseline alarms here (full observability week 6): unhealthy host, 5xx rate, task restart churn

### 5. Testing & docs
- [ ] `terraform test`: task-def assertions (hardening flags), SG topology, listener config
- [ ] Sandbox apply: end-to-end completion call transcript saved to `docs/verification/gateway-proof.md`
- [ ] Module README + updated architecture diagram (gateway plane now real)

## Verification

- checkov ECS/ALB families zero-skip; tflint clean.
- In-VPC test (SSM session or one-off task): completion request → Bedrock response, while `curl https://example.com` fails (no-egress reconfirmed with workload present).
- Tightening pass on week-3 `TODO(scope)` markers now that real ARNs exist — diff shows scopes narrowing, not widening.

## Commit Milestones (4-6 commits)

1. Cluster + hardened task definition
2. Service + SG wiring
3. ALB + TLS + health checks
4. LiteLLM config + secrets injection + ADR-005
5. Autoscaling + alarms + gateway proof doc

## Risks & Notes

- Bedrock model access must be enabled per-account/region ahead of time — document as prerequisite prominently (top support question otherwise).
- LiteLLM image updates fast; digest-pinning + a documented update procedure beats `:latest` convenience.
- Private CA (ACM PCA) is ~$400/month — sandbox uses self-signed with verification disabled *documented as sandbox-only*; the prod path states PCA cost honestly.
