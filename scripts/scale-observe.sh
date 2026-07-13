#!/usr/bin/env bash
# scripts/scale-observe.sh
# Run in a separate terminal during load tests to watch HPA reactions in real-time
 
KUBECONFIG="${HOME}/.kube/three-tier-config"
INTERVAL=5
 
while true; do
  clear
  echo "=== $(date) ==="
  echo ""
  echo "--- HPA Status ---"
  kubectl get hpa -n apps --kubeconfig "$KUBECONFIG" 2>/dev/null
  echo ""
  echo "--- Pod Status ---"
  kubectl get pods -n apps --kubeconfig "$KUBECONFIG" 2>/dev/null
  echo ""
  echo "--- Resource Usage ---"
  kubectl top pods -n apps --kubeconfig "$KUBECONFIG" 2>/dev/null || echo "(metrics-server warming up)"
  sleep $INTERVAL
done
