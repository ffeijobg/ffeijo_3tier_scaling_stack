#!/usr/bin/env bash
# scripts/teardown.sh
# DESTRUCTIVE: removes cluster and all PVCs.
# PVC data in /tmp/three-tier-kind is also removed.
 
set -euo pipefail
 
read -rp "This will DESTROY the cluster and all data. Type 'yes' to confirm: " CONFIRM
[[ "$CONFIRM" != "yes" ]] && echo "Aborted." && exit 0
 
echo "Deleting all namespace resources first (clean StatefulSet finalizers)..."
kubectl delete ns apps --grace-period=30 \
  --kubeconfig "${HOME}/.kube/three-tier-config" 2>/dev/null || true
 
echo "Destroying Terraform-managed cluster..."
cd terraform && terraform destroy -auto-approve
 
echo "Cleaning PVC backing storage..."
rm -rf /tmp/three-tier-kind
 
echo "Done."
