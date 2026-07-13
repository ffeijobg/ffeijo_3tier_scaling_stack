# terraform/outputs.tf
 
output "cluster_name" {
  value = kind_cluster.main.name
}
 
output "kubeconfig_path" {
  value = pathexpand(var.kubeconfig_path)
}
 
output "cluster_endpoint" {
  value = kind_cluster.main.endpoint
}
 
output "http_port" {
  value = var.control_plane_host_port_http
  description = "Host port for HTTP ingress access"
}
 
output "https_port" {
  value = var.control_plane_host_port_https
  description = "Host port for HTTPS ingress access"
}
