# Audit Walkthrough — Verification Procedure

## Status

- **Static proof:** Automated in CI via `modules/audit/tests/*.tftest.hcl` assertions — runs on every PR, validates variable wiring, encryption settings, log group names. No credentials required.
- **Dynamic proof:** PENDING first sandbox execution — transcripts and outputs below are placeholders to be filled on initial deploy.

---

## Claim

When the `audit` module is deployed into the `examples/minimal` stack (week 6):

- CloudTrail logs all control-plane API calls (management events) and documents-bucket S3 object access (data events) into the audit bucket and CloudWatch Logs group, with log-file validation enabled.
- Bedrock model-invocation metadata (principal identity, model ID, timestamp, token counts) is logged to a CloudWatch Logs group by default (full content optional via `enable_full_content_logging`).
- AWS Config monitors resource encryption (EBS volumes, RDS storage), public accessibility, SSH ingress, and key rotation; noncompliance events trigger EventBridge → SNS alarm notifications.
- An auditor with CloudTrail, CloudWatch Logs, and AWS Config permissions can answer: "Who accessed document X?", "What models did role Y invoke yesterday?", and "Did any resources drift out of compliance?" without access to the documents bucket or application code.

---

## Static Proof (Automated in CI)

The audit module includes native Terraform test assertions in `modules/audit/tests/`:

- `trail_and_bucket.tftest.hcl`: Asserts the trail is multi-region with global events and log-file validation on, S3 key prefix "cloudtrail", KMS encryption from the logs CMK, data-event selectors scoped to the documents bucket, Insights off by default; audit bucket SSE-KMS (logs CMK) with bucket keys, versioning, public-access block all-true, object lock on by default, server-access logging to the access-logs bucket under `audit/`, and the CloudTrail/Config/Bedrock bucket-policy statements present.
- `config_and_bedrock.tftest.hcl`: Asserts the Config recorder records all supported types, the delivery channel writes to the audit bucket under `config/` with KMS, exactly 10 managed rules exist with "Aligns to NIST 800-53" descriptions; Bedrock invocation logging defaults to metadata-only (all `*_data_delivery_enabled` false), flips with `enable_full_content_logging`, and is absent when `enable_bedrock_invocation_logging = false`.
- `validation.tftest.hcl`: Asserts plan-time rejection of invalid variables (retention values outside the CloudWatch allowed set, audit-log expiration not greater than object-lock retention, invalid project/environment/data_classification, invalid Config snapshot frequency).

These run on every PR (mocked AWS providers, no credentials needed). Passing CI green confirms static audit infrastructure wiring.

---

## Dynamic Proof Procedure

This procedure proves that CloudTrail, Bedrock, and Config logs are recorded and queryable. An auditor with the minimal read permissions (CloudTrail, CloudWatch Logs, AWS Config, CloudTrail S3 object access) can perform all three questions.

### Prerequisites

- AWS credentials with permissions to:
  - Read CloudTrail events via `cloudtrail:LookupEvents` (does NOT include S3 data events; you need S3 object-level CloudTrail in the audit bucket)
  - Read CloudWatch Logs via `logs:DescribeLogGroups`, `logs:DescribeLogStreams`, `logs:GetLogEvents`
  - Execute CloudWatch Logs Insights queries: `logs:StartQuery`, `logs:GetQueryResults`
  - Read AWS Config: `config:DescribeComplianceByConfigRule`, `config:GetResourceConfigHistory`
  - (Optional) Query Athena on the audit bucket to analyze CloudTrail at scale
- Terraform CLI >= 1.9
- AWS CLI v2
- `jq` for JSON parsing

### Cost Note

This procedure should complete (apply → queries → destroy) in approximately 30–45 minutes on top of a deployed `examples/minimal` stack — the audit module depends on the document-store buckets, so there is no audit-only deployment. Cost drivers while deployed: the RDS instance and Fargate task dominate; the audit plane adds S3 data events on the documents bucket, Config configuration items, and CloudWatch Logs ingestion. The drill's 10 GiB test volume exists for minutes. Measured costs are a week-8 deliverable; no dollar estimates are made here.

---

### Step 0: Deploy Minimal Stack with Audit Module

Initialize and apply the `examples/minimal` stack (the audit and observability modules are always part of the composition). Account ID placeholder: `123456789012`, region: `us-east-1`. See the example's README for the full `terraform.tfvars` (gateway container image digest, ECR repository ARNs, and certificate settings are required inputs).

```bash
cd examples/minimal
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Expected output: the full stack deploys (RDS is the long pole). Capture the audit-plane outputs:

```
# TRANSCRIPT PENDING
Outputs:

audit_bucket_id = "fedllm-dev-audit-logs-123456789012"
audit_log_group_name = "/aws/fedllm-dev/cloudtrail"
bedrock_log_group_name = "/aws/fedllm-dev/bedrock-invocations"
config_recorder_name = "fedllm-dev-config"
trail_arn = "arn:aws:cloudtrail:us-east-1:123456789012:trail/fedllm-dev-trail"
```

---

## Question 1: Who accessed document X?

**Auditor Question:** "I need a record of all principals that read or modified document `reports/q2-summary-cui.pdf` from the documents bucket in the last 24 hours."

**Evidence Source:** CloudTrail S3 data events on the documents bucket.

**Limitation:** `aws cloudtrail lookup-events` does **NOT** return S3 data events. You must query CloudWatch Logs Insights (if CloudTrail is configured to stream logs to CloudWatch) or use Athena to scan the CloudTrail S3 bucket.

### Option 1: CloudWatch Logs Insights Query

CloudTrail writes events to CloudWatch Logs group `/aws/fedllm-dev/cloudtrail`. S3 data events have `eventSource = "s3.amazonaws.com"`.

```bash
# Query the CloudTrail log group for S3 data events on the documents bucket in the last 24 hours
aws logs start-query \
  --log-group-name "/aws/fedllm-dev/cloudtrail" \
  --start-time $(( $(date +%s) - 86400 )) \
  --end-time $(date +%s) \
  --query-string 'fields @timestamp, eventName, userIdentity.arn, requestParameters.bucketName, requestParameters.key, sourceIPAddress
  | filter eventSource = "s3.amazonaws.com"
  | filter requestParameters.bucketName = "fedllm-dev-documents-123456789012"
  | filter requestParameters.key like /reports\/q2-summary-cui.pdf/
  | sort @timestamp desc' \
  --region us-east-1
```

This returns a `queryId`. Poll for results:

```bash
QUERY_ID="<returned-queryId>"
aws logs get-query-results \
  --query-id "$QUERY_ID" \
  --region us-east-1 \
  --output json | jq '.results'
```

**Expected result:** A table of S3 GetObject / PutObject / DeleteObject events on that object, with timestamps and principal ARNs.

```
# TRANSCRIPT PENDING
[
  ["2026-07-04T14:35:22Z", "GetObject", "arn:aws:iam::123456789012:role/fedllm-dev-app", "fedllm-dev-documents-123456789012", "reports/q2-summary-cui.pdf", "10.0.1.42"],
  ["2026-07-04T14:36:01Z", "GetObject", "arn:aws:iam::123456789012:role/fedllm-dev-app", "fedllm-dev-documents-123456789012", "reports/q2-summary-cui.pdf", "10.0.1.42"]
]
```

### Option 2: Athena Query (At-Scale Alternative)

For production, use Athena to query the CloudTrail S3 bucket directly. CloudTrail writes to `s3://fedllm-dev-audit-logs-123456789012/cloudtrail/AWSLogs/...` with JSON objects. Create an Athena table and query it:

```bash
# Create Athena table (one-time setup; DDL follows the AWS-documented
# CloudTrail SerDe pattern — see "Querying AWS CloudTrail logs" in the Athena docs)
aws athena start-query-execution \
  --query-string 'CREATE EXTERNAL TABLE cloudtrail_logs (
    eventVersion STRING,
    eventId STRING,
    eventTime STRING,
    eventSource STRING,
    eventName STRING,
    userIdentity STRUCT<
      type: STRING,
      arn: STRING,
      principalId: STRING>,
    requestParameters STRING,
    responseElements STRING,
    sourceIPAddress STRING
  ) PARTITIONED BY (region STRING, year STRING, month STRING, day STRING)
  ROW FORMAT SERDE "com.amazon.emr.hive.serde.CloudTrailSerde"
  STORED AS INPUTFORMAT "com.amazon.emr.cloudtrail.CloudTrailInputFormat"
  OUTPUTFORMAT "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
  LOCATION "s3://fedllm-dev-audit-logs-123456789012/cloudtrail/AWSLogs/123456789012/CloudTrail/"
  ' \
  --result-configuration 'OutputLocation=s3://fedllm-dev-audit-logs-123456789012/athena-results/' \
  --region us-east-1
```

Then query:

```bash
aws athena start-query-execution \
  --query-string "SELECT eventtime, eventname, useridentity.arn, sourceipaddress
  FROM cloudtrail_logs
  WHERE eventsource = 's3.amazonaws.com'
  AND requestparameters LIKE '%q2-summary-cui.pdf%'
  AND year = '2026' AND month = '07' AND day = '04'
  " \
  --result-configuration 'OutputLocation=s3://<your-athena-results-bucket>/' \
  --region us-east-1
```

Point `OutputLocation` at a separate scratch bucket — do not write query results into the audit bucket, whose lifecycle and object-lock rules are sized for log delivery only.

Wait for execution:

```bash
EXECUTION_ID="<returned-QueryExecutionId>"
aws athena get-query-execution \
  --query-execution-id "$EXECUTION_ID" \
  --region us-east-1
```

**Status:** Illustrative — TRANSCRIPT PENDING (requires documents bucket and sample access).

---

## Question 2: What models did role Y invoke yesterday, and how many tokens?

**Auditor Question:** "Show me all Bedrock model invocations by the role `arn:aws:iam::123456789012:role/fedllm-dev-app` in the last 24 hours, grouped by model, with total token counts."

**Evidence Source:** Bedrock model-invocation logs in CloudWatch Logs group `/aws/fedllm-dev/bedrock-invocations` (created and enabled by the audit module).

### CloudWatch Logs Insights Query

```bash
# Query Bedrock invocation logs for a specific role over the last 24 hours
aws logs start-query \
  --log-group-name "/aws/fedllm-dev/bedrock-invocations" \
  --start-time $(( $(date +%s) - 86400 )) \
  --end-time $(date +%s) \
  --query-string 'fields schemaType, timestamp, modelId, identity.arn, input.inputTokenCount, output.outputTokenCount
  | filter identity.arn = "arn:aws:iam::123456789012:role/fedllm-dev-app"
  | stats sum(input.inputTokenCount) as total_input_tokens, sum(output.outputTokenCount) as total_output_tokens, count() as invocation_count by modelId, identity.arn
  | sort invocation_count desc' \
  --region us-east-1
```

This returns a `queryId`. Poll for results:

```bash
QUERY_ID="<returned-queryId>"
# Wait for query to complete (status = "Complete")
for i in {1..30}; do
  STATUS=$(aws logs get-query-results --query-id "$QUERY_ID" --region us-east-1 --query 'status' --output text)
  if [ "$STATUS" = "Complete" ]; then
    aws logs get-query-results --query-id "$QUERY_ID" --region us-east-1 --output json | jq '.results[] | @csv'
    break
  fi
  echo "Query status: $STATUS, waiting..."
  sleep 2
done
```

**Expected result:** A table of models invoked, grouped by model, with token counts and invocation count.

```
# TRANSCRIPT PENDING
modelId,total_input_tokens,total_output_tokens,invocation_count,identity.arn
anthropic.claude-sonnet-4-5-20250929-v1:0,12500,8900,42,arn:aws:iam::123456789012:role/fedllm-dev-app
```

Interpretation: The `fedllm-dev-app` role invoked the Sonnet model 42 times in the last 24 hours, sending 12,500 tokens and receiving 8,900 tokens.

---

## Question 3: Did any resources drift out of compliance?

**Auditor Question:** "Show me the compliance status of all Config rules. If any are NON_COMPLIANT, list the noncompliant resources and the timeline of when they drifted."

**Evidence Source:** AWS Config rule compliance and resource configuration history.

### Step 3a: Describe Compliance by Config Rule

```bash
# List all Config rules and their compliance status
aws configservice describe-compliance-by-config-rule \
  --region us-east-1 \
  --output json | jq '.ComplianceByConfigRules[] | {
    ConfigRuleName,
    Compliance: .Compliance.ComplianceType
  }'
```

**Expected result:** A list of config rules and their compliance status (COMPLIANT or NON_COMPLIANT).

```
# TRANSCRIPT PENDING
{
  "ConfigRuleName": "fedllm-dev-encrypted-volumes",
  "Compliance": "COMPLIANT"
}
{
  "ConfigRuleName": "fedllm-dev-rds-storage-encrypted",
  "Compliance": "COMPLIANT"
}
{
  "ConfigRuleName": "fedllm-dev-rds-instance-public-access-check",
  "Compliance": "COMPLIANT"
}
{
  "ConfigRuleName": "fedllm-dev-s3-bucket-public-read-prohibited",
  "Compliance": "COMPLIANT"
}
{
  "ConfigRuleName": "fedllm-dev-s3-bucket-public-write-prohibited",
  "Compliance": "COMPLIANT"
}
{
  "ConfigRuleName": "fedllm-dev-s3-bucket-ssl-requests-only",
  "Compliance": "COMPLIANT"
}
{
  "ConfigRuleName": "fedllm-dev-cloud-trail-log-file-validation-enabled",
  "Compliance": "COMPLIANT"
}
{
  "ConfigRuleName": "fedllm-dev-iam-policy-no-statements-with-admin-access",
  "Compliance": "COMPLIANT"
}
{
  "ConfigRuleName": "fedllm-dev-restricted-ssh",
  "Compliance": "COMPLIANT"
}
{
  "ConfigRuleName": "fedllm-dev-cmk-backing-key-rotation-enabled",
  "Compliance": "COMPLIANT"
}
```

### Step 3b: Get Resource Configuration History (for any NON_COMPLIANT rule)

If a rule shows NON_COMPLIANT, retrieve the timeline of when the resource drifted. Config addresses resources by its own `resourceId` — discover it first rather than guessing:

```bash
# Find the Config resourceId for the RDS instance
aws configservice list-discovered-resources \
  --resource-type AWS::RDS::DBInstance \
  --region us-east-1 \
  --output json | jq '.resourceIdentifiers'

# Then pull the configuration timeline
aws configservice get-resource-config-history \
  --resource-type AWS::RDS::DBInstance \
  --resource-id "<resourceId-from-above>" \
  --region us-east-1 \
  --output json | jq '.ConfigurationItems[] | {
    configurationItemCaptureTime,
    configurationItemStatus,
    resourceType,
    resourceId,
    configuration: .configuration | {
      storageEncrypted: .storageEncrypted
    }
  }'
```

**Expected result:** A timeline of configuration snapshots, showing when StorageEncrypted changed.

```
# TRANSCRIPT PENDING
{
  "configurationItemCaptureTime": "2026-07-04T12:00:00Z",
  "configurationItemStatus": "OK",
  "resourceType": "AWS::RDS::DBInstance",
  "resourceId": "db-ABCDEFGHIJKL0123456789",
  "configuration": {
    "storageEncrypted": true
  }
}
{
  "configurationItemCaptureTime": "2026-07-04T14:35:22Z",
  "configurationItemStatus": "ResourceDeleted",
  "resourceType": "AWS::RDS::DBInstance",
  "resourceId": "db-ABCDEFGHIJKL0123456789"
}
```

### Step 3c: Verify EventBridge → SNS Notification Path

When a rule changes to NON_COMPLIANT, the `fedllm-dev-config-noncompliant` EventBridge rule fires and sends a notification to the SNS topic. Verify the rule exists and is wired:

```bash
# List EventBridge rules
aws events list-rules \
  --name-prefix "fedllm-dev-config-noncompliant" \
  --region us-east-1 \
  --output json | jq '.Rules[0] | {
    Name,
    State,
    EventPattern: .EventPattern
  }'
```

**Expected result:**

```
# TRANSCRIPT PENDING
{
  "Name": "fedllm-dev-config-noncompliant",
  "State": "ENABLED",
  "EventPattern": "{\"source\":[\"aws.config\"],\"detail-type\":[\"Config Rules Compliance Change\"],\"detail\":{\"newEvaluationResult\":{\"complianceType\":[\"NON_COMPLIANT\"]}}}"
}
```

Verify SNS targets:

```bash
aws events list-targets-by-rule \
  --rule "fedllm-dev-config-noncompliant" \
  --region us-east-1 \
  --output json | jq '.Targets[0].Arn'
```

**Expected result** (no target role — the SNS topic policy authorizes events.amazonaws.com directly):

```
# TRANSCRIPT PENDING
"arn:aws:sns:us-east-1:123456789012:fedllm-dev-alarms"
```

---

## Verification Checklist: Intentional Drift Drill

To prove the compliance monitoring chain end-to-end, simulate an intentional compliance violation (create an unencrypted EBS volume), verify that Config flags it as NON_COMPLIANT, and check that EventBridge fires.

### Prerequisites

- Same AWS credentials as above
- EC2 permissions to create/delete volumes

### Drill: Create Unencrypted Volume, Trigger Config Evaluation

```bash
# Step 1: Create an unencrypted EBS volume (intentional violation)
VOLUME_ID=$(aws ec2 create-volume \
  --size 10 \
  --region us-east-1 \
  --availability-zone us-east-1a \
  --no-encrypted \
  --output text \
  --query 'VolumeId')

echo "Created unencrypted volume: $VOLUME_ID"

# Add tags so Config can find it
aws ec2 create-tags \
  --resources "$VOLUME_ID" \
  --tags "Key=Project,Value=fedllm" "Key=Environment,Value=dev" \
  --region us-east-1

# Step 2: Trigger Config evaluation manually (optional; Config runs on schedule)
aws configservice start-config-rules-evaluation \
  --config-rule-names "fedllm-dev-encrypted-volumes" \
  --region us-east-1

# Step 3: Wait for Config to evaluate (60–120 seconds)
echo "Waiting for Config evaluation..."
sleep 90

# Step 4: Check compliance status
aws configservice describe-compliance-by-config-rule \
  --config-rule-names "fedllm-dev-encrypted-volumes" \
  --region us-east-1 \
  --output json | jq '.ComplianceByConfigRules[0]'
```

**Expected result:** The rule should show NON_COMPLIANT, with the new unencrypted volume listed as a noncompliant resource.

```
# TRANSCRIPT PENDING
{
  "ConfigRuleName": "fedllm-dev-encrypted-volumes",
  "Compliance": {
    "ComplianceType": "NON_COMPLIANT",
    "ComplianceContributorCount": {
      "CappedCount": 1,
      "CapExceeded": false
    }
  }
}
```

### Drill Cleanup: Delete Unencrypted Volume

```bash
# Delete the test volume
aws ec2 delete-volume \
  --volume-id "$VOLUME_ID" \
  --region us-east-1

echo "Deleted volume $VOLUME_ID"

# Trigger evaluation again to verify compliance returns
aws configservice start-config-rules-evaluation \
  --config-rule-names "fedllm-dev-encrypted-volumes" \
  --region us-east-1

sleep 90

# Verify compliance is back to COMPLIANT
aws configservice describe-compliance-by-config-rule \
  --config-rule-names "fedllm-dev-encrypted-volumes" \
  --region us-east-1 \
  --output json | jq '.ComplianceByConfigRules[0].Compliance.ComplianceType'
```

**Expected result:**

```
# TRANSCRIPT PENDING
"COMPLIANT"
```

---

## Summary

An auditor with CloudTrail, CloudWatch Logs, and AWS Config permissions can:

1. **Q1 (Document Access):** Query CloudTrail S3 data events in CloudWatch Logs Insights or Athena to answer "Who accessed document X?" — requires documents bucket to be deployed.

2. **Q2 (Model Invocations):** Query Bedrock logs in CloudWatch Logs Insights to answer "What models did role Y invoke?" — metadata is always available; full content requires opt-in via `enable_full_content_logging`.

3. **Q3 (Drift Detection):** Use AWS Config compliance rules and resource config history to answer "Did resources stay compliant?" — noncompliance triggers EventBridge → SNS notifications automatically.

**All three audit planes are wired and queryable without application-layer access.** This is week-6 exit criterion.
