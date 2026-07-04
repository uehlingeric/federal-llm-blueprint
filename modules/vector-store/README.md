# Vector Store Module

Provisions a managed AWS RDS PostgreSQL instance with pgvector extension for embeddings storage. The database is encrypted end-to-end with customer-managed KMS keys, deployed into private subnets only (no public accessibility), enforces IAM database authentication as the preferred access method, requires TLS for all client connections, maintains automated backups with point-in-time recovery, and outputs connection details for downstream RAG workloads.

## What This Module Deploys

- **RDS PostgreSQL 16 Instance** — engine_version 16 with auto minor-version upgrades; major version upgrades manual (allow_major_version_upgrade = false)
- **pgvector Extension** — Installed via one-time bootstrap SQL script; no runtime extension management in Terraform (CREATE EXTENSION is a data plane operation)
- **Encryption**
  - Storage: gp3 volumes encrypted with the data domain KMS key (rds-storage)
  - Performance Insights: Encrypted with the data domain KMS key (7-day free-tier retention)
  - Master user credentials: RDS-managed secret in Secrets Manager, encrypted with the secrets domain KMS key
  - CloudWatch Logs (postgresql, upgrade): Encrypted with the logs domain KMS key
- **Network Isolation**
  - Private subnets only (publicly_accessible = false)
  - Security group with ingress on 5432 from app_security_group_id only
  - No egress rules (database initiates no outbound connections)
- **Security Hardening**
  - rds.force_ssl = 1: Enforces TLS 1.2+ for all client connections (including IAM auth)
  - iam_database_authentication_enabled = true: Allows temporary credentials via AWS IAM (no permanent passwords)
  - RDS-managed master password: Automatic rotation via Secrets Manager (no customer Lambda needed — critical in no-egress VPCs)
  - Deletion protection enabled by default (prevents accidental destruction)
  - Final snapshot on destroy (unless skip_final_snapshot = true)
- **Backups & Recovery**
  - Automated backups: Retention configurable 7–35 days (federal minimum 7)
  - delete_automated_backups = false: Automated backups retained after instance deletion
  - Point-in-time recovery available for the full retention window
  - Final snapshot on destroy (unless skipped)
- **Monitoring & Observability**
  - Enhanced monitoring: OS-level metrics (optional; disabled at monitoring_interval = 0)
  - CloudWatch Logs: postgresql and upgrade logs exported to pre-created, encrypted log groups
  - Performance Insights: Visual database performance data (enabled by default)

## Data Classification Guidance

### CUI (Controlled Unclassified Information) — Default

When `var.data_classification = "cui"`, this module enforces:

| Control | Implementation | Why |
|---------|-----------------|-----|
| **Encryption at Rest** | gp3 storage + data KMS key (CMK) | Aligns to SC-28(1): encryption of information at rest |
| **Encryption in Transit** | TLS 1.2+ (rds.force_ssl = 1) | Aligns to SC-8: encrypted transport for all client connections |
| **Authentication** | IAM database auth preferred (app_user with GRANT rds_iam) | Aligns to AC-2 (Account Management): no hardcoded passwords; temporary credentials via role assumption |
| **Network Isolation** | Private subnet only; no public route | Aligns to SC-7: information system boundary protection (no direct internet route) |
| **Backup Retention** | Minimum 7 days (federal floor) | Aligns to CP-9 (System Backup): recoverable state maintained |
| **Deletion Protection** | Enabled by default (must explicitly disable then apply to destroy) | Prevents accidental data loss |
| **Master Password Rotation** | RDS-managed (Secrets Manager automatic rotation, no customer Lambda) | Aligns to IA-5 (Authenticator Management): rotation enforced; RDS rotation eliminates Lambda code paths in no-egress VPCs |

**Operational Posture for CUI:**
- Backup retention: 7–35 days (recommend 30 for compliance audits)
- Multi-AZ: true by default (production-ready; set to false only for minimal demo with explicit override)
- Monitoring interval: 60 seconds (OS-level metrics)
- Log retention: 90 days (federal audits often require 365+; configure via var.log_retention_days)

### Restricted / Secret

Not in scope for this repository (IL5+ governance, FedRAMP-certified HSM, etc.). See IL5 guidance for drive encryption, FIPS compliance, and enclave placement.

## Bootstrap: One-Time pgvector Setup

pgvector is a PostgreSQL extension that Terraform **cannot create** (CREATE EXTENSION is a DML operation). After the RDS instance is running, execute the included `bootstrap.sql` script from an in-VPC task:

### Steps

1. **Retrieve master credentials from Secrets Manager** (RDS-managed secrets are named `rds!db-<uuid>`, so always address them by ARN from the `master_secret_arn` output):
   ```bash
   SECRET_ARN="<master_secret_arn output>"
   aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
     --query SecretString --output text | jq -r '.password' > /tmp/master_pass.txt
   ```

2. **Connect from an in-VPC ECS task or EC2 instance** (requires network access on 5432 to the RDS security group):
   ```bash
   export PGPASSWORD="$(cat /tmp/master_pass.txt)"
   psql \
     -h fedllm-dev-vector.c1a2b3c4d5e6.us-east-1.rds.amazonaws.com \
     -U postgres \
     -d vectordb \
     -f bootstrap.sql
   ```

3. **Verify pgvector extension**:
   ```sql
   -- From psql, as postgres user
   \dx vector
   ```

   Expected output:
   ```
                    List of installed extensions
    Name  | Version | Schema |     Description      
   -------+---------+--------+----------------------
    vector | 0.x.x   | public | open-source vector similarity search
   (1 row)
   ```

4. **Verify app_user and permissions**:
   ```sql
   \du
   -- Should list: app_user with rds_iam role
   ```

**One-Time Nature:** Run `bootstrap.sql` once. The extension and app_user persist across instance restarts. CREATE EXTENSION uses IF NOT EXISTS; a re-run fails on `CREATE USER app_user` ("role already exists"), which is harmless — the remaining GRANTs are safe to re-apply.

### Why No Customer Lambda for Rotation

RDS-managed Secrets Manager rotation (manage_master_user_password = true) uses AWS's native rotation handler — no customer Lambda code. This is critical in **no-egress VPCs**:
- Customer-written Lambda for rotation would need to execute from a task or EC2 instance, requiring network access to both RDS and Secrets Manager (both available via VPC endpoints, but adds complexity and runtime dependencies).
- RDS-managed rotation runs on AWS infrastructure outside the VPC, avoiding egress dependencies.
- Manual rotation (if needed) triggers via: `aws secretsmanager rotate-secret --secret-id $SECRET_ARN`.

## RDS-Managed Master Password & Secrets Manager

**Credentials Flow:**
1. RDS creates a random master password and stores it in Secrets Manager (in the master_user_secret)
2. Secrets Manager encrypts the secret with the secrets domain KMS key (var.secrets_kms_key_arn)
3. RDS automatically rotates the password every 30 days (default, configurable via Secrets Manager rotation settings)
4. Application never handles the password directly; instead:
   - For IAM auth: Use temporary credentials via `aws rds generate-db-auth-token`
   - For bootstrap/admin tasks: Retrieve the secret via `aws secretsmanager get-secret-value` at runtime

**Output:** `master_secret_arn` is the Secrets Manager secret ARN. Credentials are retrieved out-of-band (not stored in Terraform state).

## IAM Database Authentication

Preferred over password authentication. Use for application access to the database:

```bash
# In ECS task or Lambda with app_task_role attached
# Generate a temporary auth token (15-minute validity)
TOKEN=$(aws rds generate-db-auth-token \
  --hostname fedllm-dev-vector.c1a2b3c4d5e6.us-east-1.rds.amazonaws.com \
  --port 5432 \
  --username app_user \
  --region us-east-1)

# Connect using the token as the password (no plaintext password used).
# verify-full requires the RDS certificate bundle:
#   https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
PGPASSWORD="$TOKEN" psql \
  "host=fedllm-dev-vector.c1a2b3c4d5e6.us-east-1.rds.amazonaws.com \
   port=5432 user=app_user dbname=vectordb \
   sslmode=verify-full sslrootcert=/path/to/rds-bundle.pem" \
  -c "SELECT 1"
```

**IAM Policy** (on the app_task_role, from iam module):
```json
{
  "Effect": "Allow",
  "Action": ["rds-db:connect"],
  "Resource": [
    "arn:aws:rds-db:us-east-1:123456789012:dbuser:db-ABCDEFGHIJKLMNOPQRST/app_user"
  ]
}
```

The `db_resource_id` output is the DbiResourceId (e.g., db-ABCDEFGHIJKLMNOPQRST) needed in the ARN.

## Instance Sizing & Performance

### Demo (Default)

| Metric | Value | Notes |
|--------|-------|-------|
| **Instance Class** | db.t4g.medium (Graviton2, burstable) | ~$120/mo multi-AZ, us-east-1 (production-ready default) |
| **Storage** | 20 GiB (gp3) allocated, auto-scale to 100 GiB | Suitable for <10M vectors (~1–2 GiB per M vectors at 1536-dim) |
| **Multi-AZ** | true | Synchronous replication; automatic failover; meets production SLAs |
| **Backup Retention** | 7 days | Minimum federal floor |
| **Monitoring** | 60-second interval | OS metrics captured |

### Production

For production workloads, adjust:

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| **Instance Class** | r6g.large or r6i.xlarge | Memory-optimized for index caching; avoid t4g burstable |
| **Storage** | 100+ GiB allocated; max 1000+ GiB | Larger working set; gp3 cost scales linearly |
| **Multi-AZ** | true | Automatic failover; synchronous replication |
| **Backup Retention** | 30–35 days | Compliance audit window |
| **Monitoring** | 60-second interval (keep) | Monitor in production |
| **Log Retention** | 365 days | Federal retention requirements (configurable in var.log_retention_days) |

Example terraform.tfvars for production:
```hcl
instance_class        = "r6g.large"
allocated_storage     = 200
max_allocated_storage = 500
multi_az              = true
backup_retention_days = 30
log_retention_days    = 365
monitoring_interval   = 60
```

## Destroy & Snapshot Behavior

### Default (deletion_protection = true, skip_final_snapshot = false)

```bash
# Step 1: Disable deletion protection
terraform apply -var deletion_protection=false

# Step 2: Destroy (creates final snapshot)
terraform destroy
# Output: fedllm-dev-vector-final snapshot created in RDS
```

**Result:** RDS instance deleted; fedllm-dev-vector-final snapshot persists (queryable for recovery).

### If skip_final_snapshot = true

```bash
terraform destroy
# Instance deleted immediately; no snapshot created
# Automated backups retained for backup_retention_days
```

### Restore from Snapshot

```bash
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier fedllm-dev-vector-restored \
  --db-snapshot-identifier fedllm-dev-vector-final \
  --db-subnet-group-name fedllm-dev-vector-subnet-group \
  --vpc-security-group-ids sg-xxxxx \
  --storage-encrypted \
  --kms-key-id arn:aws:kms:...
```

Point-in-time recovery also available within the backup_retention_days window via `restore-db-instance-to-point-in-time`.

## Monitoring & Observability

### CloudWatch Logs

**Log Groups** (pre-created and encrypted):
- `/aws/rds/instance/fedllm-dev-vector/postgresql` — RDS activity, errors, queries
- `/aws/rds/instance/fedllm-dev-vector/upgrade` — Minor/major version upgrade logs

Retention configurable via var.log_retention_days (default 90 days).

### Enhanced Monitoring (Optional)

When var.monitoring_interval > 0, OS-level metrics are captured:
- CPU, memory, I/O
- Database processes
- Replica lag (if read replicas present)

Disable with monitoring_interval = 0 (no monitoring role created, reduces cost).

### Performance Insights

Enabled by default (var.enable_performance_insights = true). Provides:
- Database load (active sessions over time)
- Top SQL and wait events
- 7-day retention (free tier)

## Cross-Module Dependencies

| Output | Consumed By | Use Case |
|--------|-------------|----------|
| `db_endpoint` | LLM gateway task | psycopg2 or similar: host = db_endpoint |
| `db_port` | LLM gateway task | port = 5432 (fixed) |
| `db_resource_id` | iam module | Construct rds-db:connect ARN for app_user |
| `master_secret_arn` | Bootstrap task | aws secretsmanager get-secret-value for initial master password |
| `db_name` | Bootstrap script | Target database in psql -d $db_name |

## Cost Estimation

**Monthly (us-east-1, multi-AZ, demo sizing):**
- RDS instance (db.t4g.medium, multi-AZ): ~$120
- Storage (20–100 GiB gp3, multi-AZ): ~$10–$50
- Backups (7 days, replicated): ~$4
- Enhanced monitoring (60s): ~$2
- Data transfer (in-VPC): $0
- KMS (3 keys, usage): ~$3

**Total: ~$139/month (multi-AZ default)** → ~$300–$600 (production r6g/r6i classes with larger storage).

To minimize costs for development-only environments (not for production), set `multi_az = false` and use a smaller `allocated_storage`, reducing to ~$70/month single-AZ.

## Notes

### pgvector Installation

pgvector on RDS PostgreSQL 16 requires **no** shared_preload_libraries modification. It is a pure extension (CREATE EXTENSION IF NOT EXISTS vector). The bootstrap.sql script is idempotent.

### TLS / SSL

rds.force_ssl = 1 enforces TLS for all connections, including IAM auth. Common PostgreSQL clients default to sslmode=prefer, which encrypts but does NOT verify the server certificate — configure clients with sslmode=verify-full and the RDS certificate bundle (rds-ca-rsa2048-g1 is GovCloud-compatible), as `scripts/seed-vectors.py` does.

### No Egress Connectivity

Database initiates zero outbound connections. All secrets retrieval (rotation, master password bootstrap) flows through VPC endpoints (Secrets Manager endpoint) or are handled by AWS managed services (RDS-managed rotation).

---

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
| [aws_cloudwatch_log_group.postgresql](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.upgrade](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_db_instance.vector](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance) | resource |
| [aws_db_parameter_group.vector](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_parameter_group) | resource |
| [aws_db_subnet_group.vector](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_iam_role.rds_monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.rds_monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_security_group.db](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_ingress_rule.db_from_app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_iam_policy_document.rds_monitoring_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| app\_security\_group\_id | Security group ID for application workloads (from network module); used as ingress source for RDS database security group | `string` | n/a | yes |
| data\_kms\_key\_arn | ARN of the KMS CMK for encrypting RDS storage and performance insights (from kms module, data domain) | `string` | n/a | yes |
| environment | Deployment environment (dev, staging, prod) | `string` | n/a | yes |
| logs\_kms\_key\_arn | ARN of the KMS CMK for encrypting CloudWatch Logs (from kms module, logs domain) | `string` | n/a | yes |
| private\_subnet\_ids | List of private subnet IDs for RDS placement; must span at least 2 AZs | `list(string)` | n/a | yes |
| project | Project name used in resource naming and tags | `string` | n/a | yes |
| secrets\_kms\_key\_arn | ARN of the KMS CMK for encrypting RDS-managed master user secret in Secrets Manager (from kms module, secrets domain) | `string` | n/a | yes |
| vpc\_id | VPC ID in which to launch the RDS instance (from network module) | `string` | n/a | yes |
| allocated\_storage | Initial allocated storage in GiB (default 20; demo sizing) | `number` | `20` | no |
| backup\_retention\_days | Automated backup retention period in days (minimum 7 enforced for federal compliance; default 7) | `number` | `7` | no |
| data\_classification | Data classification level: public, internal, or cui | `string` | `"cui"` | no |
| db\_name | Initial database name (default vectordb) | `string` | `"vectordb"` | no |
| deletion\_protection | Enable deletion protection (default true; prevents accidental instance deletion) | `bool` | `true` | no |
| enable\_performance\_insights | Enable Performance Insights (default true; provides database performance visibility) | `bool` | `true` | no |
| engine\_version | PostgreSQL major version (default 16; minor upgrades applied automatically) | `string` | `"16"` | no |
| instance\_class | RDS instance class (default db.t4g.medium; ~$60/mo single-AZ, suitable for demo workloads; prod: r6g classes with multi\_az = true recommended) | `string` | `"db.t4g.medium"` | no |
| log\_retention\_days | CloudWatch Logs retention period in days (must be a valid CloudWatch retention value; default 90) | `number` | `90` | no |
| master\_username | Master database user (default postgres) | `string` | `"postgres"` | no |
| max\_allocated\_storage | Maximum allocated storage for autoscaling in GiB (default 100; must exceed allocated\_storage) | `number` | `100` | no |
| monitoring\_interval | Enhanced monitoring interval in seconds (default 60; must be 0, 1, 5, 10, 15, 30, or 60; 0 disables enhanced monitoring and the monitoring role) | `number` | `60` | no |
| multi\_az | Enable Multi-AZ deployment for high availability (default true for production-readiness; set to false only for minimal demo) | `bool` | `true` | no |
| preferred\_backup\_window | Preferred backup window in HH:MM-HH:MM UTC format (default 03:00-04:00) | `string` | `"03:00-04:00"` | no |
| preferred\_maintenance\_window | Preferred maintenance window in ddd:HH:MM-ddd:HH:MM UTC format (default sun:04:30-sun:05:30) | `string` | `"sun:04:30-sun:05:30"` | no |
| skip\_final\_snapshot | Skip final snapshot on destroy (default false; when false, a final snapshot {identifier}-final is taken on instance deletion) | `bool` | `false` | no |
| tags | Additional tags applied to all taggable resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| db\_endpoint | RDS Postgres endpoint hostname (hostname only, not endpoint:port) |
| db\_instance\_arn | ARN of the RDS instance |
| db\_instance\_id | RDS instance identifier |
| db\_name | Initial database name |
| db\_port | RDS Postgres port (5432) |
| db\_resource\_id | RDS DbiResourceId (used in rds-db:connect IAM auth ARNs for app\_user access) |
| db\_security\_group\_id | Security group ID for the RDS instance |
| master\_secret\_arn | ARN of the Secrets Manager secret containing RDS-managed master user credentials |
<!-- END_TF_DOCS -->
