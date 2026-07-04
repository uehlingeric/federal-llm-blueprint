# Secrets Handling — Federal LLM Blueprint

## Scope: What Is and Isn't a Secret

### Secrets (stored in Secrets Manager)
- **Gateway master key:** Per-instance API key (if using a non-Bedrock LLM provider in hybrid configuration)
- **Non-Bedrock LLM API keys:** Keys for OpenAI, Anthropic, or other third-party models in multi-provider setups
- **RDS master password:** Database root credentials (created in week 5; handled by the vector-store module)

### Not Secrets (safe in code, Terraform, or logs)
- **Endpoint IDs:** VPC endpoint IDs (e.g., vpce-xxxx) — are AWS-internal and not sensitive
- **Resource ARNs:** IAM role ARNs, S3 bucket ARNs, RDS instance ARNs — all loggable in CloudTrail
- **KMS key IDs:** CMK IDs and aliases — public within the account; key policies govern access
- **Model ARN references:** Bedrock model ARNs (e.g., `arn:aws:bedrock:...::model/anthropic.claude-3...`) — service-public
- **VPC CIDR blocks, subnet IDs:** Network topology — not sensitive in a private deployment

---

## The Pattern: Secrets Manager + KMS + ECS Injection

### Step 1: Create the Secret (Terraform)

```hcl
# Example: gateway master API key
resource "aws_secretsmanager_secret" "gateway_api_key" {
  name_prefix             = "${local.name_prefix}-gateway-key-"
  recovery_window_in_days = 7
  kms_key_id              = var.kms_key_ids["secrets"]
  #checkov:skip=CKV_AWS_149: Resource policy enforced separately below

  tags = merge(local.common_tags, {
    DataClassification = "confidential"
  })
}

# Resource policy: only app_task role can read
data "aws_iam_policy_document" "gateway_secret_policy" {
  statement {
    sid       = "AllowAppTaskRead"
    effect    = "Allow"
    principals {
      type        = "AWS"
      identifiers = [var.app_task_role_arn]
    }
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.gateway_api_key.arn]
  }

  statement {
    sid       = "DenyUnencryptedTransport"
    effect    = "Deny"
    principals { type = "AWS"; identifiers = ["*"] }
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.gateway_api_key.arn]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_secretsmanager_secret_resource_policy" "gateway_api_key" {
  secret_id              = aws_secretsmanager_secret.gateway_api_key.id
  resource_policy       = data.aws_iam_policy_document.gateway_secret_policy.json
}
```

### Step 2: Populate the Secret Value (Out-of-Band)

**Never use Terraform literals for secret values.** Use AWS CLI or the AWS console:

```bash
aws secretsmanager put-secret-value \
  --secret-id $(terraform output -raw gateway_secret_id) \
  --secret-string "sk_live_xxxx" \
  --no-cli-pager
```

Or, for automated provisioning pipelines, use the AWS provider's write-only secret version (Terraform ≥1.10 ephemeral resources):

```hcl
# TF 1.10+ ephemeral resource pattern (preferred)
resource "terraform_data" "gateway_secret_value" {
  provisioners {
    local-exec {
      command = <<-EOT
        aws secretsmanager put-secret-value \
          --secret-id ${aws_secretsmanager_secret.gateway_api_key.id} \
          --secret-string "${var.gateway_api_key_value}" \
          --no-cli-pager
      EOT
    }
  }

  lifecycle {
    ignore_changes = [provisioners]
  }

  # Alternative: fetch the secret ARN, don't reference the plaintext
  # This value is only logged as an ARN, never the secret itself
  depends_on = [aws_secretsmanager_secret_resource_policy.gateway_api_key]
}
```

For older Terraform, create the secret version out-of-band (CI/CD pipeline or manual):
```bash
# Step 1: Terraform creates the secret resource (value empty)
# Step 2: Pipeline populates it after apply
# Step 3: Reference only the ARN in downstream configs
```

### Step 3: Inject into ECS Task Definition

The secret is **never** stored in the Terraform state as plaintext. It is injected by ECS at task launch:

```hcl
resource "aws_ecs_task_definition" "gateway" {
  family                   = "${local.name_prefix}-llm-gateway"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = var.task_execution_role_arn

  container_definitions = jsonencode([
    {
      name      = "gateway"
      image     = var.gateway_image_digest
      portMappings = [{ containerPort = 8000, hostPort = 8000, protocol = "tcp" }]

      # CORRECT: reference secret via ARN only, ECS injects at launch
      secrets = [
        {
          name      = "LITELLM_MASTER_KEY"  # container env var name
          valueFrom = aws_secretsmanager_secret.gateway_api_key.arn  # NOT the value
        }
      ]

      # WRONG: never include plaintext environment variables
      # environment = [
      #   { name = "LITELLM_MASTER_KEY", value = "sk_..." }  # NEVER
      # ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.gateway.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}
```

**How it works:**
1. Terraform creates the task definition with `secrets` referencing the ARN, not the value.
2. At task launch, the ECS task-execution role (which has `secretsmanager:GetSecretValue` on this specific ARN) retrieves the secret.
3. ECS injects the plaintext into the container's environment at launch; the plaintext never appears in Terraform state or logs.

---

## State Exposure: What Lands Where and Mitigation

### Terraform State
- **What lands there:** Only the secret **resource metadata** (ARN, creation date, version), never the plaintext value.
  - State entry example: `aws_secretsmanager_secret.gateway_api_key = { arn = "arn:aws:secretsmanager:...", id = "..." }`
- **Why it's safe:** Secrets Manager stores the actual value server-side, encrypted with KMS. State contains only the reference.
- **Why you must protect state:** State is still sensitive (contains ARNs, key IDs, role assumptions). Always use S3 + KMS backend (see ADR-002).

### CloudTrail (Logs All Activity)
- **Recorded:** `GetSecretValue` calls, `PutSecretValue` calls, who called them, when.
- **Not recorded:** The plaintext value (CloudTrail does not log the `SecretString` response data).
- **Implication:** Audit trails show who accessed a secret; they don't expose the value.

### CloudWatch Logs
- **Risk:** If container logs include the injected secret (e.g., debug output prints env vars), it lands in CloudWatch Logs.
- **Mitigation:** Container images must not log environment variables. LiteLLM does not log its master key by default; verify this in your image build.

### Git History
- **Rule:** Never commit Terraform values, env files, or secrets configuration files.
- **CI Integration:** Pre-commit hooks (or checkov) flag hardcoded secrets in Terraform files and block commits.

---

## Rotation Posture: Structure for Automation

Secrets Manager supports automatic rotation via Lambda. The architecture is ready for rotation but the Lambda function is toggled on when the consumer exists (week 5 for RDS master password).

### Rotation-Ready Structure (Now)
```hcl
resource "aws_secretsmanager_secret" "rds_master" {
  name                    = "${local.name_prefix}-rds-master"
  kms_key_id              = var.kms_key_ids["secrets"]
  recovery_window_in_days = 7

  # Rotation will be enabled in week 5
  # rotation_rules {
  #   automatically_after_days = 30
  # }
}
```

### Rotation Lambda (Week 5, No-Egress Mode)
When rotation is enabled (week 5), a Lambda function runs every 30 days to rotate the RDS master password:

1. **Lambda placement:** Private subnet (no internet egress).
2. **VPC endpoint requirement:** The Lambda needs access to Secrets Manager; if in no-egress mode, it uses the VPC endpoint (already provisioned in week 2).
3. **IAM role:** Lambda role has:
   - `secretsmanager:GetSecretValue` + `PutSecretValue` on the rotation secret
   - `rds:ModifyDBCluster` + `rds:DescribeDBClusters` to change the master password
   - No internet access (rotation stays within AWS APIs).

### Rotation-Lambda Code Pattern (Example)
```python
import boto3

secrets_client = boto3.client("secretsmanager")
rds_client = boto3.client("rds")

def lambda_handler(event, context):
    secret_id = event["SecretId"]
    
    # Get current secret
    current = secrets_client.get_secret_value(SecretId=secret_id)
    
    # Generate new password (Secrets Manager helper)
    new_password = secrets_client.get_random_password(PasswordLength=32)["RandomPassword"]
    
    # Update RDS master password
    rds_client.modify_db_cluster(
        DBClusterIdentifier=DB_CLUSTER_ID,
        MasterUserPassword=new_password,
        ApplyImmediately=True
    )
    
    # Store new password in Secrets Manager (versioning, auto-finalization)
    secrets_client.put_secret_value(
        SecretId=secret_id,
        SecretString=new_password,
        VersionStages=["AWSCURRENT"]
    )
    
    return {"statusCode": 200}
```

### Manual Rotation (Air-Gap Fallback)
If rotation Lambda is not enabled or fails, manual rotation is the documented fallback:

```bash
# 1. Generate new password
NEW_PW=$(openssl rand -base64 32)

# 2. Update RDS master password (via SSM Session into the VPC)
aws rds modify-db-cluster \
  --db-cluster-identifier federal-llm-prod-cluster \
  --master-user-password "$NEW_PW" \
  --apply-immediately

# 3. Update Secrets Manager
aws secretsmanager put-secret-value \
  --secret-id federal-llm-prod-rds-master \
  --secret-string "$NEW_PW"

# 4. Verify: attempt a connection
psql -h <endpoint> -U postgres -d postgres -c "SELECT 1"
```

---

## Lifecycle: Create → Inject → Rotate → Revoke → Destroy

| Stage | Who | How | Notes |
|-------|-----|-----|-------|
| **Create** | Terraform (week 3-5) | `aws_secretsmanager_secret` resource; resource policy restricted to app_task role | Secret ARN appears in state (safe; no plaintext) |
| **Populate** | CI/CD or manual | `aws secretsmanager put-secret-value` (out-of-band); never Terraform `aws_secretsmanager_secret_version` with inline `secret_string` | Plaintext never in state; CloudTrail logs the action, not the value |
| **Inject** | ECS at task launch | Task definition `secrets` block references ARN; ECS task-execution role retrieves and injects into container env | Plaintext only in container memory; never in logs or state |
| **Rotate** | Lambda (week 5+) or manual | Lambda on 30-day schedule; manual `modify-db-cluster` + `put-secret-value` if no Lambda | Secrets Manager versions the value; RDS password change atomic with secret store update |
| **Revoke** | Infrastructure cleanup | Remove IAM policy `secretsmanager:GetSecretValue` from any role; update secret resource policy | Secret remains in Secrets Manager; applications unable to retrieve |
| **Destroy** | Terraform destroy (decom) | `aws_secretsmanager_secret` deletion (recovery window 7 days by default); CloudTrail logs the deletion | No audit gap; recovery window allows accidental restore |

**NIST IA-5 (Access Controls) Mapping:**
- Create → IA-5(1)(a): Establish secret storage with encryption
- Populate → IA-5(1)(c): Protect secret values from exposure (never plaintext in VCS or state)
- Inject → IA-5(1)(c): Distribute secrets securely to runtime (ECS mechanism, not manual)
- Rotate → IA-5(1)(e): Periodic credential change (30-day cycle)
- Revoke → IA-5(1)(b): Revoke unused credentials (policy removal, resource policy tightening)
- Destroy → IA-5(1)(b): End-of-life credential destruction (scheduled deletion)
