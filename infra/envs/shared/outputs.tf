# envs/shared/outputs.tf
#
# VPC, subnet, and DocumentDB outputs have been removed.
# All services now use DynamoDB — no shared networking required.

output "route53_zone_id" {
  description = "Route53 hosted zone ID for andreas.services"
  value       = data.aws_route53_zone.main.zone_id
}

output "route53_name_servers" {
  description = "Name servers for the root domain (configure at your registrar)"
  value       = data.aws_route53_zone.main.name_servers
}

output "acm_certificate_arn" {
  description = "ARN of the *.andreas.services wildcard ACM certificate (us-east-1)"
  value       = aws_acm_certificate.wildcard.arn
}

output "github_actions_role_arn" {
  description = "IAM role ARN to use as AWS_ROLE_ARN in GitHub Actions environments"
  value       = aws_iam_role.github_actions.arn
}

output "humbugg_ci_role_arn" {
  description = "Humbugg's own GitHub Actions role (AWS_ROLE_ARN in ansavva/humbugg humbugg-prod.yaml)"
  value       = aws_iam_role.humbugg_ci.arn
}

output "humbugg_workload_boundary_arn" {
  description = "Permissions boundary every Humbugg-created IAM role must carry"
  value       = aws_iam_policy.humbugg_workload_boundary.arn
}
