# Network

## Overview

The network module establishes the foundational VPC infrastructure for the federal LLM blueprint. It deploys a private-subnet-only VPC across 2–3 availability zones with endpoint-based connectivity to AWS services required by the LLM stack: Bedrock (runtime and agent), S3, ECR, CloudWatch Logs, KMS, Secrets Manager, ECS, SSM Parameter Store, and STS.

The module enforces a **provably no-egress mode** when `no_egress = true`: zero Internet Gateways, zero NAT Gateways, zero Elastic IPs, and zero public subnets. All AWS service traffic routes through secured VPC endpoints with private DNS resolution enabled. In this mode, the architecture is air-gap-ready and suitable for federal and GovCloud deployments. A supporting test suite verifies that these resources are absent (not merely "unused").

The module also supports a standard-private mode (`no_egress = false`) for corporate deployments with optional public subnets and NAT gateways. In both modes, VPC endpoints are the primary path to AWS services; the mode difference is purely the availability of internet egress.

## Responsibilities

- **VPC Creation**: Private-subnet architecture across configurable AZs (2 or 3)
- **Conditional Internet Gateway**: Present only in standard mode with public subnets enabled
- **Conditional NAT Gateway**: Present only in standard mode with both public subnets and NAT enabled; single NAT is the default (per-AZ NAT is an alternative documented in the module)
- **Interface VPC Endpoints**: Bedrock, S3, ECR, KMS, CloudWatch Logs, Secrets Manager, ECS, ECS-telemetry, SSM, STS, plus user-extensible map for services like SageMaker Runtime
- **Gateway VPC Endpoints**: S3 (always) and DynamoDB (optional)
- **Endpoint Security Group**: Restricts HTTPS (443) ingress from the VPC CIDR only
- **Application Security Group**: Provides baseline egress rules for compute workloads — 443 to endpoints and S3 gateway, 5432 to vector store
- **VPC Flow Logs**: CloudWatch Logs destination, KMS-encrypted (mandatory; key provided by caller), retention configurable
- **Exports**: VPC ID, subnet IDs, security group IDs, endpoint IDs (keyed by service), flow log group name

## Usage

### No-Egress Mode (Recommended for Federal/GovCloud)

```hcl
module "network" {
  source = "../../modules/network"

  project               = "fedllm"
  environment           = "prod"
  data_classification   = "cui"
  
  no_egress             = true
  enable_public_subnets = false
  enable_nat_gateway    = false
  
  flow_log_kms_key_arn  = module.kms.key_arns["logs"]  # From week 3
  
  # Optional customizations
  vpc_cidr              = "10.0.0.0/16"
  az_count              = 3
  enable_flow_logs      = true
  flow_log_retention_days = 90
  
  tags = {
    Owner = "platform-team"
  }
}
```

### Standard Mode (Optional Public Subnets + NAT)

```hcl
module "network" {
  source = "../../modules/network"

  project               = "fedllm"
  environment           = "staging"
  data_classification   = "internal"
  
  no_egress             = false
  enable_public_subnets = true
  enable_nat_gateway    = true  # Requires enable_public_subnets = true
  
  flow_log_kms_key_arn  = module.kms.key_arns["logs"]
  
  tags = {
    Owner = "platform-team"
  }
}
```

## VPC Endpoints Reference

This table enumerates the interface endpoints provided by default and their purpose in the LLM stack.

| Logical Key | AWS Service | Endpoint Type | Why the LLM Stack Needs It |
|---|---|---|---|
| `bedrock-runtime` | Bedrock Runtime | Interface | Invoke Bedrock models for inference |
| `bedrock-agent-runtime` | Bedrock Agent | Interface | Invoke Bedrock agents for agentic workflows |
| `ecr-api` | ECR API | Interface | Resolve ECR registry DNS (docker pull metadata) |
| `ecr-dkr` | ECR Docker | Interface | Pull container images (docker pull) |
| `logs` | CloudWatch Logs | Interface | Stream application logs from ECS tasks and flow logs |
| `kms` | AWS KMS | Interface | Decrypt data-encryption and log-encryption keys |
| `secretsmanager` | Secrets Manager | Interface | Retrieve gateway API keys and database credentials |
| `ecs` | ECS Service Discovery | Interface | Discover tasks and retrieve task metadata |
| `ecs-telemetry` | ECS Telemetry | Interface | Report container metrics to CloudWatch |
| `ssm` | SSM Parameter Store | Interface | Fetch task configuration injected via ECS secrets (ADR-005) |
| `sts` | STS (AssumeRole) | Interface | Assume IAM roles during task startup |
| `s3` | Amazon S3 | Gateway | Read/write documents and access logs |
| `dynamodb` | DynamoDB | Gateway | (Optional) Session caching or application state |

**Extensibility**: Consumers can add entries to `var.interface_endpoints` without forking the module. For example, to add SageMaker Runtime embeddings:

```hcl
interface_endpoints = {
  ...existing entries...
  "sagemaker-runtime" = "sagemaker.runtime"
}
```

The service name composes automatically as `com.amazonaws.{region}.{suffix}`.

## GovCloud Considerations

The module is designed to work across AWS partitions (standard, GovCloud, China). Keep the following in mind:

- **Partition-Safe ARNs**: The module uses `data.aws_partition.current.partition` and `data.aws_caller_identity.current.account_id` to construct ARNs; no hardcoded ARNs appear in the code.
- **Bedrock Availability Varies**: Bedrock endpoints are **not** available in all regions. In standard AWS:
  - `bedrock-runtime` is available in `us-east-1`, `us-west-2`, `eu-west-1`, etc.
  - `bedrock-agent-runtime` is available in a smaller set of regions.
  
  In GovCloud (`us-gov-west-1`), check the [AWS documentation](https://docs.aws.amazon.com/bedrock/latest/userguide/what-is-bedrock.html) for current service availability before deploying. If Bedrock is unavailable in your region, remove it from `var.interface_endpoints`.
  
- **Regional Service Name Differences**: Some AWS services have different names in GovCloud (e.g., service suffixes may differ). The module composes service names from `var.interface_endpoints` suffixes; ensure the suffix is correct for your partition.

## Cost Notes

The primary cost drivers in this module are:

- **Interface VPC Endpoints**: ~$7–8/month each **per AZ** ($0.01/endpoint-hour/AZ). The default 11 endpoints across 2 AZs cost ~$160/month; 3 AZs, ~$240/month. To reduce cost during development, disable unused endpoints:
  ```hcl
  interface_endpoints = {
    "bedrock-runtime" = "bedrock-runtime"
    "ecr-api"         = "ecr.api"
    "ecr-dkr"         = "ecr.dkr"
    "logs"            = "logs"
    "kms"             = "kms"
  }
  ```

- **Gateway VPC Endpoints**: ~$0/month (no charge for S3 and DynamoDB gateway endpoints)
- **VPC Flow Logs**: Cost depends on traffic volume; typically <$1/month for modest workloads; enable in production, disable in sandboxes to save
- **KMS Key**: ~$1/month (provided by `modules/kms` in week 3)

## Known Issues & Gotchas

### VPC Endpoint ENI Cleanup During Destroy

Interface VPC endpoints create elastic network interfaces (ENIs) that can take 30+ seconds to fully detach and delete when the endpoint is destroyed. During `terraform destroy`, if the process times out or hangs, manually verify and delete the ENIs:

```bash
# Find dangling ENIs with description containing your endpoint names
aws ec2 describe-network-interfaces \
  --filters Name=description,Values="*fedllm*endpoint*" \
  --query 'NetworkInterfaces[?Status!=`in-use`].NetworkInterfaceId' \
  --region us-east-1

# Force-detach if needed
aws ec2 detach-network-interface --attachment-id <attachment-id> --region us-east-1
aws ec2 delete-network-interface --network-interface-id <eni-id> --region us-east-1
```

### Single NAT Gateway Design

This module deploys **one NAT Gateway** (in the first public subnet) when NAT is enabled. This is the demo/sandbox posture and presents a single point of failure. For production high-availability, implement per-AZ NAT gateways by modifying the module to:

```hcl
resource "aws_nat_gateway" "main" {
  for_each      = var.enable_nat_gateway ? toset(local.azs) : toset([])
  allocation_id = aws_eip.nat[each.value].id
  subnet_id     = aws_subnet.public[each.value].id
  # ... rest of configuration
}
```

Then add one EIP per AZ. This increases cost (~$30/month per additional NAT) but eliminates the single point of failure.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9.0, < 2.0.0 |
| aws | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_log_group.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_default_security_group.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/default_security_group) | resource |
| [aws_eip.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip) | resource |
| [aws_flow_log.vpc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/flow_log) | resource |
| [aws_iam_role.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_internet_gateway.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/internet_gateway) | resource |
| [aws_nat_gateway.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/nat_gateway) | resource |
| [aws_route.private_nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route.public_igw](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route_table.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_security_group.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.endpoint](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_subnet.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_vpc.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc) | resource |
| [aws_vpc_endpoint.dynamodb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_endpoint.interface](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_endpoint.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_security_group_egress_rule.app_to_endpoints](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.app_to_s3_gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.app_to_vector_store](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.endpoint_https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.flow_logs_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.flow_logs_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.s3_endpoint](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| environment | Deployment environment (dev, staging, prod) | `string` | n/a | yes |
| flow\_log\_kms\_key\_arn | ARN of a KMS customer-managed key (CMK) for encrypting VPC Flow Logs. Required when enable\_flow\_logs = true. Obtain from modules/kms in week 3, or provide any CMK ARN. | `string` | n/a | yes |
| project | Project name used in resource naming and tags | `string` | n/a | yes |
| az\_count | Number of availability zones to span (2 or 3) | `number` | `2` | no |
| data\_classification | Data classification level for the VPC: public, internal, or cui | `string` | `"cui"` | no |
| enable\_dynamodb\_gateway\_endpoint | Enable DynamoDB gateway endpoint. If true, a gateway endpoint is created and associated with all private route tables. | `bool` | `false` | no |
| enable\_flow\_logs | Enable VPC Flow Logs to CloudWatch Logs with KMS encryption | `bool` | `true` | no |
| enable\_nat\_gateway | Enable NAT gateway for private-to-internet routing. Requires enable\_public\_subnets = true and no\_egress = false. | `bool` | `false` | no |
| enable\_public\_subnets | Enable public subnets. Forbidden when no\_egress = true. | `bool` | `false` | no |
| flow\_log\_retention\_days | CloudWatch Logs retention period for VPC flow logs (days) | `number` | `90` | no |
| interface\_endpoints | Interface VPC endpoints to create, keyed by logical name to AWS service suffix (e.g., 'bedrock-runtime' -> 'bedrock-runtime'). Service name is com.amazonaws.{region}.{suffix}. Consumers can add entries (e.g., sagemaker.runtime) without forking the module. | `map(string)` | <pre>{<br/>  "bedrock-agent-runtime": "bedrock-agent-runtime",<br/>  "bedrock-runtime": "bedrock-runtime",<br/>  "ecr-api": "ecr.api",<br/>  "ecr-dkr": "ecr.dkr",<br/>  "ecs": "ecs",<br/>  "ecs-telemetry": "ecs-telemetry",<br/>  "kms": "kms",<br/>  "logs": "logs",<br/>  "secretsmanager": "secretsmanager",<br/>  "ssm": "ssm",<br/>  "sts": "sts"<br/>}</pre> | no |
| no\_egress | Enable no-egress mode: zero IGW/NAT, endpoint-only connectivity. When true, public subnets and NAT gateways are disabled. | `bool` | `false` | no |
| tags | Additional tags applied to all taggable resources | `map(string)` | `{}` | no |
| vpc\_cidr | CIDR block for the VPC (default 10.0.0.0/16) | `string` | `"10.0.0.0/16"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| app\_security\_group\_id | Security group ID for ECS tasks and application workloads. Attached to compute resources in other modules. |
| endpoint\_security\_group\_id | Security group ID for VPC endpoints. Allows HTTPS from the VPC CIDR. |
| flow\_log\_group\_name | CloudWatch Logs group name for VPC flow logs. Null if flow logs are disabled. |
| gateway\_endpoint\_ids | Map of gateway VPC endpoint IDs keyed by service (s3 always present; dynamodb only if enabled) |
| interface\_endpoint\_ids | Map of interface VPC endpoint IDs keyed by service name (e.g., bedrock-runtime, ecr-api, logs, kms, secretsmanager, ecs, sts) |
| private\_route\_table\_ids | List of private route table IDs (one per availability zone) |
| private\_subnet\_ids | List of private subnet IDs across all availability zones |
| public\_subnet\_ids | List of public subnet IDs (empty in no-egress mode) |
| vpc\_cidr\_block | VPC CIDR block (e.g., 10.0.0.0/16) |
| vpc\_id | VPC resource ID |
<!-- END_TF_DOCS -->
