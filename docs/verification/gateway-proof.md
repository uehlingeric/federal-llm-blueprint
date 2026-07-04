# Gateway Proof — Verification Procedure

## Status

- **Static proof:** Automated in CI via `modules/ecs-llm-gateway/tests/*.tftest.hcl` assertions — runs on every PR, no credentials required.
- **Dynamic proof:** PENDING first sandbox execution — transcripts below are placeholders to be filled on initial deploy.

---

## Claim

When the `ecs-llm-gateway` module is deployed into a no-egress VPC:
- The gateway serves OpenAI-compatible completion endpoints from Bedrock via VPC endpoints, with all communication (ALB, KMS, Secrets Manager, Bedrock) remaining inside the VPC
- Authorization is enforced via API key stored in Secrets Manager, injected by ECS at task launch
- General internet egress remains blocked (week-2 no-egress invariant holds with the workload present)
- ALB logs and gateway container logs are written to CloudWatch and S3
- TLS on the internal ALB enforces encrypted transport (self-signed in sandbox; private CA in production)

---

## Static Proof (Automated in CI)

The ecs-llm-gateway module includes native Terraform test assertions in `modules/ecs-llm-gateway/tests/`:

- `hardening.tftest.hcl`: Asserts `readonlyRootFilesystem = true`, non-root user (`user = "1000"`), no `privileged` flag, secrets injection limited to `LITELLM_CONFIG` + `LITELLM_MASTER_KEY`, digest-pinned image, KMS-encrypted log group and config parameter
- `topology.tftest.hcl`: Asserts internal ALB with access logs, single HTTPS listener on 443 with the TLS 1.3 policy, SG-to-SG scoping (ALB ↔ service on the container port only), circuit breaker + rollback, autoscaling targets, baseline alarms
- `validation.tftest.hcl`: Asserts plan-time rejection of non-digest images, root users, single-subnet placement, and certificate misconfiguration

These run on every PR against mocked providers (no AWS credentials needed). Passing CI green confirms the static hardening.

---

## Dynamic Proof Procedure

This procedure proves the gateway serves completions from inside the VPC and the no-egress invariant persists with the workload.

### Prerequisites

- AWS credentials with admin access to a sandbox account
- Terraform CLI >= 1.9
- AWS CLI v2
- **CRITICAL:** Bedrock model access enabled for your account/region. Without this, InvokeModel calls fail with `AccessDeniedException`. Check via AWS Console: Bedrock → Model access (left sidebar) → Enable access for the configured model (Anthropic Claude Sonnet 4.5). This is the #1 blocker if not done pre-flight.
- **Images mirrored into private ECR.** The no-egress VPC cannot reach ghcr.io or public.ecr.aws — both the LiteLLM gateway image and the tiny curl image used by the in-VPC test client must be mirrored into a private ECR repository first (procedure in `examples/minimal/terraform.tfvars.example`). Pin the *pushed* digest, not the upstream one: a plain `docker pull`/`push` cycle can rewrite the manifest (multi-arch list → single image), changing the digest.

### Cost Note

This procedure should complete (apply → prove → destroy) in under 1 hour. Primary cost: ALB ~$16/month prorated (~$0.65/hour), ECS Fargate task ~$0.048/hour, VPC endpoints (reused from week 2, no additional cost). Recommend running in a single-hour window. Total estimated: $1–3 for the full apply → test → destroy cycle, pending Bedrock model invocations.

---

### Step 1: Deploy Minimal Stack with Gateway

Initialize and apply the `examples/minimal` stack with the gateway module enabled. Account ID placeholder: `123456789012`, region: `us-east-1`.

```bash
cd examples/minimal
cat > terraform.tfvars <<'EOF'
project     = "fedllm"
environment = "dev"
no_egress   = true
region      = "us-east-1"

# Digest of the LiteLLM image mirrored into private ECR (see prerequisites)
gateway_container_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/litellm@sha256:<pushed-digest>"
ecr_repository_arns     = ["arn:aws:ecr:us-east-1:123456789012:repository/litellm"]

create_self_signed_cert = true # sandbox only
EOF

terraform init
terraform plan -out=tfplan

# Review the plan. Expected: network, kms, iam, ecs-llm-gateway modules create:
# - 1 ECS cluster, 1 task definition, 1 service
# - 1 internal ALB with TLS listener on 443
# - 1 CloudWatch log group (KMS-encrypted)
# - 1 SSM parameter for gateway config (SecureString, encrypted under secrets CMK)
# - 1 Secrets Manager secret shell for master key (value empty until Step 2)
# - Updated IAM task-execution role with ssm:GetParameters + kms:Decrypt conditions

terraform apply tfplan
```

Expected output: Stack deploys. Capture the outputs, especially `alb_dns_name`, `gateway_log_group_name`, `cluster_arn`, `master_key_secret_arn`.

```
# TRANSCRIPT PENDING
Outputs:

alb_dns_name = "internal-fedllm-dev-gateway-1234567890.us-east-1.elb.amazonaws.com"
gateway_log_group_name = "/ecs/fedllm-dev-gateway"
cluster_arn = "arn:aws:ecs:us-east-1:123456789012:cluster/fedllm-dev-gateway"
master_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fedllm-dev-gateway-master-key-xxxxxx"
```

### Step 2: Populate Master Key (Out-of-Band)

The Secrets Manager secret resource was created in Step 1 with no value (shell). Populate it with a test API key:

```bash
MASTER_KEY="test-key-$(date +%s)"
aws secretsmanager put-secret-value \
  --secret-id $(terraform output -raw master_key_secret_arn) \
  --secret-string "$MASTER_KEY" \
  --region us-east-1 \
  --no-cli-pager

echo "Master key set to: $MASTER_KEY"
```

Expected: SecretString value stored, encrypted with KMS secrets CMK.

```
# TRANSCRIPT PENDING
{
    "ARN": "arn:aws:secretsmanager:us-east-1:123456789012:secret:federal-llm-sandbox-gateway-key-xxxxxx",
    "Name": "federal-llm-sandbox-gateway-key",
    "VersionId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

### Step 3: Wait for Service Steady State

The ECS service may take 1–2 minutes to stabilize (task launch, health check passes).

```bash
CLUSTER=$(terraform output -raw cluster_arn | awk -F/ '{print $NF}')
SERVICE=$(terraform output -raw service_name)

aws ecs wait services-stable \
  --cluster "$CLUSTER" \
  --services "$SERVICE" \
  --region us-east-1

# Verify task is running:
aws ecs describe-services \
  --cluster "$CLUSTER" \
  --services "$SERVICE" \
  --region us-east-1 \
  --query 'services[0].[runningCount,desiredCount,status]'
```

Expected: Task running, health check passed, service status `ACTIVE`.

```
# TRANSCRIPT PENDING
[
    1,
    1,
    "ACTIVE"
]
```

### Steps 4–6: In-VPC Test Client — Positive and Negative Controls

A one-off Fargate task in the same private subnets runs both controls and writes its
output to the gateway log group, where Step 7b reads it back. Notes on the approach:

- The client image (any small curl-capable image, e.g. `curlimages/curl`) must be
  mirrored into private ECR like the gateway image — the VPC cannot reach public
  registries.
- The client reuses the gateway's task execution role and log group with a distinct
  stream prefix: the execution role's logs permission is scoped to exactly that log
  group, so a separate client log group would be denied.
- ECS Exec into the gateway task is **not** an option here: the SSM agent needs a
  writable filesystem, which `readonlyRootFilesystem = true` denies — one more reason
  `enable_execute_command` stays false.
- The master key on the curl command line is the throwaway test key from Step 2,
  visible in the task definition — acceptable for a sandbox proof only.

```bash
CLUSTER=$(terraform output -raw cluster_arn | awk -F/ '{print $NF}')
SUBNET=$(terraform output -json private_subnet_ids | jq -r '.[0]')
SG=$(terraform output -raw app_security_group_id)
EXEC_ROLE=$(terraform output -raw task_execution_role_arn)
LOG_GROUP=$(terraform output -raw gateway_log_group_name)
GATEWAY_URL=$(terraform output -raw gateway_url)
CLIENT_IMAGE="123456789012.dkr.ecr.us-east-1.amazonaws.com/curl@sha256:<pushed-digest>"
MASTER_KEY="test-key-..."  # From Step 2

# Positive control: completion request via the internal ALB (model name from litellm.yaml.tpl).
# Negative control: the same client curls example.com and must fail (no route out).
# -k skips certificate validation: sandbox self-signed cert only; production uses private CA.
aws ecs register-task-definition \
  --family gateway-proof-client \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu 256 --memory 512 \
  --execution-role-arn "$EXEC_ROLE" \
  --container-definitions "[
    {
      \"name\": \"client\",
      \"image\": \"$CLIENT_IMAGE\",
      \"entryPoint\": [\"sh\", \"-c\"],
      \"command\": [\"echo '=== POSITIVE CONTROL ==='; curl -sk -X POST -H 'Authorization: Bearer $MASTER_KEY' -H 'Content-Type: application/json' -d '{\\\"model\\\":\\\"claude-sonnet-4-5\\\",\\\"messages\\\":[{\\\"role\\\":\\\"user\\\",\\\"content\\\":\\\"Say hello from inside the VPC.\\\"}],\\\"max_tokens\\\":100}' $GATEWAY_URL/v1/chat/completions; echo; echo '=== NEGATIVE CONTROL ==='; curl -sv --max-time 10 https://example.com || echo 'EGRESS BLOCKED (expected)'\"],
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"$LOG_GROUP\",
          \"awslogs-region\": \"us-east-1\",
          \"awslogs-stream-prefix\": \"proof-client\"
        }
      }
    }
  ]" \
  --region us-east-1

aws ecs run-task \
  --cluster "$CLUSTER" \
  --task-definition gateway-proof-client \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$SG],assignPublicIp=DISABLED}" \
  --region us-east-1

# The task runs both controls and stops. Read its output:
sleep 90
aws logs tail "$LOG_GROUP" --log-stream-name-prefix proof-client --since 10m --region us-east-1
```

Expected positive control: HTTP 200, OpenAI-format JSON with a Bedrock-served completion.

```
# TRANSCRIPT PENDING
=== POSITIVE CONTROL ===
{
  "id": "chatcmpl-...",
  "object": "chat.completion",
  "model": "claude-sonnet-4-5",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello from inside the VPC! ..."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": { "prompt_tokens": ..., "completion_tokens": ..., "total_tokens": ... }
}
```

Expected negative control: connection failure — no route to the internet exists, proving
the week-2 no-egress invariant holds with the workload present.

```
# TRANSCRIPT PENDING
=== NEGATIVE CONTROL ===
*   Trying 93.184.216.34:443...
* Connection timed out after 10001 milliseconds
curl: (28) Connection timed out
EGRESS BLOCKED (expected)
```

### Step 7: Secondary Checks

#### 7a: ALB Access Logs

Verify ALB is writing access logs to the document-store S3 bucket:

```bash
# Stub bucket this week; the document-store module replaces it in week 5
LOG_BUCKET=$(terraform output -raw alb_logs_bucket_id)

# List recent objects (ALB delivers logs every ~5 minutes)
aws s3 ls "s3://$LOG_BUCKET/alb/AWSLogs/" --recursive --region us-east-1 | head -20
```

Expected: Log files present.

```
# TRANSCRIPT PENDING
2026-07-04 16:45:12 1234 alb/AWSLogs/123456789012/elasticloadbalancing/us-east-1/2026/07/04/123456789012_elasticloadbalancing_us-east-1_app_...
```

#### 7b: Gateway Container Logs

Verify the gateway container is logging to CloudWatch:

```bash
LOG_GROUP=$(terraform output -raw gateway_log_group_name)

# Get recent gateway container log events (the proof-client stream was read in Steps 4-6)
aws logs tail "$LOG_GROUP" --log-stream-name-prefix gateway --since 10m --region us-east-1

# Expected: container startup logs, health check responses, completion request handling
```

Expected: Container logs visible.

```
# TRANSCRIPT PENDING
2026-07-04T16:45:10.000000Z [INFO] Starting LiteLLM proxy
2026-07-04T16:45:11.000000Z [INFO] Listening on port 4000
2026-07-04T16:45:25.000000Z [DEBUG] POST /v1/chat/completions: auth passed, model=claude-sonnet-4-5
2026-07-04T16:45:26.000000Z [INFO] Request completed: tokens=40, latency_ms=234
```

#### 7c: ALB Listener Configuration

Verify TLS is enforced and HTTP is not:

```bash
ALB_ARN=$(terraform output -raw alb_arn)

aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --region us-east-1 \
  --query 'Listeners[*].[Port,Protocol,SslPolicy]'

# Expected: exactly 1 listener on port 443 with HTTPS protocol and TLS 1.3 policy
# Zero listeners on port 80 (HTTP)
```

Expected: HTTPS listener, TLS 1.3 policy.

```
# TRANSCRIPT PENDING
[
  [
    443,
    "HTTPS",
    "ELBSecurityPolicy-TLS13-1-2-2021-06"
  ]
]
```

#### 7d: KMS Encryption of Parameter & Secret

Verify the SSM parameter and Secrets Manager secret are encrypted:

```bash
# SSM parameter
PARAM_NAME="/fedllm/dev/gateway/litellm-config"
aws ssm describe-parameters \
  --filters "Key=Name,Values=$PARAM_NAME" \
  --region us-east-1 \
  --query 'Parameters[0].ARN'

# Expected: ARN returned; confirm KMS key is the secrets domain key
aws ssm describe-parameters \
  --filters "Key=Name,Values=$PARAM_NAME" \
  --region us-east-1 \
  --query 'Parameters[0].KeyId'
```

Expected: Parameter encrypted with secrets CMK.

```
# TRANSCRIPT PENDING
"arn:aws:kms:us-east-1:123456789012:key/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

```bash
# Secrets Manager secret
SECRET_ARN=$(terraform output -raw master_key_secret_arn)
aws secretsmanager describe-secret --secret-id "$SECRET_ARN" --region us-east-1 --query 'KmsKeyId'
```

Expected: Secret encrypted with secrets CMK.

```
# TRANSCRIPT PENDING
"arn:aws:kms:us-east-1:123456789012:key/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

---

## Step 8: Teardown

```bash
# Deregister the one-off client task definition
aws ecs deregister-task-definition --task-definition gateway-proof-client:1 --region us-east-1

# ALB deletion protection is on by default; disable it, apply, then destroy.
# The SSM config parameter and the master-key secret shell are destroyed with the stack
# (the secret enters its 7-day recovery window rather than deleting immediately).
cat >> terraform.tfvars <<'EOF'
gateway_deletion_protection = false
EOF

terraform apply
terraform destroy
```

Verify cleanup:

```bash
# Confirm no dangling ECS tasks, ALB, or log groups
aws ecs list-tasks --cluster "$CLUSTER" --region us-east-1 --query 'taskArns'
aws elbv2 describe-load-balancers --region us-east-1 --query 'LoadBalancers[?contains(LoadBalancerName, `federal-llm-sandbox`)]'

# Expected: all empty after destroy completes
```

---

## Summary

If all controls pass:
- **Positive:** Completion request to ALB succeeds with Bedrock response (proves end-to-end in-VPC flow).
- **Negative:** `curl https://example.com` times out (proves no-egress invariant persists with workload).
- **Audit:** ALB access logs and container logs appear in their respective sinks (proves observability chain).
- **Security:** SSM parameter and secret both encrypted with KMS secrets CMK (proves encryption discipline).
- **Claim proven:** Gateway serves OpenAI-compatible completions from Bedrock inside the VPC; no egress, full audit trail.

Transcripts from the first sandbox run should be committed to this document (replace the `# TRANSCRIPT PENDING` blocks) to form a permanent record of the proof.
