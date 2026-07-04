# Document Store

Implements a suite of S3 buckets—one for documents, one for ALB access logs, one for S3 access logs—configured with versioning, server-side encryption via the data KMS key, access logging, public-access block enforcement, TLS-only bucket policies, lifecycle rules for cost optimization, and optional object lock for immutability. Outputs export bucket names and ARNs for integration with document ingestion and audit pipelines.

**Status:** skeleton — implementation scheduled in [week-05](../../docs/plan/week-05.md).

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
