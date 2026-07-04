mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name = "us-east-1"
    }
  }

  # Mocked policy documents must still render as valid JSON
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

# Test: Custom domain addition (e.g., backups) creates 4 keys
run "custom_domain_backups" {
  command = plan

  variables {
    project     = "fedllm"
    environment = "dev"
    domains = {
      data = {
        description  = "Data at rest: RDS storage, S3 objects, EBS"
        via_services = ["s3", "rds"]
      }
      logs = {
        description  = "CloudWatch log groups, CloudTrail, flow logs"
        via_services = ["logs"]
      }
      secrets = {
        description  = "Secrets Manager secrets"
        via_services = ["secretsmanager"]
      }
      backups = {
        description  = "RDS backups and cross-region snapshots"
        via_services = ["s3"]
      }
    }
  }

  assert {
    condition     = length(aws_kms_key.this) == 4
    error_message = "Expected 4 KMS keys when backups domain is added"
  }

  assert {
    condition     = contains(keys(aws_kms_key.this), "backups")
    error_message = "Expected backups domain key to be created"
  }

  assert {
    condition     = length(aws_kms_alias.this) == 4
    error_message = "Expected 4 KMS aliases when backups domain is added"
  }

  assert {
    condition     = aws_kms_alias.this["backups"].name == "alias/fedllm-dev-backups"
    error_message = "Expected backups alias name to be alias/fedllm-dev-backups"
  }
}
