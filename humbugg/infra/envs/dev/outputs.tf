output "resource_prefix" {
  value = local.resource_prefix
}

# The shared pool's, read back from SSM so every script keeps reading the
# machine's own outputs and none has to know where the pool lives.
# `insecure_value`: the provider marks every parameter's `value` sensitive,
# which would make these outputs refuse to render; these three are plain
# `String` ids, public in every authorize URL.
output "cognito_user_pool_id" {
  value = data.aws_ssm_parameter.cognito_user_pool_id.insecure_value
}

output "cognito_client_id" {
  value = data.aws_ssm_parameter.cognito_client_id.insecure_value
}

output "cognito_auth_domain" {
  value = data.aws_ssm_parameter.cognito_auth_domain.insecure_value
}

output "cognito_mcp_client_ids" {
  description = "MCP host => its client id on the shared dev pool"
  value       = jsondecode(data.aws_ssm_parameter.cognito_mcp_client_ids.insecure_value)
}

output "table_names" {
  value = module.storage.table_names
}

output "app_bucket_name" {
  value = module.storage.app_bucket_name
}

output "machine_id" {
  value = var.machine_id
}

output "webhook_endpoint_url" {
  description = "This machine's public Stripe webhook URL; dev-aws-setup.sh registers it with Stripe."
  value       = module.webhook_relay.endpoint_url
}

output "webhook_queue_url" {
  description = "The queue behind that endpoint; the consumer dev-up.sh starts drains it."
  value       = module.webhook_relay.queue_url
}
