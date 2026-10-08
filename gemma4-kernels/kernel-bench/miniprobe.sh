#!/bin/bash
# MoE tuning v1 vs v2 (study 2, README "MoE tuning"), run after tune-pod.yaml prints
# TUNING-DONE: copies v2's file out of the moe-tune pod (8 MB chunks, md5-checked: one
# kubectl cp of the 40 MB routing sample truncated), frees the GPU, then runs probe.sh three
# times on the Triton experts: vLLM's default config, v1 (random gating), v2 (real routing).
# Results in results/miniprobe/. Usage (workstation):
#   KUBE_CONTEXT=lab-vllm-bench-gatling bash kernel-bench/miniprobe.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
export KUBE_CONTEXT=${KUBE_CONTEXT:-gatling}
k() { kubectl --context "$KUBE_CONTEXT" -n llm-serving "$@"; }
F='E=128,N=704,device_name=NVIDIA_L40S,dtype=fp8_w8a8.json'
OUT=$HERE/results/miniprobe; mkdir -p "$OUT"

until k logs moe-tune 2>/dev/null | grep -q TUNING-DONE; do sleep 60; done
k logs moe-tune | grep -E '^(routing|device|M=|done in)' > "$HERE/results/tuning-v2.log"
SUM=$(k exec moe-tune -- md5sum "/out/$F" | cut -d' ' -f1)
k exec moe-tune -- cat "/out/$F" > "$HERE/tuned-configs-v2/$F"
[ "$(md5sum "$HERE/tuned-configs-v2/$F" | cut -d' ' -f1)" = "$SUM" ] || { echo "v2 copy corrupted"; exit 1; }
k delete pod moe-tune --wait=true

run() {  # $1 name, $2 tuned dir, $3 overrides
  TUNED_DIR=$2 KP_OUT=$OUT KP_COMBOS="$1 $3" bash "$HERE/probe.sh" >> "$OUT/probe.log" 2>&1
}
run B-default "$HERE/tuned-configs-v1" "MOE_BACKEND=triton"   # Triton with vLLM's default config (= auto)
run X-triton-tuned-v1 "$HERE/tuned-configs-v1" "MOE_BACKEND=triton TUNED_MOE_CONFIGS=true"
run X-triton-tuned-v2 "$HERE/tuned-configs-v2" "MOE_BACKEND=triton TUNED_MOE_CONFIGS=true"
python3 "$HERE/summarize.py" "$OUT" | tee "$OUT/summary.txt"
