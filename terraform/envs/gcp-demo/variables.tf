variable "project_id" {
  description = "GCP project to deploy the demo into."
  type        = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "billing_account_id" {
  description = "Billing account for the budget alert. Empty skips the budget."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  type    = number
  default = 5
}
