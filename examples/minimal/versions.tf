terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Uncomment for remote state in production (week 8):
  # backend "s3" {
  #   bucket         = "fedllm-terraform-state"
  #   key            = "minimal/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "fedllm-terraform-locks"
  #   use_lockfile   = true
  # }
}
