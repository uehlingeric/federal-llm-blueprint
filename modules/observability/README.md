# Observability

Implements a log-group factory that ensures all CloudWatch Log Groups are encrypted with the logs KMS key and configured with mandatory retention policies. Establishes a baseline alarm suite for resource utilization and audit-plane health; creates a KMS-encrypted SNS topic for alarm notifications; and provides a CloudWatch dashboard for real-time visibility into LLM gateway and data pipeline health. Outputs export the alarm topic ARN, log-group ARNs keyed by component, and the dashboard name.

## Design Notes

The module decomposes observability into:

1. **SNS Alarm Fan-Out**: A KMS-encrypted SNS topic receives CloudWatch alarm and EventBridge publishes and fans out to email subscriptions (which require manual confirmation). Access is restricted by a least-privilege topic policy with source-account and source-ARN conditions.

2. **Log-Group Factory**: A mandatory caller-driven factory ensures all CloudWatch Log Groups carry KMS encryption and finite retention policies. Retention values are validated against AWS's allowed set; infinite retention (0) is forbidden to enforce audit compliance.

3. **Platform-Wide Telemetry**:
   - **RDS Vitals**: CPU, free storage, and connection count alarms (present only when `db_instance_id` is set).
   - **Endpoint Packet-Drop Canary**: Monitors VPC interface endpoints for dropped packets—the indicator of no-egress configuration failures. Dimensions include literal AWS-published keys (`VPC Id`, `VPC Endpoint Id`, `Service Name`).
   - **CloudTrail Tamper Detection**: Metric filter on CloudTrail events detects `StopLogging`, `DeleteTrail`, and `UpdateTrail` operations; triggers on any occurrence.
   - **Config Noncompliance Notification**: EventBridge rule captures AWS Config rule violations and publishes to the alarm topic.

4. **Dashboard**: When enabled (default), renders widgets for gateway traffic/latency/5xx, ECS task health, RDS vitals, and compliance/audit metrics. Widgets are conditionally included based on input variables (e.g., gateway widgets only when `alb_arn_suffix` is set).

## Module References and Composition

Gateway request-level alarms (5xx, unhealthy hosts, task count, latency p95) are owned by the `ecs-llm-gateway` module, which consumes this module's `alarm_topic_arn` to route notifications, while this module's dashboard consumes the gateway's ALB/cluster identifiers. The mutual module references are resource-acyclic — the SNS topic does not depend on the gateway, and the dashboard does not feed the gateway — so Terraform resolves the composition without cycles.

## Runbooks

Each alarm or event rule in this module has a two-minute first-response checklist.

### RDS CPU Alarm (`{project}-{environment}-rds-cpu`)

**Symptom**: CloudWatch alarm triggered on high CPU utilization.

**First Checks**:
1. Verify the RDS instance is running: `aws rds describe-db-instances --db-instance-identifier {db_instance_id} --query 'DBInstances[0].[DBInstanceStatus]'`
2. Identify long-running queries: `SELECT pid, state, now() - query_start AS runtime, query FROM pg_stat_activity WHERE state != 'idle' ORDER BY runtime DESC;`
3. Look at CloudWatch metrics for correlations: check FreeableMemory, SwapUsage, and I/O metrics in the same window.

**Remediation**: Cancel or terminate runaway queries (`pg_cancel_backend(pid)` / `pg_terminate_backend(pid)`); scale up instance class if baseline load exceeds capacity; check for missing indexes on frequently-queried tables (pgvector index health in particular).

### RDS Free Storage Alarm (`{project}-{environment}-rds-free-storage`)

**Symptom**: CloudWatch alarm triggered on low free storage space.

**First Checks**:
1. Query the current free space: `aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name FreeStorageSpace --dimensions Name=DBInstanceIdentifier,Value={db_instance_id} --start-time {time-3h} --end-time {now} --period 300 --statistics Average`
2. Find the largest relations: `SELECT schemaname, relname, pg_size_pretty(pg_total_relation_size(relid)) FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 10;`
3. Check dead-tuple bloat awaiting vacuum: `SELECT relname, n_dead_tup FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 10;`

**Remediation**: Vacuum bloated tables; drop unused indexes; increase allocated storage (a deliberate cost decision — see the week-8 cost documentation).

### RDS Connections Alarm (`{project}-{environment}-rds-connections`)

**Symptom**: CloudWatch alarm triggered on high connection count.

**First Checks**:
1. List active connections by user: `SELECT usename, state, count(*) FROM pg_stat_activity GROUP BY usename, state;`
2. Verify the instance ceiling: `SHOW max_connections;` and compare against the alarm threshold (module default 100 is a flat default — tune to the instance class).
3. Look for idle-in-transaction sessions that are not being cleaned up: `SELECT pid, now() - state_change FROM pg_stat_activity WHERE state = 'idle in transaction';`

**Remediation**: Tighten connection pooling in the application; terminate idle-in-transaction sessions; raise the parameter-group `max_connections` only after confirming memory headroom.

### Endpoint Packet-Drop Alarm (`{project}-{environment}-endpoint-drops-{service}`)

**Symptom**: CloudWatch alarm triggered on packet drops at a VPC interface endpoint.

**First Checks**:
1. Verify the endpoint is available: `aws ec2 describe-vpc-endpoints --vpc-endpoint-ids {vpce-id} --query 'VpcEndpoints[0].State'`
2. Get the endpoint's network interfaces, then check their security group: `aws ec2 describe-vpc-endpoints --vpc-endpoint-ids {vpce-id} --query 'VpcEndpoints[0].NetworkInterfaceIds'` followed by `aws ec2 describe-network-interfaces --network-interface-ids {eni-id} --query 'NetworkInterfaces[0].Groups'` — the endpoint SG must allow 443 from the VPC CIDR.
3. Check the endpoint policy and, in no-egress mode, confirm the dropped traffic is not a workload trying to reach a service with no endpoint (this is the canary's purpose).

**Remediation**: Fix the endpoint security group or endpoint policy; if a workload legitimately needs a new AWS service, add the interface endpoint in the network module rather than opening egress.

### CloudTrail Tamper Alarm (`{project}-{environment}-trail-tamper`)

**Symptom**: CloudWatch alarm triggered on CloudTrail modification.

**First Checks**:
1. Query CloudTrail logs for recent `StopLogging`, `DeleteTrail`, or `UpdateTrail` events: `aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=StopLogging --max-results 10`
2. Cross-reference the timestamp and principal ARN with on-call and change logs.
3. Verify the trail is still logging: `aws cloudtrail get-trail-status --name {trail-name}`

**Remediation**: If unexpected, re-enable CloudTrail logging immediately; investigate the principal and reason; file an incident.

### Config Noncompliance Event

**Symptom**: EventBridge rule publishes to SNS when AWS Config detects a noncompliant resource.

**First Checks**:
1. Query Config rules and their latest evaluation: `aws configservice describe-config-rules --query 'ConfigRules[].ConfigRuleName'`
2. List noncompliant resources: `aws configservice get-compliance-details-by-config-rule --config-rule-name {rule-name} --compliance-types NON_COMPLIANT`
3. Review the noncompliant resource's configuration and remediation action.

**Remediation**: Apply the remediation action (auto-remediation if configured); update the resource to match the rule; or update the rule if it's overly strict.

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
| [aws_cloudwatch_dashboard.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_dashboard) | resource |
| [aws_cloudwatch_event_rule.config_noncompliant](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.config_to_sns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_log_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_metric_filter.trail_tamper](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_metric_filter) | resource |
| [aws_cloudwatch_metric_alarm.endpoint_packet_drops](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.rds_connections](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.rds_cpu](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.rds_free_storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.trail_tamper](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_sns_topic.alarms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_policy.alarms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_policy) | resource |
| [aws_sns_topic_subscription.alarm_emails](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.alarms_topic_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| environment | Deployment environment | `string` | n/a | yes |
| logs\_kms\_key\_arn | ARN of the KMS key for encrypting log groups and SNS topic; passed from the kms module's logs key | `string` | n/a | yes |
| project | Project identifier | `string` | n/a | yes |
| alarm\_email\_addresses | Email addresses for SNS alarm subscriptions. Note: email endpoints require manual confirmation from the subscriber | `list(string)` | `[]` | no |
| alb\_arn\_suffix | ALB ARN suffix for dashboard gateway traffic metrics. When set, gateway request/latency/5xx widgets are rendered | `string` | `null` | no |
| cloudtrail\_log\_group\_name | CloudTrail log group name. When set, a metric filter and alarm for CloudTrail tamper detection are created | `string` | `null` | no |
| cluster\_name | ECS cluster name for dashboard task health metrics. When set, ECS CPU/memory widgets are rendered | `string` | `null` | no |
| data\_classification | Data classification level for tagging | `string` | `"cui"` | no |
| db\_instance\_id | RDS database instance identifier. When set, RDS alarms are created; when null, RDS alarms are omitted | `string` | `null` | no |
| enable\_dashboard | Whether to create a CloudWatch dashboard for observability | `bool` | `true` | no |
| interface\_endpoint\_ids | Map of AWS service short names to VPC Endpoint IDs for packet-drop canary alarms. Keys are service names (e.g., 'logs', 'kms'); values are endpoint IDs (e.g., 'vpce-0abc') | `map(string)` | `{}` | no |
| log\_groups | Log group factory input: map of component names to retention configuration. retention\_in\_days is mandatory (omitting it is a type error) and must be a finite value from CloudWatch's allowed set; infinite retention is not permitted | <pre>map(object({<br/>    retention_in_days = number<br/>  }))</pre> | `{}` | no |
| rds\_connections\_threshold | CloudWatch alarm threshold for RDS database connections. Flat default; tune to instance-class max\_connections | `number` | `100` | no |
| rds\_cpu\_threshold\_percent | CloudWatch alarm threshold for RDS CPU utilization (percent) | `number` | `80` | no |
| rds\_free\_storage\_threshold\_bytes | CloudWatch alarm threshold for RDS free storage space (bytes). Default: 10 GiB | `number` | `10737418240` | no |
| runbook\_url | When set, every alarm carries a RunbookUrl tag pointing to operational runbooks | `string` | `null` | no |
| service\_name | ECS service name for dashboard task health metrics. When set with cluster\_name, ECS health widgets are rendered | `string` | `null` | no |
| tags | Additional tags to apply to resources | `map(string)` | `{}` | no |
| target\_group\_arn\_suffix | Target group ARN suffix for dashboard gateway metrics. When set, TargetGroup dimension is added to gateway metric widgets | `string` | `null` | no |
| vpc\_id | VPC ID for endpoint packet-drop alarms. When set with interface\_endpoint\_ids, endpoint alarms are created | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| alarm\_topic\_arn | ARN of the SNS topic for alarm notifications |
| dashboard\_name | Name of the CloudWatch dashboard; null if enable\_dashboard is false |
| log\_group\_arns | ARNs of created log groups, keyed by component |
<!-- END_TF_DOCS -->
