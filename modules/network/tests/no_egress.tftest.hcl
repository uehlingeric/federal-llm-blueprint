mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
      name   = "us-east-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  # Mocked policy documents must still render as valid JSON or resources
  # that validate their policy arguments fail at plan time.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  project                 = "fedllm"
  environment             = "dev"
  data_classification     = "cui"
  vpc_cidr                = "10.0.0.0/16"
  az_count                = 2
  no_egress               = true
  enable_public_subnets   = false
  enable_nat_gateway      = false
  enable_flow_logs        = true
  flow_log_retention_days = 90
  flow_log_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012"
}

run "no_egress_mode" {
  command = plan

  assert {
    condition     = length(aws_internet_gateway.main) == 0
    error_message = "No-egress mode must create zero Internet Gateways"
  }

  assert {
    condition     = length(aws_nat_gateway.main) == 0
    error_message = "No-egress mode must create zero NAT Gateways"
  }

  assert {
    condition     = length(aws_eip.nat) == 0
    error_message = "No-egress mode must create zero Elastic IPs"
  }

  assert {
    condition     = length(aws_subnet.public) == 0
    error_message = "No-egress mode must create zero public subnets"
  }

  assert {
    condition     = length(aws_subnet.private) >= 1
    error_message = "No-egress mode must create private subnets for each AZ"
  }

  assert {
    condition     = alltrue([for k in ["bedrock-runtime", "bedrock-agent-runtime", "ecr-api", "ecr-dkr", "logs", "kms", "secretsmanager", "ecs", "ecs-telemetry", "ssm", "sts"] : contains(keys(aws_vpc_endpoint.interface), k)])
    error_message = "All eleven default interface endpoints must be present in no-egress mode"
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 90
    error_message = "Flow log retention must honor var.flow_log_retention_days (90 in this run)"
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) >= 10
    error_message = "All default interface endpoints must be present"
  }

  assert {
    condition     = length(aws_vpc_endpoint.s3) > 0
    error_message = "S3 gateway endpoint must be present"
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.flow_logs) == 1
    error_message = "Flow logs must be enabled"
  }
}

run "no_egress_route_table_validation" {
  command = plan

  assert {
    condition     = length(aws_route.private_nat) == 0
    error_message = "No-egress mode must have zero NAT routes in private route tables"
  }

  assert {
    condition     = length(aws_route.public_igw) == 0
    error_message = "No-egress mode must have zero public route tables"
  }
}
