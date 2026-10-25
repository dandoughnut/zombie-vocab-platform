variable "name" {
  description = "Cluster, VPC, and registry name prefix."
  type        = string
}

variable "region" {
  description = "GCP region for the cluster and registry."
  type        = string
}
