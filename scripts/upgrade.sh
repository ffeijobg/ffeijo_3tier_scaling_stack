#!/usr/bin/env bash
# scripts/upgrade.sh
# End-to-end cluster upgrade: Terraform variable update → Ansible orchestration
 
set -euo pipefail
 
TARGET_VERSION="${1:-v1.35.0}"
CLUSTER_NAME="three-tier"
KUBECONFIG="${HOME}/.kube/three-tier-config"
 
echo "=== Pre-upgrade health check ==="
kubectl get nodes --kubeconfig "$KUBECONFIG"
kubectl get pods -n apps --kubeconfig "$KUBECONFIG"
 
echo ""
echo "=== Checking PDB status ==="
kubectl get pdb -n apps --kubeconfig "$KUBECONFIG"
 
echo ""
echo "=== STEP 1: Update Terraform variable ==="
# Update the kubernetes_version variable in terraform.tfvars
sed -i "s/kubernetes_version = .*/kubernetes_version = \"${TARGET_VERSION}\"/" \
  terraform/terraform.tfvars 2>/dev/null || \
  echo "kubernetes_version = \"${TARGET_VERSION}\"" > terraform/terraform.tfvars
 
echo ""
echo "=== STEP 2: Run Ansible upgrade playbook ==="
ansible-playbook \
  -i ansible/inventory/hosts.yml \
  ansible/playbooks/upgrade.yml \
  -e "target_version=${TARGET_VERSION}" \
  -v
 
echo ""
echo "=== STEP 3: Update Terraform state (plan only — review before applying) ==="
cd terraform
terraform plan -var="kubernetes_version=${TARGET_VERSION}" -out=upgrade.tfplan
echo ""
echo "Review upgrade.tfplan, then run: terraform apply upgrade.tfplan"
 
echo ""
echo "=== Upgrade complete. Final cluster state: ==="
kubectl get nodes --kubeconfig "$KUBECONFIG"
