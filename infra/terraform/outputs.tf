output "control_plane_id" {
  description = "Konnect control plane UUID."
  value       = konnect_gateway_control_plane.demo.id
}

output "control_plane_name" {
  description = "Konnect control plane name (matches manifests/platform/konnect-extension.yaml)."
  value       = konnect_gateway_control_plane.demo.name
}

output "control_plane_endpoint" {
  description = "Konnect telemetry endpoint for this CP, used by DataPlane pods via the operator."
  value       = konnect_gateway_control_plane.demo.config[0].telemetry_endpoint
}
