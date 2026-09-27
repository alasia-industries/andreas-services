variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "api_id" {
  description = "The backend HTTP API the MCP routes are added to"
  type        = string
}

variable "api_execution_arn" {
  description = "That API's execution ARN, for the invoke permission"
  type        = string
}

variable "public_url" {
  description = "Origin the MCP server is reached at (the resource is <origin>/mcp), no trailing slash"
  type        = string
}

variable "api_url" {
  description = "Base URL the server calls the Humbugg API at; tools call <base>/api/..."
  type        = string
}

variable "cognito_domain" {
  description = "Managed Login host, without a scheme"
  type        = string
}

variable "cognito_user_pool_id" {
  description = "Cognito user pool whose access tokens the server verifies"
  type        = string
}

variable "mcp_clients_json" {
  description = "JSON object: MCP host => {client_id, redirect_uris}. The server's HUMBUGG_MCP_CLIENTS."
  type        = string
}

variable "rate_limit_per_minute" {
  description = "Calls one person may make to the MCP server per minute"
  type        = number
  default     = 60
}

variable "reserved_concurrency" {
  description = "Reserved (and maximum) concurrent executions of the MCP Lambda"
  type        = number
  default     = 20
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
