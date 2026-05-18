variable "konnect_token" {
  description = "Konnect Personal Access Token or Service Account token. Provided via TF_VAR_konnect_token from the GitHub Actions secret KONNECT_TOKEN."
  type        = string
  sensitive   = true
}

variable "konnect_server_url" {
  description = "Konnect API endpoint. AU region by default."
  type        = string
  default     = "https://au.api.konghq.com"
}

variable "control_plane_name" {
  description = "Fixed Konnect control plane name. Workflow concurrency keeps this safe."
  type        = string
  default     = "kong-cicd-demo"
}
