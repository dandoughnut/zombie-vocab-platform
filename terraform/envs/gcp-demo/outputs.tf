output "get_credentials" {
  description = "Point kubectl at the new cluster."
  value       = "gcloud container clusters get-credentials ${module.gke.cluster_name} --region ${module.gke.cluster_location} --project ${var.project_id}"
}

output "image_repository" {
  value = module.gke.image_repository
}
