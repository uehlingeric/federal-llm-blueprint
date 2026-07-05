mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }
}

mock_provider "tls" {}

variables {
  project                 = "fedllm"
  environment             = "dev"
  data_classification     = "cui"
  vpc_id                  = "vpc-12345678"
  vpc_cidr                = "10.0.0.0/16"
  private_subnet_ids      = ["subnet-11111111", "subnet-22222222"]
  app_security_group_id   = "sg-appsg12345"
  task_execution_role_arn = "arn:aws:iam::123456789012:role/ecs-task-execution-role"
  app_task_role_arn       = "arn:aws:iam::123456789012:role/ecs-app-task-role"
  logs_kms_key_arn        = "arn:aws:kms:us-east-1:123456789012:key/12345678-aaaa-bbbb-cccc-111111111111"
  secrets_kms_key_arn     = "arn:aws:kms:us-east-1:123456789012:key/12345678-dddd-eeee-ffff-222222222222"
  container_image         = "ghcr.io/berriai/litellm@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  container_port          = 4000
  config_yaml             = "model_list: []"
  alb_logs_bucket_id      = "my-alb-logs-bucket"
  certificate_arn         = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  create_self_signed_cert = false
  min_capacity            = 1
  max_capacity            = 3
  cpu_target_value        = 60
  request_count_target    = 100
}

run "alb_security_and_access_logs" {
  command = plan

  # Assert: ALB is internal (not internet-facing)
  assert {
    condition     = aws_lb.gateway.internal == true
    error_message = "ALB must be internal"
  }

  # Assert: ALB drops invalid headers
  assert {
    condition     = aws_lb.gateway.drop_invalid_header_fields == true
    error_message = "ALB must drop invalid header fields"
  }

  # Assert: ALB access logs are enabled
  assert {
    condition     = aws_lb.gateway.access_logs[0].enabled == true
    error_message = "ALB access logs must be enabled"
  }

  # Assert: ALB access logs bucket is correct
  assert {
    condition     = aws_lb.gateway.access_logs[0].bucket == "my-alb-logs-bucket"
    error_message = "ALB access logs bucket must be my-alb-logs-bucket"
  }

  # Assert: ALB access logs prefix is 'alb'
  assert {
    condition     = aws_lb.gateway.access_logs[0].prefix == "alb"
    error_message = "ALB access logs prefix must be alb"
  }
}

run "listener_and_target_group" {
  command = plan

  # Assert: HTTPS listener exists on port 443
  assert {
    condition     = aws_lb_listener.https.port == 443 && aws_lb_listener.https.protocol == "HTTPS"
    error_message = "HTTPS listener must exist on port 443 with HTTPS protocol"
  }

  # Assert: Listener uses TLS13-1-2-2021-06 policy
  assert {
    condition     = aws_lb_listener.https.ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06"
    error_message = "Listener must use TLS13-1-2-2021-06 policy"
  }

  # Assert: Target group protocol is HTTP (TLS terminates at ALB)
  assert {
    condition     = aws_lb_target_group.gateway.protocol == "HTTP"
    error_message = "Target group protocol must be HTTP (TLS terminates at ALB)"
  }

  # Assert: Target group port matches container port
  assert {
    condition     = aws_lb_target_group.gateway.port == 4000
    error_message = "Target group port must match container_port (4000)"
  }

  # Assert: Target group deregistration delay is 30 seconds
  assert {
    condition     = tostring(aws_lb_target_group.gateway.deregistration_delay) == "30"
    error_message = "Target group deregistration_delay must be 30 seconds"
  }

  # Assert: Health check path is /health/liveliness
  assert {
    condition     = aws_lb_target_group.gateway.health_check[0].path == "/health/liveliness"
    error_message = "Health check path must be /health/liveliness"
  }

  # Assert: Health check matcher is 200
  assert {
    condition     = aws_lb_target_group.gateway.health_check[0].matcher == "200"
    error_message = "Health check matcher must be 200"
  }

  # Assert: Health check interval is 30 seconds
  assert {
    condition     = aws_lb_target_group.gateway.health_check[0].interval == 30
    error_message = "Health check interval must be 30 seconds"
  }

  # Assert: Health check timeout is 5 seconds
  assert {
    condition     = aws_lb_target_group.gateway.health_check[0].timeout == 5
    error_message = "Health check timeout must be 5 seconds"
  }
}

run "security_groups_and_rules" {
  command = plan

  # Assert: Service SG has ingress rule from ALB SG
  assert {
    condition     = aws_vpc_security_group_ingress_rule.service_from_alb.from_port == 4000
    error_message = "Service SG must have ingress rule from ALB SG on container port"
  }

  # Assert: ALB SG has ingress rule on 443 from VPC CIDR
  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_https.from_port == 443 && aws_vpc_security_group_ingress_rule.alb_https.cidr_ipv4 == "10.0.0.0/16"
    error_message = "ALB SG must have ingress rule on port 443 from VPC CIDR"
  }

  # Assert: ALB SG has egress rule to service SG on container port
  assert {
    condition     = aws_vpc_security_group_egress_rule.alb_to_service.from_port == 4000
    error_message = "ALB SG must have egress rule to service SG on container port"
  }
}

run "service_deployment_and_circuit_breaker" {
  command = plan

  # Assert: Service has deployment circuit breaker enabled
  assert {
    condition     = aws_ecs_service.gateway.deployment_circuit_breaker[0].enable == true && aws_ecs_service.gateway.deployment_circuit_breaker[0].rollback == true
    error_message = "Service must have circuit breaker enabled with rollback"
  }

  # Assert: Deployment maximum percent is 200
  assert {
    condition     = aws_ecs_service.gateway.deployment_maximum_percent == 200
    error_message = "deployment_maximum_percent must be 200 for demo configuration"
  }

  # Assert: Deployment minimum healthy percent is 100
  assert {
    condition     = aws_ecs_service.gateway.deployment_minimum_healthy_percent == 100
    error_message = "deployment_minimum_healthy_percent must be 100"
  }

  # Assert: Health check grace period is 120 seconds
  assert {
    condition     = aws_ecs_service.gateway.health_check_grace_period_seconds == 120
    error_message = "health_check_grace_period_seconds must be 120"
  }
}

run "autoscaling_configuration" {
  command = plan

  # Assert: Autoscaling target has correct min/max capacity
  assert {
    condition     = aws_appautoscaling_target.ecs_service.min_capacity == 1 && aws_appautoscaling_target.ecs_service.max_capacity == 3
    error_message = "Autoscaling target min_capacity must be 1 and max_capacity must be 3"
  }

  # Assert: CPU scaling policy uses correct metric type and target
  assert {
    condition     = aws_appautoscaling_policy.cpu_scaling.target_tracking_scaling_policy_configuration[0].predefined_metric_specification[0].predefined_metric_type == "ECSServiceAverageCPUUtilization" && aws_appautoscaling_policy.cpu_scaling.target_tracking_scaling_policy_configuration[0].target_value == 60
    error_message = "CPU scaling policy must use ECSServiceAverageCPUUtilization with target_value 60"
  }

  # Assert: Request count scaling policy uses correct metric type and target
  assert {
    condition     = aws_appautoscaling_policy.request_count_scaling.target_tracking_scaling_policy_configuration[0].predefined_metric_specification[0].predefined_metric_type == "ALBRequestCountPerTarget" && aws_appautoscaling_policy.request_count_scaling.target_tracking_scaling_policy_configuration[0].target_value == 100
    error_message = "Request count scaling policy must use ALBRequestCountPerTarget with target_value 100"
  }
}

run "cloudwatch_alarms_exist" {
  command = plan

  # Assert: Three alarms are configured (they exist as singular resources)
  assert {
    condition     = aws_cloudwatch_metric_alarm.unhealthy_hosts.alarm_name != ""
    error_message = "Unhealthy hosts alarm must exist"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.target_5xx.alarm_name != ""
    error_message = "Target 5xx alarm must exist"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.running_task_count.alarm_name != ""
    error_message = "Running task count alarm must exist"
  }

  # Assert: latency alarm tracks p95 TargetResponseTime with the default threshold
  assert {
    condition     = aws_cloudwatch_metric_alarm.latency_p95.metric_name == "TargetResponseTime" && aws_cloudwatch_metric_alarm.latency_p95.extended_statistic == "p95" && aws_cloudwatch_metric_alarm.latency_p95.threshold == 60
    error_message = "Latency alarm must track p95 TargetResponseTime with the 60s default threshold"
  }

  # Assert: Alarms have empty action lists when alarm_topic_arn is null (default)
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.unhealthy_hosts.alarm_actions) == 0
    error_message = "Unhealthy hosts alarm must have empty alarm_actions when alarm_topic_arn is null"
  }
}

run "self_signed_certificate_creation" {
  command = plan

  variables {
    certificate_arn         = null
    create_self_signed_cert = true
  }

  # Assert: Self-signed certificate resources are planned (count > 0)
  assert {
    condition     = length(tls_private_key.self_signed) > 0 && length(tls_self_signed_cert.self_signed) > 0 && length(aws_acm_certificate.self_signed) > 0
    error_message = "Self-signed certificate resources must be created when create_self_signed_cert = true"
  }
}

run "fargate_spot_capacity_provider" {
  command = plan

  variables {
    enable_fargate_spot = true
  }

  # Assert: FARGATE_SPOT capacity provider is included
  assert {
    condition     = contains(aws_ecs_cluster_capacity_providers.gateway.capacity_providers, "FARGATE_SPOT")
    error_message = "FARGATE_SPOT must be included in capacity providers when enabled"
  }

  # Assert: FARGATE capacity provider is always present
  assert {
    condition     = contains(aws_ecs_cluster_capacity_providers.gateway.capacity_providers, "FARGATE")
    error_message = "FARGATE must always be included in capacity providers"
  }
}
