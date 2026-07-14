# terraform/variables.tf

variable "cluster_name" {
  description = "KinD cluster name. Maps to the Docker network name, so keep it lowercase."
  type        = string
  default     = "three-tier"
}

variable "kubernetes_version" {
  description = "Kubernetes version for all nodes. Change this and re-apply for upgrades."
  type        = string
  default     = "v1.34.0"
}

variable "worker_count" {
  description = "Number of worker nodes. Minimum 3 to allow meaningful anti-affinity and PDB enforcement."
  type        = number
  default     = 3

  validation {
    condition     = var.worker_count >= 2
    error_message = "Need at least 2 workers for PDB minAvailable:1 to have any effect."
  }
}

variable "control_plane_host_port_http" {
  description = "Host port mapped to ingress HTTP. Must be free on your machine."
  type        = number
  default     = 8080
}

variable "control_plane_host_port_https" {
  description = "Host port mapped to ingress HTTPS. Must be free on your machine."
  type        = number
  default     = 8443
}

variable "kubeconfig_path" {
  description = "Where to write the kubeconfig after cluster creation."
  type        = string
  default     = "~/.kube/three-tier-config"
}
