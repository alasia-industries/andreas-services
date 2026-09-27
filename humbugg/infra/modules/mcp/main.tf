# The Humbugg MCP server (`humbugg/mcp`), hosted for Claude and every other
# MCP host: uvicorn serving `humbugg_mcp.hosted:app` behind the Lambda Web
# Adapter, stateless Streamable HTTP at https://api.humbugg.com/mcp.
#
# It rides the existing backend HTTP API rather than a gateway of its own, so
# the connector URL, the OAuth metadata and /api/* share one origin. Its routes
# carry NO authorizer: the server answers 401 itself with the
# `WWW-Authenticate` pointer an MCP host needs to start OAuth, verifies the
# Cognito access token, and passes it on to /api/*, where the gateway's JWT
# authorizer and Program.cs check it again.
#
# It holds no AWS permission beyond its own logs and one atomic counter: every
# byte of Humbugg data goes through the API as the signed-in person, so the API
# stays the one place authorization lives.

resource "aws_ecr_repository" "mcp" {
  name                 = "${var.project}-${var.environment}-mcp"
  image_tag_mutability = "MUTABLE"
  # Set at creation, not at a later rename: Terraform destroys against prior
  # state, so a flag added in the same apply as a rename is never seen.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "mcp" {
  repository = aws_ecr_repository.mcp.name

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

# Per-`sub` fixed-window counter. The stage throttle is one aggregate limit and
# WAF cannot front an HTTP API, so the server counts each person's calls here:
# one UpdateItem (ADD, conditional on the limit) per request, the item expiring
# with its window.
resource "aws_dynamodb_table" "ratelimit" {
  name         = "${var.project}-${var.environment}-mcp-ratelimit"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = var.tags
}

resource "aws_iam_role" "mcp" {
  name = "${var.project}-${var.environment}-mcp-role"

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

resource "aws_cloudwatch_log_group" "mcp" {
  name              = "/aws/lambda/${var.project}-${var.environment}-mcp"
  retention_in_days = 14

  tags = var.tags
}

# Its own log group and nothing wider — not AWSLambdaBasicExecutionRole, which
# grants CreateLogGroup and PutLogEvents on every group in the account.
resource "aws_iam_role_policy" "mcp_logs" {
  name = "${var.project}-${var.environment}-mcp-logs"
  role = aws_iam_role.mcp.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.mcp.arn}:*"
    }]
  })
}

resource "aws_iam_role_policy" "mcp_ratelimit" {
  name = "${var.project}-${var.environment}-mcp-dynamodb"
  role = aws_iam_role.mcp.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:UpdateItem"]
      Resource = aws_dynamodb_table.ratelimit.arn
    }]
  })
}

resource "aws_lambda_function" "mcp" {
  function_name = "${var.project}-${var.environment}-mcp"
  role          = aws_iam_role.mcp.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.mcp.repository_url}:latest"
  # One under API Gateway's 30 s integration ceiling, so the function times
  # out (and logs it) before the gateway answers 503 with nothing logged.
  timeout     = 29
  memory_size = 512
  # x86_64, as every other humbugg image: the deploy workflow builds on an
  # amd64 runner with no emulation, and an arm64 function would refuse that
  # image at update-function-code.
  architectures = ["x86_64"]

  # A ceiling on the connector, so a burst of MCP traffic cannot take the
  # account-wide concurrency the app's API Lambda needs.
  reserved_concurrent_executions = var.reserved_concurrency

  # Initial values only. The deploy workflow's update-lambda job owns both the
  # image and the environment from the first deploy on; keep its MCP block and
  # this one naming the same variables.
  environment {
    variables = {
      HUMBUGG_MCP_PUBLIC_URL            = var.public_url
      HUMBUGG_API_URL                   = var.api_url
      HUMBUGG_COGNITO_DOMAIN            = "https://${var.cognito_domain}"
      HUMBUGG_COGNITO_USER_POOL_ID      = var.cognito_user_pool_id
      HUMBUGG_MCP_CLIENTS               = var.mcp_clients_json
      HUMBUGG_MCP_RATELIMIT_TABLE       = aws_dynamodb_table.ratelimit.name
      HUMBUGG_MCP_RATE_LIMIT_PER_MINUTE = tostring(var.rate_limit_per_minute)
      AWS_LWA_PORT                      = "8080"
      AWS_LWA_READINESS_CHECK_PATH      = "/healthz"
    }
  }

  lifecycle {
    ignore_changes = [
      image_uri,
      environment,
    ]
  }

  depends_on = [aws_cloudwatch_log_group.mcp]

  tags = var.tags
}

resource "aws_apigatewayv2_integration" "mcp" {
  api_id                 = var.api_id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.mcp.invoke_arn
  payload_format_version = "2.0"
}

# The MCP endpoint, the OAuth metadata (RFC 9728 / RFC 8414) and the OAuth shim.
# No authorizer — see the top of this file. None of the three overlaps a route
# modules/compute declares (`/api/*`, `/health`), so route selection is exact.
resource "aws_apigatewayv2_route" "mcp" {
  for_each = toset([
    "ANY /mcp",
    "GET /.well-known/{proxy+}",
    "ANY /oauth/{proxy+}",
    # The icon a host can find for a connector on this domain (humbugg_mcp/favicon.py).
    "GET /favicon.ico",
    "GET /favicon.svg",
  ])

  api_id             = var.api_id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.mcp.id}"
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "mcp_api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.mcp.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${var.api_execution_arn}/*/*"
}
