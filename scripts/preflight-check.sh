#!/usr/bin/env bash
# scripts/preflight-check.sh
# Run this before ANY cluster operations
 
set -euo pipefail
 
REQUIRED_TOOLS=(docker terraform ansible kubectl helm kind k6 jq yq)
ERRORS=()
 
for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" &>/dev/null; then
    ERRORS+=("MISSING: $tool")
  else
    echo "  ✓ $tool $(${tool} version 2>/dev/null | head -1 || ${tool} --version 2>/dev/null | head -1)"
  fi
done
 
# KinD-specific: validate inotify limits (critical — KinD fails silently without these)
INOTIFY_WATCHES=$(cat /proc/sys/fs/inotify/max_user_watches)
INOTIFY_INSTANCES=$(cat /proc/sys/fs/inotify/max_user_instances)
 
if [[ "$INOTIFY_WATCHES" -lt 524288 ]]; then
  ERRORS+=("inotify max_user_watches too low: $INOTIFY_WATCHES (need >= 524288)")
fi
if [[ "$INOTIFY_INSTANCES" -lt 512 ]]; then
  ERRORS+=("inotify max_user_instances too low: $INOTIFY_INSTANCES (need >= 512)")
fi
 
if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo ""
  echo "PREFLIGHT FAILURES:"
  for err in "${ERRORS[@]}"; do echo "  ✗ $err"; done
  echo ""
  echo "Run Ansible first: ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/site.yml"
  exit 1
fi
 
echo ""
echo "Preflight passed. Proceeding."
