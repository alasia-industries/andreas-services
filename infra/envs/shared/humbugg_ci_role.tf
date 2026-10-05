# ─── Humbugg's own CI role ───────────────────────────────────────────────────
#
# Humbugg (ansavva/humbugg) deployed with `github-actions-andreas-services`,
# which is admin-equivalent (`iam:CreateRole` + `iam:PutRolePolicy` on `*`) and
# trusted for every ref of the repo. This role replaces it for Humbugg:
#
#   - Trust: only jobs running in the `humbugg-production` GitHub environment.
#     That is only as strong as the environment's deployment-branch policy —
#     restrict it to `main` in ansavva/humbugg settings.
#   - Permissions: what `humbugg-prod.yaml` and `infra/envs/prod` use, scoped
#     to `humbugg-prod-*` names, `/humbugg/prod/*` parameters, the humbugg.com
#     zone and Humbugg's own state key.
#   - IAM: roles it creates or edits must carry `humbugg-prod-workload-boundary`,
#     so a deploy cannot mint a role stronger than that boundary. The boundary
#     and this role's own policies are owned here and denied to the role.
#
# Services whose resources have id-based ARNs (API Gateway, CloudFront,
# Cognito, ACM) get `*` plus a Deny on anything tagged with another `Project`.
# `IfExists` keeps untagged and AWS-owned resources (e.g. the CloudFront
# distribution behind a Cognito custom domain) from tripping the Deny.
#
# SES v1 identity actions have no resource-level support at all. Verify/Set
# are granted on `*`; DeleteIdentity is not, so destroying humbugg.com's SES
# identity needs a human.

locals {
  humbugg_ci_role_name = "humbugg-prod-github-actions-role"
  humbugg_prefix       = "humbugg-prod"
  humbugg_state_key    = "humbugg/prod/terraform.tfstate"
}

data "aws_route53_zone" "humbugg" {
  name         = "humbugg.com"
  private_zone = false
}

# ─── Trust ───────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "humbugg_ci_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:ansavva/humbugg:environment:humbugg-production"]
    }
  }
}

resource "aws_iam_role" "humbugg_ci" {
  name                 = local.humbugg_ci_role_name
  assume_role_policy   = data.aws_iam_policy_document.humbugg_ci_trust.json
  max_session_duration = 3600
  tags                 = merge(local.shared_tags, { Project = "humbugg", Environment = "prod" })
}

# ─── Workload boundary ───────────────────────────────────────────────────────
#
# The ceiling for every role Humbugg's Terraform creates (Lambda execution
# roles). Union of what the live roles use (October 2026) plus small headroom
# (SSM read, SES send from humbugg.com, metrics/traces). No IAM, no STS, no
# other project's data.

data "aws_iam_policy_document" "humbugg_workload_boundary" {
  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }

  statement {
    sid    = "Telemetry"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricData",
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DynamoDb"
    effect = "Allow"
    actions = [
      "dynamodb:BatchGetItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:ConditionCheckItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:UpdateItem",
    ]
    resources = ["arn:aws:dynamodb:*:*:table/${local.humbugg_prefix}-*"]
  }

  statement {
    sid       = "S3"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.humbugg_prefix}-*", "arn:aws:s3:::${local.humbugg_prefix}-*/*"]
  }

  statement {
    sid    = "Sqs"
    effect = "Allow"
    actions = [
      "sqs:ChangeMessageVisibility",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage",
      "sqs:SendMessage",
    ]
    resources = [
      "arn:aws:sqs:*:*:${local.humbugg_prefix}-*",
      # Mailer's per-consumer delivery-status queue.
      "arn:aws:sqs:*:*:mailer-prod-humbugg-*",
    ]
  }

  statement {
    sid       = "Sns"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = ["arn:aws:sns:*:*:${local.humbugg_prefix}-*"]
  }

  # Mailer API (Invoke) and the realtime WebSocket API (ManageConnections).
  # API ids are not name-based.
  statement {
    sid       = "ExecuteApi"
    effect    = "Allow"
    actions   = ["execute-api:Invoke", "execute-api:ManageConnections"]
    resources = ["*"]
  }

  # Account directory (AdminGetUser), account deletion (AdminDeleteUser) and
  # the pre-sign-up linker (AdminUserGlobalSignOut ends an untrusted native
  # account's sessions before linking). Pool ARNs are id-based; the tag keeps
  # it to Humbugg's pools.
  statement {
    sid    = "Cognito"
    effect = "Allow"
    actions = [
      "cognito-idp:AdminConfirmSignUp",
      "cognito-idp:AdminCreateUser",
      "cognito-idp:AdminDeleteUser",
      "cognito-idp:AdminGetUser",
      "cognito-idp:AdminLinkProviderForUser",
      "cognito-idp:AdminSetUserPassword",
      "cognito-idp:AdminUpdateUserAttributes",
      "cognito-idp:AdminUserGlobalSignOut",
      "cognito-idp:ListUsers",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["humbugg"]
    }
  }

  statement {
    sid       = "SsmRead"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:*:*:parameter/humbugg/prod/*"]
  }

  statement {
    sid       = "KmsViaSsm"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "SesFromHumbugg"
    effect    = "Allow"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "ses:FromAddress"
      values   = ["*@humbugg.com"]
    }
  }
}

resource "aws_iam_policy" "humbugg_workload_boundary" {
  name        = "humbugg-prod-workload-boundary"
  description = "Permissions boundary required on every role Humbugg's CI creates or edits"
  policy      = data.aws_iam_policy_document.humbugg_workload_boundary.json
  tags        = merge(local.shared_tags, { Project = "humbugg", Environment = "prod" })
}

# ─── Deploy permissions: compute and data ────────────────────────────────────

data "aws_iam_policy_document" "humbugg_ci_compute" {
  # Terraform state: Humbugg's key and its lockfile only.
  statement {
    sid       = "StateList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::andreas-services-terraform-state"]
  }

  statement {
    sid       = "StateReadWrite"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["arn:aws:s3:::andreas-services-terraform-state/${local.humbugg_state_key}", "arn:aws:s3:::andreas-services-terraform-state/${local.humbugg_state_key}.tflock"]
  }

  statement {
    sid       = "StateLockRelease"
    effect    = "Allow"
    actions   = ["s3:DeleteObject"]
    resources = ["arn:aws:s3:::andreas-services-terraform-state/${local.humbugg_state_key}.tflock"]
  }

  # Buckets (marketing, app, app-files): Terraform + `s3 sync`.
  statement {
    sid       = "Buckets"
    effect    = "Allow"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::${local.humbugg_prefix}-*", "arn:aws:s3:::${local.humbugg_prefix}-*/*"]
  }

  statement {
    sid       = "DynamoDb"
    effect    = "Allow"
    actions   = ["dynamodb:*"]
    resources = ["arn:aws:dynamodb:*:*:table/${local.humbugg_prefix}-*"]
  }

  statement {
    sid       = "LambdaFunctions"
    effect    = "Allow"
    actions   = ["lambda:*"]
    resources = ["arn:aws:lambda:*:*:function:${local.humbugg_prefix}-*"]
  }

  # Event source mappings have UUID ARNs; scope by the function they feed.
  statement {
    sid    = "LambdaEventSourceMappings"
    effect = "Allow"
    actions = [
      "lambda:CreateEventSourceMapping",
      "lambda:DeleteEventSourceMapping",
      "lambda:GetEventSourceMapping",
      "lambda:UpdateEventSourceMapping",
    ]
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "lambda:FunctionArn"
      values   = ["arn:aws:lambda:*:*:function:${local.humbugg_prefix}-*"]
    }
  }

  statement {
    sid    = "LambdaEventSourceMappingMeta"
    effect = "Allow"
    actions = [
      "lambda:ListEventSourceMappings",
      "lambda:ListTags",
      "lambda:TagResource",
      "lambda:UntagResource",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "EcrRepositories"
    effect    = "Allow"
    actions   = ["ecr:*"]
    resources = ["arn:aws:ecr:*:*:repository/${local.humbugg_prefix}-*"]
  }

  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "QueuesTopicsRules"
    effect = "Allow"
    actions = [
      "sqs:*",
      "sns:*",
      "events:*",
    ]
    resources = [
      "arn:aws:sqs:*:*:${local.humbugg_prefix}-*",
      "arn:aws:sns:*:*:${local.humbugg_prefix}-*",
      "arn:aws:events:*:*:rule/${local.humbugg_prefix}-*",
    ]
  }

  statement {
    sid     = "LogGroups"
    effect  = "Allow"
    actions = ["logs:*"]
    resources = [
      "arn:aws:logs:*:*:log-group:/aws/lambda/${local.humbugg_prefix}-*",
      "arn:aws:logs:*:*:log-group:/aws/apigateway/${local.humbugg_prefix}-*",
    ]
  }

  # DescribeLogGroups is account-level; the delivery actions are what API
  # Gateway access logging (webhook relay stage) calls on the caller's behalf.
  statement {
    sid    = "LogsAccountLevel"
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:DescribeLogGroups",
      "logs:DescribeResourcePolicies",
      "logs:GetLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:UpdateLogDelivery",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "Alarms"
    effect    = "Allow"
    actions   = ["cloudwatch:*"]
    resources = ["arn:aws:cloudwatch:*:*:alarm:${local.humbugg_prefix}-*"]
  }

  statement {
    sid       = "AlarmsRead"
    effect    = "Allow"
    actions   = ["cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource"]
    resources = ["*"]
  }
}

# ─── Deploy permissions: edge, identity, config ──────────────────────────────

data "aws_iam_policy_document" "humbugg_ci_edge" {
  # Id-based ARNs; the Deny in humbugg_ci_iam keeps it off other projects.
  statement {
    sid    = "IdBasedServices"
    effect = "Allow"
    actions = [
      "apigateway:*",
      "cloudfront:*",
      "cognito-idp:*",
    ]
    resources = ["*"]
  }

  # WAF web ACLs in front of the Cognito pool (REGIONAL) and the CloudFront
  # distributions (CLOUDFRONT). ACL ARNs carry the name, so this one scopes.
  statement {
    sid     = "WafAcls"
    effect  = "Allow"
    actions = ["wafv2:*"]
    resources = [
      "arn:aws:wafv2:*:*:regional/webacl/${local.humbugg_prefix}-*/*",
      "arn:aws:wafv2:*:*:global/webacl/${local.humbugg_prefix}-*/*",
      "arn:aws:wafv2:*:*:regional/managedruleset/*/*",
      "arn:aws:wafv2:*:*:global/managedruleset/*/*",
    ]
  }

  statement {
    sid    = "WafRead"
    effect = "Allow"
    actions = [
      "wafv2:CheckCapacity",
      "wafv2:DescribeManagedRuleGroup",
      "wafv2:GetWebACLForResource",
      "wafv2:ListAvailableManagedRuleGroups",
      "wafv2:ListWebACLs",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "Certificates"
    effect = "Allow"
    actions = [
      "acm:AddTagsToCertificate",
      "acm:DeleteCertificate",
      "acm:DescribeCertificate",
      "acm:GetCertificate",
      "acm:ListCertificates",
      "acm:ListTagsForCertificate",
      "acm:RemoveTagsFromCertificate",
      "acm:RequestCertificate",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "HumbuggZone"
    effect    = "Allow"
    actions   = ["route53:*"]
    resources = ["arn:aws:route53:::hostedzone/${data.aws_route53_zone.humbugg.zone_id}"]
  }

  statement {
    sid       = "Route53Read"
    effect    = "Allow"
    actions   = ["route53:GetChange", "route53:ListHostedZones", "route53:ListHostedZonesByName"]
    resources = ["*"]
  }

  # SES: v1 identity actions are `*`-only (no DeleteIdentity, see header).
  # The email feedback smoke test sends from humbugg.com through Mailer's
  # Humbugg configuration set and clears simulator suppressions.
  statement {
    sid    = "SesIdentity"
    effect = "Allow"
    actions = [
      "ses:DeleteSuppressedDestination",
      "ses:Describe*",
      "ses:Get*",
      "ses:List*",
      "ses:SetIdentityMailFromDomain",
      "ses:VerifyDomainDkim",
      "ses:VerifyDomainIdentity",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "SesSend"
    effect  = "Allow"
    actions = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = [
      "arn:aws:ses:*:*:identity/humbugg.com",
      "arn:aws:ses:*:*:identity/*@humbugg.com",
      "arn:aws:ses:*:*:configuration-set/mailer-prod-humbugg-*",
    ]
  }

  statement {
    sid    = "SsmHumbugg"
    effect = "Allow"
    actions = [
      "ssm:AddTagsToResource",
      "ssm:DeleteParameter",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:ListTagsForResource",
      "ssm:PutParameter",
      "ssm:RemoveTagsFromResource",
    ]
    resources = ["arn:aws:ssm:*:*:parameter/humbugg/prod/*"]
  }

  # Mailer publishes Humbugg's status queue and configuration set here.
  statement {
    sid       = "SsmMailerRead"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:*:*:parameter/mailer/prod/humbugg/*"]
  }

  statement {
    sid       = "SsmDescribe"
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  statement {
    sid       = "KmsViaSsm"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

# ─── Deploy permissions: IAM, and the guard rails ────────────────────────────

data "aws_iam_policy_document" "humbugg_ci_iam" {
  # Anything that adds permissions to a role requires the boundary on it.
  statement {
    sid    = "RoleWritesUnderBoundary"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePermissionsBoundary",
      "iam:PutRolePolicy",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = ["arn:aws:iam::*:role/${local.humbugg_prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.humbugg_workload_boundary.arn]
    }
  }

  # Managed attachments: under the boundary, and only the Lambda basic
  # execution policy (the one Humbugg attaches).
  statement {
    sid       = "AttachLambdaBasicUnderBoundary"
    effect    = "Allow"
    actions   = ["iam:AttachRolePolicy"]
    resources = ["arn:aws:iam::*:role/${local.humbugg_prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.humbugg_workload_boundary.arn]
    }

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = ["arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"]
    }
  }

  # Reads, removals and tags cannot raise a role's permissions.
  statement {
    sid    = "RoleReadsAndRemovals"
    effect = "Allow"
    actions = [
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
    ]
    resources = ["arn:aws:iam::*:role/${local.humbugg_prefix}-*"]
  }

  statement {
    sid       = "PassRoleToLambdaOnly"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::*:role/${local.humbugg_prefix}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  statement {
    sid       = "ServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["email.cognito-idp.amazonaws.com", "ops.apigateway.amazonaws.com"]
    }
  }

  # The role matches `humbugg-prod-*` itself. It must not edit itself, its
  # policies or the boundary, nor strip a boundary from anything.
  statement {
    sid     = "DenySelfAndBoundaryEdits"
    effect  = "Deny"
    actions = ["iam:*"]
    resources = [
      "arn:aws:iam::*:role/${local.humbugg_ci_role_name}",
      "arn:aws:iam::*:policy/humbugg-prod-github-actions-*",
      "arn:aws:iam::*:policy/humbugg-prod-workload-boundary",
    ]
  }

  statement {
    sid       = "DenyBoundaryRemoval"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }

  # Id-based services granted on `*`: hands off anything another project tagged.
  statement {
    sid    = "DenyOtherProjectsResources"
    effect = "Deny"
    actions = [
      "acm:DeleteCertificate",
      "apigateway:DELETE",
      "apigateway:PATCH",
      "apigateway:POST",
      "apigateway:PUT",
      "cloudfront:CreateInvalidation",
      "cloudfront:DeleteDistribution",
      "cloudfront:TagResource",
      "cloudfront:UntagResource",
      "cloudfront:UpdateDistribution",
      "cognito-idp:*",
    ]
    resources = ["*"]

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "aws:ResourceTag/Project"
      values   = ["humbugg"]
    }
  }
}

resource "aws_iam_policy" "humbugg_ci" {
  for_each = {
    compute = data.aws_iam_policy_document.humbugg_ci_compute.json
    edge    = data.aws_iam_policy_document.humbugg_ci_edge.json
    iam     = data.aws_iam_policy_document.humbugg_ci_iam.json
  }

  name   = "humbugg-prod-github-actions-${each.key}"
  policy = each.value
  tags   = merge(local.shared_tags, { Project = "humbugg", Environment = "prod" })
}

resource "aws_iam_role_policy_attachment" "humbugg_ci" {
  for_each   = aws_iam_policy.humbugg_ci
  role       = aws_iam_role.humbugg_ci.name
  policy_arn = each.value.arn
}
