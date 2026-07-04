# KMS

Implements customer-managed KMS keys partitioned by data domain—data, logs, and secrets—with automatic rotation enabled, least-privilege key policies enforcing an access model where the account root enables IAM policies (preventing key lockout), optional key-admin roles have no cryptographic permissions, and services access keys only through designated AWS services (via `kms:ViaService` conditions). The module is partition-aware (works across AWS, GovCloud, China) and produces outputs shaped for consumption by every other module in the stack.

## Access Model

The KMS key policy enforces a three-tier access pattern:

1. **Root-Enable Statement** (`EnableIAMUserPermissions`): Grants `kms:*` to the account root principal. This is the documented AWS best-practice pattern. Without it, IAM policies cannot grant access to the key (they become inert), and there is no fallback admin path if all other access is revoked. This statement prevents key lockout and is non-negotiable for operability in a multi-principal environment.

2. **Key-Admin Statement** (`KeyAdministration`): When `key_admin_principal_arns` is non-empty, grants management actions only (Create*, Describe*, Enable*, List*, Put*, Update*, Revoke*, Disable*, Get*, Delete, TagResource, UntagResource, ScheduleKeyDeletion, CancelKeyDeletion). Admins manage the key *but do not* have cryptographic permissions (no Encrypt, Decrypt, GenerateDataKey, CreateGrant as a catch-all). This prevents admins from inadvertently using the key for data operations.

3. **Service-User Statement** (`AllowServiceUse`): When `via_services` is configured for a domain, grants Encrypt, Decrypt, ReEncrypt*, GenerateDataKey*, DescribeKey, and CreateGrant—but only when called *via the designated AWS service* (`kms:ViaService` condition) and from within this AWS account. This is the principal access control pattern: day-to-day principals (roles, users) are granted key access by their IAM policies (in the **iam** module), not here. This module defines what *services* may use the key, not which users.

## Usage

```hcl
module "kms" {
  source = "../../modules/kms"

  project             = "federal-llm"
  environment         = "prod"
  data_classification = "cui"

  # Optional: add custom domains (e.g., backups, temp-compute)
  domains = {
    data = {
      description  = "RDS, S3, EBS encryption"
      via_services = ["s3", "rds"]
    }
    logs = {
      description  = "CloudWatch, CloudTrail, flow logs"
      via_services = ["logs"]
    }
    secrets = {
      description  = "Secrets Manager"
      via_services = ["secretsmanager"]
    }
    backups = {
      description  = "RDS snapshots and cross-region copies"
      via_services = ["s3"]
    }
  }

  deletion_window_in_days = 30

  # When non-empty, create a key-admin statement (management only, no crypto)
  # key_admin_principal_arns = ["arn:aws:iam::ACCOUNT:role/KMSAdminRole"]

  tags = {
    Example = "custom"
  }
}

# Consume outputs in downstream modules:
# - pass module.kms.key_arns["logs"] to the network module for flow-log encryption
# - pass module.kms.key_arns to observability for log-group encryption
# - pass module.kms.key_ids to iam for key policy grants
```

## Extending with New Domains

To add a new domain (e.g., `temp-compute` for ephemeral compute scratch storage):

```hcl
domains = {
  # ... existing domains ...
  temp-compute = {
    description  = "Ephemeral compute scratch storage and container caches"
    via_services = ["ec2", "ecs"]  # or [] if no via_services condition applies
  }
}
```

- If `via_services` is empty, the domain key has only the root-enable and (if configured) key-admin statements. Services or roles using the key must be granted access by IAM policies alone.
- If `via_services` is non-empty, the domain key additionally has an `AllowServiceUse` statement that gates access to calls through those services.

## GovCloud & Partition Awareness

This module automatically handles partition differences (AWS, GovCloud, China) via `data.aws_partition.current` and `data.aws_region.current`:

- ARN partition prefix is dynamically determined.
- Service endpoints in `via_services` conditions are composed as `{service}.{region}.amazonaws.com` (or `.gov` in GovCloud, `.com.cn` in China).
- Key policies are valid across all partitions.

No hardcoded region or partition suffixes; the module is fully portable.

## Key Rotation

Key rotation is hardcoded to `enable_key_rotation = true` on all CMKs. This reflects the federal compliance posture (NIST 800-53 SC-12, SC-28) and cannot be disabled. Rotation is automatic and transparent; rotated keys remain accessible via their key ID.

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
| [aws_kms_alias.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.key_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| environment | Deployment environment (dev, staging, prod) | `string` | n/a | yes |
| project | Project name used in resource naming and tags | `string` | n/a | yes |
| data\_classification | Data classification level: public, internal, or cui | `string` | `"cui"` | no |
| deletion\_window\_in\_days | KMS key deletion window (7-30 days) | `number` | `30` | no |
| domains | KMS domains (data, logs, secrets) with descriptions and optional service-binding conditions. via\_services are AWS service prefixes composed as '{svc}.{region}.amazonaws.com' in kms:ViaService conditions. | <pre>map(object({<br/>    description  = string<br/>    via_services = optional(list(string), [])<br/>  }))</pre> | <pre>{<br/>  "data": {<br/>    "description": "Data at rest: RDS storage, S3 objects, EBS",<br/>    "via_services": [<br/>      "s3",<br/>      "rds"<br/>    ]<br/>  },<br/>  "logs": {<br/>    "description": "CloudWatch log groups, CloudTrail, flow logs",<br/>    "via_services": [<br/>      "logs"<br/>    ]<br/>  },<br/>  "secrets": {<br/>    "description": "Secrets Manager secrets and SSM SecureString parameters",<br/>    "via_services": [<br/>      "secretsmanager",<br/>      "ssm"<br/>    ]<br/>  }<br/>}</pre> | no |
| key\_admin\_principal\_arns | ARNs of principals granted KMS key admin permissions (Create*, Describe*, Enable*, List*, Put*, Update*, Revoke*, Disable*, Get*, Delete, TagResource, UntagResource, ScheduleKeyDeletion, CancelKeyDeletion). When empty, the admin statement is omitted and root account access is the only admin path. | `list(string)` | `[]` | no |
| tags | Additional tags applied to all taggable resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| alias\_arns | KMS CMK alias ARNs keyed by domain (data, logs, secrets, etc.) |
| key\_arns | KMS CMK ARNs keyed by domain (data, logs, secrets, etc.) |
| key\_ids | KMS CMK IDs keyed by domain (data, logs, secrets, etc.) |
<!-- END_TF_DOCS -->
