# Security Groups for VPC endpoint traffic and application workloads

# Endpoint Security Group: Allows HTTPS (443) from the VPC CIDR only
# Used by all interface VPC endpoints. Ingress restricted to port 443 from the VPC.
# No explicit egress rules needed (stateful SG).
resource "aws_security_group" "endpoint" {
  name_prefix = "${local.name_prefix}-endpoint-"
  description = "Security group for VPC interface endpoints"
  vpc_id      = aws_vpc.main.id

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-endpoint-sg"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

# Endpoint SG: Allow HTTPS from VPC CIDR
resource "aws_vpc_security_group_ingress_rule" "endpoint_https" {
  security_group_id = aws_security_group.endpoint.id

  description = "Allow HTTPS from VPC CIDR (endpoint clients)"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"
  cidr_ipv4   = var.vpc_cidr

  tags = {
    Name = "allow-https-from-vpc"
  }
}

# Application Security Group: For ECS tasks and application workloads
# In no-egress mode, egress is restricted to:
#   - 443 to endpoint SG (AWS service API calls)
#   - 443 to S3 gateway endpoint prefix list (S3 access)
#   - 5432 within VPC CIDR (vector store RDS access)
# In standard mode, consumers can extend with additional egress rules as needed.
resource "aws_security_group" "app" {
  #checkov:skip=CKV2_AWS_5: This SG is attached to ECS tasks by the ecs-llm-gateway module (week 4)

  name_prefix = "${local.name_prefix}-app-"
  description = "Security group for application workloads (ECS tasks, compute)"
  vpc_id      = aws_vpc.main.id

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-app-sg"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

# App SG: Egress to endpoint SG on HTTPS
# Allows application to reach interface VPC endpoints (Bedrock, ECR, Secrets Manager, etc.)
resource "aws_vpc_security_group_egress_rule" "app_to_endpoints" {
  security_group_id = aws_security_group.app.id

  description                  = "Allow HTTPS to VPC endpoints"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.endpoint.id

  tags = {
    Name = "allow-https-to-endpoints"
  }
}

# App SG: Egress to S3 gateway endpoint on HTTPS via prefix list
# S3 uses HTTPS (port 443) and is reachable via the gateway endpoint prefix list.
# The prefix list is AWS-managed and updated automatically.
resource "aws_vpc_security_group_egress_rule" "app_to_s3_gateway" {
  security_group_id = aws_security_group.app.id

  description    = "Allow HTTPS to S3 gateway endpoint"
  from_port      = 443
  to_port        = 443
  ip_protocol    = "tcp"
  prefix_list_id = aws_vpc_endpoint.s3.prefix_list_id

  tags = {
    Name = "allow-https-to-s3"
  }
}

# App SG: Egress to vector store (RDS) on port 5432
# Allows database connectivity within the VPC CIDR.
# Consumers (vector-store module) will configure the database SG to accept this.
resource "aws_vpc_security_group_egress_rule" "app_to_vector_store" {
  security_group_id = aws_security_group.app.id

  description = "Allow PostgreSQL to vector store in VPC"
  from_port   = 5432
  to_port     = 5432
  ip_protocol = "tcp"
  cidr_ipv4   = var.vpc_cidr

  tags = {
    Name = "allow-postgres-to-vectordb"
  }
}
