# Always-on but $0: an OIDC trust, one IAM role, one ECR repository. Lets the
# backend's GitHub Actions push images to AWS with no stored credentials.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # For shared state: switch to backend "s3" with `use_lockfile = true`
  # (native S3 locking, no DynamoDB table needed since Terraform 1.10).
  backend "local" {}
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project    = "zombie-vocab"
      managed_by = "terraform"
    }
  }
}

module "github_oidc" {
  source            = "../../modules/github_oidc_aws"
  name              = "zombie-vocab-api"
  github_repository = var.github_repository
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "github_repository" {
  type    = string
  default = "dandoughnut/zombie_vocab_backend"
}

output "ci_role_arn" {
  value = module.github_oidc.role_arn
}

output "ecr_repository_url" {
  value = module.github_oidc.repository_url
}
