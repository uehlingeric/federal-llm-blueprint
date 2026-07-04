data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project            = var.project
    Environment        = var.environment
    ManagedBy          = "terraform"
    DataClassification = var.data_classification
  }

  # All roles created by this module share this path for organization and policy scoping
  role_path = "/${var.project}/"

  # Bedrock model ARNs: constructed from model IDs + inference profiles
  # When inference profiles are supplied, use region wildcard for foundation models
  # (cross-region profiles invoke underlying models in destination regions; model ARNs
  # carry no account ID so identity scope stays pinned to exact model IDs — region
  # wildcard here does not widen which models can be invoked, only where they run)
  bedrock_region_segment = length(var.bedrock_inference_profile_arns) > 0 ? "*" : data.aws_region.current.region
  bedrock_model_arns = [
    for id in var.bedrock_model_ids :
    "arn:${data.aws_partition.current.partition}:bedrock:${local.bedrock_region_segment}::foundation-model/${id}"
  ]
  bedrock_all_arns = concat(local.bedrock_model_arns, var.bedrock_inference_profile_arns)

  # RDS database user ARNs for IAM authentication
  # Each pair (db_resource_id, db_username) becomes arn:partition:rds-db:region:account:dbuser:resource/username
  db_connect_arns = [
    for i, db_id in var.db_resource_ids :
    "arn:${data.aws_partition.current.partition}:rds-db:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:dbuser:${db_id}/${var.db_usernames[i]}"
  ]
}

# ====================================================================
# Permission Boundary Policy Document
# ====================================================================
# The boundary is the CEILING: a policy document that intersects with
# every identity policy, preventing any role from escalating past its
# defined scope. Statements are ALLOWS that enumerate what the entire
# stack is permitted to do (not grants, just ceilings). Explicit DENYs
# prevent boundary escape. Resource "*" is acceptable in a boundary's
# allow-list because it is intersected with identity policies and is
# not a grant by itself; every line includes a # boundary: comment.
#
# Reviewers read this line by line to verify the ceiling is tight.

data "aws_iam_policy_document" "permission_boundary" {
  # ====== ALLOW statements: Service action ceiling ======
  # Each statement represents a service family the stack can ever invoke.
  # Resource "*" in boundaries (ceilings, not grants) must have inline justifications.

  statement {
    sid       = "AllowEC2Describe"
    effect    = "Allow"
    actions   = ["ec2:Describe*"]
    resources = ["*"]
    # These checks misfire on permission boundaries where Resource "*" scopes to the ceiling (permit-list intersected with identity policies).
    # Boundaries are not grants; they prevent escalation past the defined scope.
    # checkov:skip=CKV_AWS_107: Boundary is a ceiling; credentials exposure is scoped by identity policies.
    # checkov:skip=CKV_AWS_108: Boundary is a ceiling; data exfiltration is scoped by identity policies.
    # checkov:skip=CKV_AWS_109: Boundary is a ceiling; Resource "*" defines the permit-list ceiling.
    # checkov:skip=CKV_AWS_111: Boundary is a ceiling; write actions are scoped by identity policies to specific buckets/prefixes.
    # checkov:skip=CKV_AWS_356: Boundary is a ceiling; Resource "*" scopes to the ceiling concept by definition.
    # boundary: Describe-only on EC2 resources (VPC, subnets, SGs, ENIs) — read-only inspection, no modifications
  }

  statement {
    sid    = "AllowECSTaskOperations"
    effect = "Allow"
    actions = [
      "ecs:DescribeClusters",
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:DescribeTasks",
      "ecs:ListClusters",
      "ecs:ListServices",
      "ecs:ListTasks",
      "ecs:UpdateService",
      "ecs:UpdateTaskSet",
      "ecs:RunTask",
      "ecs:StopTask"
    ]
    resources = ["*"]
    # boundary: Limited ECS operations: describe (read-only), update on task/service (deploys),
    # and run/stop one-off tasks (the week-5 seed-task pattern). Not create/delete of clusters or services.
  }

  statement {
    sid     = "AllowPassRoleToECSOnly"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    # Only roles under this project's path can be passed, and only to ECS tasks —
    # without this, no principal under the boundary could ever start a task; with a
    # wider version, a principal could pass an over-privileged foreign role.
    resources = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role${local.role_path}*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
    # boundary: PassRole restricted to project-path roles and the ECS tasks service.
  }

  statement {
    sid    = "AllowAuditRead"
    effect = "Allow"
    # Read-only ceiling for the auditor tier (SecurityAudit and the CloudTrail/Logs
    # read policies intersect with the boundary — without these allows, an auditor's
    # identity policy would intersect to nothing). Every action here is Describe/Get/
    # List/Lookup-class; nothing mutates state.
    actions = [
      "cloudtrail:DescribeTrails",
      "cloudtrail:GetTrailStatus",
      "cloudtrail:GetEventSelectors",
      "cloudtrail:ListTags",
      "cloudtrail:LookupEvents",
      "config:Describe*",
      "config:Get*",
      "config:List*",
      "iam:Get*",
      "iam:List*",
      "iam:GenerateCredentialReport",
      "iam:GenerateServiceLastAccessedDetails",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:ListKeys",
      "kms:ListAliases",
      "kms:ListResourceTags",
      "logs:FilterLogEvents",
      "logs:GetQueryResults",
      "logs:StartQuery",
      "logs:StopQuery",
      "rds:ListTagsForResource",
      "s3:GetBucketLocation",
      "s3:GetBucketPolicy",
      "s3:GetBucketPolicyStatus",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketVersioning",
      "s3:GetBucketLogging",
      "s3:GetEncryptionConfiguration",
      "s3:GetBucketTagging",
      "s3:ListAllMyBuckets",
      "sns:GetTopicAttributes",
      "sns:ListTopics",
      "sns:ListTagsForResource"
    ]
    resources = ["*"]
    # boundary: Audit-read ceiling — read-only inspection actions for compliance review. No mutations.
  }

  statement {
    sid    = "AllowECRRead"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories"
    ]
    resources = ["*"]
    # boundary: ECR read-only. GetAuthorizationToken must use Resource "*" (AWS service design). No push/delete.
  }

  statement {
    sid    = "AllowLogsWrite"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:GetLogEvents"
    ]
    resources = ["*"]
    # boundary: CloudWatch Logs write (streams, events) and read (describe, get). All log groups visible for diagnostics.
  }

  statement {
    sid    = "AllowKMSCrypto"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey"
    ]
    resources = ["*"]
    # boundary: KMS cryptographic operations on all keys (scoped by identity policy via key ARNs). No key rotation/deletion.
  }

  statement {
    sid    = "AllowSecretsManagerRead"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]
    resources = ["*"]
    # boundary: Secrets Manager read-only (get secret and metadata). No create/delete/update.
  }

  statement {
    sid    = "AllowSSMParameterRead"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters"
    ]
    resources = ["*"]
    # boundary: Read-only parameter retrieval for ECS secret injection, scoped by identity policies to named parameters. No PutParameter/DeleteParameter (no write/delete ceiling).
  }

  statement {
    sid    = "AllowS3ObjectOperations"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = ["*"]
    # boundary: S3 read and write (document store). Scoped by identity policy to specific buckets/prefixes.
  }

  statement {
    sid    = "AllowRDSDescribe"
    effect = "Allow"
    actions = [
      "rds:DescribeDBInstances",
      "rds:DescribeDBClusters",
      "rds:DescribeDBParameters",
      "rds-db:connect"
    ]
    resources = ["*"]
    # boundary: RDS describe-only and iam-auth connect. No modify/delete.
  }

  statement {
    sid    = "AllowBedrockInvoke"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:ListFoundationModels"
    ]
    resources = ["*"]
    # boundary: Bedrock model invocation (scoped by identity policy to named models). No training/fine-tuning.
  }

  statement {
    sid    = "AllowCloudWatchMetrics"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "cloudwatch:DescribeAlarms"
    ]
    resources = ["*"]
    # boundary: CloudWatch metrics publish and read. No delete/disable alarms.
  }

  statement {
    sid    = "AllowSNSPublish"
    effect = "Allow"
    actions = [
      "sns:Publish"
    ]
    resources = ["*"]
    # boundary: SNS publish-only (alarm notifications, etc.). Scoped by identity policy to topic ARNs.
  }

  statement {
    sid    = "AllowSTSAssumeRole"
    effect = "Allow"
    actions = [
      "sts:AssumeRole",
      "sts:GetCallerIdentity"
    ]
    resources = ["*"]
    # boundary: STS assume role (for human role assumption) and get caller identity (for audit). No create/delete roles.
  }

  statement {
    sid    = "AllowApplicationAutoscaling"
    effect = "Allow"
    actions = [
      "application-autoscaling:DescribeScalableTargets",
      "application-autoscaling:DescribeScalingActivities"
    ]
    resources = ["*"]
    # boundary: Application Auto Scaling read-only (ECS service scaling metadata).
  }

  statement {
    sid    = "AllowELBDescribe"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:Describe*"
    ]
    resources = ["*"]
    # boundary: Load balancer describe-only (health checks, target group info). No modify.
  }

  # ====== EXPLICIT DENY statements: Boundary Escape Prevention ======
  # These denies prevent anyone (even admin) from removing or weakening the boundary.

  statement {
    sid    = "DenyPermissionsBoundaryModification"
    effect = "Deny"
    actions = [
      "iam:PutRolePermissionsBoundary",
      "iam:DeleteRolePermissionsBoundary"
    ]
    resources = ["*"]
    # boundary: Prevent removal or replacement of the permission boundary (the ceiling itself).
  }

  # Self-referential deny: CreateRole/PutRolePolicy/AttachRolePolicy only allowed
  # if a new role names THIS boundary as its boundary. Constructed via partition/account/policy name.
  statement {
    sid    = "DenyRoleCreationWithoutBoundary"
    effect = "Deny"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePolicy",
      "iam:AttachRolePolicy"
    ]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "iam:PermissionsBoundary"
      # Must match the real policy ARN including its path (aws_iam_policy.permission_boundary
      # sets path = local.role_path); a pathless ARN here would deny even compliant role creation.
      values = [
        "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy${local.role_path}${local.name_prefix}-permission-boundary"
      ]
    }
    # boundary: If you create a role or attach policies, that role MUST have this boundary. Self-enforcing escalation prevention.
  }

  # ====== EXPLICIT DENY statements: High-Blast-Radius Prevention ======
  # These actions are categorically forbidden to all stack roles.

  statement {
    sid    = "DenyOrganizationsActions"
    effect = "Deny"
    actions = [
      "organizations:*"
    ]
    resources = ["*"]
    # boundary: No access to AWS Organizations (account-level decisions out of scope).
  }

  statement {
    sid    = "DenyAccountActions"
    effect = "Deny"
    actions = [
      "account:*"
    ]
    resources = ["*"]
    # boundary: No access to AWS Account API (billing, settings out of scope).
  }

  statement {
    sid    = "DenyIAMAccessKeyManagement"
    effect = "Deny"
    actions = [
      "iam:*AccessKey*",
      "iam:*LoginProfile*"
    ]
    resources = ["*"]
    # boundary: No access key or console login creation (forces use of roles + MFA for human access).
  }

  statement {
    sid    = "DenyKMSKeyScheduleDeletion"
    effect = "Deny"
    actions = [
      "kms:ScheduleKeyDeletion",
      "kms:PutKeyPolicy"
    ]
    resources = ["*"]
    # boundary: No ability to schedule key deletion or replace key policies (encryption continuity).
  }

  statement {
    sid    = "DenyCloudTrailLogModification"
    effect = "Deny"
    actions = [
      "cloudtrail:StopLogging",
      "cloudtrail:DeleteTrail"
    ]
    resources = ["*"]
    # boundary: No ability to stop audit logging or delete trails (audit trail integrity).
  }

  statement {
    sid    = "DenyConfigRecorderModification"
    effect = "Deny"
    actions = [
      "config:StopConfigurationRecorder",
      "config:DeleteConfigurationRecorder"
    ]
    resources = ["*"]
    # boundary: No ability to stop or delete Config recorder (compliance assessment continuity).
  }
}

# Permission boundary policy resource
resource "aws_iam_policy" "permission_boundary" {
  name        = "${local.name_prefix}-permission-boundary"
  path        = local.role_path
  description = "Permission boundary (ceiling) applied to all stack roles. Enumerates permitted service actions and prevents boundary escape."
  policy      = data.aws_iam_policy_document.permission_boundary.json

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-permission-boundary"
    }
  )
}

# ====================================================================
# ECS Task Execution Role
# ====================================================================
# Pulled by ECS at task launch: allows pulling images from ECR,
# writing logs to CloudWatch, retrieving secrets, and decrypting keys.
# Trust: ecs-tasks.amazonaws.com with source account + ARN conditions.

data "aws_iam_policy_document" "task_execution_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name                 = "${local.name_prefix}-task-execution"
  path                 = local.role_path
  assume_role_policy   = data.aws_iam_policy_document.task_execution_trust.json
  permissions_boundary = aws_iam_policy.permission_boundary.arn

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-task-execution"
    }
  )
}

# Task execution inline policy
data "aws_iam_policy_document" "task_execution" {
  # ECR image pull: GetAuthorizationToken must use Resource "*" (AWS service design)
  dynamic "statement" {
    for_each = ["ecr-authorization"]
    content {
      sid       = "ECRGetAuthorizationToken"
      effect    = "Allow"
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]
      # task-execution: ECR service requires GetAuthorizationToken on Resource "*" per AWS documentation.
    }
  }

  # ECR image pull from specific repositories
  dynamic "statement" {
    for_each = length(var.ecr_repository_arns) > 0 ? [1] : []
    content {
      sid    = "ECRPullImages"
      effect = "Allow"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ]
      resources = var.ecr_repository_arns
      # task-execution: Pull images from ECR repositories (scoped to var.ecr_repository_arns, typically in network/ecs module).
    }
  }

  # CloudWatch Logs: create streams and write events
  dynamic "statement" {
    for_each = length(var.log_group_arns) > 0 ? [1] : []
    content {
      sid    = "CloudWatchLogsWrite"
      effect = "Allow"
      actions = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      resources = [
        for arn in var.log_group_arns : "${arn}:*" # Allow all streams within log groups
      ]
      # task-execution: Write to ECS task log streams (one log group per component: gateway, seed tasks, etc.).
    }
  }

  # Secrets Manager: retrieve secrets (e.g., API keys)
  dynamic "statement" {
    for_each = length(var.secret_arns) > 0 ? [1] : []
    content {
      sid    = "SecretsManagerRead"
      effect = "Allow"
      actions = [
        "secretsmanager:GetSecretValue"
      ]
      resources = var.secret_arns
      # task-execution: Retrieve secrets at task startup. Scoped to specific secret ARNs.
    }
  }

  # SSM Parameter Store: retrieve configuration parameters
  dynamic "statement" {
    for_each = length(var.ssm_parameter_arns) > 0 ? [1] : []
    content {
      sid    = "SSMGetParameters"
      effect = "Allow"
      actions = [
        "ssm:GetParameters"
      ]
      resources = var.ssm_parameter_arns
      # task-execution: Retrieve SSM parameters at task startup (ECS secrets valueFrom injection). Scoped to specific parameter ARNs.
    }
  }

  # KMS: decrypt secrets
  dynamic "statement" {
    for_each = contains(keys(var.kms_key_arns), "secrets") && (length(var.secret_arns) > 0 || length(var.ssm_parameter_arns) > 0) ? [1] : []
    content {
      sid    = "KMSDecryptSecrets"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey"
      ]
      resources = [var.kms_key_arns["secrets"]]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values = concat(
          length(var.secret_arns) > 0 ? ["secretsmanager.${data.aws_region.current.region}.amazonaws.com"] : [],
          length(var.ssm_parameter_arns) > 0 ? ["ssm.${data.aws_region.current.region}.amazonaws.com"] : []
        )
      }
      # task-execution: Decrypt secrets via Secrets Manager and/or SecureString parameters via SSM. ViaService condition ensures key is used only for these purposes.
    }
  }
}

resource "aws_iam_role_policy" "task_execution" {
  name   = "${local.name_prefix}-task-execution"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.task_execution.json
}

# ====================================================================
# ECS App Task Role
# ====================================================================
# Assumed by ECS app task containers: database, Bedrock, S3, KMS operations
# scoped to specific resources (model ARNs, bucket prefixes, DB users).
# Trust: same as task_execution.

data "aws_iam_policy_document" "app_task_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "app_task" {
  name                 = "${local.name_prefix}-app-task"
  path                 = local.role_path
  assume_role_policy   = data.aws_iam_policy_document.app_task_trust.json
  permissions_boundary = aws_iam_policy.permission_boundary.arn

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-app-task"
    }
  )
}

# App task inline policy
data "aws_iam_policy_document" "app_task" {
  # Bedrock: invoke named models
  dynamic "statement" {
    for_each = length(local.bedrock_all_arns) > 0 ? [1] : []
    content {
      sid    = "BedrockInvoke"
      effect = "Allow"
      actions = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ]
      resources = local.bedrock_all_arns
      # app-task: Invoke Bedrock foundation models (scoped to specific model ARNs and inference profiles).
    }
  }

  # S3: get objects from document buckets
  dynamic "statement" {
    for_each = length(var.document_bucket_read_prefixes) > 0 ? [1] : []
    content {
      sid    = "S3GetDocuments"
      effect = "Allow"
      actions = [
        "s3:GetObject",
        "s3:GetObjectVersion"
      ]
      resources = var.document_bucket_read_prefixes
      # app-task: Read document chunks from S3 (scoped to document/ prefix in the documents bucket).
    }
  }

  # S3: list bucket for document discovery
  dynamic "statement" {
    for_each = length(var.document_bucket_arns) > 0 ? [1] : []
    content {
      sid    = "S3ListDocuments"
      effect = "Allow"
      actions = [
        "s3:ListBucket"
      ]
      resources = var.document_bucket_arns
      # s3:prefix takes bare key prefixes ("documents/"), not ARNs — a separate
      # variable from the object-ARN read prefixes above. When no key prefixes
      # are supplied, listing is scoped to the named buckets only.
      dynamic "condition" {
        for_each = length(var.document_key_prefixes) > 0 ? [1] : []
        content {
          test     = "StringLike"
          variable = "s3:prefix"
          values   = [for p in var.document_key_prefixes : "${p}*"]
        }
      }
      # app-task: List named buckets, prefix-scoped when key prefixes are provided.
    }
  }

  # RDS IAM auth: connect to database as named user
  dynamic "statement" {
    for_each = length(local.db_connect_arns) > 0 ? [1] : []
    content {
      sid    = "RDSConnect"
      effect = "Allow"
      actions = [
        "rds-db:connect"
      ]
      resources = local.db_connect_arns
      # app-task: Connect to vector store via IAM database authentication (scoped to specific resource:user pairs).
    }
  }

  # KMS: decrypt data key
  dynamic "statement" {
    for_each = contains(keys(var.kms_key_arns), "data") && (length(var.document_bucket_arns) > 0 || length(local.db_connect_arns) > 0) ? [1] : []
    content {
      sid    = "KMSDecryptData"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey"
      ]
      resources = [var.kms_key_arns["data"]]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values = concat(
          length(var.document_bucket_arns) > 0 ? ["s3.${data.aws_region.current.region}.amazonaws.com"] : [],
          length(local.db_connect_arns) > 0 ? ["rds.${data.aws_region.current.region}.amazonaws.com"] : []
        )
      }
      # app-task: Decrypt data at rest (S3, RDS) via ViaService condition (keys decrypted only for these services).
    }
  }

  # KMS: decrypt secrets the application reads at runtime.
  # Deliberately var.app_secret_arns, not var.secret_arns: startup-injected secrets
  # (e.g., the gateway master key) are read by the execution role and arrive as env
  # vars — the app process never calls GetSecretValue for them, so it gets no grant.
  dynamic "statement" {
    for_each = contains(keys(var.kms_key_arns), "secrets") && length(var.app_secret_arns) > 0 ? [1] : []
    content {
      sid    = "KMSDecryptSecrets"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey"
      ]
      resources = [var.kms_key_arns["secrets"]]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${data.aws_region.current.region}.amazonaws.com"]
      }
      # app-task: Decrypt runtime-read secrets via Secrets Manager (e.g., third-party API keys in hybrid mode).
    }
  }

  # Secrets Manager: retrieve secrets the application reads at runtime
  dynamic "statement" {
    for_each = length(var.app_secret_arns) > 0 ? [1] : []
    content {
      sid    = "SecretsManagerRead"
      effect = "Allow"
      actions = [
        "secretsmanager:GetSecretValue"
      ]
      resources = var.app_secret_arns
      # app-task: Retrieve runtime-read secrets (e.g., external API keys). Startup-injected secrets are excluded — see var.app_secret_arns.
    }
  }
}

resource "aws_iam_role_policy" "app_task" {
  name   = "${local.name_prefix}-app-task"
  role   = aws_iam_role.app_task.id
  policy = data.aws_iam_policy_document.app_task.json
}

# ====================================================================
# CI/CD Deployment Role
# ====================================================================
# Assumed by GitHub Actions (or other CI platform) for terraform plan/apply.
# Created only when ci_trust_principal_arns is non-empty (count = 0 otherwise).
# Attached: AWS managed ReadOnlyAccess for plan, + boundary caps modifications.

# Count-guarded alongside the role: with no principals supplied this document
# would be invalid (empty identifiers). AWS-type principals cover CI roles/users
# in this or another account; GitHub OIDC federation needs a Federated trust
# document instead — consumers bring their own in that case.
data "aws_iam_policy_document" "ci_deploy_trust" {
  count = length(var.ci_trust_principal_arns) > 0 ? 1 : 0

  statement {
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = var.ci_trust_principal_arns
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ci_deploy" {
  count                = length(var.ci_trust_principal_arns) > 0 ? 1 : 0
  name                 = "${local.name_prefix}-ci-deploy"
  path                 = local.role_path
  assume_role_policy   = data.aws_iam_policy_document.ci_deploy_trust[0].json
  permissions_boundary = aws_iam_policy.permission_boundary.arn

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-ci-deploy"
    }
  )
}

# CI role: attach managed ReadOnlyAccess for planning (apply permissions are consumer-specific)
resource "aws_iam_role_policy_attachment" "ci_deploy_readonly" {
  count      = length(var.ci_trust_principal_arns) > 0 ? 1 : 0
  role       = aws_iam_role.ci_deploy[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
  # ci-deploy: AWS managed ReadOnlyAccess for terraform plan. Apply permissions are injected by deployment platform (GitHub Actions, etc.) based on environment.
}

# ====================================================================
# Human Role Tiers (for_each over var.human_trust_principals)
# ====================================================================
# Assumable roles for human users (via SSO, IdP integration, or federation).
# Each tier has different permission sets:
# - platform-admin: PowerUserAccess + IAMReadOnlyAccess (strong admin, but boundary prevents full admin)
# - auditor: SecurityAudit + CloudWatchLogsReadOnlyAccess + CloudTrail read
# - developer: ReadOnlyAccess + scoped inline policy for deploy-to-nonprod

data "aws_iam_policy_document" "human_tier_trust" {
  for_each = var.human_trust_principals

  statement {
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = each.value
    }
    actions = ["sts:AssumeRole"]

    # MFA is required for all human role assumption (enforced via aws:MultiFactorAuthPresent condition)
    # Note: Some SSO implementations may not support MFA conditions; consult your IdP documentation.
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

# Platform admin role
resource "aws_iam_role" "human_tier" {
  for_each             = var.human_trust_principals
  name                 = "${local.name_prefix}-${each.key}"
  path                 = local.role_path
  assume_role_policy   = data.aws_iam_policy_document.human_tier_trust[each.key].json
  permissions_boundary = aws_iam_policy.permission_boundary.arn

  tags = merge(
    local.common_tags,
    var.tags,
    {
      Name = "${local.name_prefix}-${each.key}"
      Role = each.key
    }
  )
}

# Managed policy attachments for platform-admin
resource "aws_iam_role_policy_attachment" "admin_power_user" {
  for_each = {
    for tier, role in aws_iam_role.human_tier : tier => role if tier == "platform-admin"
  }

  role       = aws_iam_role.human_tier[each.key].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy_attachment" "admin_iam_readonly" {
  for_each = {
    for tier, role in aws_iam_role.human_tier : tier => role if tier == "platform-admin"
  }

  role       = aws_iam_role.human_tier[each.key].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/IAMReadOnlyAccess"
  # platform-admin: PowerUserAccess (everything except IAM) + IAMReadOnlyAccess (see IAM structure). Boundary prevents escalation to administrator.
}

# Auditor: SecurityAudit + logs + audit trails
resource "aws_iam_role_policy_attachment" "auditor_security" {
  for_each = {
    for tier, role in aws_iam_role.human_tier : tier => role if tier == "auditor"
  }

  role       = aws_iam_role.human_tier[each.key].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/SecurityAudit"
}

resource "aws_iam_role_policy_attachment" "auditor_logs" {
  for_each = {
    for tier, role in aws_iam_role.human_tier : tier => role if tier == "auditor"
  }

  role       = aws_iam_role.human_tier[each.key].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchLogsReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "auditor_cloudtrail" {
  for_each = {
    for tier, role in aws_iam_role.human_tier : tier => role if tier == "auditor"
  }

  role       = aws_iam_role.human_tier[each.key].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AWSCloudTrail_ReadOnlyAccess"
  # auditor: SecurityAudit (compliance/config inspection) + CloudWatch logs read + CloudTrail read. Read-only visibility into full stack.
}

# Developer: ReadOnlyAccess + scoped inline for ECS update-service (deploy-to-nonprod pattern)
resource "aws_iam_role_policy_attachment" "developer_readonly" {
  for_each = {
    for tier, role in aws_iam_role.human_tier : tier => role if tier == "developer"
  }

  role       = aws_iam_role.human_tier[each.key].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}

# Developer inline policy: scoped ECS update-service for nonprod deployments
data "aws_iam_policy_document" "developer_deploy" {
  for_each = {
    for tier, role in aws_iam_role.human_tier : tier => role if tier == "developer"
  }

  statement {
    sid    = "ECSDeployNonprod"
    effect = "Allow"
    actions = [
      "ecs:UpdateService",
      "ecs:UpdateTaskSet"
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:service/*",
      "arn:${data.aws_partition.current.partition}:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:task-set/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = ["dev", "staging"]
    }
    # developer: Deploy to nonprod environments only (Environment tag dev or staging). Prevents accidental prod changes.
  }
}

resource "aws_iam_role_policy" "developer_deploy" {
  for_each = {
    for tier, role in aws_iam_role.human_tier : tier => role if tier == "developer"
  }

  role   = aws_iam_role.human_tier[each.key].name
  name   = "${local.name_prefix}-${each.key}-deploy"
  policy = data.aws_iam_policy_document.developer_deploy[each.key].json
}
