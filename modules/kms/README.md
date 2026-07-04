# KMS

Implements customer-managed KMS keys partitioned by data domain—data, logs, and secrets—with automatic rotation enabled, split key-admin and key-user IAM policies for least-privilege access control, and service-integration grants that enable other modules to use keys without managing inline policies. Outputs are shaped for seamless consumption by every other module in the stack.

**Status:** skeleton — implementation scheduled in [week-03](../../docs/plan/week-03.md).

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
