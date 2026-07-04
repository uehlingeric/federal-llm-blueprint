# Minimal Example

The smallest deployable slice of the blueprint. Demonstrates the network module in both no-egress and standard-private modes.

## What This Deploys

- **VPC** with private-subnet architecture across 2 availability zones
- **VPC Endpoints** for Bedrock (runtime + agent), S3, ECR, CloudWatch Logs, KMS, Secrets Manager, ECS, and STS
- **Security Groups** for application workloads and endpoint access
- **VPC Flow Logs** encrypted with a temporary KMS key (replaced by modules/kms in week 3)
- **No-egress mode** (default): Zero Internet Gateways, zero NAT Gateways. All AWS service traffic routes through private VPC endpoints.
- **Standard mode** (optional): Public subnets and optional NAT Gateway for standard private-VPC deployments with outbound internet access.

## Modes

### No-Egress Mode (Default: `no_egress = true`)

- No public subnets
- No Internet Gateway
- No NAT Gateway
- All AWS service traffic via VPC endpoints with private DNS resolution enabled
- Suitable for federal/air-gap environments and GovCloud deployments

### Standard Mode (`no_egress = false`)

- Optional public subnets (default: disabled in this example)
- Optional NAT Gateway (default: disabled in this example)
- Same VPC endpoints as no-egress mode (endpoints are the primary AWS-service path in both modes)
- Suitable for corporate private-VPC deployments with optional internet egress

## Quick Start

1. Copy `terraform.tfvars.example` to `terraform.tfvars`:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Adjust variables (project, environment, region, no_egress mode):
   ```bash
   cat terraform.tfvars
   ```

3. Plan and apply:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

4. View outputs:
   ```bash
   terraform output -json
   ```

5. Destroy (careful with ENI cleanup):
   ```bash
   terraform destroy
   ```

## Prerequisites

- AWS account with appropriate permissions (VPC, KMS, CloudWatch Logs, etc.)
- Terraform >= 1.9.0
- AWS CLI configured with credentials
- **Not required**: Bedrock model access (until week 4)

## Cost

This example provisions:
- 1 VPC: ~$0/month
- 2–3 private subnets: ~$0/month
- 10 interface VPC endpoints: ~$7–8/month each (biggest line item)
- 1 S3 gateway endpoint: ~$0/month
- VPC Flow Logs: minimal cost
- Temporary KMS key: ~$1/month (week 2 only; replaced by modules/kms in week 3)

**Estimated cost: ~$70–80/month** for the minimal example. The interface endpoints dominate; consider disabling unused endpoints via `var.interface_endpoints` to reduce cost during development.

## Known Gotchas

- **VPC Endpoint ENI cleanup**: Interface endpoints create elastic network interfaces that can take 30+ seconds to detach and delete during `terraform destroy`. If destroy times out, manually force-detach the ENIs in the AWS console.
- **Bedrock availability**: Bedrock endpoints are not available in all AWS regions. In `us-east-1` (default), both Bedrock runtime and agent endpoints are available. In other regions, verify endpoint availability in the AWS documentation before deploying.
- **Flow logs key policy**: The temporary KMS key in this example has a simple policy allowing the CloudWatch Logs service. In production (week 3), modules/kms provides a more comprehensive key policy.

## Files

- `main.tf`: VPC and KMS key (temporary)
- `variables.tf`: Project, environment, region, mode toggle
- `outputs.tf`: Network module outputs
- `versions.tf`: Provider requirements
- `terraform.tfvars.example`: Example configuration

## Next Week

Week 3 introduces the KMS module. Replace the `aws_kms_key` resource in `main.tf` with a call to `module "kms"` that produces keys for data, logs, and secrets domains.
