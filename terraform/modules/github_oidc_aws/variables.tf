variable "name" {
  description = "Prefix for the IAM role and ECR repository."
  type        = string
}

variable "github_repository" {
  description = "owner/repo allowed to assume the CI role."
  type        = string
}

variable "allowed_refs" {
  description = "OIDC subject suffixes allowed to assume the role, e.g. ref:refs/heads/main or environment:prod."
  type        = list(string)
  default     = ["ref:refs/heads/main"]
}
