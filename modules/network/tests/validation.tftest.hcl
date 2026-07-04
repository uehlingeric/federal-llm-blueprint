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

# Test 1: az_count = 4 should fail validation
run "invalid_az_count_fails" {
  command = plan

  variables {
    project                 = "fedllm"
    environment             = "dev"
    data_classification     = "cui"
    vpc_cidr                = "10.0.0.0/16"
    az_count                = 4
    no_egress               = false
    enable_public_subnets   = false
    enable_nat_gateway      = false
    enable_flow_logs        = true
    flow_log_retention_days = 90
    flow_log_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012"
  }

  expect_failures = [
    var.az_count
  ]
}

# Test 2: Invalid VPC CIDR should fail validation
run "invalid_vpc_cidr_fails" {
  command = plan

  variables {
    project                 = "fedllm"
    environment             = "dev"
    data_classification     = "cui"
    vpc_cidr                = "invalid-cidr"
    az_count                = 2
    no_egress               = false
    enable_public_subnets   = false
    enable_nat_gateway      = false
    enable_flow_logs        = true
    flow_log_retention_days = 90
    flow_log_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012"
  }

  expect_failures = [
    var.vpc_cidr
  ]
}

# Test 3: Invalid environment should fail validation
run "invalid_environment_fails" {
  command = plan

  variables {
    project                 = "fedllm"
    environment             = "invalid-env"
    data_classification     = "cui"
    vpc_cidr                = "10.0.0.0/16"
    az_count                = 2
    no_egress               = false
    enable_public_subnets   = false
    enable_nat_gateway      = false
    enable_flow_logs        = true
    flow_log_retention_days = 90
    flow_log_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012"
  }

  expect_failures = [
    var.environment
  ]
}

# Test 4: Invalid data_classification should fail validation
run "invalid_data_classification_fails" {
  command = plan

  variables {
    project                 = "fedllm"
    environment             = "dev"
    data_classification     = "invalid-classification"
    vpc_cidr                = "10.0.0.0/16"
    az_count                = 2
    no_egress               = false
    enable_public_subnets   = false
    enable_nat_gateway      = false
    enable_flow_logs        = true
    flow_log_retention_days = 90
    flow_log_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012"
  }

  expect_failures = [
    var.data_classification
  ]
}

# Cross-variable: no_egress = true forbids public subnets
run "no_egress_forbids_public_subnets" {
  command = plan

  variables {
    project                 = "fedllm"
    environment             = "dev"
    data_classification     = "cui"
    vpc_cidr                = "10.0.0.0/16"
    az_count                = 2
    no_egress               = true
    enable_public_subnets   = true
    enable_nat_gateway      = false
    enable_flow_logs        = true
    flow_log_retention_days = 90
    flow_log_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012"
  }

  expect_failures = [
    var.enable_public_subnets
  ]
}

# Cross-variable: NAT requires public subnets and standard mode
run "nat_requires_public_subnets" {
  command = plan

  variables {
    project                 = "fedllm"
    environment             = "dev"
    data_classification     = "cui"
    vpc_cidr                = "10.0.0.0/16"
    az_count                = 2
    no_egress               = false
    enable_public_subnets   = false
    enable_nat_gateway      = true
    enable_flow_logs        = true
    flow_log_retention_days = 90
    flow_log_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012"
  }

  expect_failures = [
    var.enable_nat_gateway
  ]
}
