variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "dynamodb_table_arns" {
  description = "Map of DynamoDB table ARNs the Lambda needs access to"
  type        = map(string)
  default     = {}
}

variable "cognito_user_pool_arn" {
  description = "Cognito User Pool ARN the API may read verified email addresses from"
  type        = string
}

variable "cognito_user_pool_id" {
  description = "Cognito user pool used to authorize API requests"
  type        = string
}

variable "cognito_client_id" {
  description = "Cognito web client accepted by the API authorizer"
  type        = string
}

variable "cognito_additional_client_ids" {
  description = "Further Cognito clients the API authorizer accepts beside the app client — one per MCP host"
  type        = list(string)
  default     = []
}

variable "mailer_status_queue_arn" {
  description = "Mailer status queue consumed by the Humbugg status Lambda"
  type        = string
}

variable "email_messages_table_arn" {
  description = "DynamoDB delivery-ledger table ARN"
  type        = string
}

variable "avatars_bucket_arn" {
  description = "S3 bucket ARN for user profile photos the backend Lambda writes to"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "api_throttling_rate_limit" {
  description = "Steady-state requests/second for the backend API stage (API Gateway default route throttling, applied to every route)."
  type        = number
  default     = 500
}

variable "api_throttling_burst_limit" {
  description = "Token-bucket burst capacity for the backend API stage default throttling."
  type        = number
  default     = 1000
}
