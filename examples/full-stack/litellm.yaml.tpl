model_list:
  - model_name: ${model_name}
    litellm_params:
      model: bedrock/${bedrock_inference_profile_id}
      aws_region_name: ${region}
      rpm: 60

litellm_settings:
  drop_params: true
  max_budget: 100.0
  budget_duration: 30d

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
