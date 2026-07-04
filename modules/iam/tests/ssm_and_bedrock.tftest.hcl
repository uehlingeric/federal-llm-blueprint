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
      name   = "us-east-1"
      region = "us-east-1"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

# The mocked aws_iam_policy_document returns canned json, so assertions target the
# data source's expanded statement blocks (plan-known config) rather than rendered json.

run "ssm_parameters_grant_task_execution_read" {
  command = plan

  variables {
    project             = "fedllm"
    environment         = "dev"
    data_classification = "cui"
    kms_key_arns        = { secrets = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012" }
    ssm_parameter_arns  = ["arn:aws:ssm:us-east-1:123456789012:parameter/fedllm/dev/gateway/litellm-config"]
    secret_arns         = []
  }

  # Assert: SSMGetParameters statement present, scoped to the supplied parameter ARN
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.task_execution.statement :
      s.sid == "SSMGetParameters" && tolist(s.resources) == tolist(["arn:aws:ssm:us-east-1:123456789012:parameter/fedllm/dev/gateway/litellm-config"])
    ])
    error_message = "task_execution must gain an SSMGetParameters statement scoped to the supplied parameter ARNs"
  }

  # Assert: KMSDecryptSecrets is created for SSM alone and its ViaService lists ssm (not secretsmanager)
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.task_execution.statement :
      s.sid == "KMSDecryptSecrets" && anytrue([
        for c in s.condition : contains(c.values, "ssm.us-east-1.amazonaws.com") && !contains(c.values, "secretsmanager.us-east-1.amazonaws.com")
      ])
    ])
    error_message = "KMSDecryptSecrets ViaService must include ssm and exclude secretsmanager when only SSM parameters are supplied"
  }

  # Assert: boundary carries the SSM read ceiling (grants intersect to nothing without it)
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.permission_boundary.statement :
      s.sid == "AllowSSMParameterRead"
    ])
    error_message = "permission boundary must include the AllowSSMParameterRead ceiling statement"
  }
}

run "ssm_and_secrets_together_list_both_via_services" {
  command = plan

  variables {
    project             = "fedllm"
    environment         = "dev"
    data_classification = "cui"
    kms_key_arns        = { secrets = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012" }
    ssm_parameter_arns  = ["arn:aws:ssm:us-east-1:123456789012:parameter/fedllm/dev/gateway/litellm-config"]
    secret_arns         = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:fedllm-dev-gateway-master-key-AbCdEf"]
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.task_execution.statement :
      s.sid == "KMSDecryptSecrets" && anytrue([
        for c in s.condition : contains(c.values, "ssm.us-east-1.amazonaws.com") && contains(c.values, "secretsmanager.us-east-1.amazonaws.com")
      ])
    ])
    error_message = "KMSDecryptSecrets ViaService must include both ssm and secretsmanager when both sources are supplied"
  }
}

run "no_ssm_parameters_omits_statement" {
  command = plan

  variables {
    project             = "fedllm"
    environment         = "dev"
    data_classification = "cui"
    ssm_parameter_arns  = []
    secret_arns         = []
  }

  assert {
    condition = !anytrue([
      for s in data.aws_iam_policy_document.task_execution.statement :
      s.sid == "SSMGetParameters"
    ])
    error_message = "SSMGetParameters statement must be omitted when ssm_parameter_arns is empty"
  }

  assert {
    condition = !anytrue([
      for s in data.aws_iam_policy_document.task_execution.statement :
      s.sid == "KMSDecryptSecrets"
    ])
    error_message = "KMSDecryptSecrets statement must be omitted when no secrets or parameters are supplied"
  }
}

run "startup_secrets_do_not_leak_into_app_task" {
  command = plan

  variables {
    project             = "fedllm"
    environment         = "dev"
    data_classification = "cui"
    kms_key_arns        = { secrets = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012" }
    secret_arns         = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:fedllm-dev-gateway-master-key-AbCdEf"]
    app_secret_arns     = []
  }

  # Assert: startup-injected secrets grant the execution role, never the app task
  assert {
    condition = !anytrue([
      for s in data.aws_iam_policy_document.app_task.statement :
      s.sid == "SecretsManagerRead" || s.sid == "KMSDecryptSecrets"
    ])
    error_message = "app_task must gain no Secrets Manager access from secret_arns (startup-injected secrets are execution-role only)"
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.task_execution.statement :
      s.sid == "SecretsManagerRead"
    ])
    error_message = "task_execution must retain SecretsManagerRead for startup-injected secrets"
  }
}

run "app_secret_arns_grant_app_task_read" {
  command = plan

  variables {
    project             = "fedllm"
    environment         = "dev"
    data_classification = "cui"
    kms_key_arns        = { secrets = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012" }
    app_secret_arns     = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:fedllm-dev-external-api-key-AbCdEf"]
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.app_task.statement :
      s.sid == "SecretsManagerRead" && tolist(s.resources) == tolist(["arn:aws:secretsmanager:us-east-1:123456789012:secret:fedllm-dev-external-api-key-AbCdEf"])
    ])
    error_message = "app_task must gain SecretsManagerRead scoped to app_secret_arns"
  }
}

run "bedrock_with_profiles_uses_wildcard_region" {
  command = plan

  variables {
    project                        = "fedllm"
    environment                    = "dev"
    data_classification            = "cui"
    bedrock_model_ids              = ["anthropic.claude-sonnet-4-5-20250929-v1:0"]
    bedrock_inference_profile_arns = ["arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-4-5-20250929-v1:0"]
  }

  # Cross-region profiles invoke destination-region models: the foundation-model ARN
  # region must be wildcarded, while the model ID (and the profile ARN) stay exact.
  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.app_task.statement :
      s.sid == "BedrockInvoke" &&
      contains(s.resources, "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0") &&
      contains(s.resources, "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-4-5-20250929-v1:0")
    ])
    error_message = "BedrockInvoke must wildcard the foundation-model region when inference profiles are supplied, keeping model IDs exact"
  }
}

run "bedrock_without_profiles_pins_current_region" {
  command = plan

  variables {
    project                        = "fedllm"
    environment                    = "dev"
    data_classification            = "cui"
    bedrock_model_ids              = ["anthropic.claude-sonnet-4-5-20250929-v1:0"]
    bedrock_inference_profile_arns = []
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.app_task.statement :
      s.sid == "BedrockInvoke" &&
      contains(s.resources, "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0")
    ])
    error_message = "BedrockInvoke must pin the current region when no inference profiles are supplied"
  }
}
