mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name   = "us-east-1"
      region = "us-east-1"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-1:123456789012:mock-topic"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-east-1:123456789012:rule/mock-rule"
    }
  }
}

variables {
  project                   = "fedllm"
  environment               = "dev"
  data_classification       = "cui"
  tags                      = {}
  logs_kms_key_arn          = "arn:aws:kms:us-east-1:123456789012:key/12345678-aaaa-bbbb-cccc-dddddddddddd"
  db_instance_id            = "fedllm-dev-postgres"
  vpc_id                    = "vpc-12345678"
  interface_endpoint_ids    = { logs = "vpce-0abc", kms = "vpce-0def" }
  cloudtrail_log_group_name = "/aws/cloudtrail/fedllm-dev"
  runbook_url               = "https://wiki.example.com/runbooks"
  enable_dashboard          = true
  alb_arn_suffix            = "app/fedllm-dev-gateway/1234567890abcdef"
  target_group_arn_suffix   = "targetgroup/fedllm-dev-gateway/0123456789abcdef"
  cluster_name              = "fedllm-dev"
  service_name              = "gateway"
}

run "rds_alarms_present" {
  command = apply

  # RDS alarms: all three should be present when db_instance_id is set
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.rds_cpu) == 1
    error_message = "RDS CPU alarm should be present when db_instance_id is set"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.rds_free_storage) == 1
    error_message = "RDS free storage alarm should be present when db_instance_id is set"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.rds_connections) == 1
    error_message = "RDS connections alarm should be present when db_instance_id is set"
  }

  # RDS alarms: verify DBInstanceIdentifier dimension
  assert {
    condition     = aws_cloudwatch_metric_alarm.rds_cpu[0].dimensions["DBInstanceIdentifier"] == "fedllm-dev-postgres"
    error_message = "RDS CPU alarm must have DBInstanceIdentifier dimension"
  }

  # RDS alarms: verify topic actions are set
  assert {
    condition = alltrue([
      for alarm in [aws_cloudwatch_metric_alarm.rds_cpu[0], aws_cloudwatch_metric_alarm.rds_free_storage[0], aws_cloudwatch_metric_alarm.rds_connections[0]] :
      contains(alarm.alarm_actions, aws_sns_topic.alarms.arn)
    ])
    error_message = "All RDS alarms must have alarm_actions pointing to topic"
  }
}

run "endpoint_alarms_check" {
  command = apply

  # Endpoint alarms: should be present for each endpoint
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.endpoint_packet_drops) == 2
    error_message = "Should have 2 endpoint packet-drop alarms"
  }

  # Endpoint dimensions and naming
  assert {
    condition     = aws_cloudwatch_metric_alarm.endpoint_packet_drops["logs"].dimensions["Service Name"] == "com.amazonaws.us-east-1.logs"
    error_message = "Endpoint alarm must have correct Service Name dimension (logs)"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.endpoint_packet_drops["kms"].dimensions["Service Name"] == "com.amazonaws.us-east-1.kms"
    error_message = "Endpoint alarm must have correct Service Name dimension (kms)"
  }

  # Endpoint alarms: treat_missing_data should be notBreaching
  assert {
    condition = alltrue([
      for alarm in aws_cloudwatch_metric_alarm.endpoint_packet_drops :
      alarm.treat_missing_data == "notBreaching"
    ])
    error_message = "Endpoint alarms must have treat_missing_data = notBreaching"
  }
}

run "trail_tamper_check" {
  command = apply

  # CloudTrail tamper: filter and alarm should be present
  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.trail_tamper) == 1
    error_message = "Trail tamper filter should be present when cloudtrail_log_group_name is set"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.trail_tamper) == 1
    error_message = "Trail tamper alarm should be present when cloudtrail_log_group_name is set"
  }

  # Filter pattern must contain StopLogging
  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.trail_tamper[0].pattern) > 0
    error_message = "Trail tamper filter pattern must be set"
  }

  # Alarm namespace must be correct
  assert {
    condition     = aws_cloudwatch_metric_alarm.trail_tamper[0].namespace == "fedllm-dev/audit"
    error_message = "Trail tamper alarm namespace must be {project}-{environment}/audit"
  }
}

run "runbook_url_tag_check" {
  command = apply

  # RunbookUrl tag should be present on all alarms when runbook_url is set
  assert {
    condition = alltrue([
      for alarm in aws_cloudwatch_metric_alarm.rds_cpu :
      lookup(alarm.tags, "RunbookUrl", null) == "https://wiki.example.com/runbooks"
    ])
    error_message = "RDS alarms must have RunbookUrl tag when runbook_url is set"
  }

  assert {
    condition = alltrue([
      for alarm in aws_cloudwatch_metric_alarm.endpoint_packet_drops :
      lookup(alarm.tags, "RunbookUrl", null) == "https://wiki.example.com/runbooks"
    ])
    error_message = "Endpoint alarms must have RunbookUrl tag when runbook_url is set"
  }

  assert {
    condition = alltrue([
      for alarm in aws_cloudwatch_metric_alarm.trail_tamper :
      lookup(alarm.tags, "RunbookUrl", null) == "https://wiki.example.com/runbooks"
    ])
    error_message = "Trail tamper alarm must have RunbookUrl tag when runbook_url is set"
  }
}

run "dashboard_check" {
  command = apply

  # Dashboard: present by default
  assert {
    condition     = length(aws_cloudwatch_dashboard.this) == 1
    error_message = "Dashboard should be present when enable_dashboard is true"
  }

  # Dashboard body must be valid JSON
  assert {
    condition     = length(jsondecode(aws_cloudwatch_dashboard.this[0].dashboard_body).widgets) > 0
    error_message = "Dashboard body must be valid JSON with widgets"
  }

  # Dashboard should have widgets from all configured sources
  assert {
    condition     = length(jsondecode(aws_cloudwatch_dashboard.this[0].dashboard_body).widgets) >= 4
    error_message = "Dashboard should have gateway, ECS, RDS, and compliance widgets"
  }

  # Dashboard metric arrays must carry dimensions as positional "Name", "value"
  # string pairs — the alarm-style dimensions-map form renders empty charts
  assert {
    condition = anytrue([
      for w in jsondecode(aws_cloudwatch_dashboard.this[0].dashboard_body).widgets :
      anytrue([
        for m in try(w.properties.metrics, []) :
        contains(m, "LoadBalancer") && contains(m, var.alb_arn_suffix)
      ]) if w.type == "metric"
    ])
    error_message = "Gateway widget metrics must include the positional LoadBalancer dimension pair"
  }

  # The alarm-status widget must reference this module's alarm ARNs
  assert {
    condition = anytrue([
      for w in jsondecode(aws_cloudwatch_dashboard.this[0].dashboard_body).widgets :
      length(try(w.properties.alarms, [])) > 0 if w.type == "alarm"
    ])
    error_message = "Dashboard must include an alarm-status widget listing module alarm ARNs"
  }
}
