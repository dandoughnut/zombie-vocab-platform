# Ephemeral demo environment. Lifecycle:
#   terraform apply   → cluster up (~10 min)
#   demo / record     → see README "Cloud demo"
#   terraform destroy → back to $0
# The budget alert is the safety net for forgetting the last step.

terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
  }
  # Local state by default (one person, one throwaway env). For a shared env,
  # copy backend.hcl.example and run `terraform init -backend-config=backend.hcl`.
  backend "local" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

module "gke" {
  source = "../../modules/gke_autopilot"
  name   = "zombie-vocab"
  region = var.region
}

resource "google_billing_budget" "guardrail" {
  count           = var.billing_account_id == "" ? 0 : 1
  billing_account = var.billing_account_id
  display_name    = "zombie-vocab demo guardrail"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.monthly_budget_usd)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 1.0
  }
}

data "google_project" "this" {
  project_id = var.project_id
}
