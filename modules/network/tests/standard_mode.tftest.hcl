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
  no_egress               = false
  enable_public_subnets   = true
  enable_nat_gateway      = true
  enable_flow_logs        = true
  flow_log_retention_days = 90
  flow_log_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012"
}

run "standard_mode_with_nat" {
  command = plan

  assert {
    condition     = length(aws_internet_gateway.main) == 1
    error_message = "Standard mode with public subnets must create one Internet Gateway"
  }

  assert {
    condition     = length(aws_nat_gateway.main) == 1
    error_message = "Standard mode with enable_nat_gateway must create one NAT Gateway"
  }

  assert {
    condition     = length(aws_eip.nat) == 1
    error_message = "Standard mode with enable_nat_gateway must create one Elastic IP"
  }

  assert {
    condition     = length(aws_subnet.public) >= 1
    error_message = "Standard mode with enable_public_subnets must create public subnets for each AZ"
  }

  assert {
    condition     = length(aws_subnet.private) >= 1
    error_message = "Standard mode must create private subnets for each AZ"
  }

  assert {
    condition     = length(aws_route.private_nat) >= 1
    error_message = "Private route tables must have default routes to NAT"
  }

  assert {
    condition     = length(aws_route.public_igw) == 1
    error_message = "Public route table must have default route to IGW"
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) >= 10
    error_message = "Endpoints should be present in standard mode"
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.flow_logs) == 1
    error_message = "Flow logs must be enabled in standard mode"
  }
}

run "standard_mode_public_subnet_count" {
  command = plan

  assert {
    condition     = length(aws_route_table_association.public) >= 1
    error_message = "Public subnets must be associated with public route table"
  }

  assert {
    condition     = length(aws_route_table_association.private) >= 1
    error_message = "Private subnets must be associated with private route tables"
  }
}
