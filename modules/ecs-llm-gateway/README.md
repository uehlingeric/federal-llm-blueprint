# ECS LLM Gateway

Deploys a hardened ECS Fargate service running LiteLLM, an LLM gateway that routes requests to Bedrock through VPC endpoints. The service runs with non-root user, read-only root filesystem, digest-pinned container images, and automatic scaling based on request latency. All logs are encrypted with the logs CMK; service integrates with Application Load Balancer for internal routing and observability.

**Status:** skeleton — implementation scheduled in [week-04](../../docs/plan/week-04.md).

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
