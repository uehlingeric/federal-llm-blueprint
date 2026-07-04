# Observability

Implements a log-group factory that ensures all CloudWatch Log Groups are encrypted with the logs KMS key and configured with mandatory retention policies. Establishes a baseline alarm suite for latency, error rates, and resource utilization; creates KMS-encrypted SNS topics for alarm notifications; and provides a CloudWatch dashboard for real-time visibility into LLM gateway and data pipeline health. Outputs export log groups, topics, and dashboard ARNs.

**Status:** skeleton — implementation scheduled in [week-06](../../docs/plan/week-06.md).

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
