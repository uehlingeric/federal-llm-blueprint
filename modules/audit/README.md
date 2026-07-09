# Audit

Deploys CloudTrail and AWS Config for comprehensive audit logging, forensic analysis, and compliance validation across the stack.

## Overview

This module provisions:

- **CloudTrail**: Multi-region API call logging with mandatory log-file validation, KMS encryption, and data events on the documents bucket (S3 object-level access tracking for CUI audit trail)
- **AWS Config**: Configuration recorder with 10 managed rules that encode this blueprint's security claims (encryption, access control, compliance posture)
- **Bedrock Model-Invocation Logging**: Optional per-invocation logging of Bedrock API calls, with metadata-only default (prompt/response bodies excluded by design per ADR-007)

## Design Decisions

### Audit Bucket

The audit bucket holds all CloudTrail and Config snapshots in a single KMS-encrypted, versioned, publicly-blocked S3 bucket. The bucket policy is pre-created and must exist before CloudTrail creates the trail (CloudTrail validates the policy at creation). Unlike the documents bucket, this bucket does NOT carry SSE-KMS downgrade-deny statements—CloudTrail and Config set their own encryption context, and denies on client headers would break service delivery. The default bucket encryption (aws:kms) and per-service KMS integration provide at-rest protection.

### CloudTrail Data Events

CloudTrail records both management events (all control-plane API calls) and object-level data events on the documents bucket. Data events are the *promised* replacement for the `CKV2_AWS_62` skips in the document-store module—all read/write access to CUI data flows through the trail. **Cost toggle**: Data events bill per event recorded.

### Bedrock Invocation Logging

Bedrock logging is a **regional singleton** (one configuration per account per region). Enabling this module will overwrite any existing Bedrock logging configuration in the region. By design, prompt and response bodies are excluded from logs (metadata-only: model id, timestamps, token counts, invocation identity). Full-content logging (prompts, responses, images, embeddings) is opt-in via `enable_full_content_logging = true`; see ADR-007 (docs/adr/007-prompt-capture-posture.md) for the capture posture rationale.

### Service-Assumed Roles

CloudTrail, Config, and Bedrock delivery roles are deliberately **outside** the iam module's permission boundary. These roles are assumed by AWS services (not by workload identities), and the boundary's ceilings on logs delivery would prevent service operation. Same pattern as RDS enhanced-monitoring (see the vector-store module README). Config uses its service-linked role, which cannot carry a boundary at all; if `AWSServiceRoleForConfig` already exists in the account, import it (`terraform import 'module.audit.aws_iam_service_linked_role.config' <role-arn>`) rather than letting the apply fail on creation.

### Cost Toggles

| Feature | Default | Cost Implication |
|---------|---------|------------------|
| CloudTrail Data Events | enabled (documents bucket only) | Per-event cost; excludes management events (always on, no cost) |
| CloudTrail Insights | disabled | Per-invocation analysis charge; separate from data events |
| AWS Config Recorder | enabled | Per-configuration-item recorded; baseline 10 managed rules |
| Global Resource Types | enabled (one region only) | Recording IAM/global resources in more than one region duplicates every configuration item; enable in exactly one region per account |
| Bedrock Full-Content Logging | disabled (metadata-only) | Large-data S3 overflow prevents truncation >100KB; impacts S3 costs if enabled |

## Control Alignment

| NIST 800-53 Control | Aligns To |
|---------------------|-----------|
| AU-9 (Log Integrity) | CloudTrail log-file validation + object lock + versioning |
| AC-3, SC-7 (Access Control) | S3 public-access blocking, Config managed rules (public read/write) |
| SC-8, SC-8(1) (Transmission Confidentiality) | TLS enforcement, S3 bucket policies, Config rule (SSL-only) |
| SC-12 (Key Management) | KMS key rotation via Config rule |
| SC-28, SC-28(1) (Information Protection) | SSE-KMS on all buckets and logs, Config encryption rules |
| AC-6 (Least Privilege) | Config rule (no admin-access policies), IAM boundary pattern |
| AC-17 (Remote Access) | Config rule (restricted SSH) |

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
| [aws_bedrock_model_invocation_logging_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrock_model_invocation_logging_configuration) | resource |
| [aws_cloudtrail.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudtrail) | resource |
| [aws_cloudwatch_log_group.bedrock](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.trail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_config_config_rule.rules](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/config_config_rule) | resource |
| [aws_config_configuration_recorder.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/config_configuration_recorder) | resource |
| [aws_config_configuration_recorder_status.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/config_configuration_recorder_status) | resource |
| [aws_config_delivery_channel.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/config_delivery_channel) | resource |
| [aws_iam_role.bedrock_logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.cloudtrail_to_cwl](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.bedrock_logging_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.cloudtrail_cwl_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_service_linked_role.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_service_linked_role) | resource |
| [aws_s3_bucket.audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_logging.audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_logging) | resource |
| [aws_s3_bucket_object_lock_configuration.audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_object_lock_configuration) | resource |
| [aws_s3_bucket_policy.audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.audit_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.bedrock_logging_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.bedrock_logging_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cloudtrail_cwl_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cloudtrail_to_cwl_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| access\_logs\_bucket\_id | ID of the S3 bucket for receiving audit bucket server access logs | `string` | n/a | yes |
| documents\_bucket\_arn | ARN of the documents bucket (used to scope CloudTrail S3 data events) | `string` | n/a | yes |
| environment | Deployment environment | `string` | n/a | yes |
| logs\_kms\_key\_arn | ARN of the KMS key used to encrypt CloudTrail, CloudWatch Logs, Config snapshots, and the audit bucket | `string` | n/a | yes |
| project | Project name used in resource naming and tags | `string` | n/a | yes |
| abort\_incomplete\_multipart\_days | Abort incomplete multipart uploads after (days) | `number` | `7` | no |
| audit\_log\_expiration\_days | Audit bucket log expiration (days). Default 913 implements M-21-31 ≈12 months active + 18 months cold. Must be > object\_lock\_retention\_days. | `number` | `913` | no |
| bedrock\_log\_retention\_days | Bedrock model-invocation log retention in CloudWatch (days). Must be in CloudWatch allowed set. Default 365 implements M-21-31 12-month active retention. | `number` | `365` | no |
| config\_snapshot\_frequency | AWS Config snapshot delivery frequency | `string` | `"TwentyFour_Hours"` | no |
| data\_classification | Data classification level | `string` | `"cui"` | no |
| enable\_bedrock\_invocation\_logging | Enable Bedrock model-invocation logging. WARNING: This is a regional SINGLETON configuration (one per account per region). Enabling here overwrites any existing configuration in the region. | `bool` | `true` | no |
| enable\_full\_content\_logging | When false, only invocation metadata (model id, timestamps, token counts, identity) is logged; prompt/response bodies are excluded. See ADR-007 (docs/adr/007-prompt-capture-posture.md) | `bool` | `false` | no |
| enable\_insights | Enable CloudTrail Insights (adds per-event analysis charges) | `bool` | `false` | no |
| enable\_object\_lock | Enable S3 Object Lock on the audit bucket (prevents deletion and shortening of retention periods) | `bool` | `true` | no |
| force\_destroy | Allow terraform destroy to empty the audit bucket (all object versions) first. Sandbox teardown aid — CloudTrail/Config deliver continuously, so destroy reliably fails without it. Production keeps false; incompatible with the intent of object lock. | `bool` | `false` | no |
| include\_global\_resource\_types | Include global resource types (IAM, etc.) in Config recording. Enable in exactly ONE region per account to avoid duplicate configuration items. | `bool` | `true` | no |
| object\_lock\_mode | S3 Object Lock retention mode (GOVERNANCE or COMPLIANCE) | `string` | `"GOVERNANCE"` | no |
| object\_lock\_retention\_days | S3 Object Lock default retention period (days) | `number` | `30` | no |
| tags | Additional tags to apply to resources | `map(string)` | `{}` | no |
| trail\_log\_retention\_days | CloudTrail log retention in CloudWatch (days). Must be in CloudWatch allowed set. Default 365 implements M-21-31 12-month active retention. | `number` | `365` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| audit\_bucket\_arn | ARN of the audit bucket |
| audit\_bucket\_id | ID of the audit bucket |
| audit\_log\_group\_name | Name of the CloudTrail CloudWatch Logs group |
| bedrock\_log\_group\_name | Name of the Bedrock model-invocation CloudWatch Logs group (null if disabled) |
| config\_recorder\_name | Name of the AWS Config configuration recorder |
| trail\_arn | ARN of the CloudTrail |
<!-- END_TF_DOCS -->
