# VPC Endpoints for AWS service connectivity
# Interface endpoints with private DNS resolution enabled
# Gateway endpoints for S3 (and optionally DynamoDB) with route table associations

# Interface VPC Endpoints for AWS services
# These are created in both no-egress and standard modes; private DNS allows
# AWS service DNS names (e.g., bedrock-runtime.region.amazonaws.com) to resolve
# to endpoint ENIs instead of public IPs.
resource "aws_vpc_endpoint" "interface" {
  for_each = var.interface_endpoints

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  # Associate to all private subnets
  subnet_ids = [for az in local.azs : aws_subnet.private[az].id]

  # Use the dedicated endpoint security group (defined in security-groups.tf)
  security_group_ids = [aws_security_group.endpoint.id]

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-${each.key}-endpoint"
    }
  )
}

# S3 Gateway Endpoint
# Associated to all private and public (if enabled) route tables.
# Uses a restrictive endpoint policy scoped to in-account buckets.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"

  # Route table associations: all private RTs and the public RT if it exists
  route_table_ids = concat(
    [for az in local.azs : aws_route_table.private[az].id],
    var.enable_public_subnets ? [aws_route_table.public[0].id] : []
  )

  policy = data.aws_iam_policy_document.s3_endpoint.json

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-s3-endpoint"
    }
  )
}

# S3 endpoint policy: restrictive starting point — any principal, but only
# against buckets owned by this account. Documented in the README as a
# baseline to tighten, not gospel.
data "aws_iam_policy_document" "s3_endpoint" {
  statement {
    sid       = "AllowInAccountS3Only"
    effect    = "Allow"
    actions   = ["s3:*"]
    resources = ["*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # ECR stores image layers in an AWS-owned regional bucket; Fargate pulls
  # fetch layers from it THROUGH this endpoint. Without this read-only
  # exception every task launch fails with CannotPullContainerError — the
  # in-account condition above cannot match an AWS-owned bucket. Bucket name
  # per AWS ECR docs ("Minimum Amazon S3 bucket permissions for Amazon ECR").
  statement {
    sid       = "AllowEcrLayerBucketRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::prod-${data.aws_region.current.region}-starport-layer-bucket/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

# DynamoDB Gateway Endpoint (optional)
# Only created if enable_dynamodb_gateway_endpoint = true.
# Associated to all private route tables and the public RT if present.
resource "aws_vpc_endpoint" "dynamodb" {
  count             = var.enable_dynamodb_gateway_endpoint ? 1 : 0
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.dynamodb"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    [for az in local.azs : aws_route_table.private[az].id],
    var.enable_public_subnets ? [aws_route_table.public[0].id] : []
  )

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-dynamodb-endpoint"
    }
  )
}
