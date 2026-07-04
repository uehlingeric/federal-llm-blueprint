# ECS LLM Gateway

Deploys a hardened ECS Fargate service running **LiteLLM**, an open-source LLM gateway that routes inference requests to AWS Bedrock through private VPC endpoints. The gateway terminates HTTPS at an internal Application Load Balancer, runs with a non-root user and read-only root filesystem, consumes digest-pinned container images, and automatically scales based on CPU utilization and request count.

Key features:

- **Private-VPC-only deployment**: Internal ALB with HTTPS termination; no public internet access.
- **Bedrock integration**: Routes requests to Bedrock models via VPC endpoints; no public API calls.
- **Hardened container**: Non-root user (UID 1000 default), read-only root filesystem, health checks, Container Insights enabled.
- **Automatic scaling**: Target-tracking policies for CPU and request-count-per-task; safe for both demo (1 task) and production (3+ tasks).
- **Secrets management**: LiteLLM master API key stored in Secrets Manager (KMS-encrypted); config YAML in SSM Parameter Store (Intelligent-Tiering for > 4 KB).
- **Observability**: CloudWatch Logs (KMS-encrypted), Container Insights, and three baseline CloudWatch alarms; full observability dashboard in week 6.
- **TLS options**: Use an existing ACM certificate (ACM Private CA recommended for production; ~$400/month) or create a self-signed certificate (sandbox only; private key in Terraform state).

## Prerequisites

1. **Bedrock models enabled**: Ensure your AWS account and region have Bedrock access and the desired models (e.g., Claude) enabled. See [AWS Bedrock Documentation](https://docs.aws.amazon.com/bedrock/latest/userguide/what-is-bedrock.html).

2. **Network infrastructure** (from `modules/network`):
   - VPC with private subnets (minimum 2 across different AZs).
   - VPC endpoints for Bedrock (runtime + agent), ECR, CloudWatch Logs, KMS, Secrets Manager, ECS, and STS (already provisioned by network module).
   - App security group for ECS tasks (provides egress to Bedrock, S3, etc.).

3. **IAM roles** (from `modules/iam`):
   - Task execution role (pulls container image from ECR, writes logs to CloudWatch).
   - App task role (invokes Bedrock models, accesses Secrets Manager, optionally reads S3 documents and RDS).

4. **KMS customer-managed keys** (from `modules/kms`):
   - Logs key (encrypts CloudWatch Logs).
   - Secrets key (encrypts Secrets Manager secrets and SSM parameters).

5. **S3 bucket for ALB access logs** (external):
   - Create a bucket in your account (e.g., `my-alb-logs-bucket`); the module never creates it (`examples/minimal` ships a compliant stub, replaced by the document-store module in week 5).
   - Ensure the bucket policy allows the ELB log-delivery service to write, and use SSE-S3 — log delivery rejects SSE-KMS destinations.

6. **LiteLLM container image** (digest-pinned, in private ECR):
   - **No-egress deployments cannot pull from public registries** (ghcr.io, public.ecr.aws are unreachable). Mirror the image into a private ECR repository and pass that repository's ARN to the iam module's `ecr_repository_arns`:
     ```bash
     aws ecr create-repository --repository-name litellm
     docker pull ghcr.io/berriai/litellm:main-stable
     docker tag ghcr.io/berriai/litellm:main-stable <account>.dkr.ecr.<region>.amazonaws.com/litellm:main-stable
     docker push <account>.dkr.ecr.<region>.amazonaws.com/litellm:main-stable
     ```
   - Pin the **pushed** digest (a pull/push cycle can rewrite the manifest, changing the digest):
     `docker inspect --format='{{index .RepoDigests 0}}' <account>.dkr.ecr.<region>.amazonaws.com/litellm:main-stable`
   - To update: repeat the mirror, re-pin the new digest in `container_image`, and apply. Digest-pinning plus this documented procedure beats `:latest` convenience — LiteLLM releases move fast, and an unpinned tag makes deployments unreproducible.

## LiteLLM Configuration

The module accepts a `config_yaml` variable containing the LiteLLM proxy configuration file. This YAML is stored in AWS Systems Manager Parameter Store as a SecureString, encrypted with the secrets KMS key.

**Important**: The config YAML must NOT contain secret values (API keys, master keys, credentials). Instead:

- Place the **LiteLLM master key** (API key for the proxy) in a Secrets Manager secret. The module either creates a new secret (when `master_key_secret_arn = null`) or uses an existing one.
- The container startup script materializes the config from SSM Parameter Store onto the writable `/tmp` ephemeral volume at startup, injecting the master key from Secrets Manager as the `LITELLM_MASTER_KEY` environment variable.
- The master key value is **populated out-of-band** (manually or via a Lambda rotation function) per the pattern documented in `docs/secrets-handling.md` and `docs/adr/004-secrets-pattern-not-module.md`.

Example `config_yaml` (the working composition template lives at `examples/minimal/litellm.yaml.tpl`):

```yaml
model_list:
  - model_name: claude-sonnet-4-5
    litellm_params:
      model: bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0
      aws_region_name: us-east-1
      rpm: 60

litellm_settings:
  drop_params: true
  max_budget: 100.0
  budget_duration: 30d

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

The `rpm` (requests per minute per model) and `max_budget`/`budget_duration` (spend ceiling)
lines are the proxy-level cost controls — set them deliberately for every deployment.
Refer to the [LiteLLM documentation](https://docs.litellm.ai/) for full configuration options.

## Master Key Population (Out-of-Band)

When `master_key_secret_arn = null`, the module creates an empty Secrets Manager secret with the name `${project}-${environment}-gateway-master-key`. The secret's value must be populated separately:

1. **Manual population** (for dev/testing):
   ```bash
   aws secretsmanager put-secret-value \
     --secret-id fedllm-dev-gateway-master-key \
     --secret-string "your-litellm-api-key-here"
   ```

2. **Lambda rotation** (for production): A Lambda function (deployed separately) can periodically rotate the master key by generating new values and updating the secret. Refer to `docs/secrets-handling.md` for the rotation pattern.

The module logs the secret ARN in its outputs; use this to populate the secret after deployment.

## TLS Certificate Configuration

The module supports two modes:

### 1. Existing ACM Certificate (Recommended for Production)

```hcl
module "ecs_gateway" {
  # ...
  certificate_arn            = "arn:aws:acm:us-east-1:123456789012:certificate/12345678-1234-1234-1234-123456789012"
  create_self_signed_cert    = false
}
```

For production federal deployments, use **ACM Private CA** (~$400/month):
- Private CA signs a certificate for your internal ALB domain.
- Private key never leaves AWS; not stored in Terraform state.
- Certificate is automatically rotated by ACM Private CA.
- Suitable for compliance/audit requirements (no plaintext keys in state).

See [AWS ACM Private CA Documentation](https://docs.aws.amazon.com/privateca/latest/userguide/PcaWelcome.html) for setup.

### 2. Self-Signed Certificate (Sandbox Only)

```hcl
module "ecs_gateway" {
  # ...
  certificate_arn            = null
  create_self_signed_cert    = true
}
```

**⚠️ SANDBOX ONLY**: The private key is stored in the Terraform state file. Do NOT use in production or any assessed environment. This mode is suitable for:
- Local development and testing.
- Temporary demo environments.
- CI/CD pipelines that discard state after testing.

## ALB → Task Communication

The Application Load Balancer terminates HTTPS (TLS 1.2/1.3) from external clients. The ALB forwards requests to ECS tasks via plaintext HTTP on the container port (default 4000) inside the VPC.

**Why plaintext HTTP inside the VPC?**

- The hop is confined to the VPC and scoped SG-to-SG: only the ALB security group can reach the service security group, and only on the container port.
- AWS does not expose the ALB→target network path to other tenants; the residual risk is a compromised workload inside the same VPC, which the SG scoping and the no-egress posture mitigate but do not eliminate.
- This is a common pattern for internal load-balanced services; environments that mandate end-to-end encryption should use the steps below.

**How to add end-to-end encryption** (if required):

- Configure LiteLLM to listen on HTTPS internally (requires its own certificate).
- Update the target group protocol from HTTP to HTTPS.
- Ensure the security group rules permit HTTPS (port 443).

## Fargate Spot Capacity (Nonproduction Only)

The module supports ECS Fargate Spot to reduce costs in nonproduction environments:

```hcl
module "ecs_gateway" {
  # ...
  enable_fargate_spot = true
}
```

When enabled:
- Capacity provider strategy includes `FARGATE_SPOT` with weight 4: the first task is always On-Demand (`base = 1`); beyond it, tasks are placed roughly 4 Spot per 1 On-Demand.
- Fargate Spot instances can be interrupted with 2-minute warning; ECS handles graceful shutdown and replacement.
- **Do not use in production** where availability is critical.

## ECS Exec Access (Debugging)

The module includes an optional `enable_execute_command` flag:

```hcl
module "ecs_gateway" {
  # ...
  enable_execute_command = true
}
```

When enabled, operators can open an interactive shell into running tasks:

```bash
aws ecs execute-command \
  --cluster fedllm-dev-gateway \
  --task <task-id> \
  --container gateway \
  --interactive \
  --command "/bin/sh"
```

⚠️ **Audit implications**: ECS Exec opens a session manager channel into the task, which is logged to CloudTrail and (optionally) to S3. Enable only in development environments, never in assessed/audited deployments.

⚠️ **Incompatible with this module's hardening as shipped**: the SSM agent that powers ECS Exec needs a writable filesystem, which `readonlyRootFilesystem = true` denies. Exec sessions into the hardened gateway task will fail even with the flag enabled — use a separate one-off debug task instead (see `docs/verification/gateway-proof.md` for the pattern).

## Deletion Protection & Destroy

The ALB has `enable_deletion_protection = true` by default, preventing accidental deletion. To destroy the module:

1. Set `enable_deletion_protection = false` and apply:
   ```hcl
   module "ecs_gateway" {
     # ...
     enable_deletion_protection = false
   }
   ```
   Then `terraform apply`.

2. Run `terraform destroy`.

## Scaling Configuration

Deployment percentages are fixed by the module at `deployment_minimum_healthy_percent = 100`
and `deployment_maximum_percent = 200`: the old task keeps serving until its replacement
passes health checks, and rollouts may temporarily double the task count. These values are
correct for both the single-task demo and multi-task production — with N tasks, ECS replaces
them in waves without ever dropping below N healthy.

### Demo/Single-Task Mode (default)

```hcl
module "ecs_gateway" {
  desired_count = 1
  min_capacity  = 1
  max_capacity  = 3
}
```

- Starts with 1 task; scales up to 3 under load (request count or CPU).
- During a rollout there are briefly 2 tasks (old + new).

### Production Multi-Task Mode (recommended)

For production, run multiple tasks across availability zones:

```hcl
module "ecs_gateway" {
  desired_count = 2
  min_capacity  = 2
  max_capacity  = 6
}
```

- Starts with 2 tasks; with ≥ 2 private subnets ECS spreads them across AZs.
- Scales up to 6 tasks under sustained load; never drops below 2 healthy during rollouts.

### Scale-In Cooldown

Both configurations use `scale_in_cooldown = 300` seconds (5 minutes) for target-tracking autoscaling:
- Prevents rapid scale-down thrashing when request load decreases temporarily.
- Conservative approach; adjust to 60–180 seconds if faster scale-in is needed.

## CloudWatch Alarms

The module creates three baseline alarms (week 6 adds full observability):

1. **Unhealthy Hosts**: Triggers if any target in the ALB target group becomes unhealthy for 5 consecutive minutes.
2. **Target 5xx Errors**: Triggers if targets return ≥ 10 HTTP 5xx responses in a 5-minute window.
3. **Running Task Count**: Triggers if running task count falls below `min_capacity` for 3 consecutive minutes (indicates restart churn or crash loop).

All alarms are created but only wired to an SNS topic if `alarm_topic_arn` is provided. Use the `observability` module (week 6) to create the SNS topic.

## Container Hardening

The ECS task definition is hardened per federal compliance requirements:

- **Non-root user**: Container runs as UID `1000` by default (configurable via `container_user`; must not be root or UID 0).
- **Read-only root filesystem**: The root filesystem is read-only; `/tmp` is writable via an ephemeral volume.
- **Digest-pinned image**: Container image must be specified with a `@sha256:` digest hash, ensuring reproducible deployments.
- **No privileged mode**: The `privileged` flag is not set (and Fargate would reject it anyway).
- **Health checks**: Liveness probe checks `/health/liveliness` endpoint every 30 seconds.

The startup command uses `printf` (not `echo`) to preserve YAML escapes in the config file, and uses `exec` to ensure LiteLLM (PID 1) receives OS signals for graceful shutdown.

---

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9.0, < 2.0.0 |
| aws | ~> 6.0 |
| tls | ~> 4.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.0 |
| tls | ~> 4.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_acm_certificate.self_signed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate) | resource |
| [aws_appautoscaling_policy.cpu_scaling](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_policy.request_count_scaling](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_target.ecs_service](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_target) | resource |
| [aws_cloudwatch_log_group.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_metric_alarm.running_task_count](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.target_5xx](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.unhealthy_hosts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_ecs_cluster.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster) | resource |
| [aws_ecs_cluster_capacity_providers.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster_capacity_providers) | resource |
| [aws_ecs_service.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service) | resource |
| [aws_ecs_task_definition.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition) | resource |
| [aws_lb.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb) | resource |
| [aws_lb_listener.https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_listener) | resource |
| [aws_lb_target_group.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group) | resource |
| [aws_secretsmanager_secret.master_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_security_group.alb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.service](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_ssm_parameter.litellm_config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_vpc_security_group_egress_rule.alb_to_service](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.alb_https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.service_from_alb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [tls_private_key.self_signed](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [tls_self_signed_cert.self_signed](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/self_signed_cert) | resource |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| alb\_logs\_bucket\_id | S3 bucket ID for ALB access logs (must be created externally; module never creates the bucket) | `string` | n/a | yes |
| app\_security\_group\_id | Security group ID for application workloads (from network module); attached to ECS tasks alongside module-created service SG | `string` | n/a | yes |
| app\_task\_role\_arn | ARN of the ECS app task role (from iam module); grants Bedrock, Secrets Manager, and database access | `string` | n/a | yes |
| config\_yaml | LiteLLM proxy config YAML stored in SSM Parameter Store. Must not contain secret values (e.g., API keys); the master key is injected separately from Secrets Manager. | `string` | n/a | yes |
| container\_image | Digest-pinned container image for LiteLLM (e.g., 'ghcr.io/berriai/litellm@sha256:abc123...'). Must contain '@sha256:' to enforce reproducible deployments. | `string` | n/a | yes |
| environment | Deployment environment (dev, staging, prod) | `string` | n/a | yes |
| logs\_kms\_key\_arn | ARN of the KMS CMK for encrypting CloudWatch Logs (from kms module, logs domain) | `string` | n/a | yes |
| private\_subnet\_ids | List of private subnet IDs for ECS tasks and ALB placement; must span at least 2 AZs | `list(string)` | n/a | yes |
| project | Project name used in resource naming and tags | `string` | n/a | yes |
| secrets\_kms\_key\_arn | ARN of the KMS CMK for encrypting Secrets Manager and SSM Parameter Store (from kms module, secrets domain) | `string` | n/a | yes |
| task\_execution\_role\_arn | ARN of the ECS task execution role (from iam module); grants ECR pull and CloudWatch logs write | `string` | n/a | yes |
| vpc\_cidr | VPC CIDR block; used to configure ALB ingress rules for internal clients | `string` | n/a | yes |
| vpc\_id | VPC ID in which to launch the ECS service (from network module) | `string` | n/a | yes |
| alarm\_topic\_arn | SNS topic ARN for CloudWatch alarm notifications. When null, alarms are created but not wired to any topic. | `string` | `null` | no |
| certificate\_arn | ARN of an existing ACM certificate for ALB HTTPS listener. Exactly one of certificate\_arn or create\_self\_signed\_cert must be set. Default null (use create\_self\_signed\_cert). | `string` | `null` | no |
| container\_port | Port on which the container listens (default 4000, typical for LiteLLM) | `number` | `4000` | no |
| container\_user | Non-root user ID for container execution (default 1000); must not be '0' or 'root' | `string` | `"1000"` | no |
| cpu\_target\_value | Target CPU utilization percentage for autoscaling (default 60) | `number` | `60` | no |
| create\_self\_signed\_cert | Create a self-signed certificate for HTTPS (sandbox only; private key stored in Terraform state). Exactly one of certificate\_arn or create\_self\_signed\_cert must be set. | `bool` | `false` | no |
| data\_classification | Data classification level: public, internal, or cui | `string` | `"cui"` | no |
| desired\_count | Initial desired number of ECS tasks; autoscaling ignores this after deployment (lifecycle ignore\_changes) | `number` | `1` | no |
| enable\_deletion\_protection | Enable deletion protection on the ALB (prevents accidental destroy; set false then apply before destroying) | `bool` | `true` | no |
| enable\_execute\_command | Enable ECS Exec for interactive task debugging. WARNING: Opens an interactive shell channel into tasks — has AU/audit implications. Leave false in assessed environments. | `bool` | `false` | no |
| enable\_fargate\_spot | Enable ECS Fargate Spot capacity provider (cost optimization; nonprod only) | `bool` | `false` | no |
| log\_retention\_days | CloudWatch Logs retention period in days (must be a valid CloudWatch retention value) | `number` | `90` | no |
| master\_key\_secret\_arn | ARN of existing Secrets Manager secret holding the LiteLLM master key. When null, the module creates an empty secret shell (value populated out-of-band per docs/secrets-handling.md). | `string` | `null` | no |
| max\_capacity | Maximum number of ECS tasks for autoscaling (default 3) | `number` | `3` | no |
| min\_capacity | Minimum number of ECS tasks for autoscaling (default 1 for demo; prod should be 2+) | `number` | `1` | no |
| request\_count\_target | Target request count per ECS task for autoscaling (default 100) | `number` | `100` | no |
| tags | Additional tags applied to all taggable resources | `map(string)` | `{}` | no |
| task\_cpu | ECS Fargate task CPU units (256, 512, 1024, 2048, 4096; default 1024) | `number` | `1024` | no |
| task\_memory | ECS Fargate task memory in MB (512, 1024, 2048, 3072, 4096, etc.; default 2048) | `number` | `2048` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| alb\_arn | ARN of the Application Load Balancer |
| alb\_dns\_name | Internal ALB DNS name (for in-VPC client requests) |
| alb\_security\_group\_id | Security group ID for the ALB |
| cluster\_arn | ARN of the ECS cluster |
| config\_parameter\_arn | ARN of the SSM Parameter Store SecureString holding the LiteLLM config YAML |
| gateway\_url | Gateway HTTPS URL (constructed from ALB DNS name) |
| log\_group\_arn | CloudWatch log group ARN for gateway container logs |
| log\_group\_name | CloudWatch log group name for gateway container logs |
| master\_key\_secret\_arn | ARN of the Secrets Manager secret holding the LiteLLM master key (either provided or created by module) |
| service\_name | Name of the ECS service |
<!-- END_TF_DOCS -->
