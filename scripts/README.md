# Scripts

Operational scripts for the federal-llm-blueprint.

## seed-vectors.py

**Purpose**: One-time proof-of-concept script validating that pgvector works end-to-end in the vector store. Demonstrates table creation, vector insertion, and cosine-similarity search.

### Running In-VPC (Recommended)

The vector store database is isolated in a private VPC with no egress. The seed script must run inside the VPC through a one-off ECS task:

1. **Build or mirror a Docker image** with Python 3.11+, `psycopg[binary]`, and `boto3` + `numpy`:
   ```bash
   # Option 1: Use a mirrored Python slim image with pre-installed dependencies
   # (See examples/minimal/README.md for the ECR mirror procedure)
   
   # Option 2: Build a custom Dockerfile. Bake the RDS CA bundle into the image —
   # the no-egress VPC cannot download it at runtime.
   cat > Dockerfile <<'EOF'
   FROM python:3.12-slim
   RUN pip install --no-cache-dir psycopg[binary] boto3 numpy
   ADD https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /app/rds-bundle.pem
   ENV SSL_CERT_PATH=/app/rds-bundle.pem
   COPY scripts/seed-vectors.py /app/seed-vectors.py
   ENTRYPOINT ["python3", "/app/seed-vectors.py"]
   EOF
   docker build -t seed-vectors:latest .
   aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com
   docker tag seed-vectors:latest <account>.dkr.ecr.<region>.amazonaws.com/seed-vectors:latest
   docker push <account>.dkr.ecr.<region>.amazonaws.com/seed-vectors:latest
   ```

2. **Run the task** in the ECS cluster. The task runs in the **app** security group (the DB security group only admits traffic *from* the app SG):
   ```bash
   # Retrieve outputs from the example
   CLUSTER_ARN=$(terraform -chdir=examples/minimal output -raw cluster_arn)
   CLUSTER_NAME=$(echo "$CLUSTER_ARN" | cut -d/ -f2)
   SUBNET=$(terraform -chdir=examples/minimal output -json private_subnet_ids | jq -r '.[0]')
   SG=$(terraform -chdir=examples/minimal output -raw app_security_group_id)
   DB_HOST=$(terraform -chdir=examples/minimal output -raw db_endpoint)
   
   # Get database credentials from Secrets Manager (RDS-managed secret contains
   # only username and password — the host comes from the db_endpoint output)
   SECRET_ARN=$(terraform -chdir=examples/minimal output -raw db_master_secret_arn)
   SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text)
   DB_USER=$(echo "$SECRET_JSON" | jq -r '.username')
   DB_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.password')
   
   # Run the task
   aws ecs run-task \
     --cluster "$CLUSTER_NAME" \
     --task-definition seed-vectors:1 \
     --launch-type FARGATE \
     --network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$SG]}" \
     --overrides "containerOverrides=[{name=seed-vectors,environment=[\
       {name=DB_HOST,value=$DB_HOST},\
       {name=DB_USER,value=$DB_USER},\
       {name=DB_PASSWORD,value=$DB_PASSWORD},\
       {name=DB_PORT,value=5432},\
       {name=DB_NAME,value=vectordb},\
       {name=AUTH_MODE,value=password},\
       {name=AWS_REGION,value=us-east-1}\
     ]}]"
   ```

3. **Monitor task logs** in CloudWatch or through the ECS console.

### Running Locally Against a Tunnel (Sandbox Only)

In a development environment, you may temporarily forward a tunnel to the database. **Do NOT do this in production** — the vector store database has no public access and should remain isolated:

```bash
# This requires an instance with Systems Manager Session Manager access
# (not available in the no-egress sandbox — use the in-VPC task method above instead)
```

### Environment Variables

- **DB_HOST** (required): Database hostname or IP
- **DB_PORT** (optional, default: 5432): PostgreSQL port
- **DB_NAME** (optional, default: vectordb): Database name
- **DB_USER** (optional, default: app_user): Database user
- **AUTH_MODE** (optional, default: iam): Authentication mode — `iam` or `password`
- **DB_PASSWORD** (required if AUTH_MODE=password): Plaintext password
- **AWS_REGION** (optional, default: us-east-1): AWS region (used for IAM auth token generation)
- **SSL_CERT_PATH** (optional, default: /tmp/rds-bundle.pem): Path to RDS global certificate bundle (IAM auth mode only)

### IAM Auth Mode

When AUTH_MODE=iam:

1. The script generates an ephemeral authentication token using `boto3.client('rds').generate_db_auth_token()`.
2. The token is valid for 15 minutes.
3. Requires `rds-db:connect` IAM permission scoped to the database instance and user.
4. Enforces TLS with certificate verification (sslmode=verify-full and the RDS global bundle).

Download the RDS global certificate bundle if not present:

```bash
curl -o /tmp/rds-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
```

### Script Behavior

1. Connects to the database and creates the `embeddings` table and an HNSW index for cosine distance (both idempotent via `IF NOT EXISTS`).
2. **Truncates** any existing data (`TRUNCATE TABLE embeddings`) to ensure idempotency.
3. Inserts 8 deterministic sample vectors (8-dimensional; real embeddings are 256–3072 dims).
4. Runs a cosine-similarity search (`<=>` operator) and retrieves the 3 nearest neighbors.
5. Asserts that the expected nearest neighbor (id=1, the probe vector itself) comes back first.
6. Exits 0 on success, 1 on failure.

Each step is logged with a `[seed]` prefix for clarity in CI/CD transcripts.

### See Also

- `docs/verification/vector-proof.md`: Full verification procedure and expected outputs
- `examples/minimal/README.md`: Vector store bootstrap instructions
- `modules/vector-store/README.md`: Database module documentation
