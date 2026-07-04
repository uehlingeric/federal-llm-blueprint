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

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

# Test 1: invalid environment should fail validation
run "invalid_environment_fails" {
  command = plan

  variables {
    project             = "fedllm"
    environment         = "production" # Invalid: must be dev, staging, or prod
    data_classification = "cui"
  }

  expect_failures = [
    var.environment
  ]
}

# Test 2: invalid data_classification should fail validation
run "invalid_data_classification_fails" {
  command = plan

  variables {
    project             = "fedllm"
    environment         = "dev"
    data_classification = "secret" # Invalid: must be public, internal, or cui
  }

  expect_failures = [
    var.data_classification
  ]
}

# Test 3: valid minimal configuration should plan successfully
run "valid_minimal_config" {
  command = plan

  variables {
    project             = "fedllm"
    environment         = "dev"
    data_classification = "cui"
    # All other variables at defaults (empty lists/maps)
  }

  # Should succeed without expect_failures
  assert {
    condition     = aws_iam_role.task_execution != null
    error_message = "task_execution role should be created with minimal config"
  }
}

# Test 4: valid full configuration should plan successfully
run "valid_full_config" {
  command = plan

  variables {
    project             = "fedllm"
    environment         = "staging"  # Valid
    data_classification = "internal" # Valid

    kms_key_arns = {
      data    = "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-1111-1111-1111-111111111111"
      logs    = "arn:aws:kms:us-east-1:123456789012:key/bbbbbbbb-2222-2222-2222-222222222222"
      secrets = "arn:aws:kms:us-east-1:123456789012:key/cccccccc-3333-3333-3333-333333333333"
    }

    ecr_repository_arns = [
      "arn:aws:ecr:us-east-1:123456789012:repository/my-app"
    ]

    log_group_arns = [
      "arn:aws:logs:us-east-1:123456789012:log-group:/aws/ecs/my-app"
    ]

    secret_arns = [
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:my-key"
    ]

    bedrock_model_ids = [
      "anthropic.claude-opus-20250219-v1:0"
    ]

    bedrock_inference_profile_arns = [
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/some-profile"
    ]

    document_bucket_arns = [
      "arn:aws:s3:::my-documents"
    ]

    document_bucket_read_prefixes = [
      "arn:aws:s3:::my-documents/docs/*"
    ]

    db_resource_ids = [
      "db-XYZABC123"
    ]
    db_usernames = [
      "app_user"
    ]

    ci_trust_principal_arns = [
      "arn:aws:iam::123456789012:role/ci-role"
    ]

    human_trust_principals = {
      platform-admin = ["arn:aws:iam::123456789012:role/admin"]
      auditor        = ["arn:aws:iam::123456789012:role/auditor"]
      developer      = ["arn:aws:iam::123456789012:role/dev"]
    }

    tags = {
      Owner = "Platform"
    }
  }

  # Should succeed
  assert {
    condition     = aws_iam_role.task_execution != null
    error_message = "task_execution role should be created"
  }

  assert {
    condition     = aws_iam_role.app_task != null
    error_message = "app_task role should be created"
  }

  assert {
    condition     = length(aws_iam_role.ci_deploy) == 1
    error_message = "ci_deploy role should be created"
  }

  assert {
    condition     = length(aws_iam_role.human_tier) == 3
    error_message = "all three human tiers should be created"
  }
}

# Test 5: invalid data classification in prod environment
run "invalid_data_classification_prod" {
  command = plan

  variables {
    project             = "fedllm"
    environment         = "prod"
    data_classification = "restricted" # Will fail — allowed values are public, internal, cui only
  }

  expect_failures = [
    var.data_classification
  ]
}
