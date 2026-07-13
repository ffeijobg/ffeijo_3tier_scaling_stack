#!/usr/bin/env bash
# tests/chaos/kill-frontend-pods.sh
# Scenario: Kill all frontend pods simultaneously.
# Expected: PDB prevents complete outage; at least 1 pod survives (or new pod starts < 5s).
# HPA + Deployment controller should restore full replica count within 30s.
 
KUBECONFIG="${HOME}/.kube/three-tier-config"
 
echo "=== Frontend Crash Test ==="
echo "Current pods:"
kubectl get pods -n apps -l app=frontend --kubeconfig "${KUBECONFIG}"
 
echo ""
echo "Scaling frontend to 4 pods first (to make crash scenario more visible)..."
kubectl scale deploy/frontend -n apps --replicas=4 --kubeconfig "${KUBECONFIG}"
kubectl rollout status deploy/frontend -n apps --kubeconfig "${KUBECONFIG}"
 
echo ""
echo "Killing ALL frontend pods simultaneously..."
START=$(date +%s%N)
kubectl delete pods -n apps -l app=frontend --grace-period=0 --force \
  --kubeconfig "${KUBECONFIG}"
 
echo ""
echo "Watching recovery (Ctrl+C to stop)..."
kubectl get pods -n apps -l app=frontend -w --kubeconfig "${KUBECONFIG}" &
WATCH_PID=$!
 
# Wait for all pods to be running
kubectl wait --for=condition=ready pod \
  -l app=frontend -n apps --timeout=60s \
  --kubeconfig "${KUBECONFIG}"
 
END=$(date +%s%N)
ELAPSED=$(( (END - START) / 1000000 ))
 
kill $WATCH_PID 2>/dev/null
 
echo ""
echo "Recovery time: ${ELAPSED}ms"
echo ""
echo "Final state:"
kubectl get pods -n apps -l app=frontend --kubeconfig "${KUBECONFIG}"
