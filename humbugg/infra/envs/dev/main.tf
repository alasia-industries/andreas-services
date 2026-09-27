locals {
  resource_prefix = "humbugg-dev-${var.machine_short_id}"
  app_bucket_name = "humbugg-dev-${var.aws_account_id}-${var.machine_short_id}-app"

  common_tags = {
    Project            = "humbugg"
    Environment        = "development"
    ManagedBy          = "Terraform"
    DeveloperMachineId = var.machine_id
    DeveloperPrincipal = var.aws_principal_arn
    MachineName        = var.machine_name
  }
}

# THE POOL IS NOT HERE. It is the shared stack's, `envs/dev-shared`, one pool
# for every machine — because social sign-in registers one redirect URI per
# Managed Login domain at four provider consoles, and a per-machine domain
# made every new machine four console edits. `dev-aws-setup.sh` applies that
# stack before this one; these reads fail with the parameter's name if it has
# not been. Tables, bucket and webhook relay stay per machine.
data "aws_ssm_parameter" "cognito_user_pool_id" {
  name = "/humbugg/dev/cognito-user-pool-id"
}

data "aws_ssm_parameter" "cognito_client_id" {
  name = "/humbugg/dev/cognito-client-id"
}

data "aws_ssm_parameter" "cognito_auth_domain" {
  name = "/humbugg/dev/cognito-auth-domain"
}

# MCP host => client id (JSON). No MCP Lambda runs in a dev stack — the backend
# runs in Docker with no gateway in front of it — so this is read only to hand
# the ids to dev.env: the local backend's allow-list and the local MCP server.
data "aws_ssm_parameter" "cognito_mcp_client_ids" {
  name = "/humbugg/dev/cognito-mcp-client-ids"
}

module "storage" {
  source = "../../modules/dev_storage"

  resource_prefix = local.resource_prefix
  app_bucket_name = local.app_bucket_name
  tags            = local.common_tags
}

# THE ONE PUBLIC ENDPOINT A DEV STACK HAS.
#
# Stripe cannot reach `localhost:5001`, so for as long as this environment had
# no public URL the only way a Plus purchase could complete locally was the
# Stripe CLI relaying events while it happened to be running. This gives each
# machine a real webhook endpoint — a gateway, a zip receiver and a queue —
# and `dev-up.sh` runs the consumer that drains the queue into the local
# backend. `dev-aws-setup.sh` registers the URL with Stripe after this applies
# and writes the queue and secret into dev.env; see the module for the design
# and for why Terraform does not touch the Stripe side.
module "webhook_relay" {
  source = "../../modules/webhook_relay"

  name_prefix = local.resource_prefix
  tags        = local.common_tags
}
