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
