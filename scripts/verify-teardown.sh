#!/bin/bash
#
# verify-teardown.sh — Post-destroy billable resource sweeper (READ-ONLY)
#
# This script verifies that no billable AWS resources remain after a `terraform destroy`
# of a federal-llm-blueprint example composition. It performs ONLY AWS read-only
# operations: list/describe/get calls. It never creates, modifies, or deletes any
# resources — strict read-only guarantee.
#
# Usage: verify-teardown.sh -p <project> -e <environment> [-r <region>]
#
# Exit codes:
#   0  — No billable resources found (residue count == 0)
#   1  — Billable resources found (residue count > 0)
#   2  — Usage error (missing required flag or unknown flag)

set -euo pipefail

PROJECT=""
ENVIRONMENT=""
REGION="${AWS_REGION:-}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      shift
      PROJECT="$1"
      shift
      ;;
    -e)
      shift
      ENVIRONMENT="$1"
      shift
      ;;
    -r)
      shift
      REGION="$1"
      shift
      ;;
    -*)
      echo "Usage: verify-teardown.sh -p <project> -e <environment> [-r <region>]" >&2
      exit 2
      ;;
    *)
      echo "Usage: verify-teardown.sh -p <project> -e <environment> [-r <region>]" >&2
      exit 2
      ;;
  esac
done

# Validate required arguments
if [[ -z "$PROJECT" ]] || [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage: verify-teardown.sh -p <project> -e <environment> [-r <region>]" >&2
  exit 2
fi

# Validate region
if [[ -z "$REGION" ]]; then
  echo "Usage: verify-teardown.sh -p <project> -e <environment> [-r <region>]" >&2
  exit 2
fi

# Counters
RESIDUE_COUNT=0
INFO_COUNT=0

# Helper function: safe AWS call with error tolerance
# WARN goes to stderr — stdout feeds the callers' read loops, so any
# diagnostic on stdout would be miscounted as a residue line.
aws_safe() {
  local check_name="$1"
  shift
  if ! output=$("$@" 2>&1); then
    echo "WARN $check_name aws call failed" >&2
    return 0
  fi
  echo "$output"
}

# ============================================================================
# Check 1: Tag Sweep — get-resources with Project + Environment filters
# ============================================================================
# Primary detection: list all taggable resources matching both tags.
# aws CLI auto-paginates by default via NextToken; no explicit pagination loop needed.
# KMS keys and Secrets Manager secrets keep their tags while pending deletion,
# so they are skipped here and handled by the state-aware checks 6 and 7.
# NOTE: --output text prints scalar-list query results TAB-SEPARATED ON ONE
# LINE, so every single-column pipeline below runs through tr '\t' '\n' —
# without it a while-read loop sees one concatenated line and prefix matches
# silently miss everything after the first item. (The secrets check reads
# two-column rows, which text output already prints one per line.)

while IFS= read -r arn; do
  if [[ -n "$arn" ]]; then
    if [[ "$arn" == *":kms:"* || "$arn" == *":secretsmanager:"* ]]; then
      continue
    fi
    echo "RESIDUE resourcegroupstaggingapi $arn tag-match"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
  fi
done < <(
  aws_safe "tag-sweep" \
    aws resourcegroupstaggingapi get-resources \
    --region "$REGION" \
    --tag-filter-list \
      "Key=Project,Values=$PROJECT" \
      "Key=Environment,Values=$ENVIRONMENT" \
    --output text \
    --query 'ResourceTagMappingList[*].ResourceARN' 2>/dev/null | tr '\t' '\n' || true
)

# ============================================================================
# Check 2: Orphaned ENIs — available network interfaces (post-detach residue)
# ============================================================================
# Region-wide by design: post-destroy the VPC (and its tags) are gone, so
# orphaned ENIs cannot be tag-filtered. In a shared account this can report
# ENIs belonging to other stacks.

while IFS= read -r eni_id; do
  if [[ -n "$eni_id" ]]; then
    echo "RESIDUE ec2 $eni_id orphaned-eni-available-status"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
  fi
done < <(
  aws_safe "orphaned-enis" \
    aws ec2 describe-network-interfaces \
    --region "$REGION" \
    --filters "Name=status,Values=available" \
    --output text \
    --query 'NetworkInterfaces[*].NetworkInterfaceId' 2>/dev/null | tr '\t' '\n' || true
)

# ============================================================================
# Check 3: RDS — DB instances and snapshots with project-environment prefix
# ============================================================================

# DB Instances with matching name
while IFS= read -r db_id; do
  if [[ -n "$db_id" && "$db_id" == "$PROJECT-$ENVIRONMENT"* ]]; then
    echo "RESIDUE rds-instance $db_id remaining-after-destroy"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
  fi
done < <(
  aws_safe "rds-instances" \
    aws rds describe-db-instances \
    --region "$REGION" \
    --output text \
    --query 'DBInstances[*].DBInstanceIdentifier' 2>/dev/null | tr '\t' '\n' || true
)

# Manual DB Snapshots (client-side filter on snapshot identifier)
while IFS= read -r snapshot_id; do
  if [[ -n "$snapshot_id" && "$snapshot_id" == "$PROJECT-$ENVIRONMENT"* ]]; then
    echo "RESIDUE rds-snapshot $snapshot_id manual-snapshot-billable"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
  fi
done < <(
  aws_safe "rds-snapshots" \
    aws rds describe-db-snapshots \
    --region "$REGION" \
    --snapshot-type manual \
    --output text \
    --query 'DBSnapshots[*].DBSnapshotIdentifier' 2>/dev/null | tr '\t' '\n' || true
)

# Automated DB Snapshots — the JMESPath filter matches on DBInstanceIdentifier;
# automated snapshot ids themselves are prefixed "rds:", so no prefix check here
while IFS= read -r snapshot_id; do
  if [[ -n "$snapshot_id" ]]; then
    echo "RESIDUE rds-snapshot $snapshot_id automated-snapshot-may-be-billable"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
  fi
done < <(
  aws_safe "rds-auto-snapshots" \
    aws rds describe-db-snapshots \
    --region "$REGION" \
    --snapshot-type automated \
    --output text \
    --query "DBSnapshots[?contains(DBInstanceIdentifier, '$PROJECT-$ENVIRONMENT')].DBSnapshotIdentifier" 2>/dev/null | tr '\t' '\n' || true
)

# ============================================================================
# Check 4: CloudWatch Log Groups — exact patterns from modules
# ============================================================================
# These patterns come from reading modules/*/main.tf:
# - RDS PostgreSQL: /aws/rds/instance/{project}-{environment}-vector/postgresql (vector-store module)
# - ECS Gateway: /ecs/{project}-{environment}-gateway (ecs-llm-gateway module)
# - CloudTrail: /aws/{project}-{environment}/cloudtrail (audit module)
# - Bedrock: /aws/{project}-{environment}/bedrock-invocations (audit module, count-guarded)
# - Flow Logs: /aws/vpc/flow-logs/{project}-{environment} (network module)
# - Log factory: /aws/{project}-{environment}/{key} (observability module)
# - Container Insights: /aws/ecs/containerinsights/{project}-{environment}-gateway/*
#   (AUTO-CREATED by ECS outside Terraform when containerInsights is enabled;
#   survives destroy — found live 2026-07-09)

declare -a LOG_GROUP_PREFIXES=(
  "/aws/rds/instance/${PROJECT}-${ENVIRONMENT}-vector"
  "/ecs/${PROJECT}-${ENVIRONMENT}-gateway"
  "/aws/${PROJECT}-${ENVIRONMENT}/cloudtrail"
  "/aws/${PROJECT}-${ENVIRONMENT}/bedrock-invocations"
  "/aws/vpc/flow-logs/${PROJECT}-${ENVIRONMENT}"
  "/aws/${PROJECT}-${ENVIRONMENT}/"
  "/aws/ecs/containerinsights/${PROJECT}-${ENVIRONMENT}-gateway"
)

# Check each log group prefix
for prefix in "${LOG_GROUP_PREFIXES[@]}"; do
  while IFS= read -r log_group; do
    if [[ -n "$log_group" ]]; then
      echo "RESIDUE cloudwatch-logs $log_group log-group-exists"
      RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
    fi
  done < <(
    aws_safe "log-groups-$prefix" \
      aws logs describe-log-groups \
      --region "$REGION" \
      --log-group-name-prefix "$prefix" \
      --output text \
      --query 'logGroups[*].logGroupName' 2>/dev/null | tr '\t' '\n' || true
  )
done

# Bedrock model-invocation logging configuration is a regional singleton
# (one per account per region). If destroy left it pointing at this stack's
# deleted log group it is broken-but-free residue — report as INFO.
bedrock_logging_config=$(aws_safe "bedrock-logging-config" \
  aws bedrock get-model-invocation-logging-configuration \
  --region "$REGION" \
  --output text 2>/dev/null || true)

if [[ -n "$bedrock_logging_config" && "$bedrock_logging_config" == *"$PROJECT-$ENVIRONMENT"* ]]; then
  echo "INFO bedrock model-invocation-logging-configuration still-references-$PROJECT-$ENVIRONMENT"
  INFO_COUNT=$((INFO_COUNT + 1))
fi

# ============================================================================
# Check 5: S3 Buckets — name prefix filter (client-side)
# ============================================================================
# Bucket patterns from document-store and audit modules:
# - {project}-{environment}-documents-{account_id}
# - {project}-{environment}-access-logs-{account_id}
# - {project}-{environment}-alb-logs-{account_id}
# - {project}-{environment}-audit-logs-{account_id}

while IFS= read -r bucket; do
  if [[ -n "$bucket" && "$bucket" == "$PROJECT-$ENVIRONMENT"* ]]; then
    echo "RESIDUE s3 $bucket s3-bucket-remains"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
  fi
done < <(
  aws_safe "s3-buckets" \
    aws s3api list-buckets \
    --region "$REGION" \
    --output text \
    --query 'Buckets[*].Name' 2>/dev/null | tr '\t' '\n' || true
)

# ============================================================================
# Check 6: KMS Keys — aliases and key state
# ============================================================================
# Alias pattern: alias/{project}-{environment}-{domain}
# Keys states: Enabled → RESIDUE, PendingDeletion → INFO (with DeletionDate), others → RESIDUE

while IFS= read -r alias; do
  if [[ -n "$alias" && "$alias" == "alias/$PROJECT-$ENVIRONMENT"* ]]; then
    # Extract key ID from alias
    key_id=$(aws_safe "kms-alias-describe-$alias" \
      aws kms describe-key \
      --region "$REGION" \
      --key-id "$alias" \
      --output text \
      --query 'KeyMetadata.KeyId' 2>/dev/null || echo "")

    if [[ -n "$key_id" ]]; then
      key_state=$(aws_safe "kms-key-state-$key_id" \
        aws kms describe-key \
        --region "$REGION" \
        --key-id "$key_id" \
        --output text \
        --query 'KeyMetadata.KeyState' 2>/dev/null || echo "")

      if [[ "$key_state" == "PendingDeletion" ]]; then
        deletion_date=$(aws_safe "kms-deletion-date-$key_id" \
          aws kms describe-key \
          --region "$REGION" \
          --key-id "$key_id" \
          --output text \
          --query 'KeyMetadata.DeletionDate' 2>/dev/null || echo "unknown")
        echo "INFO kms $alias pending-deletion-scheduled-for-$deletion_date"
        INFO_COUNT=$((INFO_COUNT + 1))
      elif [[ -n "$key_state" && "$key_state" != "Enabled" ]]; then
        echo "RESIDUE kms $alias key-state-$key_state"
        RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
      elif [[ "$key_state" == "Enabled" ]]; then
        echo "RESIDUE kms $alias key-enabled-billable"
        RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
      fi
    fi
  fi
done < <(
  aws_safe "kms-aliases" \
    aws kms list-aliases \
    --region "$REGION" \
    --output text \
    --query 'Aliases[*].AliasName' 2>/dev/null | tr '\t' '\n' || true
)

# ============================================================================
# Check 7: Secrets Manager — secrets with project-environment prefix
# ============================================================================
# Pattern: {project}-{environment}-gateway-master-key

while IFS=$'\t' read -r secret_name deletion_date; do
  if [[ -n "$secret_name" && "$secret_name" == "$PROJECT-$ENVIRONMENT"* ]]; then
    if [[ -n "$deletion_date" && "$deletion_date" != "None" ]]; then
      echo "INFO secrets-manager $secret_name scheduled-deletion-on-$deletion_date"
      INFO_COUNT=$((INFO_COUNT + 1))
    else
      echo "RESIDUE secrets-manager $secret_name secret-remains"
      RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
    fi
  fi
done < <(
  aws_safe "secrets-manager" \
    aws secretsmanager list-secrets \
    --region "$REGION" \
    --include-planned-deletion \
    --output text \
    --query 'SecretList[*].[Name, DeletedDate]' 2>/dev/null || true
)

# ============================================================================
# Check 8: ELBv2 — Load Balancers + Target Groups, ECS Clusters, SNS Topics
# ============================================================================

# ALB name pattern: {project}-{environment}-gateway (ecs-llm-gateway module)
while IFS= read -r alb_arn; do
  if [[ -n "$alb_arn" ]]; then
    echo "RESIDUE elb-alb $alb_arn alb-remains-after-destroy"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
  fi
done < <(
  aws_safe "elb-albs" \
    aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --output text \
    --query "LoadBalancers[?Name=='$PROJECT-$ENVIRONMENT-gateway'].LoadBalancerArn" 2>/dev/null | tr '\t' '\n' || true
)

# Target Groups (name_prefix = gw in ecs-llm-gateway module, but ARN suffix pattern is more reliable)
while IFS= read -r tg_arn; do
  if [[ -n "$tg_arn" && "$tg_arn" == *"$PROJECT-$ENVIRONMENT"* ]]; then
    echo "RESIDUE elb-target-group $tg_arn target-group-remains"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
  fi
done < <(
  aws_safe "elb-target-groups" \
    aws elbv2 describe-target-groups \
    --region "$REGION" \
    --output text \
    --query 'TargetGroups[*].TargetGroupArn' 2>/dev/null | tr '\t' '\n' || true
)

# ECS Clusters with matching name
while IFS= read -r cluster_arn; do
  if [[ -n "$cluster_arn" && "$cluster_arn" == *"$PROJECT-$ENVIRONMENT-gateway"* ]]; then
    echo "RESIDUE ecs-cluster $cluster_arn ecs-cluster-remains"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
  fi
done < <(
  aws_safe "ecs-clusters" \
    aws ecs list-clusters \
    --region "$REGION" \
    --output text \
    --query 'clusterArns[*]' 2>/dev/null | tr '\t' '\n' || true
)

# SNS Topics with matching name
while IFS= read -r topic_arn; do
  if [[ -n "$topic_arn" && "$topic_arn" == *"$PROJECT-$ENVIRONMENT-alarms"* ]]; then
    echo "RESIDUE sns-topic $topic_arn sns-topic-remains"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
  fi
done < <(
  aws_safe "sns-topics" \
    aws sns list-topics \
    --region "$REGION" \
    --output text \
    --query 'Topics[*].TopicArn' 2>/dev/null | tr '\t' '\n' || true
)

# ============================================================================
# Check 9: CloudWatch Alarms + Dashboards, EventBridge Rules, VPCs + Endpoints
# ============================================================================

# CloudWatch Alarms with project-environment prefix
while IFS= read -r alarm_name; do
  if [[ -n "$alarm_name" && "$alarm_name" == "$PROJECT-$ENVIRONMENT"* ]]; then
    echo "RESIDUE cloudwatch-alarm $alarm_name alarm-remains"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
  fi
done < <(
  aws_safe "cloudwatch-alarms" \
    aws cloudwatch describe-alarms \
    --region "$REGION" \
    --output text \
    --query 'MetricAlarms[*].AlarmName' 2>/dev/null | tr '\t' '\n' || true
)

# CloudWatch Dashboards with project-environment prefix
while IFS= read -r dashboard_name; do
  if [[ -n "$dashboard_name" && "$dashboard_name" == "$PROJECT-$ENVIRONMENT"* ]]; then
    echo "RESIDUE cloudwatch-dashboard $dashboard_name dashboard-remains"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
  fi
done < <(
  aws_safe "cloudwatch-dashboards" \
    aws cloudwatch list-dashboards \
    --region "$REGION" \
    --output text \
    --query 'DashboardEntries[*].DashboardName' 2>/dev/null | tr '\t' '\n' || true
)

# EventBridge Rules with matching name
while IFS= read -r rule_name; do
  if [[ -n "$rule_name" && "$rule_name" == "$PROJECT-$ENVIRONMENT"* ]]; then
    echo "RESIDUE eventbridge-rule $rule_name event-rule-remains"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
  fi
done < <(
  aws_safe "eventbridge-rules" \
    aws events list-rules \
    --region "$REGION" \
    --output text \
    --query 'Rules[*].Name' 2>/dev/null | tr '\t' '\n' || true
)

# VPCs with matching tag
while IFS= read -r vpc_id; do
  if [[ -n "$vpc_id" ]]; then
    echo "RESIDUE vpc $vpc_id vpc-with-matching-tags"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
  fi
done < <(
  aws_safe "vpcs" \
    aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters \
      "Name=tag:Project,Values=$PROJECT" \
      "Name=tag:Environment,Values=$ENVIRONMENT" \
    --output text \
    --query 'Vpcs[*].VpcId' 2>/dev/null | tr '\t' '\n' || true
)

# VPC Endpoints with matching tags (usually clean but check)
while IFS= read -r endpoint_id; do
  if [[ -n "$endpoint_id" ]]; then
    echo "RESIDUE vpc-endpoint $endpoint_id vpc-endpoint-remains"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
  fi
done < <(
  aws_safe "vpc-endpoints" \
    aws ec2 describe-vpc-endpoints \
    --region "$REGION" \
    --filters \
      "Name=tag:Project,Values=$PROJECT" \
      "Name=tag:Environment,Values=$ENVIRONMENT" \
    --output text \
    --query 'VpcEndpoints[*].VpcEndpointId' 2>/dev/null | tr '\t' '\n' || true
)

# CloudTrail Trails with matching name
while IFS= read -r trail_name; do
  if [[ -n "$trail_name" && "$trail_name" == "$PROJECT-$ENVIRONMENT-trail"* ]]; then
    echo "RESIDUE cloudtrail $trail_name trail-remains"
    RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
  fi
done < <(
  aws_safe "cloudtrail-trails" \
    aws cloudtrail list-trails \
    --region "$REGION" \
    --output text \
    --query 'Trails[*].Name' 2>/dev/null | tr '\t' '\n' || true
)

# AWS Config Recorder with matching name
recorder_name=$(aws_safe "config-recorder" \
  aws configservice describe-configuration-recorders \
  --region "$REGION" \
  --output text \
  --query "ConfigurationRecorders[?Name=='$PROJECT-$ENVIRONMENT-config'].Name" 2>/dev/null || echo "")

if [[ -n "$recorder_name" ]]; then
  echo "RESIDUE config $recorder_name config-recorder-remains"
  RESIDUE_COUNT=$((RESIDUE_COUNT + 1))
fi

# ============================================================================
# Check 10: ACM Certificates (self-signed sandbox cert, no cost but report as INFO)
# ============================================================================
# ACM ARNs are opaque UUIDs; the identifying field is DomainName, which the
# gateway module sets to {project}-{environment}-gateway.internal

while IFS= read -r cert_arn; do
  if [[ -n "$cert_arn" ]]; then
    echo "INFO acm $cert_arn self-signed-cert-no-cost-clutter"
    INFO_COUNT=$((INFO_COUNT + 1))
  fi
done < <(
  aws_safe "acm-certs" \
    aws acm list-certificates \
    --region "$REGION" \
    --output text \
    --query "CertificateSummaryList[?DomainName=='$PROJECT-$ENVIRONMENT-gateway.internal'].CertificateArn" 2>/dev/null | tr '\t' '\n' || true
)

# ============================================================================
# Final Summary
# ============================================================================

echo "SUMMARY residue=$RESIDUE_COUNT info=$INFO_COUNT"

if [[ $RESIDUE_COUNT -eq 0 ]]; then
  exit 0
else
  exit 1
fi
