#!/bin/bash
# Apply-config step for study 2 (Gemma 4 kernels; runs on the toolbox host via the Akamas
# workflow's Executor task, after FileConfigurator has rendered params.env). Ported from
# vllm-benchmark studies/30-l40s-gemma4-26b-tps/k8s/apply_config.sh, retargeted at the
# vllm-bench-gatling cluster.
#
# One experiment = one vLLM configuration on the whole L40S. Study 28's sequence without the
# MIG part: validate -> free the GPU -> start one replica -> warm-up -> health check -> logs.
# Env overrides PARAMS / RENDERED for the startup probe (../probe/probe.sh).
#
# Fail-fast by design (set -e, explicit checks): a half-applied configuration would
# benchmark the previous experiment's vLLM under the current one's name.
set -euo pipefail

STUDY_DIR=${STUDY_DIR:-/work/akamas-gatling-llms-optimization/gemma4-kernels}   # overridable for manual tests
NS=llm-serving
NODE_LABEL=gpu=l40s
MODEL=gemma4-26b-l40s
# Explicit cluster, never the current context: toolbox's default context is the shared
# vllm-bench cluster, where llm-serving exists too and other studies measure (see
# k8s/apply_config.sh). `gatling` is toolbox's alias for vllm-bench-gatling; from a
# workstation, KUBE_CONTEXT=lab-vllm-bench-gatling.
KUBE_CONTEXT=${KUBE_CONTEXT:-gatling}
kubectl() { command kubectl --context "$KUBE_CONTEXT" "$@"; }
TUNED_DIR=${TUNED_DIR:-$STUDY_DIR/kernel-bench/tuned-configs}   # overridable to compare tunings
PARAMS=${PARAMS:-$STUDY_DIR/k8s/params.env}
TEMPLATE=$STUDY_DIR/k8s/01-statefulset_template.yaml
RENDERED=${RENDERED:-$STUDY_DIR/k8s/01-statefulset.yaml}
RENDER=$STUDY_DIR/k8s/render_statefulset.sh
ROLLOUT_S=${ROLLOUT_S:-2400}
# shellcheck source=lib_health.sh
source "$STUDY_DIR/k8s/lib_health.sh"

t() { echo "$(date -u +%T) apply_config: $*"; }
die() { echo "error: $*" >&2; exit "${2:-2}"; }

# --- 0. Parameters -------------------------------------------------------------------
# Validate everything BEFORE touching the cluster: render_statefulset.sh exits 2 on a
# leftover token, an empty value or a value outside what vLLM accepts.
bash "$RENDER" "$PARAMS" "$TEMPLATE" "$RENDERED" || die "invalid parameters in $PARAMS"
t "parameters: $(grep -v '^#' "$PARAMS" | grep . | tr '\n' ' ')"
t "vLLM flags: $(grep -E '^ +- "--' "$RENDERED" | sed -e 's/^ *- "//' -e 's/"$//' | tr '\n' ' ')"

NODE=$(kubectl get nodes -l $NODE_LABEL -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$NODE" ] || die "no node with $NODE_LABEL (node group llm-serving-l40s scaled to 0?)" 3
if grep -q '^TUNED_MOE_CONFIGS=true' "$PARAMS"; then
  ls "$TUNED_DIR"/*.json >/dev/null 2>&1 || die "TUNED_MOE_CONFIGS=true but no tuned config in $TUNED_DIR"
fi

# --- 1. Free the GPU -----------------------------------------------------------------
t "1/3 scaling vLLM to 0"
kubectl -n $NS scale sts vllm --replicas=0 2>/dev/null || true   # absent on the first run
# Delete the pod explicitly as well: with OrderedReady the controller stalls a scale-down
# while the replica is unready, and two engines must never share the GPU.
kubectl -n $NS delete pod -l app=vllm --ignore-not-found --wait=true --timeout=180s >/dev/null
LEFT=$(kubectl -n $NS get pods -l app=vllm -o name | wc -l | tr -d ' ')
[ "$LEFT" = 0 ] || die "$LEFT vLLM pod(s) still present after scale-down" 3

# --- 2. Start the replica -------------------------------------------------------------
t "2/3 starting vLLM on $NODE"
kubectl apply -f "$STUDY_DIR/k8s/02-service-headless.yaml" >/dev/null
# The tuned fused-MoE configs, refreshed every trial (the pod reads them only when the
# rendered spec sets VLLM_TUNED_CONFIG_FOLDER).
# The ConfigMap key is plain (no '=' or ','); the template maps it back to vLLM's file name.
TUNED_FILE="$TUNED_DIR/E=128,N=704,device_name=NVIDIA_L40S,dtype=fp8_w8a8.json"
if [ -f "$TUNED_FILE" ]; then
  # kubectl rejects '=' in a --from-file path as well: go through a plain-named copy.
  TMP_CFG=$(mktemp -d)
  cp "$TUNED_FILE" "$TMP_CFG/moe-e128-n704-l40s-fp8.json"
  kubectl -n $NS create configmap moe-tuned-configs --from-file="$TMP_CFG/moe-e128-n704-l40s-fp8.json" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -rf "$TMP_CFG"
fi
kubectl apply -f "$RENDERED" || die "kubectl apply failed — refusing to benchmark a stale configuration" 3
# `apply` alone does not restart a pod whose spec did not change; the delete above already
# removed it, so the controller creates a fresh one with this spec.
kubectl -n $NS scale sts vllm --replicas=1 >/dev/null

# Don't exit on a failed rollout before printing the logs: they land in the Akamas UI.
set +e
# Wait for Ready, but fail fast on a crash loop instead of sitting out the whole ROLLOUT_S
# (a config that OOMs at startup would otherwise cost 40 min per failure). 2400 s covers a
# cold node: ~10 GB image pull plus the ~27 GiB model download.
ROLLOUT_EXIT=1
T0=$SECONDS
while [ $((SECONDS - T0)) -lt "$ROLLOUT_S" ]; do
  READY=$(kubectl -n $NS get sts vllm -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [ "${READY:-0}" = 1 ]; then ROLLOUT_EXIT=0; break; fi
  RESTARTS=$(kubectl -n $NS get pod vllm-0 -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  if [ "${RESTARTS:-0}" -ge 2 ]; then
    echo "error: vllm-0 restarted ${RESTARTS} times during startup — crash loop, failing now" >&2
    ROLLOUT_EXIT=4; break
  fi
  sleep 20
done
[ $ROLLOUT_EXIT = 1 ] && echo "error: vllm-0 not Ready after $ROLLOUT_S s" >&2
t "rollout exit=$ROLLOUT_EXIT after $((SECONDS - T0)) s"
set -e

# --- 3. Warm-up ------------------------------------------------------------------------
# The first requests a fresh vLLM serves hit first-use kernel JIT (TTFT p95 33.6 s in study
# 25's phase 0). They happen here, so they are > 150 s old (the p95 window of the
# constraints and of the watchdog) when RunTest's measured run starts after pip install and
# its own 60 s warm-up.
if [ $ROLLOUT_EXIT -eq 0 ]; then
  t "3/3 warm-up: 8 requests"
  WARM_FAIL=0
  kubectl -n $NS exec vllm-0 -c vllm -- python3 -c '
import json, sys, time, urllib.request, concurrent.futures as cf
def one(i):
    body = {"model": sys.argv[1], "max_tokens": 64,
            "messages": [{"role": "user", "content": "Write a short story about the number %d." % i}]}
    s = time.perf_counter()
    urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8000/v1/chat/completions",
        json.dumps(body).encode(), {"Content-Type": "application/json"}), timeout=300).read()
    return time.perf_counter() - s
with cf.ThreadPoolExecutor(4) as ex:
    print("warm-up e2e (s):", " ".join("%.2f" % x for x in ex.map(one, range(8))))
' "$MODEL" || { echo "error: warm-up requests failed on vllm-0" >&2; WARM_FAIL=1; }
  # Still Ready and never restarted: a replica OOMKilled by its first requests would
  # otherwise leave RunTest to discover it ~3 min later.
  READY=$(kubectl -n $NS get sts vllm -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  RESTARTS=$(kubectl -n $NS get pod vllm-0 -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  if ! REASON=$(replicas_healthy 1 "$READY" "${RESTARTS:-0}" "$WARM_FAIL"); then
    echo "error: $REASON, failing the trial" >&2
    ROLLOUT_EXIT=4
  fi
fi

# Full logs, success or failure, so the Akamas task output alone is enough to debug an
# experiment. The summary first, because the full dump is long.
echo "--- vllm-0: startup summary ---"
kubectl -n $NS logs vllm-0 --all-containers --tail=-1 2>/dev/null \
  | grep -E 'Selected .*Kernel|Using .*[Bb]ackend|MoE backend|[Mm]oE config|tuned|TRITON_ATTN|heterogeneous head|attention backend|linear|Model loading took|Available KV cache memory|GPU KV cache size|Maximum concurrency|CUDA graph|Error|Traceback' || true
echo "--- vllm-0: full logs ---"
kubectl -n $NS logs vllm-0 --all-containers --tail=-1 2>/dev/null || true
if [ $ROLLOUT_EXIT -ne 0 ]; then
  echo "--- vllm-0: previous container (if it crashed and restarted) ---"
  kubectl -n $NS logs vllm-0 --all-containers --tail=-1 --previous 2>/dev/null || true
  kubectl -n $NS describe pod vllm-0 2>/dev/null | tail -30 || true
fi
exit $ROLLOUT_EXIT
