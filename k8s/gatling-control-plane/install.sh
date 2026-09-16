#!/bin/bash
# Installs the Gatling Enterprise control plane for the in-cluster Kubernetes
# private location `prl_akamas_vllm_k8s`. Idempotent: re-running updates the
# ConfigMap + Deployment and restarts the pod to pick up config changes.
#
# Prereqs (deliberately NOT created here):
#   1. A control plane created in Gatling Enterprise (Admin > Private Locations >
#      Control Planes) -- copy its token.
#   2. The token Secret applied manually (see secret.example.yaml).
#
# Docs: https://docs.gatling.io/reference/deploy/private-locations/kubernetes/
set -euo pipefail

NS=llm-benchmark
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fail early with a clear message if the token Secret isn't in place yet.
if ! kubectl get secret gatling-control-plane-token -n "$NS" >/dev/null 2>&1; then
  echo "ERROR: Secret gatling-control-plane-token missing in namespace $NS." >&2
  echo "       Create it first -- see $HERE/secret.example.yaml." >&2
  exit 1
fi

# RBAC first (the Deployment references this ServiceAccount).
kubectl apply -f "$HERE/rbac.yaml"

# Bundle both HOCON files into the ConfigMap the Deployment mounts at /app/conf, so
# `include "job.json"` resolves next to control-plane.conf.
kubectl create configmap gatling-control-plane \
  -n "$NS" \
  --from-file="$HERE/control-plane.conf" \
  --from-file="$HERE/job.json" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$HERE/deployment.yaml"

# kubectl does not restart pods on a ConfigMap change -- force it.
kubectl rollout restart deployment/gatling-control-plane -n "$NS"
kubectl rollout status deployment/gatling-control-plane -n "$NS" --timeout=180s

echo
echo "Control plane installed. Confirm it registered the private location in Gatling"
echo "Enterprise > Admin > Private Locations (id: prl_akamas_vllm_k8s) before running."
