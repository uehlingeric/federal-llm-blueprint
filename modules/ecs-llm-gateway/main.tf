data "aws_region" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project            = var.project
    Environment        = var.environment
    ManagedBy          = "terraform"
    DataClassification = var.data_classification
  }

  # Resolve certificate ARN: use var if provided, otherwise use the created self-signed cert
  certificate_arn = var.certificate_arn != null ? var.certificate_arn : aws_acm_certificate.self_signed[0].arn

  # Resolve master key secret ARN: use var if provided, otherwise use the created secret
  master_key_secret_arn = var.master_key_secret_arn != null ? var.master_key_secret_arn : aws_secretsmanager_secret.master_key[0].arn
}

# ECS Cluster with Container Insights enabled
resource "aws_ecs_cluster" "gateway" {
  name = "${local.name_prefix}-gateway"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway"
    }
  )
}

# Capacity providers: FARGATE always, + FARGATE_SPOT when enabled
resource "aws_ecs_cluster_capacity_providers" "gateway" {
  cluster_name = aws_ecs_cluster.gateway.name

  capacity_providers = concat(
    ["FARGATE"],
    var.enable_fargate_spot ? ["FARGATE_SPOT"] : []
  )

  default_capacity_provider_strategy {
    base              = 1
    weight            = 1
    capacity_provider = "FARGATE"
  }
}

# CloudWatch Log Group for ECS task logs, encrypted with logs KMS key
resource "aws_cloudwatch_log_group" "gateway" {
  #checkov:skip=CKV_AWS_338: Retention is configurable via var.log_retention_days; default 90 days is appropriate for gateway logs in development environments. Federal deployments set 365+.
  name              = "/ecs/${local.name_prefix}-gateway"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway-logs"
    }
  )
}

# SSM Parameter for LiteLLM config YAML (SecureString, Intelligent-Tiering tier for > 4KB support)
resource "aws_ssm_parameter" "litellm_config" {
  name        = "/${var.project}/${var.environment}/gateway/litellm-config"
  type        = "SecureString"
  key_id      = var.secrets_kms_key_arn
  value       = var.config_yaml
  tier        = "Intelligent-Tiering"
  description = "LiteLLM proxy configuration (YAML format, no secrets; master key injected separately)"

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway-config"
    }
  )
}

# Secrets Manager secret for LiteLLM master key (count = 0 if var.master_key_secret_arn is provided)
# Value is populated out-of-band (manually or via Lambda rotation); no aws_secretsmanager_secret_version here
resource "aws_secretsmanager_secret" "master_key" {
  count                   = var.master_key_secret_arn == null ? 1 : 0
  name                    = "${local.name_prefix}-gateway-master-key"
  kms_key_id              = var.secrets_kms_key_arn
  recovery_window_in_days = 7 # Allow recovery for 7 days before permanent deletion

  # Manual rotation is documented in docs/secrets-handling.md per federal audit requirements
  #checkov:skip=CKV2_AWS_57: Rotation is managed out-of-band per docs/secrets-handling.md pattern for federated systems

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway-master-key"
    }
  )
}

# ECS Task Definition: hardened configuration with non-root user, read-only FS, digest-pinned image
resource "aws_ecs_task_definition" "gateway" {
  family                   = "${local.name_prefix}-gateway"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.app_task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  # Ephemeral /tmp volume: Fargate does not support tmpfs, so use a named volume instead
  # Allows writing config and temp files to /tmp while keeping root filesystem read-only
  volume {
    name = "tmp"
  }

  container_definitions = jsonencode([
    {
      # Fargate bind mounts surface root-owned 0755, so the non-root gateway
      # user cannot write its materialized config. This throwaway init
      # container (same image — no extra mirror in no-egress mode) restores
      # the image's 1777 mode on the volume, then exits; the gateway container
      # depends on its SUCCESS. This is the AWS-documented pattern for
      # non-root writable volumes on Fargate.
      name       = "tmp-init"
      image      = var.container_image
      essential  = false
      user       = "0"
      entryPoint = ["sh", "-c"]
      command    = ["chmod 1777 /tmp"]

      mountPoints = [
        {
          containerPath = "/tmp"
          sourceVolume  = "tmp"
          readOnly      = false
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.gateway.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "tmp-init"
        }
      }
    },
    {
      name      = "gateway"
      image     = var.container_image
      essential = true
      user      = var.container_user

      # Gate on the volume-permission init container having succeeded
      dependsOn = [
        {
          containerName = "tmp-init"
          condition     = "SUCCESS"
        }
      ]

      # Port mapping: container listens on var.container_port (default 4000)
      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      # Hardening: read-only root filesystem (config materialized to /tmp at startup)
      readonlyRootFilesystem = true

      # Note: privileged is not set here; Fargate rejects the privileged flag anyway
      # Container runs as non-root user for additional hardening

      # Mount ephemeral /tmp volume: writable, used for config and temp files
      mountPoints = [
        {
          containerPath = "/tmp"
          sourceVolume  = "tmp"
          readOnly      = false
        }
      ]

      # Secrets injection from Parameter Store and Secrets Manager
      secrets = [
        {
          name      = "LITELLM_CONFIG"
          valueFrom = aws_ssm_parameter.litellm_config.arn
        },
        {
          name      = "LITELLM_MASTER_KEY"
          valueFrom = local.master_key_secret_arn
        }
      ]

      # Start command: materialize config from env var to /tmp, then start LiteLLM
      # Uses printf (not echo) to preserve YAML escapes; exec so litellm is PID 1
      # Reference ADR-005: config injection via SSM with ephemeral /tmp materialization
      entryPoint = ["sh", "-c"]
      command = [
        "printf '%s' \"$LITELLM_CONFIG\" > /tmp/config.yaml && exec litellm --config /tmp/config.yaml --port ${var.container_port}"
      ]

      # Health check: Python urllib-based HTTP check to /health/liveliness endpoint
      # Python is used because the LiteLLM image is Python-based and curl is not guaranteed
      healthCheck = {
        command     = ["CMD-SHELL", "python3 -c \"import urllib.request; urllib.request.urlopen('http://localhost:${var.container_port}/health/liveliness')\" || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }

      # CloudWatch Logs: send container logs to the gateway log group
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.gateway.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "gateway"
        }
      }
    }
  ])

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway"
    }
  )
}

# ALB Security Group: ingress 443 from VPC CIDR, egress only to service SG on container_port
# Standalone rules allow service SG to reference ALB SG without circular dependency
resource "aws_security_group" "alb" {
  name_prefix = "${local.name_prefix}-gateway-alb-"
  description = "Security group for ECS LLM Gateway ALB"
  vpc_id      = var.vpc_id

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway-alb-sg"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

# ALB SG: Ingress on HTTPS (443) from VPC CIDR (internal clients only)
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id

  description = "Allow HTTPS from VPC CIDR (internal clients)"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"
  cidr_ipv4   = var.vpc_cidr

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway-alb-https-in"
    }
  )
}

# ALB SG: Egress only to service SG on container port (no other egress)
# This is part 1 of the SG-to-SG scoping; service SG ingress from ALB completes the chain
resource "aws_vpc_security_group_egress_rule" "alb_to_service" {
  security_group_id = aws_security_group.alb.id

  description                  = "Allow traffic to ECS service on container port"
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.service.id

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway-alb-to-svc"
    }
  )
}

# App SG: Egress to the ALB on 443. The gateway exists to be called by
# in-VPC workloads, which run in the app SG — but the network module's app SG
# only grants egress to VPC endpoints and the vector store, so without this
# rule no app-tier client can reach the ALB at all (found in the first live
# full-stack proof). Lives here, not in network: this module owns the ALB SG.
resource "aws_vpc_security_group_egress_rule" "app_to_alb" {
  security_group_id = var.app_security_group_id

  description                  = "Allow app-tier workloads to reach the gateway ALB"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway-app-to-alb"
    }
  )
}

# Service (ECS tasks) Security Group: ingress only from ALB SG
# Task egress (to Bedrock, S3, etc.) is provided by var.app_security_group_id
resource "aws_security_group" "service" {
  name_prefix = "${local.name_prefix}-gateway-svc-"
  description = "Security group for ECS LLM Gateway tasks"
  vpc_id      = var.vpc_id

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway-svc-sg"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

# Service SG: Ingress from ALB SG on container port (HTTP inside VPC; TLS terminates at ALB)
resource "aws_vpc_security_group_ingress_rule" "service_from_alb" {
  security_group_id = aws_security_group.service.id

  description                  = "Allow traffic from ALB on container port"
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway-svc-from-alb"
    }
  )
}

# Note: No egress rules on service SG. Task egress (Bedrock, S3, KMS, etc.) is scoped by
# var.app_security_group_id (network module's app SG), which is attached to tasks alongside
# this service SG. This approach allows the network module to own egress policy.

# Application Load Balancer (internal, private subnets only)
# Name is <= 32 chars; project and environment names are short (typically < 20 chars combined)
resource "aws_lb" "gateway" {
  name               = "${local.name_prefix}-gateway"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.private_subnet_ids

  enable_deletion_protection = var.enable_deletion_protection
  drop_invalid_header_fields = true
  idle_timeout               = 120 # Streaming responses may take time; 120s allows longer streams

  access_logs {
    bucket  = var.alb_logs_bucket_id
    prefix  = "alb"
    enabled = true
  }

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway-alb"
    }
  )
}

# Target Group: HTTP on container_port (TLS terminates at ALB; ALB→task hop is plaintext HTTP
# inside VPC, mitigated by SG-to-SG scoping and no-egress network isolation)
resource "aws_lb_target_group" "gateway" {
  name_prefix = "gw"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  deregistration_delay = 30

  health_check {
    path                = "/health/liveliness"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    port                = "traffic-port"
  }

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway-tg"
    }
  )
}

# Self-signed certificate resources (count = 1 when create_self_signed_cert = true)
# SANDBOX ONLY: private key lands in Terraform state. Production uses ACM Private CA (~$400/month).

resource "tls_private_key" "self_signed" {
  count     = var.create_self_signed_cert ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "self_signed" {
  count             = var.create_self_signed_cert ? 1 : 0
  private_key_pem   = tls_private_key.self_signed[0].private_key_pem
  is_ca_certificate = false

  subject {
    common_name = "${local.name_prefix}-gateway.internal"
  }

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth"
  ]
}

# Import self-signed cert into ACM (count = 1 when create_self_signed_cert = true)
resource "aws_acm_certificate" "self_signed" {
  count            = var.create_self_signed_cert ? 1 : 0
  private_key      = tls_private_key.self_signed[0].private_key_pem
  certificate_body = tls_self_signed_cert.self_signed[0].cert_pem

  # An in-use listener certificate cannot be deleted before its replacement exists
  lifecycle {
    create_before_destroy = true
  }

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway-cert"
    }
  )
}

# HTTPS Listener (443 only; no HTTP listener anywhere)
# TLS 1.2 / 1.3 per AWS security best practices
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.gateway.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }
}

# ECS Service: links cluster, task definition, target group, and network configuration
resource "aws_ecs_service" "gateway" {
  name            = "${local.name_prefix}-gateway"
  cluster         = aws_ecs_cluster.gateway.id
  task_definition = aws_ecs_task_definition.gateway.arn
  desired_count   = var.desired_count

  # Autoscaling owns desired_count after deployment
  lifecycle {
    ignore_changes = [desired_count]
  }

  # Capacity provider strategy: FARGATE base 1 weight 1 always; FARGATE_SPOT optional (nonprod)
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }

  # Spot interruption kills tasks with 2 minutes' notice — nonprod only
  dynamic "capacity_provider_strategy" {
    for_each = var.enable_fargate_spot ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      weight            = 4
    }
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.app_security_group_id, aws_security_group.service.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.gateway.arn
    container_name   = "gateway"
    container_port   = var.container_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Single-task demo: min healthy 100% keeps the old task serving until the new one
  # passes health checks; max 200% allows the replacement to start alongside it.
  # Production guidance (>= 2 tasks across AZs) is in the README.
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  health_check_grace_period_seconds = 120
  enable_execute_command            = var.enable_execute_command # WARNING: ECS Exec has audit implications

  propagate_tags = "SERVICE"

  depends_on = [aws_lb_listener.https]

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway"
    }
  )
}

# Auto Scaling Target for the ECS service
resource "aws_appautoscaling_target" "ecs_service" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${aws_ecs_cluster.gateway.name}/${aws_ecs_service.gateway.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# Auto Scaling Policy: Target-tracking on CPU utilization
resource "aws_appautoscaling_policy" "cpu_scaling" {
  name               = "${local.name_prefix}-gateway-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.cpu_target_value
    scale_in_cooldown  = 300 # Conservative scale-in avoids thrashing on bursty LLM traffic
    scale_out_cooldown = 60
  }
}

# Auto Scaling Policy: Target-tracking on request count per task
resource "aws_appautoscaling_policy" "request_count_scaling" {
  name               = "${local.name_prefix}-gateway-request-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.gateway.arn_suffix}/${aws_lb_target_group.gateway.arn_suffix}"
    }
    target_value       = var.request_count_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# CloudWatch Alarms: baseline set (full observability is week 6)

# Alarm 1: Unhealthy hosts in target group
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${local.name_prefix}-gateway-unhealthy-hosts"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 5
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = {
    LoadBalancer = aws_lb.gateway.arn_suffix
    TargetGroup  = aws_lb_target_group.gateway.arn_suffix
  }

  alarm_description = "Alert when ALB target group has unhealthy hosts"
  alarm_actions     = var.alarm_topic_arn != null ? [var.alarm_topic_arn] : []
  ok_actions        = var.alarm_topic_arn != null ? [var.alarm_topic_arn] : []

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway-unhealthy-hosts"
    }
  )
}

# Alarm 2: Target 5xx errors
resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${local.name_prefix}-gateway-target-5xx"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.gateway.arn_suffix
    TargetGroup  = aws_lb_target_group.gateway.arn_suffix
  }

  alarm_description = "Alert when target returns >= 10 5xx errors in 5 minutes"
  alarm_actions     = var.alarm_topic_arn != null ? [var.alarm_topic_arn] : []
  ok_actions        = var.alarm_topic_arn != null ? [var.alarm_topic_arn] : []

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway-target-5xx"
    }
  )
}

# Alarm 3: Running task count floor (detect restart churn)
resource "aws_cloudwatch_metric_alarm" "running_task_count" {
  alarm_name          = "${local.name_prefix}-gateway-running-tasks"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Minimum"
  threshold           = var.min_capacity
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.gateway.name
    ServiceName = aws_ecs_service.gateway.name
  }

  alarm_description = "Alert when running task count falls below min_capacity (indicates restart churn)"
  alarm_actions     = var.alarm_topic_arn != null ? [var.alarm_topic_arn] : []
  ok_actions        = var.alarm_topic_arn != null ? [var.alarm_topic_arn] : []

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway-running-tasks"
    }
  )
}

# Alarm 4: Target response time p95
resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  alarm_name          = "${local.name_prefix}-gateway-latency-p95"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  extended_statistic  = "p95"
  threshold           = var.latency_p95_threshold_seconds
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.gateway.arn_suffix
    TargetGroup  = aws_lb_target_group.gateway.arn_suffix
  }

  alarm_description = "Alert when p95 target response time exceeds threshold for 15 minutes (LLM completions are inherently slow; threshold tuned for full-response generation, not TTFB)"
  alarm_actions     = var.alarm_topic_arn != null ? [var.alarm_topic_arn] : []
  ok_actions        = var.alarm_topic_arn != null ? [var.alarm_topic_arn] : []

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-gateway-latency-p95"
    }
  )
}
