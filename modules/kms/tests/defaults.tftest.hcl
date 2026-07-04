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

# Test 1: Default configuration creates 3 keys (data, logs, secrets)
run "defaults_creates_three_keys" {
  command = plan

  variables {
    project     = "fedllm"
    environment = "dev"
  }

  assert {
    condition     = length(aws_kms_key.this) == 3
    error_message = "Expected 3 KMS keys (data, logs, secrets) with default domains configuration"
  }

  assert {
    condition     = contains(keys(aws_kms_key.this), "data")
    error_message = "Expected data domain key to be created"
  }

  assert {
    condition     = contains(keys(aws_kms_key.this), "logs")
    error_message = "Expected logs domain key to be created"
  }

  assert {
    condition     = contains(keys(aws_kms_key.this), "secrets")
    error_message = "Expected secrets domain key to be created"
  }
}

# Test 2: All keys have rotation enabled by default
run "defaults_key_rotation_enabled" {
  command = plan

  variables {
    project     = "fedllm"
    environment = "dev"
  }

  assert {
    condition     = aws_kms_key.this["data"].enable_key_rotation == true
    error_message = "Expected data key to have rotation enabled"
  }

  assert {
    condition     = aws_kms_key.this["logs"].enable_key_rotation == true
    error_message = "Expected logs key to have rotation enabled"
  }

  assert {
    condition     = aws_kms_key.this["secrets"].enable_key_rotation == true
    error_message = "Expected secrets key to have rotation enabled"
  }
}

# Test 3: All keys have default deletion window of 30 days
run "defaults_deletion_window" {
  command = plan

  variables {
    project     = "fedllm"
    environment = "dev"
  }

  assert {
    condition     = aws_kms_key.this["data"].deletion_window_in_days == 30
    error_message = "Expected data key deletion_window_in_days to be 30"
  }

  assert {
    condition     = aws_kms_key.this["logs"].deletion_window_in_days == 30
    error_message = "Expected logs key deletion_window_in_days to be 30"
  }

  assert {
    condition     = aws_kms_key.this["secrets"].deletion_window_in_days == 30
    error_message = "Expected secrets key deletion_window_in_days to be 30"
  }
}

# Test 4: Three aliases are created with expected names
run "defaults_creates_three_aliases" {
  command = plan

  variables {
    project     = "fedllm"
    environment = "dev"
  }

  assert {
    condition     = length(aws_kms_alias.this) == 3
    error_message = "Expected 3 KMS aliases (data, logs, secrets)"
  }

  assert {
    condition     = contains(keys(aws_kms_alias.this), "data")
    error_message = "Expected data domain alias to be created"
  }

  assert {
    condition     = contains(keys(aws_kms_alias.this), "logs")
    error_message = "Expected logs domain alias to be created"
  }

  assert {
    condition     = contains(keys(aws_kms_alias.this), "secrets")
    error_message = "Expected secrets domain alias to be created"
  }
}

# Test 5: Alias names follow naming convention
run "defaults_alias_naming" {
  command = plan

  variables {
    project     = "fedllm"
    environment = "dev"
  }

  assert {
    condition     = aws_kms_alias.this["data"].name == "alias/fedllm-dev-data"
    error_message = "Expected data alias name to be alias/fedllm-dev-data"
  }

  assert {
    condition     = aws_kms_alias.this["logs"].name == "alias/fedllm-dev-logs"
    error_message = "Expected logs alias name to be alias/fedllm-dev-logs"
  }

  assert {
    condition     = aws_kms_alias.this["secrets"].name == "alias/fedllm-dev-secrets"
    error_message = "Expected secrets alias name to be alias/fedllm-dev-secrets"
  }
}

# Test 6: Outputs have expected keys
run "defaults_output_keys" {
  command = plan

  variables {
    project     = "fedllm"
    environment = "dev"
  }

  assert {
    condition = (
      contains(keys(output.key_arns), "data") &&
      contains(keys(output.key_arns), "logs") &&
      contains(keys(output.key_arns), "secrets")
    )
    error_message = "Expected key_arns output to have data, logs, secrets keys"
  }

  assert {
    condition = (
      contains(keys(output.key_ids), "data") &&
      contains(keys(output.key_ids), "logs") &&
      contains(keys(output.key_ids), "secrets")
    )
    error_message = "Expected key_ids output to have data, logs, secrets keys"
  }

  assert {
    condition = (
      contains(keys(output.alias_arns), "data") &&
      contains(keys(output.alias_arns), "logs") &&
      contains(keys(output.alias_arns), "secrets")
    )
    error_message = "Expected alias_arns output to have data, logs, secrets keys"
  }
}
