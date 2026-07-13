#!/usr/bin/env bash
# tests/chaos/kill-db-pod.sh
# Scenario: Force-kill Postgres pod (simulates node failure, OOM, or process crash).
# Expected:
#   1. Backend pods become unready (readiness probe to DB fails)
#   2. Traffic stops at frontend (502) while backends are unready
#   3. StatefulSet brings postgres-0 back up
#   4. PVC is reattached automatically (data intact)
#   5. Backend pods become ready again
#   6. Traffic resumes
 
KUBECONFIG="${HOME}/.kube/three-tier-config"
 
echo "=== Database Crash Test ==="
echo ""
 
# Record baseline
BEFORE=$(kubectl exec -n apps postgres-0 \
  --kubeconfig "${KUBECONFIG}" \
  -- psql -U appuser -d appdb -t -c "SELECT count(*) FROM items;" 2>/dev/null | tr -d '[:space:]')
echo "Items in DB BEFORE crash: ${BEFORE}"
 
echo ""
echo "Starting write traffic (to test mid-write crash behavior)..."
kubectl run write-load \
  --image=curlimages/curl:8.0.1 \
  --restart=Never \
  --namespace=apps \
  --kubeconfig "${KUBECONFIG}" \
  -- sh -c "for i in \$(seq 1 100); do curl -sf http://backend-service:8000/api/items -X POST -d 'name=crash-test-'$i; sleep 0.5; done" &
 
sleep 5  # Let some writes land
 
echo ""
echo "Force-crashing Postgres pod..."
kubectl delete pod postgres-0 -n apps --grace-period=0 --force \
  --kubeconfig "${KUBECONFIG}"
 
echo "Waiting for StatefulSet to recreate postgres-0..."
kubectl wait --for=condition=ready pod/postgres-0 \
  -n apps --timeout=120s --kubeconfig "${KUBECONFIG}"
 
echo ""
echo "Waiting for backends to become ready (readiness probe to DB)..."
kubectl wait --for=condition=ready pod \
  -l app=backend -n apps --timeout=60s --kubeconfig "${KUBECONFIG}"
 
# Give write-load pod time to finish
sleep 10
 
# Verify data integrity
AFTER=$(kubectl exec -n apps postgres-0 \
  --kubeconfig "${KUBECONFIG}" \
  -- psql -U appuser -d appdb -t -c "SELECT count(*) FROM items;" 2>/dev/null | tr -d '[:space:]')
echo ""
echo "Items in DB AFTER crash recovery: ${AFTER}"
echo "Items BEFORE: ${BEFORE}"
 
if [[ "${AFTER}" -ge "${BEFORE}" ]]; then
  echo "✓ PASS: Data persisted across crash (PVC survived pod deletion)"
else
  echo "✗ FAIL: Item count decreased — potential data loss"
fi
 
# Check WAL integrity
echo ""
echo "Checking PostgreSQL WAL integrity post-recovery..."
kubectl exec -n apps postgres-0 --kubeconfig "${KUBECONFIG}" \
  -- psql -U appuser -d appdb -c \
  "SELECT pg_is_in_recovery(), pg_current_wal_lsn();"
 
kubectl delete pod write-load -n apps --kubeconfig "${KUBECONFIG}" 2>/dev/null || true
