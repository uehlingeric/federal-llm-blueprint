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

run "defaults_create_core_roles_only" {
  command = plan

  variables {
    project             = "fedllm"
    environment         = "dev"
    data_classification = "cui"
    # All other variables left at defaults (empty lists/maps)
  }

  # Assert: task_execution role is always created
  assert {
    condition     = length(aws_iam_role.task_execution) > 0
    error_message = "task_execution role must always be created"
  }

  # Assert: app_task role is always created
  assert {
    condition     = length(aws_iam_role.app_task) > 0
    error_message = "app_task role must always be created"
  }

  # Assert: ci_deploy role is NOT created (count = 0)
  assert {
    condition     = length(aws_iam_role.ci_deploy) == 0
    error_message = "ci_deploy role must not be created when ci_trust_principal_arns is empty"
  }

  # Assert: no human roles are created (for_each over empty map)
  assert {
    condition     = length(aws_iam_role.human_tier) == 0
    error_message = "no human roles should be created when human_trust_principals is empty"
  }

  # Assert: permission boundary is still created
  assert {
    condition     = length(aws_iam_policy.permission_boundary) > 0
    error_message = "permission boundary must always be created"
  }
}

run "ci_principal_creates_ci_deploy_role" {
  command = plan

  variables {
    project             = "fedllm"
    environment         = "dev"
    data_classification = "cui"
    ci_trust_principal_arns = [
      "arn:aws:iam::123456789012:role/github-actions"
    ]
  }

  # Assert: ci_deploy role IS created when ci_trust_principal_arns is non-empty
  assert {
    condition     = length(aws_iam_role.ci_deploy) == 1
    error_message = "ci_deploy role must be created when ci_trust_principal_arns is non-empty"
  }

  # Assert: human roles still not created
  assert {
    condition     = length(aws_iam_role.human_tier) == 0
    error_message = "no human roles should be created when human_trust_principals is empty"
  }
}

# New run: only human trust principals
run "human_principals_create_tier_roles" {
  command = plan

  variables {
    project                 = "fedllm"
    environment             = "dev"
    data_classification     = "cui"
    ci_trust_principal_arns = []
    human_trust_principals = {
      developer = [
        "arn:aws:iam::123456789012:role/okta-dev"
      ]
    }
  }

  # Assert: human developer role is created
  assert {
    condition     = contains(keys(aws_iam_role.human_tier), "developer")
    error_message = "developer role must be created when human_trust_principals contains 'developer'"
  }

  # Assert: other tiers are not created
  assert {
    condition     = !contains(keys(aws_iam_role.human_tier), "platform-admin") && !contains(keys(aws_iam_role.human_tier), "auditor")
    error_message = "only developer role should be created (auditor and platform-admin not supplied)"
  }

  # Assert: ci_deploy role is not created (count = 0 due to empty ci_trust_principal_arns)
  assert {
    condition     = length(aws_iam_role.ci_deploy) == 0
    error_message = "ci_deploy role must not be created when ci_trust_principal_arns is empty"
  }
}

# All tiers supplied
run "all_human_tiers_created" {
  command = plan

  variables {
    project             = "fedllm"
    environment         = "dev"
    data_classification = "cui"
    human_trust_principals = {
      platform-admin = ["arn:aws:iam::123456789012:role/admin"]
      auditor        = ["arn:aws:iam::123456789012:role/auditor"]
      developer      = ["arn:aws:iam::123456789012:role/dev"]
    }
  }

  # Assert: all three tiers are created
  assert {
    condition     = contains(keys(aws_iam_role.human_tier), "platform-admin") && contains(keys(aws_iam_role.human_tier), "auditor") && contains(keys(aws_iam_role.human_tier), "developer")
    error_message = "all three human tiers must be created when all supplied"
  }

  # Assert: exactly three roles
  assert {
    condition     = length(aws_iam_role.human_tier) == 3
    error_message = "exactly three human roles should be created"
  }
}
