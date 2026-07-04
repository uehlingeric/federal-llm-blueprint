# Vector Store

Provisions a managed RDS PostgreSQL instance with pgvector extension enabled for embeddings storage. The database is encrypted with the data domain KMS key, deployed into private subnets only, enforces IAM database authentication, requires TLS for all connections, and maintains automated backups with point-in-time recovery. Outputs include connection endpoints and credentials for RAG workload consumption.

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
