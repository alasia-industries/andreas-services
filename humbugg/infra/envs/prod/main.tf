locals {
  project              = "humbugg"
  environment          = "prod"
  domain_name          = "humbugg.com"
  api_domain_name      = "api.${local.domain_name}"
  realtime_domain_name = "ws.${local.domain_name}"
  auth_domain_name     = "auth.${local.domain_name}"

  # What the backend derives invite URLs and avatar URLs from, and what Cognito
  # redirects to — so it is the product app, not the marketing site. The
  # marketing origin has no Terraform consumer; it is a build-time value the
  # deploy workflow passes to Vite.
  app_base_url = "https://app.${local.domain_name}"

  # One Cognito app client per MCP host (modules/auth/mcp_clients.tf). Claude's
  # hosted surfaces finish OAuth at these two, matched exactly. `smoke` is the
  # post-deploy smoke test's password-only client: a token the MCP server
  # accepts, from an account that holds nothing (docs/TESTING.md rule 9).
  mcp_clients = {
    claude = {
      oauth         = true
      callback_urls = ["https://claude.ai/api/mcp/auth_callback", "https://claude.com/api/mcp/auth_callback"]
    }
    smoke = {
      oauth         = false
      callback_urls = []
    }
  }

  common_tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "Terraform"
  }

}

data "aws_route53_zone" "humbugg" {
  name         = "humbugg.com"
  private_zone = false
}

data "aws_ssm_parameter" "mailer_status_queue_arn" {
  name = "/mailer/prod/humbugg/status-queue-arn"
}

data "aws_ssm_parameter" "mailer_auth_configuration_set" {
  name = "/mailer/prod/humbugg/auth-configuration-set"
}

module "auth" {
  source = "../../modules/auth"

  project     = local.project
  environment = local.environment

  # Two literals per list because the same codebase produces two redirects: the
  # web export served from app.humbugg.com, and the custom scheme a store build
  # returns to. Cognito matches exactly, so a bare origin is not a callback and
  # a missing entry is a hard `redirect_mismatch`.
  callback_urls = ["${local.app_base_url}/auth/callback", "humbugg://auth/callback"]
  logout_urls   = ["${local.app_base_url}/login", "humbugg://auth/logout"]

  auth_domain          = local.auth_domain_name
  auth_certificate_arn = module.certificates.certificate_arn
  route53_zone_id      = data.aws_route53_zone.humbugg.zone_id

  email_sending_account   = "DEVELOPER"
  email_from_address      = module.email.from_address
  email_source_arn        = module.email.identity_arn
  email_configuration_set = data.aws_ssm_parameter.mailer_auth_configuration_set.value

  # Social sign-in. Empty leaves a provider off; see envs/*/variables.tf.
  google_client_id       = var.google_client_id
  google_client_secret   = var.google_client_secret
  facebook_app_id        = var.facebook_app_id
  facebook_app_secret    = var.facebook_app_secret
  apple_services_id      = var.apple_services_id
  apple_team_id          = var.apple_team_id
  apple_key_id           = var.apple_key_id
  apple_private_key      = var.apple_private_key
  linkedin_client_id     = var.linkedin_client_id
  linkedin_client_secret = var.linkedin_client_secret

  mcp_clients = local.mcp_clients

  tags = local.common_tags
}

module "storage" {
  source = "../../modules/storage"

  project     = local.project
  environment = local.environment
  aws_region  = var.aws_region
  domain_name = local.domain_name

  tags = local.common_tags
}

module "compute" {
  source = "../../modules/compute"

  project     = local.project
  environment = local.environment

  dynamodb_table_arns      = module.storage.dynamodb_table_arns
  email_messages_table_arn = module.storage.email_messages_table_arn
  # app_files, not app: the SPA bundle and user uploads live in separate buckets, and
  # the Lambda writes avatars to the files one (HUMBUGG_APP_BUCKET). Granting it against
  # the hosting bucket made every avatar upload a 500 — AccessDenied on PutObject.
  avatars_bucket_arn      = module.storage.app_files_bucket_arn
  mailer_status_queue_arn = data.aws_ssm_parameter.mailer_status_queue_arn.value
  cognito_user_pool_id    = module.auth.user_pool_id
  cognito_user_pool_arn   = module.auth.user_pool_arn
  cognito_client_id       = module.auth.user_pool_client_id
  # Every MCP host's client, so the tokens the MCP server passes on reach the
  # application. Program.cs's allow-list is the other half; the deploy
  # workflow sets it from the same SSM parameter as the MCP Lambda's clients.
  cognito_additional_client_ids = values(module.auth.mcp_client_ids)

  api_throttling_rate_limit  = var.api_throttling_rate_limit
  api_throttling_burst_limit = var.api_throttling_burst_limit

  tags = local.common_tags
}

module "certificates" {
  source = "../../modules/certificates"

  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  domain_name = local.domain_name

  # Every name Humbugg serves. Adding one later replaces the certificate, so the full
  # set is declared up front rather than grown surface by surface.
  #
  # `auth.` was added after the fact anyway, when sign-in moved to Managed Login
  # (#365) — a replacement, not an update. `create_before_destroy` in
  # modules/certificates makes that survivable: the new certificate is issued and
  # every consumer repointed before the old one goes, so www, app and api keep
  # serving through the swap.
  subject_alternative_names = [
    "www.${local.domain_name}",
    "app.${local.domain_name}",
    local.api_domain_name,
    local.auth_domain_name,
    local.realtime_domain_name,
  ]

  route53_zone_id = data.aws_route53_zone.humbugg.zone_id

  tags = local.common_tags
}

# api.humbugg.com answers alongside the existing humbugg.com/api/* CloudFront path.
# Nothing is cut over here: no caller is repointed and the CloudFront behavior is untouched.
module "api_domain" {
  source = "../../modules/api_domain"

  domain_name     = local.api_domain_name
  certificate_arn = module.certificates.certificate_arn

  api_id     = module.compute.api_id
  stage_name = module.compute.api_stage_name

  route53_zone_id = data.aws_route53_zone.humbugg.zone_id

  tags = local.common_tags
}

# The realtime channel (#691): the WebSocket API on ws.humbugg.com. Its two Lambdas run the
# backend's image under the API's role, the way the reminder consumer does, so the table grant the
# storage output confers reaches them without a policy of their own.
module "realtime" {
  source = "../../modules/realtime"

  project     = local.project
  environment = local.environment
  aws_region  = var.aws_region

  image_uri              = "${module.compute.ecr_repository_url}:latest"
  lambda_role_arn        = module.compute.api_role_arn
  lambda_role_name       = module.compute.api_role_name
  connections_table_name = module.storage.dynamodb_table_names["chat_connections"]

  tags = local.common_tags
}

# ws.humbugg.com — the same domain module as api.humbugg.com, mapped onto the WebSocket stage.
module "realtime_domain" {
  source = "../../modules/api_domain"

  domain_name     = local.realtime_domain_name
  certificate_arn = module.certificates.certificate_arn

  api_id     = module.realtime.api_id
  stage_name = module.realtime.stage_name

  route53_zone_id = data.aws_route53_zone.humbugg.zone_id

  tags = local.common_tags
}

# What the app connects to, and what the backend posts through. Both known here, so both are
# Terraform's to publish; update-lambda and deploy-app read them.
resource "aws_ssm_parameter" "realtime_url" {
  name        = "/humbugg/prod/realtime-url"
  description = "Public WebSocket URL of the realtime channel"
  type        = "String"
  value       = "wss://${module.realtime_domain.domain_name}"

  tags = local.common_tags
}

resource "aws_ssm_parameter" "realtime_endpoint" {
  name        = "/humbugg/prod/realtime-endpoint"
  description = "Management endpoint the backend posts to WebSocket connections through"
  type        = "String"
  value       = module.realtime.management_endpoint

  tags = local.common_tags
}

# Terraform owns this parameter because Terraform knows the value; the deploy workflow's
# put-parameter step exists for outputs the app jobs consume, and can read this one.
resource "aws_ssm_parameter" "api_domain" {
  name        = "/humbugg/prod/api-domain"
  description = "Public base URL of the backend API on its own domain"
  type        = "String"
  value       = module.api_domain.api_base_url

  tags = local.common_tags
}

# The MCP connector at https://api.humbugg.com/mcp — routes on the same HTTP API
# as /api/*, so the connector, its OAuth metadata and the API share an origin.
module "mcp" {
  source = "../../modules/mcp"

  project     = local.project
  environment = local.environment

  api_id            = module.compute.api_id
  api_execution_arn = module.compute.api_execution_arn

  public_url           = module.api_domain.api_base_url
  api_url              = module.api_domain.api_base_url
  cognito_domain       = module.auth.auth_domain
  cognito_user_pool_id = module.auth.user_pool_id
  mcp_clients_json     = local.mcp_clients_json

  tags = local.common_tags
}

locals {
  # HUMBUGG_MCP_CLIENTS, the server's contract: host => {client_id, redirect_uris}.
  # The server's dynamic registration answers a redirect with the client whose
  # list contains it, so these are the same lists Cognito was given.
  mcp_clients_json = jsonencode({
    for host, id in module.auth.mcp_client_ids : host => {
      client_id     = id
      redirect_uris = local.mcp_clients[host].callback_urls
    }
  })
}

# Terraform knows the value, so Terraform publishes it. The deploy workflow
# reads it for three things: the MCP Lambda's HUMBUGG_MCP_CLIENTS, the API's
# COGNITO_ADDITIONAL_CLIENT_IDS (every client_id in it), and the smoke test's
# client (`.smoke.client_id`).
resource "aws_ssm_parameter" "mcp_clients" {
  name        = "/humbugg/prod/mcp-clients"
  description = "MCP host => Cognito client id and redirect URIs (JSON)"
  type        = "String"
  value       = local.mcp_clients_json

  tags = local.common_tags
}

module "hosting_marketing" {
  source = "../../modules/hosting_marketing"

  environment = local.environment
  project     = local.project
  domain_name = local.domain_name

  certificate_arn = module.certificates.certificate_arn

  route53_zone_id = data.aws_route53_zone.humbugg.zone_id

  marketing_bucket_id                   = module.storage.marketing_bucket_id
  marketing_bucket_arn                  = module.storage.marketing_bucket_arn
  marketing_bucket_regional_domain_name = module.storage.marketing_bucket_regional_domain_name

  marketing_api_domain = module.compute.marketing_api_domain

  tags = local.common_tags
}

module "hosting_app" {
  source = "../../modules/hosting_app"

  environment = local.environment
  project     = local.project
  domain_name = local.domain_name

  certificate_arn = module.certificates.certificate_arn
  route53_zone_id = data.aws_route53_zone.humbugg.zone_id

  app_bucket_id                   = module.storage.app_bucket_id
  app_bucket_arn                  = module.storage.app_bucket_arn
  app_bucket_regional_domain_name = module.storage.app_bucket_regional_domain_name

  app_files_bucket_id                   = module.storage.app_files_bucket_id
  app_files_bucket_arn                  = module.storage.app_files_bucket_arn
  app_files_bucket_regional_domain_name = module.storage.app_files_bucket_regional_domain_name

  tags = local.common_tags
}

module "email" {
  source = "../../modules/email"

  aws_region      = var.aws_region
  domain_name     = local.domain_name
  route53_zone_id = data.aws_route53_zone.humbugg.zone_id

  # DKIM public key generated in Google Admin (Apps → Gmail → Authenticate
  # email). Empty until generated; the record is created once set.
  google_dkim_txt_value = ""

  # The manually created google-site-verification string lives at the apex;
  # the single managed apex TXT record set must carry it alongside SPF.
  # Public value — safe to commit. Never remove it: Google re-checks it.
  apex_txt_additional_records = ["google-site-verification=Ty65XWNQL5fqun83W2_nuKQGbXwmS5IRTHDpU9up1gQ"]
}

module "billing" {
  source = "../../modules/billing"

  project     = local.project
  environment = local.environment

  stripe_publishable_key = var.stripe_publishable_key
  stripe_secret_key      = var.stripe_secret_key
  stripe_webhook_secret  = var.stripe_webhook_secret

  tags = local.common_tags
}

# THE STRIPE WEBHOOK PATH, THE SAME ONE DEV RUNS.
#
# Stripe posts to this module's gateway, not to the API's route; the receiver
# queues it and the consumer — the API's own image, entered through
# ConsumerHost like the email-status and reminder Lambdas — verifies and
# applies it. Dev is identical with a Compose service where the Lambda is. The
# module header has the reasoning; the decision was that prod and dev do not
# get to take different paths to the same code.
#
# The Stripe endpoint pointing at `webhook_endpoint_url` is registered by hand
# (docs/stripe-setup.md §3) — the URL is known only after this applies. The
# API's `/api/billing/stripe/webhook` route stays: harmless, and the smoke
# test still proves the gateway reaches the application through it.
module "webhook_relay" {
  source = "../../modules/webhook_relay"

  name_prefix = "${local.project}-${local.environment}"

  create_consumer    = true
  consumer_image_uri = "${module.compute.ecr_repository_url}:latest"
  consumer_role_arn  = module.compute.api_role_arn
  consumer_role_name = module.compute.api_role_name
  alarm_topic_arn    = module.alerting.topic_arn

  tags = local.common_tags
}

module "alerting" {
  source = "../../modules/alerting"

  project     = local.project
  environment = local.environment

  alert_email = var.alert_email

  # `email-status` keeps its original threshold of 1: every error is a delivery status
  # that never reached the ledger. The rest tolerate 2 errors in five minutes so a lone
  # cold-start failure does not mail anyone. Throttles are alarmed for the request-path
  # Lambda only — the consumers are asynchronous and retry.
  lambda_functions = {
    api = {
      function_name   = module.compute.lambda_function_name
      error_threshold = 3
      throttle_alarm  = true
    }
    reminders = {
      function_name   = module.compute.reminders_lambda_function_name
      error_threshold = 3
    }
    marketing = {
      function_name   = module.compute.marketing_lambda_function_name
      error_threshold = 3
    }
    "email-status" = {
      function_name   = module.compute.email_status_lambda_function_name
      error_threshold = 1
    }
    # Errors here are infrastructure — a DynamoDB refusal, a bad image — not
    # refused webhooks, which the consumer logs and consumes without throwing.
    # A message that keeps failing lands in the relay's DLQ, which has its own
    # alarm on the same topic.
    "stripe-webhooks" = {
      function_name   = module.webhook_relay.consumer_function_name
      error_threshold = 2
    }
    "realtime-authorizer" = {
      function_name   = module.realtime.authorizer_lambda_function_name
      error_threshold = 3
    }
    "realtime-connections" = {
      function_name   = module.realtime.connections_lambda_function_name
      error_threshold = 3
    }
    # Throttles alarm too: reserved concurrency caps this function, and a
    # connector throttled at its ceiling is a user-facing refusal.
    mcp = {
      function_name   = module.mcp.lambda_function_name
      error_threshold = 3
      throttle_alarm  = true
    }
  }

  api_ids = {
    api       = module.compute.api_id
    marketing = module.compute.marketing_api_id
  }

  dynamodb_table_names = module.storage.dynamodb_table_names

  tags = local.common_tags
}

# The alarm predates the module. `moved` keeps the same AWS alarm — it is relocated in
# state, not replaced, so nothing is destroyed and no alarm history is lost.
moved {
  from = module.compute.aws_cloudwatch_metric_alarm.email_status_errors
  to   = module.alerting.aws_cloudwatch_metric_alarm.lambda_errors["email-status"]
}

# Published for future consumers — another stack that wants to notify the same place
# reads this rather than duplicating a topic.
resource "aws_ssm_parameter" "alerts_topic_arn" {
  name        = "/humbugg/prod/alerts-topic-arn"
  description = "SNS topic every Humbugg production alarm publishes to"
  type        = "String"
  value       = module.alerting.topic_arn

  tags = local.common_tags
}

