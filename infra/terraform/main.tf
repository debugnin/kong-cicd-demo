provider "konnect" {
  personal_access_token = var.konnect_token
  server_url            = var.konnect_server_url
}

resource "konnect_gateway_control_plane" "demo" {
  name         = var.control_plane_name
  description  = "Ephemeral CP for kong-cicd-demo end-to-end pipeline. Recreated per run."
  cluster_type = "CLUSTER_TYPE_CONTROL_PLANE"
  auth_type    = "pinned_client_certs"

  labels = {
    managed_by = "kong-cicd-demo"
    env        = "demo"
  }
}
