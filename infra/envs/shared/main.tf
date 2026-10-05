# envs/shared/main.tf
# Shared platform infrastructure: Route53 zone (data source) + ACM wildcard certificate.
#
# The VPC, NAT Gateway, subnets, and DocumentDB cluster have been removed.
# All services now use DynamoDB (IAM-controlled, no VPC required).

locals {
  shared_tags = {
    Project     = "platform"
    Environment = "shared"
    ManagedBy   = "terraform"
    Scope       = "shared"
  }
}

# Route53 hosted zone — managed outside Terraform (registered domain)
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# Wildcard ACM certificate for *.andreas.services (must be in us-east-1 for CloudFront)
resource "aws_acm_certificate" "wildcard" {
  provider          = aws.us_east_1
  domain_name       = "*.${var.domain_name}"
  validation_method = "DNS"

  subject_alternative_names = [var.domain_name]

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.shared_tags, {
    Name = "wildcard-${var.domain_name}"
  })
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main.zone_id
}

# ─── Google Workspace mail (andreas.services is the Workspace primary domain) ─
#
# Inbound mail for andreas.services is handled by Google Workspace. The
# verification TXT was originally created by hand during Workspace signup;
# allow_overwrite adopts it into the managed apex TXT record set (Route53
# permits only one TXT record set per name, so SPF and verification strings
# must live together). Never drop the google-site-verification string —
# Google re-checks it periodically.

locals {
  # Public values adopted verbatim from the live zone (created during Workspace
  # signup / the Gmail activation wizard). Safe to commit — both are public DNS.
  google_site_verification = "google-site-verification=wjiO8oxINCfOTRGVieMAxuWE1xqfKhgmGo3vM8L1wnE"
  google_dkim_txt_value    = "v=DKIM1;k=rsa;p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCrt4acTNGEoZXzcxMp/ixGSsNUqHaS85sFqHYMdoFnMJFdQEHGVmD1LYzUkHX2y8VW0ZWx4P0Hfu0E9TqzaPkL2Zz+BsVXpXpxHACKAhhPq9B9u9U+QHG9LHl9j41vWHjRYo4nmI+/2iHRs5DwPH2ROvguVzWgrIDjec6UW542tQIDAQAB"
}

resource "aws_route53_record" "apex_mx" {
  zone_id         = data.aws_route53_zone.main.zone_id
  name            = var.domain_name
  type            = "MX"
  ttl             = 300
  allow_overwrite = true
  records         = ["1 smtp.google.com"]
}

resource "aws_route53_record" "apex_txt" {
  zone_id         = data.aws_route53_zone.main.zone_id
  name            = var.domain_name
  type            = "TXT"
  ttl             = 300
  allow_overwrite = true
  records = [
    "v=spf1 include:_spf.google.com ~all",
    local.google_site_verification,
  ]
}

# 2048-bit DKIM keys exceed Route53's 255-char TXT string limit; the value is
# split into embedded quoted chunks (the provider's multi-string convention).
resource "aws_route53_record" "google_dkim" {
  count           = local.google_dkim_txt_value != "" ? 1 : 0
  zone_id         = data.aws_route53_zone.main.zone_id
  name            = "google._domainkey.${var.domain_name}"
  type            = "TXT"
  ttl             = 300
  allow_overwrite = true
  records         = [join("\"\"", [for i in range(0, ceil(length(local.google_dkim_txt_value) / 255)) : substr(local.google_dkim_txt_value, i * 255, 255)])]
}

# ─── GitHub Actions OIDC ──────────────────────────────────────────────────────

resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS auto-validates GitHub's TLS cert; thumbprint is ignored but required by the API
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = local.shared_tags
}

data "aws_iam_policy_document" "github_actions_trust" {
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

    # andreas-services: every job that assumes this role runs in a GitHub
    # environment (shared-infra, <service>-production), so only environment
    # subjects are trusted — a bare branch or PR job cannot assume it.
    # Extra repos keep `:*` until they move to their own role (Humbugg:
    # humbugg_ci_role.tf; drop it from extra_github_repos once its deploy uses
    # that role).
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = concat(
        ["repo:${var.github_repo}:environment:*"],
        [for repo in var.extra_github_repos : "repo:${repo}:*"],
      )
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "github-actions-andreas-services"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
  tags               = local.shared_tags
}

data "aws_iam_policy_document" "github_actions_permissions" {
  # CloudFormation — legacy; no service uses it today
  statement {
    effect    = "Allow"
    actions   = ["cloudformation:*"]
    resources = ["*"]
  }

  # Lambda — code deploys, env var updates, invocations
  statement {
    effect    = "Allow"
    actions   = ["lambda:*"]
    resources = ["*"]
  }

  # ECR — Docker image pushes for every container Lambda
  statement {
    effect    = "Allow"
    actions   = ["ecr:*"]
    resources = ["*"]
  }

  # DynamoDB — created by CloudFormation/Terraform; read during stack ops
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:*"]
    resources = ["*"]
  }

  # S3 — Lambda zip uploads, frontend syncs, Terraform state
  statement {
    effect    = "Allow"
    actions   = ["s3:*"]
    resources = ["*"]
  }

  # API Gateway — service REST/HTTP APIs
  statement {
    effect    = "Allow"
    actions   = ["apigateway:*"]
    resources = ["*"]
  }

  # CloudFront — invalidations + stack management
  statement {
    effect    = "Allow"
    actions   = ["cloudfront:*"]
    resources = ["*"]
  }

  # Route53 — DNS records created by stacks
  statement {
    effect    = "Allow"
    actions   = ["route53:*"]
    resources = ["*"]
  }

  # ACM — shared wildcard cert (Terraform)
  statement {
    effect    = "Allow"
    actions   = ["acm:*"]
    resources = ["*"]
  }

  # EventBridge — service schedules
  statement {
    effect    = "Allow"
    actions   = ["events:*"]
    resources = ["*"]
  }

  # CloudWatch Logs — stack log groups
  statement {
    effect    = "Allow"
    actions   = ["logs:*"]
    resources = ["*"]
  }

  # CloudWatch — Mailer alarms and service health metrics
  statement {
    effect    = "Allow"
    actions   = ["cloudwatch:*"]
    resources = ["*"]
  }

  # SNS — SES feedback topics and subscriptions
  statement {
    effect    = "Allow"
    actions   = ["sns:*"]
    resources = ["*"]
  }

  # GuardDuty — Malware Protection for Mailer attachment storage
  statement {
    effect    = "Allow"
    actions   = ["guardduty:*"]
    resources = ["*"]
  }

  # Cognito — service user pools (Terraform)
  statement {
    effect    = "Allow"
    actions   = ["cognito-idp:*"]
    resources = ["*"]
  }

  # SQS — service queues, e.g. mailer DLQ (Terraform)
  statement {
    effect    = "Allow"
    actions   = ["sqs:*"]
    resources = ["*"]
  }

  # SES — service email identities, domain authentication, and simulator smoke tests
  statement {
    effect    = "Allow"
    actions   = ["ses:*"]
    resources = ["*"]
  }

  # IAM — creating Lambda execution roles via CloudFormation/Terraform
  statement {
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:PassRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:CreateOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:CreatePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:DeletePolicy",
      "iam:TagPolicy",
    ]
    resources = ["*"]
  }

  # IAM — Cognito creates a service-linked role the first time a user pool sends
  # email through SES (email_sending_account = "DEVELOPER"). The UpdateUserPool
  # call is made with these credentials, so the role must be allowed to create
  # that specific service-linked role. Scoped to the Cognito email service only.
  statement {
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::*:role/aws-service-role/email.cognito-idp.amazonaws.com/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["email.cognito-idp.amazonaws.com"]
    }
  }

  # SSM — infra workflows write outputs; code workflows read them.
  #
  # This is the ONLY resource-scoped statement in this policy; every other one
  # is `resources = ["*"]`. So a new service that writes an SSM parameter needs
  # a line added below, and forgetting it fails nowhere until the very end of
  # that service's first `terraform apply` — after the CloudFront distribution
  # has already spent three minutes creating (#240).
  statement {
    effect = "Allow"
    actions = [
      "ssm:AddTagsToResource",
      "ssm:DeleteParameter",
      "ssm:GetParameter",
      "ssm:GetParameters",
      # Humbugg's deploy reads every hand-set value under /humbugg/prod/config/
      # in one call — Terraform's `aws_ssm_parameters_by_path` and
      # scripts/ci-prod-config.sh (ansavva/humbugg#1, October 2026).
      "ssm:GetParametersByPath",
      "ssm:ListTagsForResource",
      "ssm:PutParameter",
      "ssm:RemoveTagsFromResource",
    ]
    resources = [
      "arn:aws:ssm:*:*:parameter/humbugg/*",
      "arn:aws:ssm:*:*:parameter/mailer/*",
      "arn:aws:ssm:*:*:parameter/website/*",
      "arn:aws:ssm:*:*:parameter/classroom/*",
    ]
  }

  # DescribeParameters does not support resource-level permissions. Terraform
  # uses it to read parameter metadata after creating or updating a parameter.
  statement {
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  # KMS, and ONLY through SSM. **Required the moment any service stores a
  # SecureString** — e.g. a provider API token written by a service's prod
  # workflow from a GitHub environment secret and read at runtime by the Lambda
  # under its own role.
  #
  # A SecureString is encrypted with the account's AWS-managed `aws/ssm` key,
  # whose key policy grants the account access *conditioned on the call arriving
  # via SSM* — which means it delegates the real decision to IAM, so the caller's
  # own policy has to allow it. Without this, `PutParameter --type SecureString`
  # and Terraform's read-back both fail with an `AccessDeniedException` naming
  # **KMS**, which sends the reader to look for a KMS policy that does not exist.
  #
  # `kms:ViaService` is the whole of the scope and is what makes `resources =
  # ["*"]` acceptable here: this role can use the key through Parameter Store and
  # in no other way. It cannot decrypt an EBS volume, an S3 object or anybody's
  # secret — only a parameter it is already allowed to read by the statement
  # above.
  #
  # **This is applied by a DIFFERENT workflow from the one that needs it**, which
  # is the same trap the SSM statement above documents: the shared apply has to
  # land before the service's next deploy, or that deploy fails at the parameter with
  # an error naming a service nobody changed.
  statement {
    sid    = "UseTheSsmKeyThroughSsmOnly"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "github_actions" {
  name   = "github-actions-andreas-services"
  policy = data.aws_iam_policy_document.github_actions_permissions.json
  tags   = local.shared_tags
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions.arn
}

# ─── ACM ──────────────────────────────────────────────────────────────────────

resource "aws_acm_certificate_validation" "wildcard" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# SES reputation is account-wide even though individual applications use
# separate configuration sets. Hard bounces and complaints therefore share one
# suppression policy across every Mailer consumer.
resource "aws_sesv2_account_suppression_attributes" "shared" {
  suppressed_reasons = ["BOUNCE", "COMPLAINT"]
}
