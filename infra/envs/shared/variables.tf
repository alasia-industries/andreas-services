# envs/shared/variables.tf

variable "aws_region" {
  description = "AWS region for shared infrastructure"
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Root domain name"
  type        = string
  default     = "andreas.services"
}

variable "github_repo" {
  description = "GitHub repo allowed to assume the Actions role (owner/repo)"
  type        = string
  default     = "ansavva/andreas-services"
}

# Services split out of this monorepo deploy with the same role. Humbugg moved
# to its own repo on 2026-09-30.
variable "extra_github_repos" {
  description = "Further GitHub repos allowed to assume the Actions role (owner/repo)"
  type        = list(string)
  default     = ["ansavva/humbugg"]
}

# Cost guardrails (cost_guardrails.tf).

variable "alert_email" {
  description = "Address subscribed to the cost-alerts SNS topic. Empty = no subscription (TF_VAR_alert_email from the ALERT_EMAIL secret)."
  type        = string
  default     = ""
  sensitive   = true
}

# Usage ran ~$30/month Aug–Sep 2026; Route 53 Registrar renewals add $40–70
# in the months they fall (Aug, Oct). 100 sits above a renewal month and well
# below anything that would hurt.
variable "monthly_budget_usd" {
  description = "Monthly account cost budget in USD"
  type        = number
  default     = 100
}

variable "anomaly_threshold_usd" {
  description = "Minimum absolute impact (USD) for an immediate cost-anomaly alert"
  type        = number
  default     = 20
}
