# No-Egress Proof — Verification Procedure

## Status

- **Static proof:** Automated in CI via `modules/network/tests/*.tftest.hcl` assertions — runs on every PR, no credentials required.
- **Dynamic proof:** PENDING first sandbox execution — transcripts below are placeholders to be filled on initial deploy.

---

## Claim

When `no_egress = true`:
- Zero Internet Gateway, NAT Gateway, Elastic IP, and public-subnet resources created
- Workloads inside the VPC reach allow-listed AWS services (Bedrock, S3, ECR, KMS, etc.) via private VPC endpoints with private DNS resolution
- Any internet destination is provably unreachable (no route, no NAT escape path)

---

## Static Proof (Automated in CI)

The network module includes native Terraform test assertions in `modules/network/tests/`:

- `no_egress.tftest.hcl`: Asserts `count(aws_internet_gateway) = 0`, `count(aws_nat_gateway) = 0`, `count(aws_eip) = 0` when `no_egress = true`
- `routes.tftest.hcl`: Asserts all private route tables contain zero routes to `0.0.0.0/0`
- `endpoints.tftest.hcl`: Asserts all required interface endpoints exist with `private_dns_enabled = true`

These run on every PR with plan-only assertions (no AWS credentials needed). Passing CI green confirms the static shape.

---

## Dynamic Proof Procedure

This procedure proves reachability (S3 via endpoint) and unreachability (internet) from inside a no-egress VPC at runtime.

### Prerequisites

- AWS credentials with admin access to a sandbox account
- Terraform CLI >= 1.5
- AWS CLI v2
- Session Manager plugin installed (`aws-cli-v2/sessionmanagerplugin/install`)

### Cost Note

Interface endpoints cost ~$0.01/hour each. This procedure should complete (apply → probe → destroy) in under 2 hours. Recommend running in a single-day window; endpoint-hours are the dominant cost.

---

### Step 1: Deploy Minimal Stack in No-Egress Mode

Initialize and apply with `no_egress = true`. Account ID placeholder: `123456789012`, region: `us-east-1`.

```bash
cd examples/minimal
cat > terraform.tfvars <<'EOF'
project      = "federal-llm"
environment  = "sandbox"
no_egress    = true
vpc_cidr     = "10.0.0.0/16"
region       = "us-east-1"
tags = {
  Purpose = "no-egress-proof"
}
EOF

terraform init
terraform plan -out=tfplan

# Review the plan. Expected: network module creates 11 interface endpoints (default map), 1 S3 gateway endpoint, zero IGW/NAT.
# Estimated cost: $0.11/hour per AZ (11 endpoints × $0.01/endpoint-hr/AZ) — $0.22/hour at az_count = 2.

terraform apply tfplan
```

Expected output: Stack deploys. Capture the network module outputs, especially `vpc_id`, `private_subnet_ids`, `app_security_group_id`.

```
# TRANSCRIPT PENDING
Outputs:

vpc_id = "vpc-0123456789abcdef0"
private_subnet_ids = ["subnet-...", "subnet-..."]
app_security_group_id = "sg-..."
```

### Step 2: Add SSM Endpoints (Temporary for Test)

The default endpoint map in `modules/network` includes `ssm` (the gateway task fetches its configuration through it) but not the Session Manager channel endpoints (`ssmmessages`, `ec2messages`) — those are needed only for this probe.

Temporarily add them to your `terraform.tfvars` (the map is logical-name → service suffix; restate the defaults you keep):

```bash
cat >> terraform.tfvars <<'EOF'

# Temporary: add Session Manager channel endpoints for probe connectivity only.
# Remove after this test completes.
interface_endpoints = {
  ssm         = "ssm"
  ssmmessages = "ssmmessages"
  ec2messages = "ec2messages"
  # ... plus the existing entries from the module default map
}
EOF

terraform apply
# Creates 2 additional endpoints (~$0.02/hr more).
```

### Step 3: Launch Probe Instance

Create a t4g.nano EC2 instance with SSM agent in a private subnet, using the app security group.

```bash
# Retrieve VPC and subnet details from state:
VPC_ID=$(terraform output -raw vpc_id)
SUBNET_ID=$(terraform output -json private_subnet_ids | jq -r '.[0]')
SG_ID=$(terraform output -raw app_security_group_id)

# Launch probe. Use the official SSM Agent AMI (e.g., amzn2-ami-hvm-*.5-arm64-gp2) or a custom image with ssm-agent.
# For simplicity, this example uses the AWS-provided Systems Manager Fleet manager;
# alternatively, use the public AL2 AMI with ssm-agent pre-installed.

aws ec2 run-instances \
  --image-id ami-0c02fb55c4e63e6ca \
  --instance-type t4g.nano \
  --iam-instance-profile Name=ec2-ssm-role \
  --security-group-ids "$SG_ID" \
  --subnet-id "$SUBNET_ID" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=no-egress-probe}]' \
  --region us-east-1

# Note: You must have an IAM role `ec2-ssm-role` with `AmazonSSMManagedInstanceCore` policy attached.
# If it doesn't exist:
# aws iam create-role --role-name ec2-ssm-role --assume-role-policy-document file:///dev/stdin <<'POLICY'
# {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
# POLICY
# aws iam attach-role-policy --role-name ec2-ssm-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# Wait for instance to reach running state and SSM agent to be "online" (60–90 seconds).
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=no-egress-probe" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

aws ssm start-session --target "$INSTANCE_ID" --region us-east-1
```

Expected: Session Manager opens an interactive shell inside the probe instance (no SSH key needed).

```
# TRANSCRIPT PENDING
[ssm-user@ip-10-0-1-xxx]$
```

### Step 4: Positive Controls (Reachability via Endpoints)

From inside the probe session, verify S3 and KMS are reachable via their endpoints.

```bash
# Control 1: S3 gateway endpoint via private DNS
aws s3 ls --region us-east-1

# Expected: succeeds (may list no buckets if none exist in account; that's OK).
# Lists buckets or returns empty list.
```

```
# TRANSCRIPT PENDING
2026-07-04 16:30:15 example-doc-bucket
2026-07-04 16:29:50 example-log-bucket
```

```bash
# Control 2: KMS interface endpoint
aws kms list-keys --region us-east-1

# Expected: succeeds; returns key listing or empty list.
```

```
# TRANSCRIPT PENDING
{
    "Keys": []
}
```

### Step 5: Negative Controls (Unreachability to Internet)

From inside the probe session, verify internet destinations are unreachable.

```bash
# Control 3: Attempt to reach public internet (expect timeout, no route).
timeout 10 curl -v https://example.com

# Expected: times out or "No route to host" after ~10 seconds.
# Do NOT expect a clean connection or HTTP response.
```

```
# TRANSCRIPT PENDING
*   Trying 93.184.216.34:443...
*   % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
*     0     0    0     0    0     0      0      0 --:-- --:-- --:--  --:--  -- 0
* connect to 93.184.216.34 port 443 failed: No route to host
* Closing connection 0
curl: (7) Failed to connect to example.com port 443: No route to host
```

```bash
# Control 4: DNS resolution (expected to work; connectivity is the negative).
dig example.com +short

# Expected: resolves to public IP (e.g., 93.184.216.34).
# This is OK: Route 53 resolver is VPC-internal (not an internet path).
# The key proof is that the resolved IP is unreachable (see Control 3).
```

```
# TRANSCRIPT PENDING
93.184.216.34
```

**Why DNS resolution succeeds while connectivity fails:** The VPC has an internal Route 53 resolver (part of the VPC DNS); it forwards queries to AWS-managed resolvers, which return correct public IPs. However, no route exists in the route table to reach those IPs — they are not on the VPC CIDR and not reachable via any endpoint. This is expected and proves isolation is working.

### Step 6: Route Table Evidence

From your local machine (exit the probe session), inspect route tables directly via AWS CLI.

```bash
# Exit the probe session first.
exit

# Retrieve route table IDs for private subnets.
ROUTE_TABLE_IDS=$(terraform output -json private_route_table_ids | jq -r '.[]')

# Inspect each route table.
for rt in $ROUTE_TABLE_IDS; do
  aws ec2 describe-route-tables --route-table-ids "$rt" \
    --query 'RouteTables[0].Routes' \
    --region us-east-1
done

# Expected: each route table contains only local routes (10.0.0.0/16 → local)
# and endpoint routes (e.g., pl-12345678 → vpce-xxx for S3).
# Zero routes to 0.0.0.0/0.
```

```
# TRANSCRIPT PENDING
[
    {
        "DestinationCidrBlock": "10.0.0.0/16",
        "GatewayId": "local"
    },
    {
        "DestinationPrefixListId": "pl-12345678",
        "State": "blackhole",
        "VpcEndpointId": "vpce-0abc123def456"
    }
]
```

```bash
# Verify no Internet Gateway exists in the VPC.
aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --region us-east-1

# Expected: empty Gateways list.
```

```
# TRANSCRIPT PENDING
{
    "InternetGateways": []
}
```

```bash
# Verify no NAT Gateways exist.
aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
  --region us-east-1

# Expected: empty NatGateways list.
```

```
# TRANSCRIPT PENDING
{
    "NatGateways": []
}
```

---

### Step 7: Teardown

```bash
# Remove temporary SSM endpoints from tfvars (clean up).
# Edit terraform.tfvars, remove the interface_endpoints block added in Step 2.

terraform apply

# Destroy the stack.
terraform destroy -auto-approve
```

**Known Gotcha:** Interface endpoint ENIs can linger in EC2 after SG/subnet deletion attempts. If destroy fails with "cannot delete subnet — dependency violation," wait 2–3 minutes and retry:

```bash
sleep 180
terraform destroy -auto-approve
```

Verify cleanup:

```bash
# Confirm no dangling network interfaces remain.
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[*].[NetworkInterfaceId,Status]' \
  --region us-east-1

# Expected: empty list after destroy completes.
```

---

## Summary

If all controls pass:
- **Positive:** S3 and KMS calls succeed (prove endpoint routing works)
- **Negative:** Internet curl timeouts and no 0.0.0.0/0 routes in tables (prove egress is blocked)
- **Static:** CI assertions confirm zero IGW/NAT at plan time
- **Claim proven:** No-egress mode is a testable, provable architecture property, not an assumption.

Transcripts from the first sandbox run should be committed to this document (replace the `# TRANSCRIPT PENDING` blocks) to form a permanent record of the proof.
