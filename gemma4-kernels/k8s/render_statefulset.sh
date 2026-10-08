#!/bin/bash
# Validates params.env and renders the StatefulSet template (study 2, Gemma 4 kernels).
# Ported from vllm-benchmark studies/30-l40s-gemma4-26b-tps/k8s/render_statefulset.sh:
# MTP removed (study 2 tunes kernels only), MOE_BACKEND and TUNED_MOE_CONFIGS added.
# Usage: render_statefulset.sh <params.env> <template> <output>
# Exit codes: 0 rendered; 2 invalid input (nothing written).
#
# The tuned flags are written here, not in the template, for two reasons:
#   - vLLM 0.29.0 parses every boolean with argparse.BooleanOptionalAction, so true/false
#     must become --x / --no-x (--x=false is an error, study 27's note);
#   - LINEAR_BACKEND / ATTENTION_BACKEND are optional (see params.env.template): absent or
#     "auto" means no flag, so vLLM keeps its own choice (for Gemma 4 on SM 8.9: TRITON_ATTN,
#     forced by Gemma4Config only when no backend is given);
#   - MOE_BACKEND is optional the same way (--moe-backend, vLLM 0.29.0 KernelConfig);
#   - TUNED_MOE_CONFIGS=true sets VLLM_TUNED_CONFIG_FOLDER to the mounted ConfigMap of tuned
#     fused-MoE Triton configs (../kernel-bench/tune_moe.py); absent or false, vLLM uses
#     its default config for this shape. It only matters with the Triton MoE backend.
# EXTRA_VLLM_ARGS: see below. RENDER_ALLOW_FA_FP8=1 lifts the FLASH_ATTN + fp8 guard (the startup probe uses it to check
# that guard on this GPU; the study never sets it).
set -euo pipefail
die() { echo "error: $*" >&2; exit 2; }
[ $# -eq 3 ] || die "usage: render_statefulset.sh <params.env> <template> <output>"
PARAMS=$1 TEMPLATE=$2 OUT=$3
[ -f "$PARAMS" ] || die "no params file $PARAMS"
[ -f "$TEMPLATE" ] || die "no template $TEMPLATE"
# shellcheck disable=SC2016  # a literal ${ is what an unsubstituted Akamas token looks like
if grep -q '\${' "$PARAMS"; then
  die "params.env still has unsubstituted tokens (a parameter is missing from parametersSelection): $(grep '\${' "$PARAMS" | tr '\n' ' ')"
fi
LINEAR_BACKEND="" ATTENTION_BACKEND="" MOE_BACKEND="" TUNED_MOE_CONFIGS=""
# shellcheck disable=SC1090
source "$PARAMS"
REQUIRED="GPU_MEMORY_UTILIZATION MAX_NUM_SEQS MAX_NUM_BATCHED_TOKENS KV_CACHE_DTYPE PERFORMANCE_MODE
OPTIMIZATION_LEVEL ENFORCE_EAGER SCHEDULING_POLICY ASYNC_SCHEDULING MAX_CUDAGRAPH_CAPTURE_SIZE BLOCK_SIZE"
for v in $REQUIRED; do
  [ -n "${!v:-}" ] || die "$v is empty in params.env (doNotRenderParameters renders an empty string, not the token)"
done
# An optional line that is present must not be empty either.
for v in LINEAR_BACKEND ATTENTION_BACKEND MOE_BACKEND TUNED_MOE_CONFIGS; do
  if grep -q "^$v=" "$PARAMS" && [ -z "${!v}" ]; then die "$v is present but empty in params.env"; fi
done

[[ "$GPU_MEMORY_UTILIZATION" =~ ^0\.[0-9]+$ ]] || die "gpu_memory_utilization '$GPU_MEMORY_UTILIZATION' is not a fraction"
for v in MAX_NUM_SEQS MAX_NUM_BATCHED_TOKENS MAX_CUDAGRAPH_CAPTURE_SIZE BLOCK_SIZE OPTIMIZATION_LEVEL; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || die "$v='${!v}' is not an integer"
done
[ "$OPTIMIZATION_LEVEL" -le 3 ] || die "optimization_level '$OPTIMIZATION_LEVEL' is not 0-3"
{ [ "$BLOCK_SIZE" -ge 16 ] && [ $((BLOCK_SIZE % 16)) = 0 ]; } || die "block_size '$BLOCK_SIZE' is not a multiple of 16"
# vLLM 0.29.0 vllm/config/scheduler.py raises ValueError when max_num_batched_tokens < max_num_seqs.
[ "$MAX_NUM_BATCHED_TOKENS" -ge "$MAX_NUM_SEQS" ] || die "max_num_batched_tokens $MAX_NUM_BATCHED_TOKENS < max_num_seqs $MAX_NUM_SEQS"
[[ "$KV_CACHE_DTYPE" =~ ^(auto|fp8|fp8_e4m3|fp8_e5m2)$ ]] || die "kv_cache_dtype '$KV_CACHE_DTYPE' is not auto, fp8, fp8_e4m3 or fp8_e5m2"
[[ "$PERFORMANCE_MODE" =~ ^(balanced|interactivity|throughput)$ ]] || die "performance_mode '$PERFORMANCE_MODE' is not balanced, interactivity or throughput"
[[ "$SCHEDULING_POLICY" =~ ^(fcfs|priority)$ ]] || die "scheduling_policy '$SCHEDULING_POLICY' is not fcfs or priority"
for v in ENFORCE_EAGER ASYNC_SCHEDULING; do
  [[ "${!v}" =~ ^(true|false)$ ]] || die "$v='${!v}' is not true or false"
done
[ -z "$LINEAR_BACKEND" ] || [[ "$LINEAR_BACKEND" =~ ^[a-z0-9_]+$ ]] || die "linear_backend '$LINEAR_BACKEND' is not a backend name"
[ -z "$ATTENTION_BACKEND" ] || [[ "$ATTENTION_BACKEND" =~ ^(auto|FLASHINFER|FLASH_ATTN|TRITON_ATTN)$ ]] \
  || die "attention_backend '$ATTENTION_BACKEND' is not auto, FLASHINFER, FLASH_ATTN or TRITON_ATTN"
[ -z "$MOE_BACKEND" ] || [[ "$MOE_BACKEND" =~ ^[a-z0-9_]+$ ]] || die "moe_backend '$MOE_BACKEND' is not a backend name"
[ -z "$TUNED_MOE_CONFIGS" ] || [[ "$TUNED_MOE_CONFIGS" =~ ^(true|false)$ ]] || die "tuned_moe_configs '$TUNED_MOE_CONFIGS' is not true or false"
# FlashAttention 2 rejects an fp8 KV cache (vLLM 0.29.0 fa_utils.py: fp8 needs FA3 on SM 9.x or
# FA4 on SM 10.x); confirmed on SM 8.9 (study 24) and SM 12.0 (study 28).
if [ "$ATTENTION_BACKEND" = FLASH_ATTN ] && [ "$KV_CACHE_DTYPE" != auto ] && [ "${RENDER_ALLOW_FA_FP8:-0}" != 1 ]; then
  die "FLASH_ATTN with kv_cache_dtype $KV_CACHE_DTYPE (FlashAttention 2 rejects an fp8 KV cache)"
fi

flag() { [ "$2" = true ] && echo "--$1" || echo "--no-$1"; }
ARGS=(
  "--gpu-memory-utilization=$GPU_MEMORY_UTILIZATION"
  "--max-num-seqs=$MAX_NUM_SEQS"
  "--max-num-batched-tokens=$MAX_NUM_BATCHED_TOKENS"
  "--kv-cache-dtype=$KV_CACHE_DTYPE"
  "--performance-mode=$PERFORMANCE_MODE"
  "--optimization-level=$OPTIMIZATION_LEVEL"
  "$(flag enforce-eager "$ENFORCE_EAGER")"
  "--scheduling-policy=$SCHEDULING_POLICY"
  "$(flag async-scheduling "$ASYNC_SCHEDULING")"
  "--max-cudagraph-capture-size=$MAX_CUDAGRAPH_CAPTURE_SIZE"
  "--block-size=$BLOCK_SIZE"
)
[ -n "$LINEAR_BACKEND" ] && [ "$LINEAR_BACKEND" != auto ] && ARGS+=("--linear-backend=$LINEAR_BACKEND")
[ -n "$ATTENTION_BACKEND" ] && [ "$ATTENTION_BACKEND" != auto ] && ARGS+=("--attention-backend=$ATTENTION_BACKEND")
[ -n "$MOE_BACKEND" ] && [ "$MOE_BACKEND" != auto ] && ARGS+=("--moe-backend=$MOE_BACKEND")
# EXTRA_VLLM_ARGS (environment, not params.env): extra flags for tools outside the study, e.g.
# --enable-return-routed-experts for ../kernel-bench/capture_routing.py. Never set by Akamas.
for a in ${EXTRA_VLLM_ARGS:-}; do
  [[ "$a" =~ ^--[a-z0-9-]+(=[A-Za-z0-9_.,-]+)?$ ]] || die "EXTRA_VLLM_ARGS item '$a' is not a plain --flag[=value]"
  ARGS+=("$a")
done

INDENT=$(grep -m1 '@TUNED_ARGS@' "$TEMPLATE" | sed 's/@TUNED_ARGS@.*//')
[ -n "$INDENT" ] || die "template has no TUNED_ARGS line"
: > "$OUT.args"
for a in "${ARGS[@]}"; do printf '%s- "%s"\n' "$INDENT" "$a" >> "$OUT.args"; done
ENV_INDENT=$(grep -m1 '@TUNED_ENV@' "$TEMPLATE" | sed 's/@TUNED_ENV@.*//')
[ -n "$ENV_INDENT" ] || die "template has no TUNED_ENV line"
: > "$OUT.env"
if [ "$TUNED_MOE_CONFIGS" = true ]; then
  printf '%s- name: VLLM_TUNED_CONFIG_FOLDER\n%s  value: /moe-tuned-configs\n' "$ENV_INDENT" "$ENV_INDENT" >> "$OUT.env"
fi
sed -e "/@TUNED_ARGS@/r $OUT.args" -e '/@TUNED_ARGS@/d' -e "/@TUNED_ENV@/r $OUT.env" -e '/@TUNED_ENV@/d' "$TEMPLATE" > "$OUT.tmp"
rm -f "$OUT.args" "$OUT.env"
if grep -q '@[A-Z_]*@' "$OUT.tmp"; then
  LEFT=$(grep -o '@[A-Z_]*@' "$OUT.tmp" | sort -u | tr '\n' ' '); rm -f "$OUT.tmp"
  die "rendered StatefulSet still has tokens: $LEFT"
fi
mv "$OUT.tmp" "$OUT"
