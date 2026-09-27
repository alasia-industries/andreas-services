# One app client per MCP host (`var.mcp_clients`), named
# `<project>-<env>-mcp-<host>`. The API accepts every one of them in two
# places — the gateway authorizer's audience (modules/compute) and Program.cs's
# client allow-list — both fed from `mcp_client_ids`.
#
# Everything an OAuth host shares with the app client is copied from it on
# purpose, not by convenience:
#
# - `supported_identity_providers` and `depends_on`: the social buttons must be
#   on the page Claude opens, or a Google-only account cannot connect.
# - `refresh_token_rotation` ENABLED with no `ALLOW_REFRESH_TOKEN_AUTH`: the
#   pair is rejected by Cognito at apply time and passes `terraform validate`
#   — see the long comment on `aws_cognito_user_pool_client.main`.
# - Token validity: an MCP host refreshes as the app does.
#
# The password-only client (`oauth = false`, the smoke host) keeps rotation on
# as well. Without it the same rule applies in reverse: Cognito's answer to an
# explicit flow list that omits `ALLOW_REFRESH_TOKEN_AUTH` is not something
# this stack should depend on, and with rotation on the omission is required.
resource "aws_cognito_user_pool_client" "mcp" {
  for_each = var.mcp_clients

  name         = "${var.project}-${var.environment}-mcp-${each.key}"
  user_pool_id = aws_cognito_user_pool.main.id

  # Public: an MCP host runs PKCE and holds no secret for us.
  generate_secret = false
  callback_urls   = each.value.oauth ? each.value.callback_urls : null

  allowed_oauth_flows_user_pool_client = each.value.oauth
  allowed_oauth_flows                  = each.value.oauth ? ["code"] : null
  allowed_oauth_scopes                 = each.value.oauth ? ["openid", "email", "profile"] : null
  supported_identity_providers = (
    each.value.oauth ? concat(["COGNITO"], local.identity_provider_names) : ["COGNITO"]
  )

  depends_on = [
    aws_cognito_identity_provider.google,
    aws_cognito_identity_provider.facebook,
    aws_cognito_identity_provider.apple,
    aws_cognito_identity_provider.linkedin,
  ]

  refresh_token_rotation {
    feature                    = "ENABLED"
    retry_grace_period_seconds = 30
  }

  # SRP only. An OAuth host never calls InitiateAuth — the hosted pages sign
  # people in server-side — and the smoke host needs exactly SRP.
  explicit_auth_flows = ["ALLOW_USER_SRP_AUTH"]

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true
  access_token_validity         = 1
  id_token_validity             = 1
  refresh_token_validity        = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}

# Branding is per client: without its own record the sign-in page Claude opens
# is Cognito's unbranded default. Same document and artwork as the app's
# branding (`aws_cognito_managed_login_branding.main`, whose comments explain
# each asset) — keep `local.branding_assets` and that resource in step.
locals {
  branding_assets = concat(
    [
      for mode in ["LIGHT", "DARK"] : {
        category    = "FORM_LOGO"
        color_mode  = mode
        extension   = "PNG"
        resource_id = null
        bytes       = filebase64("${path.module}/assets/humbugg-wordmark.png")
      }
    ],
    [
      for mode in ["LIGHT", "DARK"] : {
        category    = "FAVICON_ICO"
        color_mode  = mode
        extension   = "ICO"
        resource_id = null
        bytes       = filebase64("${path.module}/assets/humbugg-favicon.ico")
      }
    ],
    [
      for mode in(local.linkedin_enabled ? ["LIGHT", "DARK"] : []) : {
        category    = "IDP_BUTTON_ICON"
        color_mode  = mode
        extension   = "SVG"
        resource_id = "LinkedIn"
        bytes       = filebase64("${path.module}/assets/linkedin-bug.svg")
      }
    ],
  )
}

resource "aws_cognito_managed_login_branding" "mcp" {
  for_each = { for host, c in var.mcp_clients : host => c if c.oauth }

  user_pool_id = aws_cognito_user_pool.main.id
  client_id    = aws_cognito_user_pool_client.mcp[each.key].id

  settings = file("${path.module}/managed-login-settings.json")

  dynamic "asset" {
    for_each = local.branding_assets
    content {
      category    = asset.value.category
      color_mode  = asset.value.color_mode
      extension   = asset.value.extension
      resource_id = asset.value.resource_id
      bytes       = asset.value.bytes
    }
  }
}
