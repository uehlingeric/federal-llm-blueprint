# Air-Gap & GovCloud Deployment Guide

## Why This Guide Exists

This architecture is partition-portable by construction: `data.aws_partition.current.partition` and `data.aws_caller_identity.current.account_id` are used throughout. See `docs/conventions.md` for the pattern. However, Terraform cannot make portable:

- Service availability per partition (Bedrock, endpoints, models)
- Endpoint DNS naming and certificate issuer models
- Inference profile ID prefixes (region-specific, not inference-profile-specific)
- Model selection and pricing

This guide covers what changes and what stays the same.

---

## AWS GovCloud (us-gov-east-1 / us-gov-west-1)

### Partition Handling (Already Works)

ARN construction, service principals, and account references use `data.aws_partition.current.partition` everywhere. Example — the constructed trail ARN local in `modules/audit/main.tf`:

```hcl
trail_arn = "arn:${data.aws_partition.current.partition}:cloudtrail:${data.aws_region.current.region}:..."
```

Inference profile prefix is the only manual override — the `locals` block in `examples/minimal/main.tf`:

```hcl
bedrock_model_id              = "anthropic.claude-sonnet-4-5-20250929-v1:0"
bedrock_inference_profile_id  = "us.anthropic.claude-sonnet-4-5-20250929-v1:0" # us. geo prefix; GovCloud uses "us-gov."
bedrock_inference_profile_arn = "arn:${data.aws_partition.current.partition}:bedrock:${data.aws_region.current.region}:..."
```

### Service Availability Matrix

| Service | Feature | us-gov-east-1 | us-gov-west-1 | Notes |
|---------|---------|------|------|-------|
| **Bedrock** | Runtime API | Yes | Yes | bedrock-runtime endpoints (incl. FIPS variants) exist in both regions — verified against the AWS service endpoint reference, 2026-07. Claude Sonnet 4.5 availability: **verify at deployment time** |
| | Inference Profiles | **Verify** | **Verify** | Profile availability and the `us-gov.` prefix format: **verify at deployment time** per region |
| **ECS/Fargate** | Cluster + Tasks | Yes | Yes | Standard GovCloud service (pattern: all standard AWS services available) |
| **RDS PostgreSQL** | Postgres 16 + pgvector | **Verify** | **Verify** | pgvector extension: **verify at deployment time** |
| **S3** | Bucket + Gateway Endpoint | Yes | Yes | Standard GovCloud service |
| **VPC Endpoints** | bedrock-runtime, bedrock-agent-runtime, s3, ecr.api, ecr.dkr, logs, kms, secretsmanager, ecs, ecs-telemetry, ssm, sts | Yes | Yes | Service names: `com.amazonaws.us-gov-{east,west}-1.{service}` |
| **KMS** | Customer-managed keys | Yes | Yes | Standard service; CMK ARNs use `arn:aws-us-gov:kms:...` |
| **CloudTrail** | Multi-region recording, log-file validation | Yes | Yes | Standard GovCloud service |
| **AWS Config** | Recorder + managed rules | Yes | Yes | Standard GovCloud service |
| **CloudWatch** | Logs, Metrics, Alarms, Dashboards, Logs Insights | Yes | Yes | Standard GovCloud service |
| **Secrets Manager** | Secret creation + rotation | Yes | Yes | Standard GovCloud service |
| **SSM Parameter Store** | SecureString parameters | Yes | Yes | Standard GovCloud service |
| **EventBridge** | Rules + SNS target | **Verify** | **Verify** | Likely available; confirm for your use case |
| **SNS** | Topic + subscriptions | Yes | Yes | Standard GovCloud service |
| **CloudWatch Container Insights** | ECS cluster monitoring | Yes | Yes | Standard GovCloud feature |
| **ACM** (TLS Certificates) | Certificate management | Yes | Yes | Available in both regions with "no differences" per AWS GovCloud service docs (verified 2026-07). For this stack's internal ALB, use ACM Private CA or an imported certificate — public DNS validation is impractical for private hostnames. See below. |

**Verification Note:** Rows for Bedrock runtime, ACM, and the FedRAMP statements in the decision matrix were verified against AWS documentation in 2026-07. Rows marked "Yes" without a note are long-standing GovCloud services listed in the [AWS GovCloud services guide](https://docs.aws.amazon.com/govcloud-us/latest/UserGuide/using-services.html); re-confirm at deployment time. Services marked "Verify" depend on region- or model-level availability that must be confirmed at deployment time.

### Endpoint DNS Naming

- **Commercial AWS:** `bedrock-runtime.us-east-1.amazonaws.com`
- **GovCloud:** `bedrock-runtime.us-gov-east-1.amazonaws.com` (or us-gov-west-1)
- **Service Name in Terraform:** `com.amazonaws.us-gov-east-1.bedrock-runtime`

VPC endpoint private DNS resolution handles this automatically: `aws_vpc_endpoint.interface` sets `private_dns_enabled = true`, so in-VPC clients use the standard service hostname and DNS resolves to the endpoint ENI.

### TLS Certificate Story (ALB)

The internal ALB in `modules/ecs-llm-gateway` requires a certificate. The module supports:

- **Production (no-egress):** `var.certificate_arn` pointing to ACM Private CA (recommended)
- **Development/Sandbox:** `var.create_self_signed_cert = true` (self-signed, module generates it)

**GovCloud:** ACM is available in both regions. Because the ALB is internal (private hostname), public DNS-validated certificates are impractical anywhere — GovCloud included. Options:

1. **ACM Private CA** (preferred): Deploy a Private Certificate Authority in GovCloud, issue a certificate, supply its ARN to `var.certificate_arn`.
2. **Self-signed** (sandbox only): Set `create_self_signed_cert = true`; module handles it (private key lands in Terraform state — sandbox only).

No code change required — just toggle variables.

### Inference Profile Prefix (Required Code Change)

In your root module (e.g., `examples/minimal/main.tf`), change:

```hcl
# Commercial AWS (current)
bedrock_inference_profile_id = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"

# GovCloud (required change)
bedrock_inference_profile_id = "us-gov.anthropic.claude-sonnet-4-5-20250929-v1:0"
```

This is a **string substitution**, not a module change.

### GovCloud Prerequisites Checklist

- [ ] AWS account in GovCloud (us-gov-east-1 or us-gov-west-1 region)
- [ ] Verify Bedrock is available in target region ([Bedrock endpoints](https://docs.aws.amazon.com/general/latest/gr/bedrock.html#bedrock_region))
- [ ] Verify desired model (e.g., Claude Sonnet 4.5) is available in GovCloud ([model support by region](https://docs.aws.amazon.com/bedrock/latest/userguide/models-regions.html))
- [ ] Verify RDS pgvector extension is available ([RDS for PostgreSQL docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_PostgreSQL.html))
- [ ] ACM Private CA deployed (for production TLS) or accept self-signed (development only)
- [ ] ECR repositories pre-populated with gateway container image (digest-pinned, per `docs/conventions.md`)
- [ ] EventBridge availability confirmed (if observability rules use it)

---

## True Air-Gap (No AWS)

### What Maps: The Pattern, Not the Code

The **architecture pattern** is portable:

- Private inference gateway (LiteLLM container) with OpenAI-compatible `/v1/chat/completions` surface
- Scoped egress: only internal VPC subnets can reach the gateway
- Per-domain encryption (data, logs, secrets)
- Append-only audit trail (CloudTrail → S3 bucket with object lock)
- Role-based access (IAM database auth, scoped S3 prefixes)

**Companion project:** `agentic-rag` demonstrates **model-layer substitution**: LiteLLM's provider abstraction points to self-hosted vLLM or Ollama (instead of Bedrock) with a config-file change (`litellm.yaml` model_list). The Terraform here is **not adapted** for air-gap; the pattern is.

### What Does NOT Map: Managed Services

| Layer | AWS (Commercial or GovCloud) | Air-Gap (Self-Hosted) | Terraform Coverage |
|-------|-----|-------|---|
| **LLM Inference** | Bedrock (managed, metered) | vLLM, Ollama, or equivalent (self-hosted on EC2 or GPU cluster) | Not in this repo; see agentic-rag |
| **Vector Database** | RDS Postgres + pgvector (managed, HA replicas optional) | Self-managed PostgreSQL + pgvector (single instance or custom HA) | **Not deployed** by this Terraform — bring your own or provision manually |
| **Document Store** | S3 (managed, versioned, encrypted) | MinIO, Ceph, or equivalent (self-hosted object store) | **Not deployed** by this Terraform |
| **Key Management** | AWS KMS (HSM-backed, FIPS-validated) | KMIP server, local HSM, or OS-level encryption (e.g., LUKS) | **Not deployed** by this Terraform |
| **Audit Trail** | CloudTrail + S3 + CloudWatch Logs (managed, tamper-evident) | Host audit daemons (auditd) + syslog + local log aggregation | **Not deployed** by this Terraform |
| **Identity & Access** | IAM + Secrets Manager (AWS-managed) | LDAP, Kerberos, or platform auth system | **Not deployed** by this Terraform |

**Honesty:** The Terraform modules in this repo are **AWS-specific**. They do not abstract over infrastructure providers. Deploying an air-gap version requires:

1. Provisioning the infrastructure (VMs, storage, networking) outside this repo.
2. Adapting the **control design** (encryption scoping, audit routing, role boundaries) to your platform's native services.
3. Reusing the **upstream LiteLLM container image** (digest-pinned, mirrored into your enclave registry), the **LiteLLM config template** (`examples/minimal/litellm.yaml.tpl`), and the companion agentic-rag app patterns (those are cloud-agnostic).

### Air-Gap Prerequisites Checklist

- [ ] Container registry available in air-gapped enclave (pull gateway + model images from mirrored registry, digest-pinned per `docs/conventions.md`)
- [ ] Model weights transport strategy (pre-load into enclave or secure transfer method)
- [ ] PostgreSQL 16 + pgvector extension installed and available (RDS alternative)
- [ ] Object storage provisioned and reachable (S3 alternative: MinIO, Ceph, etc.)
- [ ] Time synchronization working across all nodes (critical for audit log ordering)
- [ ] Encryption key material provisioned (HSM/KMIP, local KMS, or OS-level)
- [ ] Audit log retention policy equivalent (e.g., syslog + immutable log aggregator or object-lock-like mechanism)
- [ ] Gateway container image built and pushed to enclave registry
- [ ] Networking: gateway task can reach object store, vector DB, and model inference endpoint

---

## Decision Matrix: Commercial vs GovCloud vs Air-Gap

| Concern | Commercial AWS | GovCloud | Air-Gap |
|---------|---|---|---|
| **ATO Path** | Bedrock is in scope for FedRAMP Moderate in commercial East/West (AWS services-in-scope, verified 2026-07); the ATO package for the deployed system is customer responsibility | FedRAMP High baseline; Bedrock is in scope for FedRAMP High in GovCloud (verified 2026-07); model availability per region: verify | Depends on host facility (IL2–IL5 possible) |
| **Bedrock Model Availability** | Broad model catalog (Anthropic, Meta, Amazon, and others) | Subset per region; **verify at deployment** | N/A (use self-hosted vLLM/Ollama) |
| **Vector DB** | RDS pgvector (managed, HA, backups) | RDS pgvector in GovCloud; pgvector extension **verify** | Self-managed PostgreSQL + pgvector (bring your own HA strategy) |
| **Terraform Code Reuse** | Full (100%) | Full (100%) — only inference profile prefix changes | Pattern only (0% code reuse; new IaC required for your platform) |
| **Network Isolation** | Possible via no-egress mode; zero-trust proof in repo | Same architecture; zero-trust proof carries over | Depends on enclave networking (VPC equivalent or air-gapped subnet) |
| **Encryption at Rest** | AWS KMS (HSM-backed, FIPS-validated; confirm the current validation level against the AWS KMS FIPS certificate); automatic rotation | AWS KMS in GovCloud; same CMK pattern | HSM or OS-level (e.g., LUKS); rotation manual |
| **Audit Trail** | CloudTrail + S3 object lock + log-file validation (tamper-evident) | CloudTrail in GovCloud; same design | Host audit daemons + immutable log aggregator (DIY tamper-evidence) |
| **Key Agility** | High (model/region changes via litellm.yaml config) | High (same) | High (same; change litellm.yaml provider entries) |
| **Cost Transparency** | Per-model, per-region metering | Per-model, per-region metering (GovCloud pricing TBD) | Infrastructure + egress costs only (model inference on-premises) |
| **Compliance Effort** | Moderate (inherit Bedrock FedRAMP work if available; provide ATO for rest) | Moderate (GovCloud FedRAMP baseline; provider + customer responsibilities) | High (all security and audit on you) |

---

## Deployment Paths

### 1. Commercial AWS

```bash
terraform init -backend-config=...
terraform plan -var region=us-east-1 -var no_egress=true
terraform apply
```

Inference profile: `us.anthropic.claude-sonnet-...`

### 2. AWS GovCloud

```bash
terraform init -backend-config=... # GovCloud S3 backend
terraform plan -var region=us-gov-east-1 -var no_egress=true \
  -var certificate_arn=arn:aws-us-gov:acm-pca:... # Private CA cert
terraform apply
```

**Code change:** Edit root module's `bedrock_inference_profile_id` — change `us.` prefix to `us-gov.`  
**Service verification:** Confirm Bedrock availability and model list in target GovCloud region before `terraform apply`.

### 3. Air-Gap (Self-Hosted)

No Terraform in this repo. Instead:

1. Provision infrastructure (VMs, storage, network) using your platform's IaC.
2. Install PostgreSQL 16 + pgvector extension.
3. Deploy object store (MinIO or equivalent).
4. Deploy the LiteLLM gateway container (the upstream LiteLLM image, digest-pinned and mirrored into the enclave registry) on a CPU cluster; inference runs on separate GPU nodes.
5. Configure `litellm.yaml` to point to self-hosted vLLM/Ollama (see `agentic-rag` patterns).
6. Implement audit logging using host daemons (auditd, syslog) instead of CloudTrail.

Reusable artifacts: the LiteLLM config template (`examples/minimal/litellm.yaml.tpl`), the pgvector schema bootstrap (`modules/vector-store/bootstrap.sql`), and the vector seeding script (`scripts/seed-vectors.py`).

---

## Verification at Deployment Time

When targeting a specific AWS partition or air-gap platform:

- [ ] Bedrock model availability: Confirm desired model is available in target region using [AWS console](https://console.aws.amazon.com/bedrock) or `aws bedrock list-foundation-models`.
- [ ] RDS pgvector: Verify extension is installed on your RDS instance or self-managed PostgreSQL.
- [ ] Inference profile prefix: For GovCloud, confirm prefix format (`us-gov.` vs `us.`) in target region's model card.
- [ ] VPC endpoints: Confirm all required service endpoints are resolvable and reachable from the VPC.
- [ ] Container image digest: Pull and verify the gateway image digest matches `examples/minimal/main.tf`.
- [ ] Audit log retention: Verify CloudTrail/Config/Bedrock logs are flowing to the correct S3 bucket and CloudWatch Logs group.
- [ ] No-egress proof: Run a test task inside the VPC and confirm it cannot reach the public internet (document in `docs/verification/no-egress-proof.md`).
