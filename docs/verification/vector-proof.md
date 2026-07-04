# Vector Proof — Verification Procedure

## Status

- **Static proof:** Automated in CI via `modules/vector-store/tests/*.tftest.hcl` and `modules/document-store/tests/*.tftest.hcl` assertions — runs on every PR, no credentials required.
- **Dynamic proof:** PENDING first sandbox execution — transcripts below are placeholders to be filled on initial deploy.

---

## Claim

When the `vector-store` and `document-store` modules are deployed into the week-4 infrastructure:
- RDS Postgres in a private subnet accepts IAM-authenticated connections from the in-VPC gateway task only; encryption at rest (data CMK) and in transit (force_ssl = 1) are enforced
- Master credentials are stored in Secrets Manager under the secrets CMK with automatic rotation (RDS-managed, no Lambda needed)
- pgvector extension is enabled and HNSW indexes can be created on embedding vectors
- S3 document store enforces KMS encryption, version tracking, and access logging
- In-VPC tasks can seed embeddings and query by cosine distance without internet egress
- The no-egress invariant (week 2) remains intact with the data plane present

---

## Static Proof (Automated in CI)

The vector-store and document-store modules include native Terraform test assertions:

**vector-store module tests** (`modules/vector-store/tests/`):
- `encryption_and_hardening.tftest.hcl`: Asserts storage encrypted with the data CMK, RDS-managed master password with the secret under the secrets CMK, IAM database authentication enabled, no public accessibility, deletion protection on, parameter group enforces `rds.force_ssl = 1`, Performance Insights encrypted with the data CMK, pre-created log groups encrypted with the logs CMK, GovCloud-compatible CA certificate
- `topology_and_backups.tftest.hcl`: Asserts subnet group spans at least 2 private subnets, SG ingress on 5432 from the app SG only, backup retention at least 7 days, final-snapshot naming and policy, automated backups kept after deletion, postgresql/upgrade log exports, enhanced-monitoring role count-guarded on the monitoring interval, multi-AZ wiring both ways
- `validation.tftest.hcl`: Asserts plan-time rejection of invalid variable values (backup retention outside 7–35, invalid monitoring interval, single-subnet placement, `max_allocated_storage` not greater than `allocated_storage`, malformed backup/maintenance windows, invalid db_name/master_username)

**document-store module tests** (`modules/document-store/tests/`):
- `encryption_and_access.tftest.hcl`: Asserts documents bucket defaults to SSE-KMS with the data CMK and bucket keys enabled; both log buckets AES256 (S3-managed, per log-delivery platform constraint); public-access block all-true and versioning enabled on all three buckets; documents server-access logging targets the access-logs bucket under the `documents/` prefix; object lock off by default
- `lifecycle_and_lock.tftest.hcl`: Asserts STANDARD_IA transition and noncurrent-version expiration wired to their variables, log expiration on both log buckets, multipart-upload abort on all three buckets, and object-lock mode/retention wiring when enabled
- `validation.tftest.hcl`: Asserts plan-time rejection of invalid variable values (object-lock mode/retention, environment, project format, data classification, non-positive lifecycle day counts)

These run on every PR (mocked providers, no AWS credentials needed). Passing CI green confirms static hardening.

---

## Dynamic Proof Procedure

This procedure proves RDS Postgres serves pgvector queries from inside the VPC and document buckets enforce the encryption + access posture.

### Prerequisites

- AWS credentials with admin access to a sandbox account
- Terraform CLI >= 1.9
- AWS CLI v2
- **Images mirrored into private ECR:** The no-egress VPC cannot reach Docker Hub or ghcr.io. Two proof images must be pre-mirrored, both pinned by the *pushed* digest:
  - the `postgres` image (provides psql for the bootstrap and spot-check tasks; mirror procedure in `examples/minimal/README.md`), and
  - the `seed-vectors` image built per `scripts/README.md` (Python 3.11+ with `psycopg[binary]`, `boto3`, `numpy`, the seed script, and the RDS CA bundle baked in — the VPC cannot download it at runtime).

### Cost Note

This procedure should complete (apply → seed → query → restore-drill → destroy) in approximately 2–3 hours. Primary cost: RDS db.t4g.medium ~$0.065/hour, ALB and endpoints reused from week 4 (no additional cost), ECS Fargate task (seeding) ~$0.048/hour. Recommend batching this run in a single window. **Total estimated: $2–4 for the full cycle, depending on RDS startup/destruction time (15–20 min each).**

RDS creation and destruction are slow operations (not interactive). Do not iterate module interfaces against a live RDS instance; spin up once, validate all at once, tear down once.

---

### Step 1: Deploy Minimal Stack with Vector and Document Stores

Initialize and apply the `examples/minimal` stack with vector-store and document-store modules enabled. Account ID placeholder: `123456789012`, region: `us-east-1`.

```bash
cd examples/minimal
cat > terraform.tfvars <<'EOF'
project     = "fedllm"
environment = "dev"
no_egress   = true
region      = "us-east-1"

# LiteLLM gateway image mirrored into private ECR, digest-pinned (week-4 procedure)
gateway_container_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/litellm@sha256:<pushed-digest>"

# Repos the task execution role may pull from: the gateway image plus the
# postgres (psql) and seed-vectors images used by the one-off proof tasks below
ecr_repository_arns = [
  "arn:aws:ecr:us-east-1:123456789012:repository/litellm",
  "arn:aws:ecr:us-east-1:123456789012:repository/postgres",
  "arn:aws:ecr:us-east-1:123456789012:repository/seed-vectors"
]
EOF

terraform init
terraform plan -out=tfplan

# Review the plan. Expected:
# - vector-store module creates: RDS Postgres instance, DB subnet group, security group, parameter group, two log groups, monitoring role
# - document-store module creates: 3 S3 buckets (documents, access-logs, alb-logs) with encryption, versioning, policies
# - IAM role updates: app role granted rds-db:connect for the specific DB user/resource pair, S3 read on the documents/ prefix
#
# Vector-store and document-store settings come from the module blocks in
# examples/minimal/main.tf (single-AZ demo override, object lock off); edit the
# module blocks to change them — they are deliberately not example variables.

terraform apply tfplan
```

Expected output: Stack deploys in 15–20 minutes (RDS creation is slow). Capture the outputs, especially `db_endpoint`, `db_instance_id`, `db_resource_id`, and `document_bucket_ids`.

```
# TRANSCRIPT PENDING
Outputs:

db_endpoint = "fedllm-dev-vector.c123xyz.us-east-1.rds.amazonaws.com"
db_instance_id = "fedllm-dev-vector"
db_resource_id = "db-ABCDEF1234567890"
db_port = 5432
db_name = "vectordb"
db_master_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-<uuid>-xxxxxx"
documents_bucket_regional_domain_name = "fedllm-dev-documents-123456789012.s3.us-east-1.amazonaws.com"
document_bucket_ids = {
  "access-logs" = "fedllm-dev-access-logs-123456789012"
  "alb-logs"    = "fedllm-dev-alb-logs-123456789012"
  "documents"   = "fedllm-dev-documents-123456789012"
}
```

### Step 2: Retrieve and Store Master Credentials

The RDS master password is stored in Secrets Manager (created by the module, RDS-managed secret). Retrieve it for the bootstrap step:

```bash
MASTER_SECRET_ARN=$(terraform output -raw db_master_secret_arn)
MASTER_CREDS=$(aws secretsmanager get-secret-value \
  --secret-id "$MASTER_SECRET_ARN" \
  --query 'SecretString' \
  --region us-east-1 \
  --output text)

# RDS-managed secrets contain ONLY username and password (no host key):
# {"username":"postgres","password":"..."}
MASTER_USER=$(echo "$MASTER_CREDS" | jq -r '.username')
MASTER_PASSWORD=$(echo "$MASTER_CREDS" | jq -r '.password')

echo "Master user: $MASTER_USER"
# Do not echo password; it's sensitive
```

Expected: Master credentials retrieved from Secrets Manager (encrypted with secrets CMK, decrypted on-the-fly).

```
# TRANSCRIPT PENDING
Master user: postgres
```

### Step 3: Wait for RDS Availability

The database takes 10–15 minutes to initialize and be ready for connections.

```bash
DB_INSTANCE_ID=$(terraform output -raw db_instance_id)

aws rds wait db-instance-available \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --region us-east-1

# Verify status:
aws rds describe-db-instances \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBInstances[0].[DBInstanceStatus,StorageEncrypted,PubliclyAccessible,IAMDatabaseAuthenticationEnabled]' \
  --region us-east-1
```

Expected: Database is available, encrypted, not public, IAM auth enabled.

```
# TRANSCRIPT PENDING
[
  "available",
  true,
  false,
  true
]
```

### Step 4: Bootstrap pgvector — Create Extension and App User

Run the canonical bootstrap SQL (`modules/vector-store/bootstrap.sql`) as the master user from an in-VPC Fargate task. It creates the pgvector extension (master user required for CREATE EXTENSION) and `app_user` with the `rds_iam` grant.

The task runs in the **app** security group — the DB security group only admits traffic *from* the app SG. The plain postgres image does not contain the repo, so the SQL is inlined into the task command (comment lines stripped so the single-line command stays valid).

> **Sandbox-only caveat:** the master password lands in the registered task definition. Deregister the `vector-proof-*` task definitions immediately after the drill (Step 9).

```bash
CLUSTER=$(terraform output -raw cluster_arn | awk -F/ '{print $NF}')
SUBNET=$(terraform output -json private_subnet_ids | jq -r '.[0]')
SG=$(terraform output -raw app_security_group_id)
EXEC_ROLE=$(terraform output -raw task_execution_role_arn)
LOG_GROUP=$(terraform output -raw gateway_log_group_name)
POSTGRES_IMAGE="123456789012.dkr.ecr.us-east-1.amazonaws.com/postgres@sha256:<pushed-digest>"
DB_ENDPOINT=$(terraform output -raw db_endpoint)
DB_NAME=$(terraform output -raw db_name)
BOOTSTRAP_SQL=$(grep -v '^--' ../../modules/vector-store/bootstrap.sql | tr '\n' ' ')

# Register task definition for bootstrap
aws ecs register-task-definition \
  --family vector-proof-bootstrap \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu 256 --memory 512 \
  --execution-role-arn "$EXEC_ROLE" \
  --container-definitions "[
    {
      \"name\": \"bootstrap\",
      \"image\": \"$POSTGRES_IMAGE\",
      \"entryPoint\": [\"sh\", \"-c\"],
      \"command\": [\"psql 'sslmode=require' -v ON_ERROR_STOP=1 -c \\\"$BOOTSTRAP_SQL\\\"\"],
      \"environment\": [
        {\"name\": \"PGHOST\", \"value\": \"$DB_ENDPOINT\"},
        {\"name\": \"PGUSER\", \"value\": \"$MASTER_USER\"},
        {\"name\": \"PGDATABASE\", \"value\": \"$DB_NAME\"},
        {\"name\": \"PGPASSWORD\", \"value\": \"$MASTER_PASSWORD\"}
      ],
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"$LOG_GROUP\",
          \"awslogs-region\": \"us-east-1\",
          \"awslogs-stream-prefix\": \"proof-bootstrap\"
        }
      }
    }
  ]" \
  --region us-east-1

# Run the task
aws ecs run-task \
  --cluster "$CLUSTER" \
  --task-definition vector-proof-bootstrap \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$SG],assignPublicIp=DISABLED}" \
  --region us-east-1

# Wait for task completion (typically 30–60 seconds)
sleep 90

# Read the bootstrap output
aws logs tail "$LOG_GROUP" --log-stream-name-prefix proof-bootstrap --since 10m --region us-east-1
```

Expected output (one line per statement in bootstrap.sql): pgvector extension created, app_user created and granted IAM auth + schema access.

```
# TRANSCRIPT PENDING
CREATE EXTENSION
CREATE ROLE
GRANT ROLE
GRANT
GRANT
```

### Step 5: Seed Embeddings, Build HNSW Index, and Assert the Cosine Query

Run the seed script (`scripts/seed-vectors.py`) as a one-off Fargate task, using the `seed-vectors` image built per `scripts/README.md` (script, dependencies, and RDS CA bundle baked in at `/app/rds-bundle.pem`). The script connects as `app_user` via IAM authentication (no password, `sslmode=verify-full`), creates the embeddings table with an HNSW cosine index, truncates and inserts 8 deterministic 8-dimensional vectors (numpy `RandomState(42)`), then queries the 3 nearest neighbors of the first seed vector and asserts it comes back first.

```bash
SEED_IMAGE="123456789012.dkr.ecr.us-east-1.amazonaws.com/seed-vectors@sha256:<pushed-digest>"
APP_ROLE_ARN=$(terraform output -raw app_task_role_arn)

aws ecs register-task-definition \
  --family vector-proof-seed \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu 512 --memory 1024 \
  --task-role-arn "$APP_ROLE_ARN" \
  --execution-role-arn "$EXEC_ROLE" \
  --container-definitions "[
    {
      \"name\": \"seed\",
      \"image\": \"$SEED_IMAGE\",
      \"environment\": [
        {\"name\": \"DB_HOST\", \"value\": \"$DB_ENDPOINT\"},
        {\"name\": \"DB_PORT\", \"value\": \"5432\"},
        {\"name\": \"DB_NAME\", \"value\": \"$DB_NAME\"},
        {\"name\": \"DB_USER\", \"value\": \"app_user\"},
        {\"name\": \"AUTH_MODE\", \"value\": \"iam\"},
        {\"name\": \"AWS_REGION\", \"value\": \"us-east-1\"},
        {\"name\": \"SSL_CERT_PATH\", \"value\": \"/app/rds-bundle.pem\"}
      ],
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"$LOG_GROUP\",
          \"awslogs-region\": \"us-east-1\",
          \"awslogs-stream-prefix\": \"proof-seed\"
        }
      }
    }
  ]" \
  --region us-east-1

# Run the seed task
aws ecs run-task \
  --cluster "$CLUSTER" \
  --task-definition vector-proof-seed \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$SG],assignPublicIp=DISABLED}" \
  --region us-east-1

# Wait for completion
sleep 120

# Read output
aws logs tail "$LOG_GROUP" --log-stream-name-prefix proof-seed --since 15m --region us-east-1
```

**Expected output** (exact log lines emitted by the script; distances are deterministic because the seed data is): IAM auth works (force_ssl enforced), pgvector functional, nearest-neighbor assertion passes.

```
# TRANSCRIPT PENDING
[seed] Connecting to fedllm-dev-vector.c123xyz.us-east-1.rds.amazonaws.com:5432/vectordb (auth=iam)
[seed] Connection established
[seed] Creating embeddings table (idempotent)
[seed] Creating HNSW index for cosine distance (idempotent)
[seed] Table and HNSW index created/verified
[seed] Truncating embeddings table
[seed] Inserting 8 sample vectors (8-dimensional proof-of-concept)
[seed] Inserted 8 vectors
[seed] Querying 3 nearest neighbors to probe vector
[seed] Query results:
  [seed]   id=1, doc_id=doc_1, chunk=chunk_1, distance=0.000000
  [seed]   id=7, doc_id=doc_4, chunk=chunk_1, distance=0.614780
  [seed]   id=6, doc_id=doc_3, chunk=chunk_2, distance=0.924470
[seed] ✓ Nearest neighbor assertion passed (id=1 is closest)
[seed] SUCCESS: pgvector bootstrap complete
```

### Step 6: Independent Cosine-Distance Spot Check (psql)

The seed task already asserts the nearest neighbor. As an independent check with a different client, re-register the Step-4 bootstrap task with the command below (family `vector-proof-query`, same image/env/log config) and run it. The probe is the first seed vector — deterministic from numpy `RandomState(42)`, formatted to 6 decimals exactly as inserted — so id=1 must return at distance 0.

```bash
PROBE="[0.496714,-0.138264,0.647689,1.523030,-0.234153,-0.234137,1.579213,0.767435]"

# Task command (replaces the bootstrap SQL in the Step-4 task definition):
psql 'sslmode=require' -c "SELECT id, doc_id, chunk, embedding <=> '$PROBE'::vector AS distance FROM embeddings ORDER BY distance LIMIT 3;"

sleep 90
aws logs tail "$LOG_GROUP" --log-stream-name-prefix proof-query --since 10m --region us-east-1
```

Expected output: id=1 (the probe vector itself) at distance 0, then the deterministic runners-up.

```
# TRANSCRIPT PENDING
 id | doc_id | chunk   |      distance
----+--------+---------+--------------------
  1 | doc_1  | chunk_1 |                  0
  7 | doc_4  | chunk_1 | 0.6147804…
  6 | doc_3  | chunk_2 | 0.9244704…
(3 rows)
```

### Step 7: Secondary Checks

#### 7a: RDS Encryption and Configuration

Verify RDS instance enforces encryption and IAM authentication:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBInstances[0].[StorageEncrypted,IAMDatabaseAuthenticationEnabled,PubliclyAccessible,DBParameterGroups[0].DBParameterGroupName,KmsKeyId]' \
  --region us-east-1
```

Expected: All enforced (StorageEncrypted=true, IAMDatabaseAuthenticationEnabled=true, PubliclyAccessible=false, parameter group with force_ssl=1, KMS key is the data domain key).

```
# TRANSCRIPT PENDING
[
  true,
  true,
  false,
  "fedllm-dev-vector-<generated-suffix>",
  "arn:aws:kms:us-east-1:123456789012:key/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
]
```

#### 7b: RDS Security Group

Verify the DB security group allows inbound 5432 ONLY from the app security group (no broad 0.0.0.0/0):

```bash
DB_SG_ID=$(terraform output -raw db_security_group_id)
APP_SG_ID=$(terraform output -raw app_security_group_id)

aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions[*].[FromPort,ToPort,UserIdGroupPairs[*].GroupId]' \
  --region us-east-1
```

Expected: Single inbound rule on port 5432 from the app security group; no 0.0.0.0/0.

```
# TRANSCRIPT PENDING
[
  [
    5432,
    5432,
    [
      "sg-0123456789abcdef"
    ]
  ]
]
```

#### 7c: Document Bucket Encryption and Access Logging

Verify documents bucket is encrypted and access-logged:

```bash
DOCS_BUCKET=$(terraform output -json document_bucket_ids | jq -r '.documents')

aws s3api get-bucket-encryption --bucket "$DOCS_BUCKET" --region us-east-1 --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm'

aws s3api get-bucket-logging --bucket "$DOCS_BUCKET" --region us-east-1 --query 'LoggingEnabled.TargetBucket'
```

Expected: SSE-KMS encryption and access logging to the access-logs bucket.

```
# TRANSCRIPT PENDING
"aws:kms"
"fedllm-dev-access-logs-123456789012"
```

#### 7d: Document Bucket Policy — TLS-Only and Encryption Downgrade Block

Verify the documents bucket policy denies plaintext transport and explicit encryption downgrades (statement Sids: `DenyUnencryptedTransport`, `DenyExplicitlyUnencryptedPutObject`, `DenyWrongKmsKey`):

```bash
aws s3api get-bucket-policy --bucket "$DOCS_BUCKET" --region us-east-1 --query Policy --output text \
  | jq '.Statement[] | select(.Sid == "DenyUnencryptedTransport") | .Effect'

aws s3api get-bucket-policy --bucket "$DOCS_BUCKET" --region us-east-1 --query Policy --output text \
  | jq '.Statement[] | select(.Sid == "DenyExplicitlyUnencryptedPutObject" or .Sid == "DenyWrongKmsKey") | .Effect'
```

Expected: All three deny statements present (TLS-only, header-downgrade block, wrong-key block).

```
# TRANSCRIPT PENDING
"Deny"
"Deny"
"Deny"
```

#### 7e: Document Bucket Versioning

Verify versioning is enabled:

```bash
aws s3api get-bucket-versioning --bucket "$DOCS_BUCKET" --region us-east-1 --query 'Status'
```

Expected: "Enabled".

```
# TRANSCRIPT PENDING
"Enabled"
```

### Step 8: Restore Drill — Point-in-Time Recovery

Validate that RDS point-in-time restore (PITR) works. Restore to a new test instance, verify embeddings are present, then destroy the test instance.

```bash
# Restore to a point-in-time instance (the most recent backup)
DB_INSTANCE_ID=$(terraform output -raw db_instance_id)
RESTORE_ID="$DB_INSTANCE_ID-drill"

aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier "$DB_INSTANCE_ID" \
  --db-instance-identifier "$RESTORE_ID" \
  --use-latest-restorable-time \
  --db-instance-class "db.t4g.micro" \
  --no-publicly-accessible \
  --no-multi-az \
  --region us-east-1

echo "Waiting for restore to complete (~10–15 minutes)..."
aws rds wait db-instance-available \
  --db-instance-identifier "$RESTORE_ID" \
  --region us-east-1

# Verify embeddings table row count
RESTORE_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$RESTORE_ID" \
  --query 'DBInstances[0].Endpoint.Address' \
  --region us-east-1 \
  --output text)

echo "Restore complete. Verify embeddings preserved..."
# Connect as master and count rows (for simplicity; production would test as app_user)
PGPASSWORD="$MASTER_PASSWORD" psql \
  -h "$RESTORE_ENDPOINT" \
  -U "$MASTER_USER" \
  -d "$DB_NAME" \
  -c "SELECT COUNT(*) FROM embeddings;"

# Expected: row count = 8 (from seed step)
```

Expected output: Restore succeeds in 10–15 minutes, embeddings table has 8 rows.

```
# TRANSCRIPT PENDING
Restore complete. Verify embeddings preserved...
 count 
-------
     8
(1 row)
```

Cleanup:

```bash
# Delete the restore test instance
aws rds delete-db-instance \
  --db-instance-identifier "$RESTORE_ID" \
  --skip-final-snapshot \
  --region us-east-1
```

---

## Step 9: Teardown

```bash
# Deregister one-off task definitions
for task in vector-proof-bootstrap vector-proof-seed vector-proof-query; do
  aws ecs deregister-task-definition \
    --task-definition "$task:1" \
    --region us-east-1 || true
done

# Document store buckets: versioned buckets must be emptied (including all versions) before destroy
DOCS_BUCKET=$(terraform output -json document_bucket_ids | jq -r '.documents')
ACCESS_LOGS_BUCKET=$(terraform output -json document_bucket_ids | jq -r '."access-logs"')
ALB_LOGS_BUCKET=$(terraform output -json document_bucket_ids | jq -r '."alb-logs"')

echo "Removing all object versions from $DOCS_BUCKET..."
aws s3api list-object-versions --bucket "$DOCS_BUCKET" \
  --query 'Versions[*].[Key, VersionId]' \
  --output text | while read key vid; do
    aws s3api delete-object --bucket "$DOCS_BUCKET" --key "$key" --version-id "$vid"
done

# Remove noncurrent versions from access-logs and alb-logs if any
aws s3 rm "s3://$ACCESS_LOGS_BUCKET" --recursive --region us-east-1
aws s3 rm "s3://$ALB_LOGS_BUCKET" --recursive --region us-east-1

# RDS and gateway-ALB deletion protection are on by default; disable both before destroy
cat >> terraform.tfvars <<'EOF'
gateway_deletion_protection = false
vector_deletion_protection  = false
EOF

terraform apply

# Destroy (RDS destroy takes 5–10 minutes; final snapshot is created automatically)
terraform destroy
```

Verify cleanup:

```bash
# Confirm RDS is gone and final snapshot exists
aws rds describe-db-instances \
  --query "DBInstances[?contains(DBInstanceIdentifier, 'fedllm-dev-vector')]" \
  --region us-east-1 | jq 'if . == [] then "Instance destroyed" else "ERROR: Instance still exists" end'

aws rds describe-db-snapshots \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBSnapshots[?SnapshotType==`manual`].DBSnapshotIdentifier' \
  --region us-east-1
```

Expected: RDS instance deleted, final snapshot `fedllm-dev-vector-final` present. Buckets deleted (or emptied for re-creation if stacking multiple runs).

```
# TRANSCRIPT PENDING
"Instance destroyed"
[
  "fedllm-dev-vector-final"
]
```

---

## Summary

If all controls pass:

- **Positive:** RDS Postgres accepts IAM-authenticated connections from the in-VPC task (Step 5–6: seed and query succeed, HNSW index builds, cosine query returns correct nearest neighbor).
- **Encryption:** Storage (data CMK), logs (logs CMK), backups, and in-transit TLS all enforced (Step 7a).
- **Network:** DB security group allows inbound only from app SG; no public route (Step 7b).
- **Document Store:** Buckets enforce SSE-KMS (documents) or SSE-S3 (access/ALB logs per platform constraint), TLS-only, no broad public access, versioning + lifecycle + optional object lock (Step 7c–7e).
- **Restore:** PITR restores embeddings table successfully (Step 8).
- **Claim proven:** Vector store and document store are encrypted, access-controlled, and support full RAG workload flows inside the VPC; no egress.

Transcripts from the first sandbox run should be committed to this document (replace the `# TRANSCRIPT PENDING` blocks) to form a permanent record of the proof.

---

## Negative/Secondary Checks (Optional)

**Test: Connection without IAM token fails**
```bash
# As the app_user without an IAM token, connection must fail:
PGPASSWORD=wrong psql -h "$DB_ENDPOINT" -U app_user -d "$DB_NAME" -c "SELECT 1;" 2>&1 | grep -i "authentication\|failed"
```
Expected: Authentication failure (no password or wrong password).

**Test: Explicit AES256 PutObject to documents bucket is denied**
```bash
aws s3api put-object \
  --bucket "$DOCS_BUCKET" \
  --key "test-file" \
  --body /dev/null \
  --server-side-encryption AES256 \
  --region us-east-1 2>&1 | grep -i "access denied"
```
Expected: Access denied by bucket policy (downgrade-block).

**Test: TLS-enforced database connection**
Verify that `rds.force_ssl = 1` is set in the attached parameter group (the group name is generated from the `fedllm-dev-vector-` prefix, so look it up from the instance):
```bash
PG_NAME=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBInstances[0].DBParameterGroups[0].DBParameterGroupName' \
  --output text --region us-east-1)

aws rds describe-db-parameters \
  --db-parameter-group-name "$PG_NAME" \
  --query 'Parameters[?ParameterName==`rds.force_ssl`].[ParameterValue]' \
  --region us-east-1
```
Expected: "1".
