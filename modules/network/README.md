# Network

Establishes a VPC with private-subnet architecture and VPC interface/gateway endpoints providing endpoint-only connectivity to the full LLM stack—Bedrock, S3, ECR, KMS, CloudWatch Logs, Secrets Manager, ECS, and STS. The module enforces a provable no-egress mode with zero IGW or NAT gateway, routes all service traffic through secured VPC endpoints, encrypts flow logs with KMS, and exports baseline security groups for consumption by other modules.

**Status:** skeleton — implementation scheduled in [week-02](../../docs/plan/week-02.md).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9.0, < 2.0.0 |
| aws | ~> 6.0 |

## Providers

No providers.

## Modules

No modules.

## Resources

No resources.

## Inputs

No inputs.

## Outputs

No outputs.
<!-- END_TF_DOCS -->
