# VPC Flow Logs: CloudWatch Logs destination with KMS encryption
# Captures all traffic in the VPC for audit and troubleshooting.
# Conditional: only created when enable_flow_logs = true.

# CloudWatch Logs Group for VPC Flow Logs
# KMS-encrypted with the provided key. Retention set via flow_log_retention_days variable.
resource "aws_cloudwatch_log_group" "flow_logs" {
  #checkov:skip=CKV_AWS_338: Retention is configurable via var.flow_log_retention_days; default 90 days is appropriate for audit logs in development environments

  count             = var.enable_flow_logs ? 1 : 0
  name              = "/aws/vpc/flow-logs/${local.name_prefix}"
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = var.flow_log_kms_key_arn

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-vpc-flow-logs"
    }
  )
}

# IAM Role for VPC Flow Logs service
# Assumable only by the VPC Flow Logs service; restricted to this account via condition.
resource "aws_iam_role" "flow_logs" {
  count       = var.enable_flow_logs ? 1 : 0
  name_prefix = "${local.name_prefix}-flow-logs-role-"

  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-flow-logs-role"
    }
  )
}

# Trust policy: assumable only by the VPC Flow Logs service from this account
data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    sid     = "FlowLogsServiceAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# IAM Policy for VPC Flow Logs to write to CloudWatch Logs
# Least-privilege: permits only the actions needed to create streams and write logs
# Scoped to the flow log group and its streams.
resource "aws_iam_role_policy" "flow_logs" {
  count       = var.enable_flow_logs ? 1 : 0
  role        = aws_iam_role.flow_logs[0].id
  policy      = data.aws_iam_policy_document.flow_logs_policy.json
  name_prefix = "${local.name_prefix}-flow-logs-policy-"
}

data "aws_iam_policy_document" "flow_logs_policy" {
  statement {
    sid    = "CreateLogStreamAndPutLogEvents"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams"
    ]
    resources = [
      "${aws_cloudwatch_log_group.flow_logs[0].arn}:*"
    ]
  }
}

# VPC Flow Logs: all traffic to CloudWatch Logs
# Captures both accepted and rejected traffic for security auditing.
resource "aws_flow_log" "vpc" {
  count           = var.enable_flow_logs ? 1 : 0
  iam_role_arn    = aws_iam_role.flow_logs[0].arn
  log_destination = aws_cloudwatch_log_group.flow_logs[0].arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.main.id
  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-vpc-flow-logs"
    }
  )
}
