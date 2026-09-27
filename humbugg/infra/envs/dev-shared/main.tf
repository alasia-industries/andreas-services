# THE ONE THING EVERY DEV STACK SHARES: the Cognito pool.
#
# Every other development resource is per machine — tables, bucket, webhook
# relay — and stays that way. The pool moved out of `envs/dev` in September
# 2026 for one reason: social sign-in. Each provider's console holds a list of
# exact redirect URIs, and a per-machine pool means a per-machine Managed Login
# domain, which means every new machine is a console edit at Google, Meta,
# LinkedIn and Apple before its developer can sign in with any of them. One
# pool is one domain is one URI, registered once:
#
#   https://humbugg-dev.auth.us-east-1.amazoncognito.com/oauth2/idpresponse
#
# What sharing costs: accounts are shared. A `.test` person seeded on one
# machine exists for every machine, with whatever password the LAST seed set —
# `ensure_pool_user` converges the password every run. Per-machine tables still
# hold per-machine data; only the identities are common. And `dev-aws-reset.sh`
# no longer deletes users, because they are not one machine's to delete.
#
# Applied by `dev-aws-setup.sh` on every machine, every run, before the
# per-machine stack. Idempotent, so whoever runs it last is irrelevant — with
# one catch. The social credentials come from the applying machine's
# `dev.env` (a developer gets them from the team's password manager), and
# Terraform cannot tell "this machine has no Google keys" from "remove
# Google". So `dev-aws-setup.sh` refuses to apply this stack while the pool
# holds a provider whose keys the machine lacks; `--skip-shared` uses the
# pool as it is. Nothing here reads SSM for a secret: SSM is where this
# stack PUBLISHES the pool's ids, not a place credentials are kept.

locals {
  project     = "humbugg"
  environment = "dev"

  common_tags = {
    Project     = local.project
    Environment = "development"
    ManagedBy   = "Terraform"
    LastApplied = var.aws_principal_arn
  }
}

module "auth" {
  source = "../../modules/auth"

  project     = local.project
  environment = local.environment

  # 8081 is Metro, the one surface that authenticates; the scheme is the store
  # build's. Identical on every machine, which is part of why one pool works.
  callback_urls = ["http://localhost:8081/auth/callback", "humbugg://auth/callback"]
  logout_urls   = ["http://localhost:8081/login", "humbugg://auth/logout"]

  # A DEFAULT Cognito domain, fixed by the prefix. A custom `auth-dev.humbugg.com`
  # would cost a SAN on the prod certificate — a replacement — for a page no
  # user ever loads.
  auth_domain_prefix = "${local.project}-${local.environment}"

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

  # The MCP hosts' clients live on the shared pool too, for the same reason
  # the pool does: one set of callback URLs, registered once. `smoke` is the
  # password-only client the local MCP integration tier signs seeded people in
  # through — a token the MCP server accepts, which the app client's is not.
  mcp_clients = {
    claude = {
      oauth         = true
      callback_urls = var.mcp_claude_callback_urls
    }
    smoke = {
      oauth         = false
      callback_urls = []
    }
  }

  tags = local.common_tags
}

# How a per-machine stack finds the pool: three parameters, the same names prod
# publishes under `/humbugg/prod/`. `envs/dev` reads them as data sources, so a
# machine set up before this stack exists fails its plan with the parameter's
# name in the error rather than with a pool that is not there.
resource "aws_ssm_parameter" "user_pool_id" {
  name  = "/${local.project}/${local.environment}/cognito-user-pool-id"
  type  = "String"
  value = module.auth.user_pool_id
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "client_id" {
  name  = "/${local.project}/${local.environment}/cognito-client-id"
  type  = "String"
  value = module.auth.user_pool_client_id
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "auth_domain" {
  name  = "/${local.project}/${local.environment}/cognito-auth-domain"
  type  = "String"
  value = module.auth.auth_domain
  tags  = local.common_tags
}

# MCP host => client id, as one JSON document so a host added to the map above
# reaches every machine without a new parameter or a new data source.
resource "aws_ssm_parameter" "mcp_client_ids" {
  name  = "/${local.project}/${local.environment}/cognito-mcp-client-ids"
  type  = "String"
  value = jsonencode(module.auth.mcp_client_ids)
  tags  = local.common_tags
}
