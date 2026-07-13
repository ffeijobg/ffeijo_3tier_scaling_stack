#!/usr/bin/env bash
# tests/chaos/kill-backend-pods.sh
# Scenario: Crash all backend pods while frontend sends traffic.
# Expected: nginx returns 502 briefly, retries hit new pods once ready.
# Probe design is critical here: readiness probe prevents unready pods from receiving traffic.
 
KUBECONFIG="${HOME}/.kube/three-tier-config"
 
echo "=== Backend Crash Test ==="
echo ""
echo "Starting continuous traffic in background (10 RPS)..."
# Run a low-rate k6 test to observe 502 window
k6 run \
  --vus 5 \
  --duration 120s \
  --env BASE_URL=http://localhost:8080 \
  tests/load/backend-load.js &
K6_PID=$!
 
sleep 10  # Let traffic establish
 
echo ""
echo "Killing backend pods (OOMKill simulation)..."
kubectl delete pods -n apps -l app=backend --grace-period=0 --force \
  --kubeconfig "${KUBECONFIG}"
 
echo ""
echo "Watching recovery..."
kubectl get pods -n apps -l app=backend -w --kubeconfig "${KUBECONFIG}" &
WATCH_PID=$!
 
kubectl wait --for=condition=ready pod \
  -l app=backend -n apps --timeout=90s \
  --kubeconfig "${KUBECONFIG}"
 
kill $WATCH_PID 2>/dev/null
wait $K6_PID 2>/dev/null || true
 
echo ""
echo "=== Check k6 output above for 502 error window ==="
