#!/usr/bin/env bash
set -euo pipefail

# Provision the throwaway `vllm-bench-gatling` EKS cluster for the Gatling Enterprise
# variant of the goodput study.
#
# Node layout (defined in cluster.yaml, created in one shot):
#   system      (m6i.2xlarge, 8 vCPU / 32 GB)            — Prometheus, Grafana,
#                                                          Gatling control plane AND
#                                                          the Gatling load generator
#   llm-serving (g5.2xlarge,  8 vCPU / 32 GB / 1x A10G)  — vLLM only (tainted)
#
# Adapted from vllm-benchmark's studies/1-goodput-realistic-load/infra/eks/provision.sh.
# Differences from that script, all consequences of this being a SEPARATE cluster that
# Akamas drives remotely (see cluster.yaml for why):
#   - creates `vllm-bench-gatling`, reusing the existing vllm-bench VPC
#   - no `akamas` node group (Akamas stays on the vllm-bench cluster)
#   - writes the kubeconfig context under an explicit alias so it cannot be confused
#     with the lab-vllm-bench context
#   - prints the Prometheus-exposure step, which does not exist in a single-cluster setup
#
# Usage:
#   ./provision.sh --profile lab
#   ./provision.sh --profile lab --region us-west-2   # also edit cluster.yaml

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLUSTER_CONFIG="$SCRIPT_DIR/cluster.yaml"
STORAGE_CLASS="$SCRIPT_DIR/storageclass.yaml"
BOOTSTRAP_DIR="$REPO_ROOT/infra/k8s-bootstrap"
K8S_DIR="$REPO_ROOT/k8s"

CLUSTER_NAME="vllm-bench-gatling"
KUBE_ALIAS="lab-vllm-bench-gatling"
AWS_REGION="us-east-2"
AWS_PROFILE=""

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --region)   AWS_REGION="$2"; shift 2 ;;
    --profile)  AWS_PROFILE="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--region <region>] [--profile <profile>]"
      exit 0
      ;;
    *) echo "Unknown argument: $1. Run $0 --help for usage."; exit 1 ;;
  esac
done

# --- Prerequisites ---
for cmd in eksctl kubectl aws helm; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found in PATH"; exit 1; }
done

PROFILE_ARG=""
if [[ -n "$AWS_PROFILE" ]]; then
  PROFILE_ARG="--profile $AWS_PROFILE"
  CALLER=$(aws sts get-caller-identity $PROFILE_ARG --query 'Arn' --output text)
  echo "AWS profile : $AWS_PROFILE"
  echo "Identity    : $CALLER"
fi

echo ""
echo "=== $CLUSTER_NAME EKS Cluster (Gatling Enterprise study) ==="
echo "Cluster : $CLUSTER_NAME"
echo "Region  : $AWS_REGION"
echo ""

# --- 1. Create cluster ---
echo "[1/6] Cluster + node groups (this takes ~20 min)..."
if eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" $PROFILE_ARG >/dev/null 2>&1; then
  echo "  Cluster '$CLUSTER_NAME' already exists — skipping creation."
else
  eksctl create cluster -f "$CLUSTER_CONFIG" $PROFILE_ARG
  echo "  Cluster created."
fi

# --- 2. Update kubeconfig ---
# --alias is deliberate: without it the context is the full EKS ARN, which is easy to
# confuse with the vllm-bench one when both clusters are live at the same time. Getting
# those two mixed up means applying this study's manifests onto the cluster that is
# running someone else's study.
echo ""
echo "[2/6] Updating kubeconfig (context alias: $KUBE_ALIAS)..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --alias "$KUBE_ALIAS" $PROFILE_ARG
echo "  Context: $(kubectl config current-context)"

# --- 3. StorageClasses ---
echo ""
echo "[3/6] Applying StorageClasses (gp3 default + gp3-ephemeral)..."
kubectl apply -f "$STORAGE_CLASS"
kubectl apply -f "$BOOTSTRAP_DIR/01-storage-classes.yaml"

# --- 4. NVIDIA device plugin ---
# The GPU is invisible to Kubernetes as an allocatable nvidia.com/gpu resource until
# this DaemonSet runs. It already tolerates the nvidia.com/gpu taint.
echo ""
echo "[4/6] Installing NVIDIA device plugin..."
kubectl apply -f \
  https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml
echo "  Waiting for DaemonSet rollout on GPU node (up to 3 min)..."
kubectl rollout status daemonset/nvidia-device-plugin-daemonset \
  --namespace kube-system \
  --timeout=180s

# --- 5. Namespaces ---
echo ""
echo "[5/6] Applying namespaces (llm-serving, llm-benchmark, monitoring)..."
kubectl apply -f "$BOOTSTRAP_DIR/00-namespaces.yaml"

# --- 6. PVCs ---
echo ""
echo "[6/6] Applying PVCs..."
kubectl apply -f "$K8S_DIR/01-pvc-model-cache.yaml"
# NOTE: k8s/00-pvc.yaml (the `gatling-results` PVC) is deliberately NOT applied — on the
# Enterprise path results live in the Gatling Enterprise dashboards and that PVC is
# unused (see PLAN.md "What changed vs. the main-branch run"). Apply it only if you fall
# back to the raw-Job workflow.

# --- Summary ---
echo ""
echo "=== Done ==="
echo ""
kubectl get nodes -L node-role
echo ""
echo "Verify the GPU is visible to Kubernetes:"
echo "  kubectl describe node -l node-role=llm-serving | grep -A5 Allocatable"
echo "  # Should show: nvidia.com/gpu: 1"
echo ""
echo "Next steps (still manual, not run by this script):"
echo ""
echo "  1. Install NVIDIA DCGM Exporter (GPU hardware metrics):"
echo "       helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts"
echo "       helm repo update"
echo "       kubectl create configmap dcgm-custom-metrics \\"
echo "         --from-file=metrics=$K8S_DIR/monitoring/dcgm_counters.csv -n monitoring"
echo "       helm upgrade --install dcgm-exporter gpu-helm-charts/dcgm-exporter \\"
echo "         --namespace monitoring \\"
echo "         -f $K8S_DIR/monitoring/dcgm-exporter-values.yaml"
echo ""
echo "  2. Install Prometheus + Grafana:"
echo "       helm repo add prometheus-community https://prometheus-community.github.io/helm-charts"
echo "       helm repo update"
echo "       helm upgrade --install kube-prometheus-stack \\"
echo "         prometheus-community/kube-prometheus-stack \\"
echo "         --namespace monitoring \\"
echo "         -f $K8S_DIR/monitoring/values-kube-prometheus.yaml"
echo "       kubectl apply -f $K8S_DIR/monitoring/servicemonitor.yaml"
echo ""
echo "  3. Expose Prometheus to Akamas on the OTHER cluster (no equivalent step in the"
echo "     single-cluster setup — see k8s/monitoring/prometheus-internal-lb.yaml):"
echo "       kubectl apply -f $K8S_DIR/monitoring/prometheus-internal-lb.yaml"
echo "       kubectl get svc prometheus-akamas -n monitoring -w   # wait for EXTERNAL-IP"
echo "     Then put that hostname into akamas/telemetry/prometheus.yaml (config.address)"
echo "     and re-apply the telemetry instance with 'akamas create'."
echo ""
echo "     Verify reachability FROM Akamas, not from here — same VPC still needs the"
echo "     security groups to allow it:"
echo "       kubectl --context=lab-vllm-bench -n akamas exec deploy/toolbox -- \\"
echo "         curl -sS -m 5 http://<nlb-hostname>:9090/-/ready"
echo ""
echo "  4. Gatling control plane (needs the cpt_ token Secret first):"
echo "       kubectl create secret generic gatling-control-plane-token \\"
echo "         -n llm-benchmark --from-literal=token=\"cpt_...\""
echo "       bash $K8S_DIR/gatling-control-plane/install.sh"
echo ""
echo "  5. Create and start the Akamas study — see PLAN.md."
echo ""
echo "Stop GPU billing (keep the cluster):"
echo "  eksctl delete nodegroup --cluster $CLUSTER_NAME --region $AWS_REGION --name llm-serving --approve $PROFILE_ARG"
echo ""
echo "Full teardown (this cluster is meant to be deleted when the study is done):"
echo "  eksctl delete cluster --name $CLUSTER_NAME --region $AWS_REGION $PROFILE_ARG"
