variable "aws_region" {
  description = "AWS region for the shared development resources"
  type        = string
  default     = "us-east-1"
}

variable "aws_principal_arn" {
  description = "Caller ARN of whoever last applied, recorded as a tag"
  type        = string
}

# Social sign-in for the shared dev pool. `dev-aws-setup.sh` passes whichever
# of these the applying machine's `dev.env` holds; an empty id leaves that
# provider off. The guard in that script is what makes "empty" safe — see
# main.tf.

variable "google_client_id" {
  type    = string
  default = ""
}

variable "google_client_secret" {
  type      = string
  default   = ""
  sensitive = true
}

variable "facebook_app_id" {
  type    = string
  default = ""
}

variable "facebook_app_secret" {
  type      = string
  default   = ""
  sensitive = true
}

variable "apple_services_id" {
  type    = string
  default = ""
}

variable "apple_team_id" {
  type    = string
  default = ""
}

variable "apple_key_id" {
  type    = string
  default = ""
}

variable "apple_private_key" {
  type      = string
  default   = ""
  sensitive = true
}

variable "linkedin_client_id" {
  type    = string
  default = ""
}

variable "linkedin_client_secret" {
  type      = string
  default   = ""
  sensitive = true
}

# Where the dev Claude client may return a code. Claude's hosted surfaces
# (claude.ai, claude.com) and Claude Code's local OAuth listener, which
# Cognito matches exactly — so Claude Code's OAuth callback must be pinned to
# this port when the connector is added.
variable "mcp_claude_callback_urls" {
  description = "Exact OAuth callback URLs for the dev pool's Claude MCP client"
  type        = list(string)
  default = [
    "https://claude.ai/api/mcp/auth_callback",
    "https://claude.com/api/mcp/auth_callback",
    "http://localhost:33418/callback",
  ]
}
