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

# Test 1: Invalid deletion_window_in_days (< 7)
run "invalid_deletion_window_too_small" {
  command = plan

  variables {
    project                 = "fedllm"
    environment             = "dev"
    data_classification     = "cui"
    deletion_window_in_days = 3
  }

  expect_failures = [
    var.deletion_window_in_days
  ]
}

# Test 2: Invalid deletion_window_in_days (> 30)
run "invalid_deletion_window_too_large" {
  command = plan

  variables {
    project                 = "fedllm"
    environment             = "dev"
    data_classification     = "cui"
    deletion_window_in_days = 45
  }

  expect_failures = [
    var.deletion_window_in_days
  ]
}

# Test 3: Invalid environment
run "invalid_environment_fails" {
  command = plan

  variables {
    project     = "fedllm"
    environment = "production"
  }

  expect_failures = [
    var.environment
  ]
}

# Test 4: Invalid data_classification
run "invalid_data_classification_fails" {
  command = plan

  variables {
    project             = "fedllm"
    environment         = "dev"
    data_classification = "unclassified"
  }

  expect_failures = [
    var.data_classification
  ]
}
