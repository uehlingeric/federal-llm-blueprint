# Minimal Example

The smallest deployable slice of the blueprint. Demonstrates KMS, network, IAM, and ECS LLM gateway wiring in both no-egress and standard-private modes.

## What This Deploys

- **KMS Keys** (data, logs, secrets domains) with automatic rotation, least-privilege policies, and partition-aware ARN construction
- **VPC** with private-subnet architecture across 2 availability zones
- **VPC Endpoints** for Bedrock (runtime + agent), S3, ECR, CloudWatch Logs, KMS, Secrets Manager, ECS, and STS
- **Security Groups** for application workloads and endpoint access
- **VPC Flow Logs** encrypted with the KMS logs key
- **IAM Roles** for task execution and app task, with permission boundary and scoped policies to gateway, vector store, and document store resources
- **LLM Gateway** (ECS Fargate task) running LiteLLM, invoking Bedrock Claude models via internal ALB
- **Document Store** (S3 bucket set): ALB logs, documents storage, and access logs with encryption and lifecycle policies
- **Vector Store** (RDS pgvector): Single-AZ PostgreSQL database with pgvector extension, IAM database authentication, and encrypted storage
- **No-egress mode** (default): Zero Internet Gateways, zero NAT Gateways. All AWS service traffic routes through private VPC endpoints.
- **Standard mode** (optional): Public subnets and optional NAT Gateway for standard private-VPC deployments with outbound internet access.

## Modes

### No-Egress Mode (Default: `no_egress = true`)

- No public subnets
- No Internet Gateway
- No NAT Gateway
- All AWS service traffic via VPC endpoints with private DNS resolution enabled
- Suitable for federal/air-gap environments and GovCloud deployments

### Standard Mode (`no_egress = false`)

- Optional public subnets (default: disabled in this example)
- Optional NAT Gateway (default: disabled in this example)
- Same VPC endpoints as no-egress mode (endpoints are the primary AWS-service path in both modes)
- Suitable for corporate private-VPC deployments with optional internet egress

## Quick Start

1. Copy `terraform.tfvars.example` to `terraform.tfvars`:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Adjust variables (project, environment, region, no_egress mode):
   ```bash
   cat terraform.tfvars
   ```

3. Plan and apply:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

4. View outputs:
   ```bash
   terraform output -json
   ```

5. Destroy (careful with ENI cleanup):
   ```bash
   terraform destroy
   ```

## Prerequisites

- AWS account with appropriate permissions (VPC, KMS, CloudWatch Logs, IAM, ECS, etc.)
- Terraform >= 1.9.0
- AWS CLI configured with credentials
- **Bedrock model access must be enabled for the account/region** (Bedrock console → Model access) before anything works. This is a top support gotcha: enable the configured foundation model (Anthropic Claude Sonnet 4.5) before deploying. The example invokes it through the `us.` cross-region inference profile.
- LiteLLM container image mirrored into private ECR and digest-pinned (see Configuration section below)
- Docker CLI (for the mirror + digest-pin procedure)

## Configuration

### Container Image: Mirror to ECR, Then Pin

In no-egress mode the VPC cannot reach public registries (ghcr.io, Docker Hub, public.ecr.aws), so the image **must** live in a private ECR repository, reached through the ECR VPC endpoints:

```bash
# 1. Create a private repository and mirror the image
aws ecr create-repository --repository-name litellm
aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com
docker pull ghcr.io/berriai/litellm:main-stable
docker tag ghcr.io/berriai/litellm:main-stable <account>.dkr.ecr.<region>.amazonaws.com/litellm:main-stable
docker push <account>.dkr.ecr.<region>.amazonaws.com/litellm:main-stable

# 2. Pin the PUSHED digest (a pull/push cycle can rewrite the manifest, changing the digest)
docker inspect --format='{{index .RepoDigests 0}}' <account>.dkr.ecr.<region>.amazonaws.com/litellm:main-stable

# 3. In terraform.tfvars: the pinned image, plus the repository ARN so the
#    task execution role's pull permission scopes to exactly this repo
gateway_container_image = "<account>.dkr.ecr.<region>.amazonaws.com/litellm@sha256:..."
ecr_repository_arns     = ["arn:aws:ecr:<region>:<account>:repository/litellm"]
```

### Master Key Population

After `terraform apply`, the gateway's master key secret (empty) must be populated:

```bash
# Get the secret ARN from outputs
SECRET_ARN=$(terraform output -raw master_key_secret_arn)

# Populate with a random key (or your own API key)
aws secretsmanager put-secret-value \
  --secret-id "$SECRET_ARN" \
  --secret-string "sk_live_$(openssl rand -hex 20)"
```

(See docs/secrets-handling.md for the pattern and rationale.)

### Self-Signed Certificate (Sandbox Only)

By default, the ALB uses a self-signed certificate (SANDBOX ONLY). The private key lands in the Terraform state. For production:

1. Provision an ACM certificate or use ACM PCA (private CA)
2. Set `create_self_signed_cert = false` and supply `certificate_arn`
3. Re-run `terraform apply`

### Vector Store Bootstrap

After `terraform apply`, the RDS pgvector database must be initialized with the application schema and bootstrap data:

1. Retrieve the RDS master credentials from Secrets Manager:
   ```bash
   SECRET_ARN=$(terraform output -raw db_master_secret_arn)
   aws secretsmanager get-secret-value --secret-id "$SECRET_ARN"
   ```

2. Run the pgvector bootstrap seed script (see `scripts/seed-vectors.py`) inside the VPC. The client task must run in the **app** security group — the database security group only admits traffic *from* the app SG; it is not a client-side group:
   ```bash
   # One-off ECS task in the cluster (requires Python 3.11+, psycopg[binary], boto3, numpy)
   aws ecs run-task \
     --cluster $(terraform output -raw cluster_arn | cut -d/ -f2) \
     --task-definition <task-definition-family> \
     --network-configuration "awsvpcConfiguration={subnets=[$(terraform output -json private_subnet_ids | jq -r '.[0]')],securityGroups=[$(terraform output -raw app_security_group_id)]}" \
     --launch-type FARGATE
   ```

3. Verify the bootstrap succeeded per docs/verification/vector-proof.md.

## Cost

This example provisions:
- 1 VPC: ~$0/month
- 2 private subnets: ~$0/month
- 11 interface VPC endpoints: ~$7–8/month each **per AZ** — ~$160/month across this example's 2 AZs (biggest line item)
- 1 S3 gateway endpoint: ~$0/month
- 1 internal ALB: ~$16–18/month
- 1 ECS Fargate task (1 vCPU, 2 GB memory): ~$30–35/month (while running; shut down when not in use)
- 1 RDS db.t4g.medium single-AZ PostgreSQL with pgvector: ~$60/month (~$2/day; second-biggest line item)
- 1 RDS gp3 20 GB storage: ~$2.50/month
- 3 S3 buckets (ALB logs, documents, access logs): ~$1/month
- 3 KMS CMKs (data, logs, secrets): ~$1/month each (~$3 total)
- VPC Flow Logs: minimal cost

**Estimated cost: ~$270–300/month (roughly $9–10/day)** while the stack is up. Interface endpoints (billed per endpoint **per AZ**), RDS database, and the Fargate task dominate. Disable deletion protection and run `terraform destroy` when not in use (see Destroy section below). These are list-price estimates; [docs/costs.md](../../docs/costs.md) has the measured itemization.

### Cost Control in the LiteLLM Config

The `litellm.yaml.tpl` contains two sandbox cost-control lines:

```yaml
litellm_settings:
  # ... other settings ...
  max_budget: 100.0         # Max USD per budget_duration
  budget_duration: 30d      # Budget window
```

And per-model rate limiting:

```yaml
model_list:
  - model_name: claude-sonnet-4-5
    litellm_params:
      # ... other params ...
      rpm: 60                # Requests per minute
```

Adjust these in `litellm.yaml.tpl` before applying; the config lands in SSM Parameter Store and is injected into the task at launch.

## Destroy

Deletion protection is enabled on the gateway ALB and the vector-store RDS instance by default (prevents accidental deletion). To destroy:

1. Disable deletion protection on both:
   ```bash
   terraform apply -var 'gateway_deletion_protection=false' -var 'vector_deletion_protection=false'
   ```
   (Or set them in `terraform.tfvars`; defaults are `true`.)

2. Destroy:
   ```bash
   terraform destroy
   ```

## Known Gotchas

- **Bedrock model access**: If the gateway task fails to start with a 403 or "User: arn:aws:iam::... is not authorized" error, check that Bedrock model access is enabled in the console (Bedrock → Model access) for the account/region.
- **VPC Endpoint ENI cleanup**: Interface endpoints create elastic network interfaces that can take 30+ seconds to detach and delete during `terraform destroy`. If destroy times out, manually force-detach the ENIs in the AWS console.
- **Master key not populated**: gateway tasks fail to launch (`ResourceInitializationError: unable to fetch secret`) until the master-key secret has a value. Populate it immediately after apply (see Configuration section above). If the deployment circuit breaker trips first (~10 failed launches), populate the secret and then force a new deployment: `aws ecs update-service --cluster <cluster> --service <service> --force-new-deployment`.
- **Self-signed cert warning**: Browsers and clients connecting to the internal ALB will see a certificate mismatch. This is expected in sandbox mode. For production, use a private CA (ACM PCA) or a trusted internal CA.
- **Bedrock availability**: Bedrock endpoints are not available in all AWS regions. In `us-east-1` (default), both Bedrock runtime and agent endpoints are available. In other regions, verify endpoint availability in the AWS documentation before deploying.
- **RDS creation time**: The vector store database takes 10–15 minutes to become available after `terraform apply`. Check the AWS console (RDS → Databases) for the instance status.
- **RDS deletion protection**: The vector store has deletion protection enabled by default (same pattern as the gateway ALB). To destroy, set `vector_deletion_protection = false` (alongside `gateway_deletion_protection = false`) and apply before `terraform destroy`. The final snapshot is named `{project}-{environment}-vector-final` and can be reviewed before deletion.

## Files

- `main.tf`: KMS, network, IAM, document-store, vector-store, gateway, and ALB modules
- `litellm.yaml.tpl`: LiteLLM configuration template (budget, rate limits, model mapping)
- `variables.tf`: Project, environment, region, container image, certificate configuration
- `outputs.tf`: KMS, network, IAM, gateway, document-store, and vector-store module outputs
- `versions.tf`: Provider requirements
- `terraform.tfvars.example`: Example configuration
- `../scripts/seed-vectors.py`: Proof-of-concept pgvector bootstrap and seed script
- `../scripts/README.md`: Instructions for running the vector seed script in-VPC
