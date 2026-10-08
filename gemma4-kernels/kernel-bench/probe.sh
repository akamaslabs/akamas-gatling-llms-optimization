#!/bin/bash
# Kernel probe for study 2 (Gemma 4 26B-A4B FP8 on one L40S, kernels). Ported from
# vllm-benchmark studies/30-l40s-gemma4-26b-tps/probe/probe.sh, the single-GPU form of study
# 24's kernel-bench. Runs outside Akamas, with the L40S node to itself, from the workstation
# or the toolbox (it only needs kubectl):
#   KUBE_CONTEXT=lab-vllm-bench-gatling KP_OUT=/tmp/kb2 setsid nohup bash kernel-bench/probe.sh > /tmp/kb2.log 2>&1 &
# For each combination: a params.env (vLLM 0.29.0 defaults plus the combination's
# overrides), ../k8s/apply_config.sh, then bench_in_pod.py inside vllm-0 (prefill step of a
# ~2000-token prompt, decode at 1 / 64 / 32 concurrent requests, 128 ShareGPT workers). It answers which kernel
# backends start with this checkpoint on SM 8.9 and how fast each one is:
#   - X-*: MoE expert backends (--moe-backend), incl. Triton with the tuned configs of
#     tune_moe.py (tuned-configs/); B-default shows which one vLLM picks by itself;
#   - L-*: FP8 linear backends (--linear-backend) for the dense layers;
#   - A-* / K-*: attention backends, and the fp8 KV cache with each.
# summarize.py tabulates every combination against B-default; the domains are decided on
# the numbers (no automatic admission rule), with the ShareGPT phase as the study's token mix.
# KP_COMBOS overrides the list (name, then KEY=VALUE overrides; "-" for none).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
STUDY_DIR=$(dirname "$HERE"); export STUDY_DIR
export KUBE_CONTEXT=${KUBE_CONTEXT:-gatling}
kubectl() { command kubectl --context "$KUBE_CONTEXT" "$@"; }
OUT=${KP_OUT:-$HERE/results}; mkdir -p "$OUT"
NS=llm-serving
BASELINE='GPU_MEMORY_UTILIZATION=0.92
MAX_NUM_SEQS=256
MAX_NUM_BATCHED_TOKENS=2048
KV_CACHE_DTYPE=auto
PERFORMANCE_MODE=balanced
OPTIMIZATION_LEVEL=2
ENFORCE_EAGER=false
SCHEDULING_POLICY=fcfs
ASYNC_SCHEDULING=true
MAX_CUDAGRAPH_CAPTURE_SIZE=512
BLOCK_SIZE=16'
COMBOS=${KP_COMBOS:-"
B-default         -
X-triton          MOE_BACKEND=triton
X-triton-tuned    MOE_BACKEND=triton TUNED_MOE_CONFIGS=true
X-marlin          MOE_BACKEND=marlin
X-humming         MOE_BACKEND=humming
X-cutlass         MOE_BACKEND=cutlass
X-fi-cutlass      MOE_BACKEND=flashinfer_cutlass
L-torch           LINEAR_BACKEND=torch
L-marlin          LINEAR_BACKEND=marlin
L-humming         LINEAR_BACKEND=humming
A-flashinfer      ATTENTION_BACKEND=FLASHINFER
K-fp8             KV_CACHE_DTYPE=fp8
K-fp8-flashinfer  KV_CACHE_DTYPE=fp8 ATTENTION_BACKEND=FLASHINFER
"}
while read -r NAME OVR; do
  [ -n "${NAME:-}" ] || continue
  P=$OUT/$NAME.params.env
  printf '%s\n' "$BASELINE" > "$P"
  for kv in $OVR; do
    [ "$kv" = - ] && continue
    if grep -q "^${kv%%=*}=" "$P"; then
      python3 - "$P" "$kv" <<'PY'
import sys
p, kv = sys.argv[1:3]; k = kv.split('=', 1)[0]
lines = [kv if l.startswith(k + '=') else l for l in open(p).read().splitlines()]
open(p, 'w').write('\n'.join(lines) + '\n')
PY
    else
      echo "$kv" >> "$P"
    fi
  done
  echo "=== $NAME: $OVR ($(date -u +%T))"
  T0=$SECONDS
  RENDER_ALLOW_FA_FP8=1 PARAMS=$P RENDERED=$OUT/$NAME.sts.yaml bash "$STUDY_DIR/k8s/apply_config.sh" > "$OUT/$NAME.log" 2>&1
  RC=$?
  START_S=$((SECONDS - T0))
  if [ $RC -ne 0 ]; then
    printf '{"name":"%s","overrides":"%s","started":false,"apply_exit":%d,"startup_s":%d}\n' \
      "$NAME" "$OVR" "$RC" "$START_S" > "$OUT/$NAME.json"
    grep -E 'Error|Traceback|not supported|ValueError|RuntimeError' "$OUT/$NAME.log" | grep -v '^--- ' | tail -5
    continue
  fi
  kubectl -n $NS cp "$STUDY_DIR/../resources/prompts.json" vllm-0:/tmp/prompts.json -c vllm >> "$OUT/$NAME.log" 2>&1
  R=$(kubectl -n $NS exec -i vllm-0 -c vllm -- python3 - < "$HERE/bench_in_pod.py" 2>>"$OUT/$NAME.log" \
      | grep '^BENCH_RESULT ' | cut -d' ' -f2-)
  python3 - "$NAME" "$OVR" "$START_S" "${R:-null}" > "$OUT/$NAME.json" <<'PY'
import json, sys
name, ovr, start, res = sys.argv[1:5]
bench = json.loads(res)
print(json.dumps({"name": name, "overrides": ovr, "started": bench is not None,
                  "startup_s": int(start), "bench": bench}))
PY
  grep -E 'Selected .*Kernel|Using .*[Bb]ackend|MoE backend|[Mm]oE config|heterogeneous head|TRITON_ATTN|Model loading took|Available KV cache memory|GPU KV cache size|Maximum concurrency' \
    "$OUT/$NAME.log" | grep -v 'apply_config' | sort -u | head -12 > "$OUT/$NAME.kernels.txt"
  cat "$OUT/$NAME.kernels.txt"
done <<< "$COMBOS"
kubectl -n $NS scale sts vllm --replicas=0
python3 "$HERE/summarize.py" "$OUT" | tee "$OUT/summary.txt"
