# Full-Stack Example

The complete composition with production-shaped defaults: network, KMS, IAM, LLM gateway, vector store, document store, audit, and observability — all eight modules in a no-egress VPC, with the LiteLLM gateway as the running workload serving OpenAI-compatible completions from Bedrock.

The `agentic-rag` application is the workload this stack is designed to host (RAG over the documents bucket + pgvector, answering through the gateway); its container integration lands post-v0.1.0. Until then the gateway is the workload, and the vector plane is proven with the [seed-script procedure](../../docs/verification/vector-proof.md).

## What This Deploys

| Plane | Resources |
|---|---|
| Network | No-egress VPC across 3 AZs, 11 interface endpoints + S3 gateway endpoint, flow logs (365-day retention) |
| Identity/Crypto | 3 CMK domains (data/logs/secrets), permission boundary, task roles, optional CI + human role tiers |
| Compute | ECS Fargate LiteLLM gateway (2 tasks, CPU + request autoscaling), internal ALB with TLS |
| Data | RDS PostgreSQL 16 + pgvector (multi-AZ, IAM auth, Performance Insights), documents/access-logs/ALB-logs buckets |
| Audit/Observability | CloudTrail (multi-region, data events on documents), AWS Config + 800-53-annotated rules, Bedrock invocation logging (metadata-only), alarms + dashboard + SNS |

Differences from [examples/minimal](../minimal/): 3 AZs (vs 2), multi-AZ RDS (vs single), 365-day log retention (vs 90), HA gateway (2 tasks vs 1), object lock and CloudTrail Insights exposed as toggles, CI/human role wiring. The demo profile in `terraform.tfvars.example` relaxes only object lock (teardown) and the ALB certificate (self-signed).

## Quick Start

```bash
cp terraform.tfvars.example terraform.tfvars
# 1. Mirror the LiteLLM image to a private ECR repo (below) and set
#    gateway_container_image to the pushed digest
# 2. terraform init && terraform apply
# 3. Populate the gateway master key (below)
```

## Prerequisites

- Terraform >= 1.9.0, AWS credentials with administrative access to a sandbox account
- The target model enabled in Bedrock (console → Model access) for the deployment region
- A private ECR repository holding the mirrored LiteLLM image (no-egress: public registries are unreachable from the VPC)

### Mirror the gateway image

```bash
aws ecr create-repository --repository-name litellm --image-tag-mutability IMMUTABLE
docker pull ghcr.io/berriai/litellm:main-stable
docker tag ghcr.io/berriai/litellm:main-stable <account>.dkr.ecr.<region>.amazonaws.com/litellm:main-stable
aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com
docker push <account>.dkr.ecr.<region>.amazonaws.com/litellm:main-stable

# Pin the PUSHED digest (a pull/push cycle can rewrite the manifest, changing the digest)
aws ecr describe-images --repository-name litellm --query 'imageDetails[0].imageDigest' --output text
```

Set `gateway_container_image = "<account>.dkr.ecr.<region>.amazonaws.com/litellm@<digest>"` and add the repository ARN to `ecr_repository_arns`.

### Master key population

The gateway's Secrets Manager secret is created empty (no `aws_secretsmanager_secret_version`; the value never enters Terraform state):

```bash
SECRET_ARN=$(terraform output -raw master_key_secret_arn)
aws secretsmanager put-secret-value --secret-id "$SECRET_ARN" \
  --secret-string "sk-$(openssl rand -hex 24)"
# Force new tasks so the service picks up the key
aws ecs update-service --cluster "$(terraform output -raw cluster_arn)" \
  --service "$(terraform output -raw service_name)" --force-new-deployment
```

## Verifying the Deployment

The full proof procedure (in-VPC completion request against the gateway, no-egress checks, audit-trail correlation) is documented in [docs/verification/full-stack-proof.md](../../docs/verification/full-stack-proof.md). The vector plane bootstrap is [docs/verification/vector-proof.md](../../docs/verification/vector-proof.md).

## Cost

Measured itemization for this exact composition: [docs/costs.md](../../docs/costs.md). The four levers that dominate the bill: interface-endpoint count × AZs, CloudTrail data events/Insights, multi-AZ RDS, and (production) ACM Private CA.

## Destroy

Object lock must be off (demo profile default). Deletion protection is on by default — flip it first, then destroy, then sweep:

```bash
# 1. Allow deletion
terraform apply -var gateway_deletion_protection=false -var vector_deletion_protection=false
# 2. Destroy
terraform destroy
# 3. Verify nothing billable remains
../../scripts/verify-teardown.sh -p fedllm -e prod -r us-east-1
```

KMS keys enter a 30-day pending-deletion window (reported as INFO by the sweeper); the RDS final snapshot is retained by default (`skip_final_snapshot = false` in the module) and is billable until deleted.

## Files

- `main.tf` — the eight-module composition
- `variables.tf` — production-shaped defaults; every demo relaxation is an explicit variable
- `litellm.yaml.tpl` — gateway config template (no secrets; SSM-injected per ADR-005)
- `terraform.tfvars.example` — the demo profile
- `outputs.tf` — the full §5 interface surface (network, IAM, gateway, data, audit, observability)
