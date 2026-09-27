output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.api.function_name
}

output "email_status_lambda_function_name" {
  description = "Mailer status consumer Lambda function name"
  value       = aws_lambda_function.email_status.function_name
}

output "reminders_lambda_function_name" {
  description = "Automatic reminder consumer Lambda function name"
  value       = aws_lambda_function.reminders.function_name
}

output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.api.repository_url
}

output "marketing_ecr_repository_url" {
  description = "Marketing SSR ECR repository URL"
  value       = aws_ecr_repository.marketing.repository_url
}

output "marketing_lambda_function_name" {
  description = "Marketing SSR Lambda function name"
  value       = aws_lambda_function.marketing.function_name
}

output "marketing_api_domain" {
  description = "Marketing SSR HTTP API host without a scheme"
  value       = replace(aws_apigatewayv2_api.marketing.api_endpoint, "https://", "")
}

output "api_endpoint" {
  description = "API Gateway invoke URL"
  value       = aws_apigatewayv2_stage.api.invoke_url
}

output "api_id" {
  description = "Backend HTTP API ID, for mapping a custom domain onto it"
  value       = aws_apigatewayv2_api.api.id
}

output "api_stage_name" {
  description = "Backend HTTP API stage name, for the custom-domain API mapping"
  value       = aws_apigatewayv2_stage.api.name
}

output "marketing_api_id" {
  description = "Marketing SSR HTTP API ID, for the 5xx alarm"
  value       = aws_apigatewayv2_api.marketing.id
}

output "api_role_arn" {
  description = "The API Lambda's execution role, which the Stripe webhook consumer runs under as well."
  value       = aws_iam_role.api.arn
}

output "api_role_name" {
  description = "Name of the same role, for an inline grant declared outside this module."
  value       = aws_iam_role.api.name
}

output "api_execution_arn" {
  description = "Backend HTTP API execution ARN, for another Lambda's invoke permission on it"
  value       = aws_apigatewayv2_api.api.execution_arn
}
