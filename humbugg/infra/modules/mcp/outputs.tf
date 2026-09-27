output "ecr_repository_url" {
  description = "MCP server ECR repository URL"
  value       = aws_ecr_repository.mcp.repository_url
}

output "lambda_function_name" {
  description = "MCP server Lambda function name"
  value       = aws_lambda_function.mcp.function_name
}

output "ratelimit_table_name" {
  description = "Per-person rate-limit counter table"
  value       = aws_dynamodb_table.ratelimit.name
}
