# Document Store

Implements an S3 document store with full compliance posture: three buckets (documents, access-logs, alb-logs) with versioning, server-side encryption, public-access block enforcement, TLS-only bucket policies, lifecycle rules, optional object lock for immutability, and access logging. Designed for federal-grade data custody and audit.

## Architecture

The module deploys three S3 buckets with distinct responsibilities:

- **documents bucket:** Customer-managed KMS encryption (SSE-KMS with CMK), versioning, server-access logging into the access-logs bucket, lifecycle rules (STANDARD → STANDARD_IA transition, noncurrent version expiration), optional object lock, optional inventory and storage-class analysis. This is the primary data plane for ingested documents and vectorized embeddings.

- **access-logs bucket:** Receives server-access logs from the documents bucket (and log-delivery service writes to this bucket itself). SSE-S3 (AES256) encryption—S3 server-access-log delivery does NOT support SSE-KMS targets (AWS platform constraint). Versioning enabled; lifecycle expiration for cost management; no logging of its own (logs-of-logs termination reasoning: audit trail delegated to CloudTrail data events, see week-6 audit module).

- **alb-logs bucket:** Receives ALB/ELB access logs via the ELB service account principal. SSE-S3 encryption (ELB log delivery rejects SSE-KMS). Versioning, lifecycle, and public-access block. No logging of itself; audit via CloudTrail data events.

All three buckets:
- Enforce public-access block (all four settings true)
- Require TLS-only transport (bucket policy deny s3:* when aws:SecureTransport = false)
- Are tagged with Project, Environment, ManagedBy, and DataClassification

## Data Classification Guidance

### For CUI (Controlled Unclassified Information) / Federal Compliance

The documents bucket is configured for CUI protection:

1. **SSE-KMS with data CMK:** All objects at rest encrypted with a customer-managed KMS key (aws:kms encryption with bucket_key_enabled = true for performance).
2. **TLS-Only Transport:** Bucket policy denies any s3:* operation over unencrypted HTTP.
3. **Public Access Blocked:** All public ACLs, public bucket policies, and public-ACL enforcement are blocked.
4. **Versioning:** Enabled to recover from accidental deletion or overwrites; lifecycle rules expire old versions after 180 days (configurable).
5. **Access Logging:** Comprehensive server-access logs written to the separate access-logs bucket with "documents/" prefix, recording all GET/PUT/DELETE operations for audit trails.
6. **Lifecycle:** Automatic transition to STANDARD_IA after 90 days (configurable) to reduce storage cost while maintaining retrieval SLA; incomplete multipart uploads are aborted after 7 days.
7. **Object Lock (Optional):** For SEC 17a-4 or FINRA 4511 style immutability requirements, enable `enable_object_lock = true` at module creation. Defaults to GOVERNANCE mode (bypassable with s3:BypassGovernanceRetention); switch to COMPLIANCE mode for unbypassable retention even by root.

When `data_classification = "cui"`, this configuration aligns to NIST 800-53 controls for document storage: SC-8 (transmission confidentiality via TLS-only policy), SC-28 (encryption at rest via SSE-KMS), AU-2/AU-12 (audit logging via server-access logs), and AC-3 (access enforcement via bucket policy + IAM). Control mapping with evidence status lands in week 7; no FedRAMP compliance is claimed.

### For public/internal data

Set `data_classification = "public"` or `"internal"` and adjust encryption/logging as policy allows. The module still enforces TLS-only transport and public-access block regardless of classification.

## Object Lock: Irreversibility Warning

**Object lock can ONLY be enabled at bucket creation time. Once created without object lock, the bucket cannot be retrofitted; changing `enable_object_lock` from false → true forces bucket replacement (destroy + recreate), losing all data.**

### When to Use Object Lock

1. **Compliance-Mode Immutability (Most Restrictive):**
   - Set `object_lock_mode = "COMPLIANCE"` and `object_lock_retention_days = N`
   - Objects cannot be deleted or modified for N days, **even by root / IAM admin**
   - Cannot reduce retention period after object upload
   - Suitable for SEC Rule 17a-4(f), FINRA 4511, or HIPAA compliance: financial records, healthcare documents, or regulatory retention
   - Once enabled, there is no escape hatch — retention period must expire to delete

2. **Governance-Mode Immutability (Recommended Default):**
   - Set `object_lock_mode = "GOVERNANCE"` and `object_lock_retention_days = N`
   - Objects cannot be deleted during retention period **unless** caller has s3:BypassGovernanceRetention permission
   - Allows administrators with explicit permission to override (for cleanup, disaster recovery)
   - Suitable for development, testing, and production systems where administrative recovery is needed
   - Default mode; use this unless you have a specific regulatory mandate for unbypassable retention

### Planning Object Lock Strategy

- **Development/staging:** Leave `enable_object_lock = false` (default). Use bucket versioning + lifecycle rules for data retention without immutability constraints.
- **Production with regulatory retention:** Enable object lock with GOVERNANCE mode (default). Grant s3:BypassGovernanceRetention only to disaster-recovery or audit roles, not daily operators.
- **Highly regulated production (financial/healthcare):** Enable with COMPLIANCE mode only if mandated by compliance framework (e.g., SEC, FINRA, HIPAA). Acceptance of unbypassable retention must be deliberate and documented in the infrastructure-as-code change control.

## Logs-of-Logs Termination

The access-logs and alb-logs buckets do NOT log to another bucket (no infinite recursion). Instead:
- **Audit of access-logs and alb-logs buckets** is provided by CloudTrail data events (enabled week-6 in the audit module) with full API call history, IAM principal identification, and cryptographic log-file validation.
- The access-logs bucket itself stores S3 server-access logs in standard format; these are sufficient for debugging access patterns and compliance audits without secondary logging.
- This is the standard logs-of-logs termination pattern: finite regress requires delegation to a higher-level service (CloudTrail > S3 logs).

## Replication & Event Notifications

By design, this is a **single-region reference architecture**. Cross-region replication is a deployment decision, not a default:
- If Terraform checks flag CKV_AWS_144 (no replication), the module inlines a skip with justification: "Single-region reference architecture; replication is a deployment decision documented in deployment guide."
- If checks flag CKV2_AWS_62 (no event notifications), similar justification: "No bucket event notification consumers; audit trail provided by CloudTrail data events (week-6)."

To enable replication or notifications, define those resources in your root module or deployment-specific overlay.

## Cost Optimization Notes

1. **Storage Classes:** Default configuration uses STANDARD for recent documents (high access) and STANDARD_IA after 90 days (cheaper for archives). Adjust `documents_ia_transition_days` based on retrieval patterns.
2. **Inventory:** Optional weekly CSV inventory aids cost analysis and compliance audits. Enable `enable_inventory = true` if you need visibility into bucket contents for S3 Storage Lens or manual analysis.
3. **Analytics:** Optional storage-class analysis (enable `enable_analytics = true`) helps identify which objects would benefit from different storage classes.
4. **Lifecycle:** Noncurrent version expiration (default 180 days) limits storage bloat; adjust `noncurrent_version_expiration_days` based on disaster-recovery and audit retention requirements.
5. **Multipart Cleanup:** Incomplete multipart uploads are automatically aborted after `abort_incomplete_multipart_days` (default 7) to prevent orphaned uploads from consuming quota.

## Outputs

- `bucket_ids`: Map of bucket IDs keyed by type (documents, access-logs, alb-logs)
- `bucket_arns`: Map of bucket ARNs keyed by type
- `documents_bucket_regional_domain_name`: Regional domain name of the documents bucket for in-VPC API calls

## Inputs

All standard module inputs (project, environment, data_classification, tags) plus:

- `data_kms_key_arn`: ARN of the data KMS CMK (required)
- `enable_object_lock`: Enable immutable object lock (irreversible; default false)
- `object_lock_mode`: GOVERNANCE (default, bypassable) or COMPLIANCE (unbypassable)
- `object_lock_retention_days`: Retention period when lock enabled (default 30)
- `documents_ia_transition_days`: Days before STANDARD → STANDARD_IA (default 90)
- `noncurrent_version_expiration_days`: Days before noncurrent versions expire (default 180)
- `log_expiration_days`: Days before logs expire (default 90)
- `abort_incomplete_multipart_days`: Days before aborting incomplete uploads (default 7)
- `alb_logs_prefix`: S3 prefix for ALB logs (default "alb")
- `enable_inventory`: Enable weekly inventory CSV (default false)
- `enable_analytics`: Enable storage-class analysis (default false)

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
| [aws_s3_bucket.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket.alb_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket.documents](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_analytics_configuration.documents](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_analytics_configuration) | resource |
| [aws_s3_bucket_inventory.documents](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_inventory) | resource |
| [aws_s3_bucket_lifecycle_configuration.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.alb_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.documents](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_logging.documents](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_logging) | resource |
| [aws_s3_bucket_object_lock_configuration.documents](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_object_lock_configuration) | resource |
| [aws_s3_bucket_policy.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_policy.alb_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_policy.documents](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_public_access_block.alb_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_public_access_block.documents](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.alb_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.documents](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_s3_bucket_versioning.alb_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_s3_bucket_versioning.documents](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_elb_service_account.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/elb_service_account) | data source |
| [aws_iam_policy_document.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.alb_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.documents](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| data\_kms\_key\_arn | ARN of the KMS CMK for encrypting documents bucket (from kms module, data domain) | `string` | n/a | yes |
| environment | Deployment environment (dev, staging, prod) | `string` | n/a | yes |
| project | Project name used in resource naming and tags | `string` | n/a | yes |
| abort\_incomplete\_multipart\_days | Number of days before aborting incomplete multipart uploads. Default 7 limits storage waste from failed uploads. | `number` | `7` | no |
| alb\_logs\_prefix | S3 prefix under which ELB/ALB writes access logs. Default 'alb'. Used to construct the bucket policy resource pattern for ELB log delivery. | `string` | `"alb"` | no |
| data\_classification | Data classification level: public, internal, or cui | `string` | `"cui"` | no |
| documents\_ia\_transition\_days | Number of days before transitioning documents from STANDARD to STANDARD\_IA storage class. Default 90 balances cost optimization against retrieval frequency. | `number` | `90` | no |
| enable\_analytics | Enable storage-class analysis on documents bucket. Generates daily analytics report (sample rate configurable by AWS). Useful for cost optimization. Default false. | `bool` | `false` | no |
| enable\_inventory | Enable weekly CSV inventory of documents bucket contents. Inventory is written to access-logs bucket under 'inventory/' prefix. Useful for compliance audits and storage cost analysis. Default false. | `bool` | `false` | no |
| enable\_object\_lock | IRREVERSIBLE: Enable object lock on documents bucket. CRITICAL: Can only be enabled at bucket creation; changing this after creation forces bucket replacement. Object lock prevents object deletion/overwrite for a retention period. Choose GOVERNANCE for bypassable retention or COMPLIANCE for unbypassable retention (even by root). Use only for regulatory retention requirements like SEC 17a-4. Default GOVERNANCE is safe for development; COMPLIANCE should be deliberate for production retention policies. | `bool` | `false` | no |
| log\_expiration\_days | Number of days before expiring logs in access-logs and alb-logs buckets. Default 90. | `number` | `90` | no |
| noncurrent\_version\_expiration\_days | Number of days before expiring noncurrent document versions. Default 180 supports compliance retention and accidental-deletion recovery. | `number` | `180` | no |
| object\_lock\_mode | Object lock retention mode: GOVERNANCE (bypassable with s3:BypassGovernanceRetention) or COMPLIANCE (unbypassable). GOVERNANCE is the safe default for most use cases; COMPLIANCE is unbypassable even by root until retention expires. | `string` | `"GOVERNANCE"` | no |
| object\_lock\_retention\_days | Number of days to retain objects when object lock is enabled. Minimum 1 day. | `number` | `30` | no |
| tags | Additional tags applied to all taggable resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| bucket\_arns | S3 bucket ARNs keyed by bucket type (documents, access-logs, alb-logs) |
| bucket\_ids | S3 bucket IDs keyed by bucket type (documents, access-logs, alb-logs) |
| documents\_bucket\_regional\_domain\_name | Regional domain name of the documents bucket; useful for in-VPC S3 API calls and data ingestion pipelines |
<!-- END_TF_DOCS -->
