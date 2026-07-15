#!/usr/bin/env bash
# scripts/build-and-load.sh
#
# Builds the backend image, loads it onto every node of the running KinD
# cluster (whatever the node count is — doesn't assume single-node), rolls
# it out, and verifies the pods that come up are actually running what was
# just built.
#
# This exists because `kubectl rollout restart` alone silently reuses
# whatever image is already tagged in the cluster — if the build or load
# step is skipped or fails quietly, pods keep running stale code with no
# error, which is exactly what happened before this script existed.
#
# The pass/fail gate is the *running pods'* reported image digest, not a
# pre-emptive containerd query on each node before rollout — a pod with
# imagePullPolicy: Never fails loudly (ErrImageNeverPull) if a node truly
# lacks the image, which is a more reliable signal than re-querying
# containerd ourselves, especially on a loaded host where `docker exec`
# can itself time out and get mistaken for "image missing".

set -euo pipefail

CLUSTER_NAME="three-tier"
KUBECONFIG="${HOME}/.kube/three-tier-config"
NAMESPACE="apps"
DEPLOYMENT="backend"
IMAGE_NAME="backend:local"
IMAGE_REF="docker.io/library/${IMAGE_NAME}"
BUILD_CONTEXT="manifests/backend/app"

export KUBECONFIG

echo "=== [1/4] Pre-build state ==="
OLD_ID="$(docker image inspect --format '{{.Id}}' "${IMAGE_NAME}" 2>/dev/null || echo "none")"
echo "  Current ${IMAGE_NAME} image ID: ${OLD_ID}"

echo ""
echo "=== [2/4] Building ${IMAGE_NAME} from ${BUILD_CONTEXT} ==="
docker build -t "${IMAGE_NAME}" "${BUILD_CONTEXT}"
NEW_ID="$(docker image inspect --format '{{.Id}}' "${IMAGE_NAME}")"
echo "  New ${IMAGE_NAME} image ID:     ${NEW_ID}"

if [[ "${OLD_ID}" == "${NEW_ID}" && "${OLD_ID}" != "none" ]]; then
  echo "  NOTE: image ID unchanged — either source didn't change, or the" \
       "build didn't pick up your edits. Double-check before assuming this" \
       "rebuild actually shipped anything new."
fi

echo ""
echo "=== [3/4] Loading image onto every node of cluster '${CLUSTER_NAME}' ==="
if ! command -v kind &>/dev/null; then
  echo "  ERROR: kind not found on PATH." >&2
  exit 1
fi

mapfile -t NODES < <(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null)
if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "  ERROR: no nodes found for cluster '${CLUSTER_NAME}' — is it running?" >&2
  exit 1
fi
echo "  Cluster has ${#NODES[@]} node(s): ${NODES[*]}"

kind load docker-image "${IMAGE_NAME}" --name "${CLUSTER_NAME}"

# Docker's own image ID above is a config digest — it is NOT the same value
# kubelet reports back as a running pod's imageID (a manifest digest that
# containerd assigns during the import kind just did). Resolve the real one
# from containerd itself so the final comparison isn't comparing two
# unrelated digest namespaces.
EXPECTED_DIGEST=""
for node in "${NODES[@]}"; do
  set +e
  digest="$(docker exec "${node}" ctr -n k8s.io images ls -q "name==${IMAGE_REF}" 2>/dev/null | head -n1)"
  set -e
  if [[ -n "${digest}" ]]; then
    EXPECTED_DIGEST="${digest}"
    break
  fi
done
if [[ -z "${EXPECTED_DIGEST}" ]]; then
  echo "  ERROR: could not resolve ${IMAGE_REF}'s digest from containerd on any node." >&2
  exit 1
fi
echo "  Loaded image digest (containerd): ${EXPECTED_DIGEST}"

echo ""
echo "  --- informational per-node check (not a pass/fail gate — a loaded" \
     "host can make 'docker exec' itself flaky, which looks identical to a" \
     "real miss; the pod rollout below is the real test) ---"
for node in "${NODES[@]}"; do
  set +e
  out="$(docker exec "${node}" ctr -n k8s.io images ls -q "name==${IMAGE_REF}" 2>&1)"
  rc=$?
  set -e
  if [[ ${rc} -ne 0 ]]; then
    echo "  ?    ${node}: query failed (rc=${rc}): ${out}"
  elif [[ "${out}" == "${EXPECTED_DIGEST}" ]]; then
    echo "  OK   ${node}"
  elif [[ -n "${out}" ]]; then
    echo "  !!   ${node}: has a different digest (${out}) — stale copy"
  else
    echo "  ??   ${node}: no match found"
  fi
done

echo ""
echo "=== [4/4] Rolling out to deployment/${DEPLOYMENT} ==="
kubectl rollout restart "deployment/${DEPLOYMENT}" -n "${NAMESPACE}"
kubectl rollout status "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --timeout=180s

echo ""
echo "--- Verifying every running pod matches the loaded digest ---"
echo "  Expected: ${EXPECTED_DIGEST}"

mapfile -t POD_LINES < <(kubectl get pods -n "${NAMESPACE}" -l "app=${DEPLOYMENT}" \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[0].restartCount,IMAGE_ID:.status.containerStatuses[0].imageID' \
  --no-headers)

printf '  %-32s %-22s %-10s %s\n' "POD" "NODE" "RESTARTS" "IMAGE_ID"
MISMATCH=0
for line in "${POD_LINES[@]}"; do
  read -r pod node restarts image_id <<<"${line}"
  printf '  %-32s %-22s %-10s %s\n' "${pod}" "${node}" "${restarts}" "${image_id}"
  if [[ "${image_id}" != *"${EXPECTED_DIGEST#sha256:}"* ]]; then
    echo "    ^ MISMATCH — not running the digest just loaded" >&2
    MISMATCH=1
  fi
done

echo ""
if [[ "${MISMATCH}" -eq 1 ]]; then
  echo "✗ At least one running pod is not on the freshly loaded image." \
       "Check that pod's node against the per-node check above, and" \
       "'kubectl describe pod <name> -n ${NAMESPACE}' for pull errors." >&2
  exit 1
fi

echo "✓ Build, load, and rollout complete — every pod matches the loaded image."
