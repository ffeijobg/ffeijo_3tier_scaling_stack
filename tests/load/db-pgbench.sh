#!/usr/bin/env bash
# tests/load/db-pgbench.sh
# pgbench tests run INSIDE a job pod that has network access to postgres-service.
# This avoids needing external DB access and is more realistic.
 
set -euo pipefail
 
KUBECONFIG="${HOME}/.kube/three-tier-config"
DB_HOST="postgres-service"
DB_USER="appuser"
DB_NAME="appdb"
PGPASSWORD="apppassword"
 
# ─── Phase 1: Initialize pgbench schema (scale factor 50 ≈ 500k rows) ─────────
echo "=== Phase 1: Initializing pgbench tables (scale=50) ==="
kubectl run pgbench-init \
  --image=postgres:16-alpine \
  --restart=Never \
  --env="PGPASSWORD=${PGPASSWORD}" \
  --namespace=apps \
  --kubeconfig "${KUBECONFIG}" \
  -- pgbench \
    -i \
    -s 50 \
    -h "${DB_HOST}" \
    -U "${DB_USER}" \
    "${DB_NAME}"
 
kubectl wait --for=condition=complete pod/pgbench-init \
  -n apps --timeout=120s --kubeconfig "${KUBECONFIG}"
kubectl logs pgbench-init -n apps --kubeconfig "${KUBECONFIG}"
kubectl delete pod pgbench-init -n apps --kubeconfig "${KUBECONFIG}"
 
# ─── Phase 2: Read-heavy benchmark (typical OLTP read pattern) ─────────────────
echo ""
echo "=== Phase 2: Read-heavy load (SELECT only, 10 clients, 30s) ==="
kubectl run pgbench-read \
  --image=postgres:16-alpine \
  --restart=Never \
  --env="PGPASSWORD=${PGPASSWORD}" \
  --namespace=apps \
  --kubeconfig "${KUBECONFIG}" \
  -- pgbench \
    -S \
    -c 10 \
    -j 4 \
    -T 30 \
    -h "${DB_HOST}" \
    -U "${DB_USER}" \
    "${DB_NAME}"
 
kubectl wait --for=condition=complete pod/pgbench-read \
  -n apps --timeout=90s --kubeconfig "${KUBECONFIG}"
kubectl logs pgbench-read -n apps --kubeconfig "${KUBECONFIG}"
kubectl delete pod pgbench-read -n apps --kubeconfig "${KUBECONFIG}"
 
# ─── Phase 3: Write-heavy benchmark (mixed TPC-B pattern) ──────────────────────
echo ""
echo "=== Phase 3: Write-heavy load (TPC-B, 20 clients, 60s) ==="
kubectl run pgbench-write \
  --image=postgres:16-alpine \
  --restart=Never \
  --env="PGPASSWORD=${PGPASSWORD}" \
  --namespace=apps \
  --kubeconfig "${KUBECONFIG}" \
  -- pgbench \
    -c 20 \
    -j 4 \
    -T 60 \
    -h "${DB_HOST}" \
    -U "${DB_USER}" \
    "${DB_NAME}"
 
kubectl wait --for=condition=complete pod/pgbench-write \
  -n apps --timeout=120s --kubeconfig "${KUBECONFIG}"
kubectl logs pgbench-write -n apps --kubeconfig "${KUBECONFIG}"
kubectl delete pod pgbench-write -n apps --kubeconfig "${KUBECONFIG}"
 
# ─── Phase 4: Data persistence validation ─────────────────────────────────────
echo ""
echo "=== Phase 4: Data Persistence Validation ==="
 
# Record row count before restart
echo "Row count BEFORE restart:"
kubectl exec -n apps postgres-0 \
  --kubeconfig "${KUBECONFIG}" \
  -- psql -U "${DB_USER}" -d "${DB_NAME}" -t -c "SELECT count(*) FROM pgbench_accounts;"
 
# Force-delete the pod (simulate crash — StatefulSet will recreate it)
echo ""
echo "Force-deleting postgres-0 (simulating crash)..."
kubectl delete pod postgres-0 -n apps --grace-period=0 --force \
  --kubeconfig "${KUBECONFIG}"
 
# Wait for StatefulSet to bring it back
echo "Waiting for postgres-0 to restart..."
kubectl wait --for=condition=ready pod/postgres-0 \
  -n apps --timeout=120s --kubeconfig "${KUBECONFIG}"
 
# Verify data survived
echo "Row count AFTER restart (should match):"
kubectl exec -n apps postgres-0 \
  --kubeconfig "${KUBECONFIG}" \
  -- psql -U "${DB_USER}" -d "${DB_NAME}" -t -c "SELECT count(*) FROM pgbench_accounts;"
 
echo ""
echo "=== Persistence test complete. Counts must match. ==="
