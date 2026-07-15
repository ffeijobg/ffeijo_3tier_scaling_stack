#!/usr/bin/env bash
# scripts/bootstrap.sh
# Complete environment setup from zero to running 3-tier cluster.
 
set -euo pipefail
 
CLUSTER_NAME="three-tier"
KUBECONFIG="${HOME}/.kube/three-tier-config"
MANIFESTS_DIR="./manifests"
 
echo "═══════════════════════════════════════════════"
echo " 3-Tier Kubernetes Cluster Bootstrap"
echo "═══════════════════════════════════════════════"
 
# Step 0: Preflight
echo ""
echo "=== [0/7] Preflight checks ==="
bash scripts/preflight-check.sh
 
# Step 1: Ansible host setup
echo ""
echo "=== [1/7] Ansible: configure host ==="
ansible-playbook \
  -i ansible/inventory/hosts.yml \
  ansible/playbooks/site.yml \
  --diff
 
# Step 2: Terraform cluster provisioning
echo ""
echo "=== [2/7] Terraform: provision KinD cluster ==="
cd terraform
terraform init -upgrade
terraform plan -out=cluster.tfplan
terraform apply -auto-approve cluster.tfplan
cd ..
 
export KUBECONFIG="${KUBECONFIG}"
 
# Step 3: Verify cluster
echo ""
echo "=== [3/7] Verify cluster health ==="
kubectl wait --for=condition=ready node \
  --all --timeout=120s
kubectl get nodes -o wide
 
# Step 4: Build and load application images
echo ""
echo "=== [4/7] Build and load application images ==="
docker build -t backend:local manifests/backend/app/
kind load docker-image backend:local --name "${CLUSTER_NAME}"
 
# Step 5: Apply manifests in order
echo ""
echo "=== [5/7] Apply Kubernetes manifests ==="
kubectl apply -f "${MANIFESTS_DIR}/00-namespace.yaml"

echo "  → Networking..."
kubectl apply -f "${MANIFESTS_DIR}/networking/"

echo "  → Database tier..."
kubectl apply -f "${MANIFESTS_DIR}/database/"
 
echo "  → Backend tier..."
kubectl apply -f "${MANIFESTS_DIR}/backend/"
 
echo "  → Frontend tier..."
kubectl apply -f "${MANIFESTS_DIR}/frontend/"
 
# Step 6: Wait for all pods
echo ""
echo "=== [6/7] Waiting for all pods to be ready ==="
kubectl rollout status statefulset/postgres -n apps --timeout=120s
kubectl rollout status deploy/backend -n apps --timeout=120s
kubectl rollout status deploy/frontend -n apps --timeout=120s
 
# Step 7: Smoke test
echo ""
echo "=== [7/7] Smoke tests ==="
sleep 5  # Brief settle time
 
# The Ingress rule (manifests/networking/02-ingress.yaml) matches on
# Host: three-tier.local, not "localhost" — --resolve pins that hostname to
# 127.0.0.1 for this request only, so nginx routes to frontend-service
# instead of falling through to its default 404 backend. No /etc/hosts
# edit needed, so this stays portable across machines/CI.
CURL_OPTS=(-sf --resolve "three-tier.local:8080:127.0.0.1")
FRONTEND_RESPONSE=$(curl "${CURL_OPTS[@]}" "http://three-tier.local:8080/health" | jq -r '.status' 2>/dev/null || echo "FAIL")
BACKEND_RESPONSE=$(curl "${CURL_OPTS[@]}" "http://three-tier.local:8080/api/items" | jq -r '.count' 2>/dev/null || echo "FAIL")
 
echo "  Frontend health: ${FRONTEND_RESPONSE}"
echo "  Backend items:   ${BACKEND_RESPONSE}"
 
if [[ "${FRONTEND_RESPONSE}" == "ok" ]]; then
  echo ""
  echo "✓ Bootstrap complete! Cluster is running."
  echo ""
  echo "  Frontend:  http://localhost:8080"
  echo "  API:       http://localhost:8080/api/items"
  echo "  Kubeconfig: ${KUBECONFIG}"
else
  echo ""
  echo "✗ Smoke test failed. Check pod logs:"
  echo "  kubectl logs -n apps -l app=frontend --kubeconfig ${KUBECONFIG}"
  exit 1
fi
