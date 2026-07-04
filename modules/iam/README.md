# IAM

Defines least-privilege IAM roles across three execution tiers—ECS task execution role, ECS task application role, and CI/CD deployment role—and three human role tiers for platform administrators, auditors, and developers. All roles are constrained by a permission boundary that encodes this blueprint's security baseline; roles contain no wildcard actions and each permission is explicitly granted. Outputs export roles and policies by service for consumption by infrastructure modules.

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
