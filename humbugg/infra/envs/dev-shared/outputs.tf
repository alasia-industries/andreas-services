output "cognito_user_pool_id" {
  value = module.auth.user_pool_id
}

output "cognito_client_id" {
  value = module.auth.user_pool_client_id
}

output "cognito_auth_domain" {
  value = module.auth.auth_domain
}

# The one redirect URI every provider console needs for development.
output "idp_response_url" {
  value = module.auth.idp_response_url
}

output "identity_providers" {
  value = module.auth.identity_providers
}

output "cognito_mcp_client_ids" {
  value = module.auth.mcp_client_ids
}
