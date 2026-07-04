-- Bootstrap script for RDS Postgres with pgvector
--
-- Run once after RDS instance creation to:
-- 1. Enable pgvector extension
-- 2. Create app_user for application access
-- 3. Grant minimal permissions for IAM authentication and schema access
--
-- Execution: From an in-VPC task with network access to RDS on port 5432
-- Master credentials sourced from Secrets Manager secret (see README for retrieval)
--
-- Example (secret ARN from the module's master_secret_arn output; RDS-managed
-- secrets are named rds!db-<uuid>, so always address them by ARN):
--   aws secretsmanager get-secret-value --secret-id <master_secret_arn> \
--     --query SecretString --output text | jq -r '.password' > /tmp/master_pass.txt
--   psql -h <db_endpoint> -U postgres -d vectordb -f bootstrap.sql
--
-- Note: pgvector on RDS PostgreSQL 16 requires no shared_preload_libraries configuration;
-- it is a plain extension that loads on CREATE EXTENSION.

-- Create pgvector extension (idempotent; IF NOT EXISTS)
CREATE EXTENSION IF NOT EXISTS vector;

-- Create app_user for application IAM database authentication
CREATE USER app_user WITH LOGIN;

-- Grant RDS IAM auth role (allows IAM tokens instead of passwords)
GRANT rds_iam TO app_user;

-- Grant connection to the initial database (IAM auth requires CONNECT)
GRANT CONNECT ON DATABASE vectordb TO app_user;

-- Grant schema permissions for RAG embeddings storage
GRANT USAGE, CREATE ON SCHEMA public TO app_user;
