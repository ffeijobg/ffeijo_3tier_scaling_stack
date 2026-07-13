# terraform/main.tf
#
# DESIGN RATIONALE:
# - One control-plane node with ingress-ready labels so nginx-ingress deploys to it.
#   In production you'd have 3+ control-plane nodes; KinD supports this but it's
#   resource-heavy locally, so we simulate via single CP + 3 workers.
# - Worker nodes have NO labels — we rely on pod anti-affinity to spread tiers
#   across them, not node selectors. This is more flexible and closer to real
#   managed cluster behavior (EKS, GKE don't pre-label nodes for you).
# - extra_mounts: we mount /var/lib/kubelet from the host into each node container.
#   This is what makes PVCs survive KIND container restarts during upgrade testing.
 
provider "kind" {}
 
resource "kind_cluster" "main" {
  name           = var.cluster_name
  wait_for_ready = true
 
  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"
 
    # Networking: use calico-compatible CIDR ranges
    networking {
      pod_subnet     = "10.244.0.0/16"
      service_subnet = "10.96.0.0/12"
      # Disable default CNI so we can install Calico for NetworkPolicy support
      disable_default_cni = true
    }
 
    # Control plane
    node {
      role  = "control-plane"
      image = "kindest/node:${var.kubernetes_version}"
 
      # Ingress controller will land here based on the ingress-ready label.
      kubeadm_config_patches = [
        <<-EOT
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
            system-reserved: "cpu=100m,memory=256Mi"
            kube-reserved: "cpu=100m,memory=256Mi"
        EOT
      ]
 
      # Port mappings let us hit ingress from the host without kubectl port-forward
      extra_port_mappings {
        container_port = 80
        host_port      = var.control_plane_host_port_http
        protocol       = "TCP"
      }
      extra_port_mappings {
        container_port = 443
        host_port      = var.control_plane_host_port_https
        protocol       = "TCP"
      }
 
      # Persistent storage backing for PVCs (survives KIND node container restarts)
      extra_mounts {
        host_path      = "/tmp/three-tier-kind/control-plane"
        container_path = "/var/local-path-provisioner"
      }
    }
 
    # Workers — generated dynamically based on worker_count variable
    dynamic "node" {
      for_each = range(var.worker_count)
 
      content {
        role  = "worker"
        image = "kindest/node:${var.kubernetes_version}"
 
        kubeadm_config_patches = [
          <<-EOT
          kind: JoinConfiguration
          nodeRegistration:
            kubeletExtraArgs:
              system-reserved: "cpu=100m,memory=256Mi"
              kube-reserved: "cpu=100m,memory=256Mi"
          EOT
        ]
 
        extra_mounts {
          host_path      = "/tmp/three-tier-kind/worker-${node.value}"
          container_path = "/var/local-path-provisioner"
        }
      }
    }
  }
}
 
# ─── Post-cluster bootstrapping ───────────────────────────────────────────────
# These null_resources fire after the cluster is up. Order is enforced via
# explicit depends_on chains.
 
# 1. Install Calico CNI (required for NetworkPolicy enforcement)
resource "null_resource" "install_calico" {
  depends_on = [kind_cluster.main]
 
  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml \
        --kubeconfig ${kind_cluster.main.kubeconfig_path}
      kubectl wait --for=condition=ready pod -l k8s-app=calico-node \
        -n kube-system --timeout=120s \
        --kubeconfig ${kind_cluster.main.kubeconfig_path}
    EOT
  }
}
 
# 2. Install metrics-server (required for HPA)
# KinD nodes use self-signed certs, hence the --kubelet-insecure-tls flag.
# In production you'd use cert-manager + proper CA.
resource "null_resource" "install_metrics_server" {
  depends_on = [null_resource.install_calico]
 
  provisioner "local-exec" {
    command = <<-EOT
      helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
      helm repo update
      helm upgrade --install metrics-server metrics-server/metrics-server \
        --namespace kube-system \
        --set args[0]="--kubelet-insecure-tls" \
        --set args[1]="--kubelet-preferred-address-types=InternalIP" \
        --kubeconfig ${kind_cluster.main.kubeconfig_path} \
        --wait
    EOT
  }
}
 
# 3. Install nginx ingress controller (tolerates the control-plane taint)
resource "null_resource" "install_ingress" {
  depends_on = [null_resource.install_calico]
 
  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.0/deploy/static/provider/kind/deploy.yaml \
        --kubeconfig ${kind_cluster.main.kubeconfig_path}
      kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=controller \
        -n ingress-nginx --timeout=120s \
        --kubeconfig ${kind_cluster.main.kubeconfig_path}
    EOT
  }
}
 
# Write kubeconfig to a dedicated file so it doesn't pollute ~/.kube/config
resource "local_file" "kubeconfig" {
  content  = kind_cluster.main.kubeconfig
  filename = pathexpand(var.kubeconfig_path)
  file_permission = "0600"
}
