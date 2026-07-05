data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project            = var.project
    Environment        = var.environment
    ManagedBy          = "terraform"
    DataClassification = var.data_classification
  }

  alarm_tags = merge(
    local.common_tags,
    var.tags,
    var.runbook_url != null ? { RunbookUrl = var.runbook_url } : {}
  )
}

# ============================================================================
# SNS Topic for Alarm Notifications
# ============================================================================

resource "aws_sns_topic" "alarms" {
  name              = "${local.name_prefix}-alarms"
  kms_master_key_id = var.logs_kms_key_arn
  # logs CMK — alarm payloads are operational metadata; the CMK's key policy
  # grants cloudwatch/events principals

  tags = merge(local.common_tags, var.tags)
}

data "aws_iam_policy_document" "alarms_topic_policy" {
  statement {
    sid    = "AllowCloudWatchAlarmsPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions = [
      "sns:Publish"
    ]

    resources = [aws_sns_topic.alarms.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:cloudwatch:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:alarm:*"]
    }
  }

  statement {
    sid    = "AllowEventBridgePublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions = [
      "sns:Publish"
    ]

    resources = [aws_sns_topic.alarms.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.config_noncompliant.arn]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "sns:Publish"
    ]

    resources = [aws_sns_topic.alarms.arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sns_topic_policy" "alarms" {
  arn    = aws_sns_topic.alarms.arn
  policy = data.aws_iam_policy_document.alarms_topic_policy.json
}

resource "aws_sns_topic_subscription" "alarm_emails" {
  for_each = toset(var.alarm_email_addresses)

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}

# ============================================================================
# Log Group Factory
# ============================================================================

resource "aws_cloudwatch_log_group" "this" {
  for_each = var.log_groups

  name              = "/aws/${local.name_prefix}/${each.key}"
  retention_in_days = each.value.retention_in_days
  kms_key_id        = var.logs_kms_key_arn
  #checkov:skip=CKV_AWS_338: retention_in_days is a mandatory caller input validated against finite values; the composition sets 365+ for audit-relevant groups

  tags = merge(local.common_tags, var.tags)
}

# ============================================================================
# RDS Alarms
# ============================================================================

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count = var.db_instance_id != null ? 1 : 0

  alarm_name          = "${local.name_prefix}-rds-cpu"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.rds_cpu_threshold_percent
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }

  alarm_description = "Alert when RDS CPU utilization >= ${var.rds_cpu_threshold_percent}%"
  alarm_actions     = [aws_sns_topic.alarms.arn]
  ok_actions        = [aws_sns_topic.alarms.arn]

  tags = local.alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  count = var.db_instance_id != null ? 1 : 0

  alarm_name          = "${local.name_prefix}-rds-free-storage"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.rds_free_storage_threshold_bytes
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }

  alarm_description = "Alert when RDS free storage <= ${var.rds_free_storage_threshold_bytes} bytes"
  alarm_actions     = [aws_sns_topic.alarms.arn]
  ok_actions        = [aws_sns_topic.alarms.arn]

  tags = local.alarm_tags
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  count = var.db_instance_id != null ? 1 : 0

  alarm_name          = "${local.name_prefix}-rds-connections"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.rds_connections_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }

  alarm_description = "Alert when RDS connections >= ${var.rds_connections_threshold}"
  alarm_actions     = [aws_sns_topic.alarms.arn]
  ok_actions        = [aws_sns_topic.alarms.arn]

  tags = local.alarm_tags
}

# ============================================================================
# Endpoint Packet-Drop Alarms (No-Egress Canary)
# ============================================================================

# Packet drops at interface endpoints are the no-egress canary — traffic that
# cannot reach a service inside the VPC shows up here, not as internet egress.
# The map keys of interface_endpoint_ids are AWS service short names
# (matches the network module's output contract).

resource "aws_cloudwatch_metric_alarm" "endpoint_packet_drops" {
  for_each = var.interface_endpoint_ids

  alarm_name          = "${local.name_prefix}-endpoint-drops-${each.key}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "PacketsDropped"
  namespace           = "AWS/PrivateLinkEndpoints"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  # Dimension KEYS contain literal spaces exactly as AWS publishes them
  dimensions = {
    "VPC Id"          = var.vpc_id
    "VPC Endpoint Id" = each.value
    "Endpoint Type"   = "Interface"
    "Service Name"    = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  }

  alarm_description = "Alert when packets are dropped at the ${each.key} endpoint"
  alarm_actions     = [aws_sns_topic.alarms.arn]
  ok_actions        = [aws_sns_topic.alarms.arn]

  tags = local.alarm_tags
}

# ============================================================================
# CloudTrail Tamper Detection
# ============================================================================

resource "aws_cloudwatch_log_metric_filter" "trail_tamper" {
  count = var.cloudtrail_log_group_name != null ? 1 : 0

  name           = "${local.name_prefix}-trail-tamper"
  log_group_name = var.cloudtrail_log_group_name
  pattern        = "{ ($.eventSource = \"cloudtrail.amazonaws.com\") && (($.eventName = \"StopLogging\") || ($.eventName = \"DeleteTrail\") || ($.eventName = \"UpdateTrail\")) }"

  metric_transformation {
    name          = "CloudTrailTamperEvents"
    namespace     = "${local.name_prefix}/audit"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "trail_tamper" {
  count = var.cloudtrail_log_group_name != null ? 1 : 0

  alarm_name          = "${local.name_prefix}-trail-tamper"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CloudTrailTamperEvents"
  namespace           = "${local.name_prefix}/audit"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  alarm_description = "Alert on CloudTrail modification (StopLogging, DeleteTrail, UpdateTrail)"
  alarm_actions     = [aws_sns_topic.alarms.arn]
  ok_actions        = [aws_sns_topic.alarms.arn]

  tags = local.alarm_tags
}

# ============================================================================
# Config Noncompliance Notification
# ============================================================================

resource "aws_cloudwatch_event_rule" "config_noncompliant" {
  name        = "${local.name_prefix}-config-noncompliant"
  description = "EventBridge rule for AWS Config noncompliance changes"

  event_pattern = jsonencode({
    source      = ["aws.config"]
    detail-type = ["Config Rules Compliance Change"]
    detail = {
      newEvaluationResult = {
        complianceType = ["NON_COMPLIANT"]
      }
    }
  })

  tags = merge(local.common_tags, var.tags)
}

resource "aws_cloudwatch_event_target" "config_to_sns" {
  rule      = aws_cloudwatch_event_rule.config_noncompliant.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.alarms.arn
}

# ============================================================================
# CloudWatch Dashboard
# ============================================================================

locals {
  # Build dashboard_widgets as a concat of conditionally-included widget lists.
  # Dashboard metric arrays take dimensions as positional "Name", "value" string
  # pairs (["Namespace", "Metric", "DimName", "DimValue", {options}]) — NOT the
  # dimensions-map form used by aws_cloudwatch_metric_alarm.

  gateway_widgets = var.alb_arn_suffix != null ? [
    {
      type = "metric"
      properties = {
        metrics = concat(
          [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "Request Count" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p95", label = "Response Time p95" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "5XX Errors" }]
          ],
          var.target_group_arn_suffix != null ? [
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", var.target_group_arn_suffix, "LoadBalancer", var.alb_arn_suffix, { stat = "Maximum", label = "Unhealthy Hosts" }]
          ] : []
        )
        period = 300
        region = data.aws_region.current.region
        title  = "Gateway Traffic & Health"
        yAxis = {
          left = {
            min = 0
          }
        }
      }
      x      = 0
      y      = 0
      width  = 12
      height = 6
    }
  ] : []

  ecs_widgets = var.cluster_name != null && var.service_name != null ? [
    {
      type = "metric"
      properties = {
        metrics = [
          ["AWS/ECS", "CPUUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name, { stat = "Average", label = "CPU" }],
          ["AWS/ECS", "MemoryUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name, { stat = "Average", label = "Memory" }]
        ]
        period = 300
        region = data.aws_region.current.region
        title  = "ECS Task Health"
        yAxis = {
          left = {
            min = 0
            max = 100
          }
        }
      }
      x      = 12
      y      = 0
      width  = 12
      height = 6
    }
  ] : []

  rds_widgets = var.db_instance_id != null ? [
    {
      type = "metric"
      properties = {
        metrics = [
          ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_instance_id, { stat = "Average", label = "CPU" }],
          ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.db_instance_id, { stat = "Average", label = "Free Storage", yAxis = "right" }],
          ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.db_instance_id, { stat = "Average", label = "Connections" }]
        ]
        period = 300
        region = data.aws_region.current.region
        title  = "RDS Database Vitals"
        yAxis = {
          left = {
            min = 0
          }
        }
      }
      x      = 0
      y      = 6
      width  = 12
      height = 6
    }
  ] : []

  # ARNs of every alarm this module creates, for the alarm-status widget.
  module_alarm_arns = concat(
    var.db_instance_id != null ? [
      aws_cloudwatch_metric_alarm.rds_cpu[0].arn,
      aws_cloudwatch_metric_alarm.rds_free_storage[0].arn,
      aws_cloudwatch_metric_alarm.rds_connections[0].arn
    ] : [],
    [for a in aws_cloudwatch_metric_alarm.endpoint_packet_drops : a.arn],
    var.cloudtrail_log_group_name != null ? [aws_cloudwatch_metric_alarm.trail_tamper[0].arn] : []
  )

  # Compliance/audit row: alarm-status widget (only valid with a non-empty alarm
  # list) plus Config-noncompliance event volume (always).
  compliance_widgets = concat(
    length(local.module_alarm_arns) > 0 ? [
      {
        type = "alarm"
        properties = {
          alarms = local.module_alarm_arns
          title  = "Alarm Status"
        }
        x      = 12
        y      = 6
        width  = 12
        height = 6
      }
    ] : [],
    [
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/Events", "Invocations", "RuleName", aws_cloudwatch_event_rule.config_noncompliant.name, { stat = "Sum", label = "Noncompliance Events" }]
          ]
          period = 300
          region = data.aws_region.current.region
          title  = "Config Noncompliance Events"
        }
        x      = 0
        y      = 12
        width  = 12
        height = 6
      }
    ]
  )

  dashboard_widgets = concat(
    local.gateway_widgets,
    local.ecs_widgets,
    local.rds_widgets,
    local.compliance_widgets
  )
}

resource "aws_cloudwatch_dashboard" "this" {
  count          = var.enable_dashboard ? 1 : 0
  dashboard_name = "${local.name_prefix}-observability"
  dashboard_body = jsonencode({ widgets = local.dashboard_widgets })
}
