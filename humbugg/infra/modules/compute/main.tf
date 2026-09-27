resource "aws_ecr_repository" "api" {
  name                 = "${var.project}-${var.environment}-api"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}

resource "aws_ecr_repository" "marketing" {
  name                 = "${var.project}-${var.environment}-marketing"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "marketing" {
  repository = aws_ecr_repository.marketing.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}

resource "aws_iam_role" "api" {
  name = "${var.project}-${var.environment}-api-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "api_basic" {
  role       = aws_iam_role.api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role" "marketing" {
  name = "${var.project}-${var.environment}-marketing-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "marketing_basic" {
  role       = aws_iam_role.marketing.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "api_dynamodb" {
  name = "${var.project}-${var.environment}-api-dynamodb"
  role = aws_iam_role.api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:Scan",
        "dynamodb:BatchWriteItem",
        "dynamodb:BatchGetItem",
        "dynamodb:TransactWriteItems",
      ]
      Resource = concat(
        values(var.dynamodb_table_arns),
        [for arn in values(var.dynamodb_table_arns) : "${arn}/index/*"]
      )
    }]
  })
}

# Least-privilege file storage access: the API Lambda may only write and delete objects under
# the avatars/ prefix. It has no ListBucket, no bucket-wide access, and no read (CloudFront serves the
# objects), so a compromised function cannot enumerate or exfiltrate the bucket.
resource "aws_iam_role_policy" "api_app_files" {
  name = "${var.project}-${var.environment}-api-app-files"
  role = aws_iam_role.api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:DeleteObject",
      ]
      Resource = "${var.avatars_bucket_arn}/avatars/*"
    }]
  })
}

resource "aws_iam_role_policy" "api_email_messages" {
  name = "${var.project}-${var.environment}-api-email-messages"
  role = aws_iam_role.api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:UpdateItem"]
      Resource = var.email_messages_table_arn
    }]
  })
}

# The verified email address behind an account (#137). Humbugg stores none of its own, so this is
# the only way to reach a participant who did not arrive through a managed (Plus) invitation — which
# is what "keep account holders informed on every plan" requires.
#
# AdminGetUser and nothing else: reading one user's attributes is the whole need. The admin API
# family also contains AdminDeleteUser, AdminSetUserPassword and AdminUpdateUserAttributes, so a
# wildcard here would let a compromised API delete the pool's accounts to send an email.
#
# The reminders Lambda shares this role, which is why one statement covers both.
resource "aws_iam_role_policy" "api_cognito_directory" {
  name = "${var.project}-${var.environment}-api-cognito-directory"
  role = aws_iam_role.api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cognito-idp:AdminGetUser"]
      Resource = var.cognito_user_pool_arn
    }]
  })
}

resource "aws_iam_role" "email_status" {
  name = "${var.project}-${var.environment}-email-status-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "email_status_basic" {
  role       = aws_iam_role.email_status.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "email_status_queue" {
  name = "${var.project}-${var.environment}-email-status-queue"
  role = aws_iam_role.email_status.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ChangeMessageVisibility",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:ReceiveMessage",
      ]
      Resource = var.mailer_status_queue_arn
    }]
  })
}

resource "aws_iam_role_policy" "email_status_table" {
  name = "${var.project}-${var.environment}-email-status"
  role = aws_iam_role.email_status.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:UpdateItem"]
      Resource = var.email_messages_table_arn
    }]
  })
}

resource "aws_lambda_function" "api" {
  function_name = "${var.project}-${var.environment}-api"
  role          = aws_iam_role.api.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.api.repository_url}:latest"
  timeout       = 30
  memory_size   = 512

  tags = var.tags

  lifecycle {
    ignore_changes = [
      image_uri,
      environment,
    ]
  }
}

resource "aws_lambda_function" "email_status" {
  function_name = "${var.project}-${var.environment}-email-status"
  role          = aws_iam_role.email_status.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.api.repository_url}:latest"
  timeout       = 30
  memory_size   = 256

  environment {
    variables = {
      HUMBUGG_CONSUMER             = "email-status"
      HUMBUGG_EMAIL_MESSAGES_TABLE = "${var.project}-${var.environment}-email-messages"
    }
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [
      image_uri,
      environment,
    ]
  }
}

resource "aws_lambda_function" "reminders" {
  function_name = "${var.project}-${var.environment}-reminders"
  role          = aws_iam_role.api.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.api.repository_url}:latest"
  timeout       = 60
  memory_size   = 512

  tags = var.tags

  lifecycle {
    ignore_changes = [
      image_uri,
      environment,
    ]
  }
}

resource "aws_cloudwatch_event_rule" "reminders" {
  name                = "${var.project}-${var.environment}-reminders"
  description         = "Runs Humbugg automatic reminder evaluation every fifteen minutes"
  schedule_expression = "rate(15 minutes)"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "reminders" {
  rule = aws_cloudwatch_event_rule.reminders.name
  arn  = aws_lambda_function.reminders.arn
}

resource "aws_lambda_permission" "reminders_eventbridge" {
  statement_id  = "AllowEventBridgeReminderSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reminders.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.reminders.arn
}

resource "aws_lambda_event_source_mapping" "email_status" {
  event_source_arn                   = var.mailer_status_queue_arn
  function_name                      = aws_lambda_function.email_status.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 1
  function_response_types            = ["ReportBatchItemFailures"]

  depends_on = [
    aws_iam_role_policy.email_status_queue,
    aws_iam_role_policy_attachment.email_status_basic,
  ]
}

resource "aws_lambda_function" "marketing" {
  function_name = "${var.project}-${var.environment}-marketing"
  role          = aws_iam_role.marketing.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.marketing.repository_url}:latest"
  timeout       = 30
  memory_size   = 512

  environment {
    variables = {
      NODE_ENV = "production"
    }
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [
      image_uri,
      environment,
    ]
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${aws_lambda_function.api.function_name}"
  retention_in_days = 14

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "marketing" {
  name              = "/aws/lambda/${aws_lambda_function.marketing.function_name}"
  retention_in_days = 14

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "email_status" {
  name              = "/aws/lambda/${aws_lambda_function.email_status.function_name}"
  retention_in_days = 14

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "reminders" {
  name              = "/aws/lambda/${aws_lambda_function.reminders.function_name}"
  retention_in_days = 14

  tags = var.tags
}

# The email-status error alarm moved to modules/alerting, which owns every alarm and
# the SNS topic they notify. A `moved` block in envs/prod keeps the same AWS alarm.

resource "aws_apigatewayv2_api" "api" {
  name          = "${var.project}-${var.environment}-api"
  protocol_type = "HTTP"
  description   = "${var.project} Backend API"

  tags = var.tags
}

resource "aws_apigatewayv2_integration" "api" {
  api_id           = aws_apigatewayv2_api.api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.api.invoke_arn

  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "api" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "ANY /api/{proxy+}"

  target             = "integrations/${aws_apigatewayv2_integration.api.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# CORS preflight. A browser sends OPTIONS without an Authorization header, so the JWT
# authorizer on the ANY route above would 401 the preflight before the Lambda ever ran and
# every non-simple cross-origin request would fail. This route mirrors the authenticated
# route's path exactly so it wins route selection (same path, more specific method), and
# carries authorization_type = NONE so the preflight reaches ASP.NET. ASP.NET's CORS
# middleware answers it — the API deliberately has no cors_configuration of its own,
# because a response carrying two Access-Control-Allow-Origin headers is rejected by the
# browser. One source of CORS headers, and it is the application.
resource "aws_apigatewayv2_route" "api_preflight" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "OPTIONS /api/{proxy+}"

  target             = "integrations/${aws_apigatewayv2_integration.api.id}"
  authorization_type = "NONE"
}

# Stripe signs the raw request body and cannot present a Cognito JWT. This exact,
# method-specific route bypasses only the gateway authorizer; ASP.NET still verifies
# Stripe-Signature before any billing state is read or written.
resource "aws_apigatewayv2_route" "stripe_webhook" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /api/billing/stripe/webhook"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

# The signed-out invitation preview, and the public price list.
#
# `[AllowAnonymous]` in ASP.NET is not enough on its own and never was: the `ANY /api/{proxy+}`
# route above carries the Cognito authorizer, so the gateway answers `{"message":"Unauthorized"}`
# and the Lambda is never invoked. The attribute governs a request that arrives; these routes are
# what let it arrive.
#
# Both of these were broken in production. The invitation preview — the screen a person sees after
# following an invite link, before they have an account — had been 401ing since it shipped, and
# nothing caught it: the browser suite answers `/api/**` from fixtures, so it never crosses a
# gateway. `AnonymousSurfaceTests` now asserts this file lists every `[AllowAnonymous]` endpoint,
# so the two halves cannot disagree again.
#
# Each is exact and method-specific, like the Stripe webhook: a wildcard here would hand the whole
# API to anybody. The application still authorizes every one of them — the invitation routes verify
# the invite secret, and the price list has nothing to authorize.
resource "aws_apigatewayv2_route" "invitation_preview" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /api/groups/{groupId}/invitation"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

resource "aws_apigatewayv2_route" "managed_invitation_preview" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /api/groups/{groupId}/invitations/{invitationId}/preview"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

resource "aws_apigatewayv2_route" "plans" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /api/plans"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

resource "aws_apigatewayv2_route" "health" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /health"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.api.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${var.project}-${var.environment}-cognito"

  # For an access token the authorizer matches `client_id` against this list.
  # The app client plus every MCP host's client: the MCP server calls /api/* as
  # the signed-in person with the token its host holds, so a client missing
  # here is the gateway's bare {"message":"Unauthorized"} on every tool call.
  # Program.cs keeps its own allow-list (COGNITO_ADDITIONAL_CLIENT_IDS); the
  # two must name the same clients.
  jwt_configuration {
    audience = concat([var.cognito_client_id], var.cognito_additional_client_ids)
    issuer   = "https://cognito-idp.us-east-1.amazonaws.com/${var.cognito_user_pool_id}"
  }
}

resource "aws_apigatewayv2_stage" "api" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true

  # Global rate limit for the entire API, enforced by API Gateway before
  # the Lambda is invoked (throttled requests cost no invocation). This applies
  # to every route via the stage default — there are no per-route overrides. It
  # is an aggregate throughput guard, not per-caller; per-IP edge protection is
  # tracked separately as AWS WAF work (see humbugg/docs/threat-model.md §4).
  default_route_settings {
    throttling_rate_limit  = var.api_throttling_rate_limit
    throttling_burst_limit = var.api_throttling_burst_limit
  }

  tags = var.tags
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

resource "aws_apigatewayv2_api" "marketing" {
  name          = "${var.project}-${var.environment}-marketing"
  protocol_type = "HTTP"
  description   = "${var.project} marketing SSR"

  tags = var.tags
}

resource "aws_apigatewayv2_integration" "marketing" {
  api_id                 = aws_apigatewayv2_api.marketing.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.marketing.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

resource "aws_apigatewayv2_route" "marketing" {
  api_id    = aws_apigatewayv2_api.marketing.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.marketing.id}"
}

resource "aws_apigatewayv2_stage" "marketing" {
  api_id      = aws_apigatewayv2_api.marketing.id
  name        = "$default"
  auto_deploy = true

  tags = var.tags
}

resource "aws_lambda_permission" "marketing_api_gateway" {
  statement_id  = "AllowAPIGatewayInvokeFrontend"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.marketing.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.marketing.execution_arn}/*/*"
}
