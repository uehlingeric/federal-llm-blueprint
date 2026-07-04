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
      region = "us-east-1"
    }
  }

  # Mock policy documents (valid JSON required)
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  # Mock IAM policy to provide a valid ARN
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/fedllm-dev-permission-boundary"
    }
  }
}

# Full variable configuration with all resource references
variables {
  project             = "fedllm"
  environment         = "dev"
  data_classification = "cui"

  # KMS keys (from kms module)
  kms_key_arns = {
    data    = "arn:aws:kms:us-east-1:123456789012:key/12345678-aaaa-bbbb-cccc-111111111111"
    logs    = "arn:aws:kms:us-east-1:123456789012:key/12345678-dddd-eeee-ffff-222222222222"
    secrets = "arn:aws:kms:us-east-1:123456789012:key/12345678-1111-2222-3333-333333333333"
  }

  # ECR repositories (from network/container module)
  ecr_repository_arns = [
    "arn:aws:ecr:us-east-1:123456789012:repository/fedllm-dev-gateway"
  ]

  # CloudWatch log groups (from observability module)
  log_group_arns = [
    "arn:aws:logs:us-east-1:123456789012:log-group:/aws/ecs/fedllm-dev-gateway",
    "arn:aws:logs:us-east-1:123456789012:log-group:/aws/ecs/fedllm-dev-seed"
  ]

  # Secrets (from secrets/external configuration)
  secret_arns = [
    "arn:aws:secretsmanager:us-east-1:123456789012:secret:fedllm-dev-api-key"
  ]

  # Bedrock models
  bedrock_model_ids = [
    "anthropic.claude-opus-20250219-v1:0"
  ]
  bedrock_inference_profile_arns = [
    "arn:aws:bedrock:us-east-1:123456789012:inference-profile/anthropic.claude-opus-20250219-v1:0"
  ]

  # S3 document store
  document_bucket_arns = [
    "arn:aws:s3:::fedllm-dev-documents"
  ]
  document_bucket_read_prefixes = [
    "arn:aws:s3:::fedllm-dev-documents/documents/*"
  ]

  # RDS database
  db_resource_ids = ["db-ABCDEF123456"]
  db_usernames    = ["app"]

  # CI/CD (GitHub Actions OIDC)
  ci_trust_principal_arns = [
    "arn:aws:iam::123456789012:role/github-actions-oidc"
  ]

  # Human role tiers
  human_trust_principals = {
    platform-admin = [
      "arn:aws:iam::123456789012:role/okta-admin"
    ]
    auditor = [
      "arn:aws:iam::123456789012:role/okta-auditor"
    ]
    developer = [
      "arn:aws:iam::123456789012:role/okta-developer"
    ]
  }
}

run "boundary_attached_to_all_roles" {
  command = apply

  # Assert: task_execution role has boundary
  assert {
    condition     = aws_iam_role.task_execution.permissions_boundary != null && aws_iam_role.task_execution.permissions_boundary != ""
    error_message = "task_execution role must have permissions_boundary set"
  }

  # Assert: app_task role has boundary
  assert {
    condition     = aws_iam_role.app_task.permissions_boundary != null && aws_iam_role.app_task.permissions_boundary != ""
    error_message = "app_task role must have permissions_boundary set"
  }

  # Assert: ci_deploy role has boundary (exists because ci_trust_principal_arns is non-empty)
  assert {
    condition     = length(aws_iam_role.ci_deploy) == 1 && aws_iam_role.ci_deploy[0].permissions_boundary != null && aws_iam_role.ci_deploy[0].permissions_boundary != ""
    error_message = "ci_deploy role must exist and have permissions_boundary set"
  }

  # Assert: all human tier roles have boundary
  assert {
    condition     = alltrue([for role in aws_iam_role.human_tier : role.permissions_boundary != null && role.permissions_boundary != ""])
    error_message = "all human tier roles must have permissions_boundary set"
  }
}

run "role_paths_correct" {
  command = apply

  # Assert: task_execution path is correct
  assert {
    condition     = aws_iam_role.task_execution.path == "/fedllm/"
    error_message = "task_execution role path must be /fedllm/"
  }

  # Assert: app_task path is correct
  assert {
    condition     = aws_iam_role.app_task.path == "/fedllm/"
    error_message = "app_task role path must be /fedllm/"
  }

  # Assert: ci_deploy path is correct
  assert {
    condition     = length(aws_iam_role.ci_deploy) == 1 && aws_iam_role.ci_deploy[0].path == "/fedllm/"
    error_message = "ci_deploy role path must be /fedllm/"
  }

  # Assert: human tier paths are correct
  assert {
    condition     = alltrue([for role in aws_iam_role.human_tier : role.path == "/fedllm/"])
    error_message = "all human tier roles must have path /fedllm/"
  }
}

run "permission_boundary_resource_exists" {
  command = apply

  # Assert: boundary policy exists with correct name
  assert {
    condition     = aws_iam_policy.permission_boundary.name == "fedllm-dev-permission-boundary"
    error_message = "permission boundary policy name must be fedllm-dev-permission-boundary"
  }

  # Assert: boundary policy has correct path
  assert {
    condition     = aws_iam_policy.permission_boundary.path == "/fedllm/"
    error_message = "permission boundary policy path must be /fedllm/"
  }

  # Assert: boundary policy ARN references match
  assert {
    condition     = aws_iam_role.task_execution.permissions_boundary == aws_iam_policy.permission_boundary.arn
    error_message = "task_execution boundary ARN must match permission_boundary policy ARN"
  }
}
