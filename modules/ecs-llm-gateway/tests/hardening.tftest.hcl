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

  # The mocked-apply run below resolves computed attributes; without these defaults
  # the mock generates random strings that fail the provider's ARN syntax validation
  # on downstream resources (listener, autoscaling, container secrets).
  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/mock-alb/1234567890abcdef"
      arn_suffix = "app/mock-alb/1234567890abcdef"
      dns_name   = "internal-mock-alb.elb.us-east-1.amazonaws.com"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/mock-tg/1234567890abcdef"
      arn_suffix = "targetgroup/mock-tg/1234567890abcdef"
    }
  }

  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:fedllm-dev-gateway-master-key-AbCdEf"
    }
  }

  mock_resource "aws_ssm_parameter" {
    defaults = {
      arn = "arn:aws:ssm:us-east-1:123456789012:parameter/fedllm/dev/gateway/litellm-config"
    }
  }

  mock_resource "aws_ecs_cluster" {
    defaults = {
      arn = "arn:aws:ecs:us-east-1:123456789012:cluster/fedllm-dev-gateway"
    }
  }

  mock_resource "aws_ecs_task_definition" {
    defaults = {
      arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/fedllm-dev-gateway:1"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
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
  container_user          = "1000"
  config_yaml             = "model_list: []"
  alb_logs_bucket_id      = "my-alb-logs-bucket"
  create_self_signed_cert = true
  certificate_arn         = null
}

run "hardening_checks" {
  command = plan

  # Assert: Task definition is configured for awsvpc network mode
  assert {
    condition     = aws_ecs_task_definition.gateway.network_mode == "awsvpc"
    error_message = "Task definition must use awsvpc network mode"
  }

  # Assert: Task definition requires FARGATE compatibility
  assert {
    condition     = contains(aws_ecs_task_definition.gateway.requires_compatibilities, "FARGATE")
    error_message = "Task definition must require FARGATE compatibility"
  }

  # Assert: /tmp ephemeral volume exists
  assert {
    condition     = length([for v in aws_ecs_task_definition.gateway.volume : v.name if v.name == "tmp"]) > 0
    error_message = "Task definition must include tmp ephemeral volume"
  }

  # Assert: Service has assign_public_ip = false
  assert {
    condition     = aws_ecs_service.gateway.network_configuration[0].assign_public_ip == false
    error_message = "Service must not assign public IPs"
  }

  # Assert: enable_execute_command defaults to false for security
  assert {
    condition     = aws_ecs_service.gateway.enable_execute_command == false
    error_message = "enable_execute_command should default to false for security hardening"
  }

  # Assert: Log group is encrypted with the logs KMS key
  assert {
    condition     = aws_cloudwatch_log_group.gateway.kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/12345678-aaaa-bbbb-cccc-111111111111"
    error_message = "Log group must be encrypted with the logs KMS key"
  }

  # Assert: SSM parameter is SecureString type
  assert {
    condition     = aws_ssm_parameter.litellm_config.type == "SecureString"
    error_message = "Config parameter must be SecureString type"
  }

  # Assert: SSM parameter uses secrets KMS key
  assert {
    condition     = aws_ssm_parameter.litellm_config.key_id == "arn:aws:kms:us-east-1:123456789012:key/12345678-dddd-eeee-ffff-222222222222"
    error_message = "Config parameter must be encrypted with secrets KMS key"
  }
}

# Container-level hardening lives inside the jsonencode'd container_definitions string,
# which is unknown at plan time (it interpolates computed ARNs). A mocked apply resolves
# those, letting us decode and assert on the actual container definition. No AWS calls.
# Index 0 is the tmp-init volume-permission container; index 1 is the gateway.
run "container_definition_hardening" {
  command = apply

  assert {
    condition     = jsondecode(aws_ecs_task_definition.gateway.container_definitions)[1].readonlyRootFilesystem == true
    error_message = "Gateway container must set readonlyRootFilesystem = true"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.gateway.container_definitions)[1].user == "1000"
    error_message = "Gateway container must run as the non-root user from var.container_user"
  }

  # privileged must not be set at all (Fargate rejects it; absence is the hardened state)
  assert {
    condition     = !can(jsondecode(aws_ecs_task_definition.gateway.container_definitions)[1].privileged)
    error_message = "Gateway container definition must not set the privileged flag"
  }

  assert {
    condition = length([
      for m in jsondecode(aws_ecs_task_definition.gateway.container_definitions)[1].mountPoints :
      m if m.containerPath == "/tmp" && m.sourceVolume == "tmp" && m.readOnly == false
    ]) == 1
    error_message = "Gateway container must mount the writable tmp ephemeral volume at /tmp"
  }

  assert {
    condition = toset([
      for s in jsondecode(aws_ecs_task_definition.gateway.container_definitions)[1].secrets : s.name
    ]) == toset(["LITELLM_CONFIG", "LITELLM_MASTER_KEY"])
    error_message = "Gateway container secrets must inject exactly LITELLM_CONFIG and LITELLM_MASTER_KEY"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.gateway.container_definitions)[1].image == var.container_image
    error_message = "Gateway container image must be exactly the digest-pinned var.container_image"
  }

  # The entrypoint override materializes config to /tmp and exec's litellm as PID 1
  assert {
    condition     = can(regex("exec litellm --config /tmp/config.yaml", jsondecode(aws_ecs_task_definition.gateway.container_definitions)[1].command[0]))
    error_message = "Gateway container command must exec litellm against the materialized /tmp/config.yaml"
  }

  assert {
    condition     = can(regex("/health/liveliness", jsondecode(aws_ecs_task_definition.gateway.container_definitions)[1].healthCheck.command[1]))
    error_message = "Gateway container health check must probe /health/liveliness"
  }

  # tmp-init: Fargate bind mounts are root-owned 0755, so a throwaway root
  # container restores 1777 on the volume before the non-root gateway starts
  assert {
    condition     = jsondecode(aws_ecs_task_definition.gateway.container_definitions)[0].name == "tmp-init" && jsondecode(aws_ecs_task_definition.gateway.container_definitions)[0].essential == false
    error_message = "tmp-init container must exist at index 0 and be non-essential"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.gateway.container_definitions)[0].command[0] == "chmod 1777 /tmp"
    error_message = "tmp-init must do exactly one thing: chmod 1777 the tmp volume"
  }

  assert {
    condition     = !can(jsondecode(aws_ecs_task_definition.gateway.container_definitions)[0].secrets)
    error_message = "tmp-init must not receive any secrets"
  }

  assert {
    condition = length([
      for d in jsondecode(aws_ecs_task_definition.gateway.container_definitions)[1].dependsOn :
      d if d.containerName == "tmp-init" && d.condition == "SUCCESS"
    ]) == 1
    error_message = "Gateway container must depend on tmp-init SUCCESS"
  }
}
