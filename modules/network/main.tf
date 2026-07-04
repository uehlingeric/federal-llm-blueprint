data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project            = var.project
    Environment        = var.environment
    ManagedBy          = "terraform"
    DataClassification = var.data_classification
  }

  # First az_count available AZs; mode combinations are enforced by
  # cross-variable validation in variables.tf (Terraform >= 1.9)
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

# VPC with DNS support and hostnames enabled (required for endpoint private DNS)
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-vpc"
    }
  )
}

# Restrict the VPC default security group to no rules: nothing should ever
# use it, and an empty rule set makes that provable (SC-7 posture).
resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-default-sg-locked"
    }
  )
}

# Private subnets across az_count AZs
resource "aws_subnet" "private" {
  for_each = toset(local.azs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 3, index(local.azs, each.value))
  availability_zone       = each.value
  map_public_ip_on_launch = false

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-private-${each.value}"
    }
  )
}

# Public subnets (count = 0 in no-egress mode)
# Public IPs are never auto-assigned; workloads that need one must request it
# explicitly (or use the NAT path), which keeps accidental exposure impossible.
resource "aws_subnet" "public" {
  for_each = var.enable_public_subnets ? toset(local.azs) : toset([])

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 3, var.az_count + index(local.azs, each.value))
  availability_zone       = each.value
  map_public_ip_on_launch = false

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-public-${each.value}"
    }
  )
}

# Internet Gateway (count = 0 in no-egress mode or when public subnets disabled)
resource "aws_internet_gateway" "main" {
  count  = var.enable_public_subnets ? 1 : 0
  vpc_id = aws_vpc.main.id

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-igw"
    }
  )
}

# Elastic IP for NAT Gateway (count = 0 in no-egress mode)
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"

  depends_on = [aws_internet_gateway.main]

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-nat-eip"
    }
  )
}

# NAT Gateway in first public subnet (count = 0 in no-egress mode or when NAT disabled)
# Single NAT is the demo posture; per-AZ NAT is documented in README as an alternative for HA.
resource "aws_nat_gateway" "main" {
  count         = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[local.azs[0]].id

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-nat"
    }
  )

  depends_on = [aws_internet_gateway.main]
}

# Private route tables (one per AZ)
resource "aws_route_table" "private" {
  for_each = toset(local.azs)

  vpc_id = aws_vpc.main.id

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-private-rt-${each.value}"
    }
  )
}

# Associate private subnets with private route tables
resource "aws_route_table_association" "private" {
  for_each = toset(local.azs)

  subnet_id      = aws_subnet.private[each.value].id
  route_table_id = aws_route_table.private[each.value].id
}

# Default route in private route tables to NAT (only when NAT is enabled)
resource "aws_route" "private_nat" {
  for_each = var.enable_nat_gateway ? toset(local.azs) : toset([])

  route_table_id         = aws_route_table.private[each.value].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id
}

# Public route table (count = 0 in no-egress mode)
resource "aws_route_table" "public" {
  count  = var.enable_public_subnets ? 1 : 0
  vpc_id = aws_vpc.main.id

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-public-rt"
    }
  )
}

# Associate public subnets with public route table
resource "aws_route_table_association" "public" {
  for_each = var.enable_public_subnets ? toset(local.azs) : toset([])

  subnet_id      = aws_subnet.public[each.value].id
  route_table_id = aws_route_table.public[0].id
}

# Default route in public route table to IGW
resource "aws_route" "public_igw" {
  count                  = var.enable_public_subnets ? 1 : 0
  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main[0].id
}
