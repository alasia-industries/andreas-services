output "api_endpoint" {
  description = "API Gateway invoke URL"
  value       = module.compute.api_endpoint
}

output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = module.compute.ecr_repository_url
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = module.compute.lambda_function_name
}

output "email_status_lambda_function_name" {
  description = "Mailer status consumer Lambda function name"
  value       = module.compute.email_status_lambda_function_name
}

output "marketing_ecr_repository_url" {
  description = "Marketing SSR ECR repository URL"
  value       = module.compute.marketing_ecr_repository_url
}

output "marketing_lambda_function_name" {
  description = "Marketing SSR Lambda function name"
  value       = module.compute.marketing_lambda_function_name
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = module.auth.user_pool_id
}

output "cognito_client_id" {
  description = "Cognito User Pool Client ID"
  value       = module.auth.user_pool_client_id
}

output "cognito_auth_domain" {
  description = "Host serving the Managed Login pages"
  value       = module.auth.auth_domain
}

output "marketing_bucket" {
  description = "Marketing hashed-asset S3 bucket name"
  value       = module.storage.marketing_bucket_id
}

output "app_files_bucket" {
  description = "Application object S3 bucket name (holds avatars under the avatars/ prefix)"
  value       = module.storage.app_files_bucket_id
}

output "api_domain" {
  description = "Public base URL of the backend API on its own domain"
  value       = module.api_domain.api_base_url
}

output "cloudfront_distribution_id" {
  description = "Marketing (www) CloudFront distribution ID"
  value       = module.hosting_marketing.cloudfront_distribution_id
}

output "app_bucket" {
  description = "Expo web export S3 bucket name"
  value       = module.storage.app_bucket_id
}

output "app_cloudfront_distribution_id" {
  description = "Product app (app.) CloudFront distribution ID"
  value       = module.hosting_app.cloudfront_distribution_id
}

output "email_from_address" {
  description = "Verified transactional email From address"
  value       = module.email.from_address
}

output "ses_identity_arn" {
  description = "Verified SES domain identity ARN"
  value       = module.email.identity_arn
}

output "realtime_authorizer_lambda_function_name" {
  description = "The realtime channel's $connect authorizer Lambda"
  value       = module.realtime.authorizer_lambda_function_name
}

output "realtime_connections_lambda_function_name" {
  description = "The realtime channel's route handler Lambda"
  value       = module.realtime.connections_lambda_function_name
}

output "webhook_endpoint_url" {
  description = "The public URL Stripe's webhook endpoint must point at — the relay's gateway, not the API's route."
  value       = module.webhook_relay.endpoint_url
}

output "identity_providers" {
  description = "Social providers enabled on the pool, in button order"
  value       = module.auth.identity_providers
}

output "cognito_mcp_client_ids" {
  description = "MCP host => its Cognito app client id"
  value       = module.auth.mcp_client_ids
}

output "mcp_ecr_repository_url" {
  description = "MCP server ECR repository URL"
  value       = module.mcp.ecr_repository_url
}

output "mcp_lambda_function_name" {
  description = "MCP server Lambda function name"
  value       = module.mcp.lambda_function_name
}
