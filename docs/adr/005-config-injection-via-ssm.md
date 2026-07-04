# ADR-005: Config Injection via SSM Parameter + ECS Secrets + Entrypoint Materialization

**Status:** Accepted  
**Date:** 2026-07-04

## Context

Week-4 architecture includes the LiteLLM gateway: a container that needs a configuration file specifying which Bedrock models to expose, rate limits, budget controls, and other operational parameters. This config file must be updateable without rebuilding and redeploying the container image (operational flexibility); it must be auditable (CloudTrail trail on every change); and it must not expose secrets in plaintext anywhere in the build pipeline or stored code.

Three competing approaches:

1. **Baked into the container image** (Dockerfile ADD instruction): Immutable provenance and simple deployment (run the image, no fetch logic needed). But every config change requires an image rebuild, digest re-pin in the task definition, another push to ECR, and a service redeploy. Config diffs are buried in image layer history. Requires a private container registry build pipeline (GitHub Actions + ECR, cost and operational overhead). For a blueprint, this locks implementers into CI/CD patterns we don't otherwise dictate.

2. **S3 object fetched at task startup** (curl in entrypoint): No size limits (objects up to 5 GB). But requires S3:GetObject IAM permission, custom fetch-and-retry logic in the entrypoint, error handling for transient failures, and another AWS service surface to manage. The plaintext config lands in container ephemeral storage (/tmp); if debugging requires container inspection or logs capture the env, exposure is possible. No native ECS integration (we'd write shell logic to fetch, not use ECS secrets).

3. **EFS mount**: Persistent, writable config without rebuilds. But adds an entire storage service, mount targets in each subnet, security-group rules for NFS, and persistent state outside the task (drift). For a reference architecture and one small file, infrastructure overhead is high.

**The chosen approach: SSM Parameter (SecureString) + ECS Secrets Injection + Entrypoint Materialization.**

Why: Config changes without image rebuild; parameter versioning + CloudTrail GetParameter/PutParameter audit trail (every change logged, who made it, when); native ECS secrets integration (no custom fetch code — the container runtime handles retrieval); same encryption-at-rest (KMS secrets domain CMK) and transport security (ViaService condition on KMS decrypt) as other secrets in the pattern.

## Decision

**The LiteLLM config YAML is stored as an AWS Systems Manager Parameter Store `SecureString` parameter, encrypted under the KMS `secrets` CMK, with name `/{project}/{environment}/gateway/litellm-config`. ECS injects it as a container secret (valueFrom the parameter ARN). Because the container image has a read-only root filesystem (hardening requirement), the entrypoint override writes it to the writable ephemeral /tmp at task startup.**

### Implementation Steps

1. **Terraform resource** (in `modules/ecs-llm-gateway`):
   ```hcl
   resource "aws_ssm_parameter" "litellm_config" {
     name   = "/${var.project}/${var.environment}/gateway/litellm-config"
     type   = "SecureString"
     key_id = var.secrets_kms_key_arn
     value  = var.config_yaml
     tier   = "Intelligent-Tiering"
   }
   ```

2. **ECS task definition secret injection**:
   ```hcl
   resource "aws_ecs_task_definition" "gateway" {
     # ... other config ...
     container_definitions = jsonencode([
       {
         name  = "gateway"
         image = var.container_image  # digest-pinned, validated at plan time
         secrets = [
           {
             name      = "LITELLM_CONFIG"  # environment variable name
             valueFrom = aws_ssm_parameter.litellm_config.arn
           },
           {
             name      = "LITELLM_MASTER_KEY"  # separate secret (Secrets Manager)
             valueFrom = local.master_key_secret_arn
           }
         ]
         # entrypoint override written below
       }
     ])
   }
   ```

3. **Container entrypoint override** (to write ephemeral /tmp/config.yaml):
   The task definition sets the entrypoint to materialize the config:
   ```hcl
   entrypoint = [
     "sh",
     "-c",
     "printf '%s' \"$LITELLM_CONFIG\" > /tmp/config.yaml && exec litellm --config /tmp/config.yaml --port 4000"
   ]
   ```
   This ensures: (a) the config lands in the writable /tmp, not the read-only root FS; (b) the LiteLLM process runs as PID 1 (proper signal handling).

4. **Task execution role IAM policy** (in `modules/iam`, statements gated on `var.ssm_parameter_arns`):
   ```hcl
   statement {
     sid       = "SSMGetParameters"
     effect    = "Allow"
     actions   = ["ssm:GetParameters"]  # plural: ECS may batch
     resources = var.ssm_parameter_arns
   }

   statement {
     sid       = "KMSDecryptSecrets"
     effect    = "Allow"
     actions   = ["kms:Decrypt", "kms:DescribeKey"]
     resources = [var.kms_key_arns["secrets"]]
     condition {
       test     = "StringEquals"
       variable = "kms:ViaService"
       values   = ["ssm.${data.aws_region.current.region}.amazonaws.com"]
     }
   }
   ```
   The permission boundary carries a matching read-only `AllowSSMParameterRead` ceiling
   (no `PutParameter`/`DeleteParameter`) — without it, the identity grant would intersect
   to nothing.

5. **Config change procedure** (Terraform owns the parameter — an out-of-band `aws ssm put-parameter` would drift and be reverted on the next apply):
   - Edit the config source (`examples/minimal/litellm.yaml.tpl` in the reference composition) and `terraform apply` — this updates the parameter value and is the CloudTrail-audited change.
   - Force a new deployment: `aws ecs update-service --cluster $CLUSTER --service $SERVICE --force-new-deployment`
   - ECS stops old tasks, starts new ones; each new task retrieves the updated parameter at launch.

## Consequences

- **Clarity:** Config is visibly stored, versioned, and audited in Parameter Store. Changes appear in CloudTrail with timestamp and principal. The YAML content is encrypted at rest and in transit (ViaService condition ensures KMS calls route through the AWS service endpoint, not the internet).

- **State Exposure:** The parameter *value* — the full config YAML — is stored in Terraform state and appears in plan diffs (masked as sensitive in output, but present in the state file). This is exactly why the config MUST NOT contain secrets: the master key travels separately via Secrets Manager, whose value Terraform never touches (shell-only resource, populated out-of-band per `docs/secrets-handling.md`). The state file itself is protected per ADR-002 (encrypted remote state). Enforce the no-secrets rule via code review of `var.config_yaml` and its template.

- **Size Limit:** SSM parameters have a 4 KB ceiling for Standard tier, 8 KB for Advanced tier. A typical Bedrock gateway config (model list, rate limits, budget controls) is <1 KB. If config grows beyond 8 KB (unlikely for this use case, but possible with many models and comments), migrate to the S3 alternative and add an s3:GetObject fetch in the entrypoint.

- **Entrypoint Drift:** The container no longer runs the image's default entrypoint verbatim. Upgrades to the LiteLLM base image must be monitored: if the image maintainer changes the entrypoint, our override silently replaces it. Document this in the module README and monitor LiteLLM release notes (same practice as container image pinning).

- **Config Changes Require Forced Redeploy:** There is no hot-reload. Changing the parameter alone does not affect running tasks. A `force-new-deployment` is required. This is a trade-off: simpler than implementing a config-reload endpoint in the gateway (additional complexity, testing surface), and aligns with container-orchestration patterns (immutable deployments, state via new revisions).

- **Audit Trail:** Every parameter change is logged in CloudTrail with `PutParameter` and `GetParameter` events. This provides auditable evidence of who changed the config and when, satisfying NIST CM control requirements.

## Alternatives Considered

**Baked into the container image (Dockerfile ADD)**  
Rejected. Immutable, but operationally inflexible: every config change is a rebuild + re-pin + registry push + service redeploy. For a reference blueprint, this prescribes a full CI/CD pipeline (GitHub Actions → build → push) that implementers may not need. Config diffs disappear into image history, making it hard to audit what changed. The overhead is justified only if config never changes post-deployment (unrealistic for operational parameters like budget limits and model allowlists).

**S3 object + curl in entrypoint**  
Considered. Fetch at startup is feasible; S3 objects have no size limit. Drawbacks: (a) requires custom fetch-and-retry logic in shell or language; error handling for timeout/permission failures complicates the entrypoint; (b) requires another IAM permission (s3:GetObject) and bucket policy surface; (c) no native ECS integration — we write the fetch ourselves, introducing a custom component where ECS Secrets already solve the problem; (d) the config lands in the task filesystem (/tmp) just like SSM does, so no operational advantage on security-in-storage.

**EFS mount**  
Rejected. Adds persistent storage outside the task, with mount targets, security-group rules, and cross-AZ NFS traffic. For a single small file per task, the infrastructure burden (EFS provisioning, lifecycle management) is disproportionate. Suitable only if multiple tasks share a large, mutable config or if config must be writable by a control plane without task restarts.

**Bake config + fetch from SSM (hybrid)**  
Rejected. Defeats the simplicity: if we bake a default config and fetch an override at runtime, we add fetch logic and parameter retrieval to the container, and the question of what happens if the parameter is missing (fail fast? use default?) introduces complexity.

## Revisit Trigger

If the config outgrows 8 KB Advanced tier ceiling, migrate to the S3 fetch alternative. If implementers need hot-reload (config changes without service restart), add a config-reload HTTP endpoint to the gateway container and change the update procedure to PATCH the endpoint instead of forcing a redeploy.
