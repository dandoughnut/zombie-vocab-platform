output "role_arn" {
  description = "Set as `role-to-assume` in aws-actions/configure-aws-credentials."
  value       = aws_iam_role.ci.arn
}

output "repository_url" {
  value = aws_ecr_repository.api.repository_url
}
