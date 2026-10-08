# Study 2: Gemma 4 26B-A4B FP8 on one L40S, kernel backends, Gatling open-loop load

**Status:** preparation. Kernel tuning and probe in progress (2026-10-08).

## What and why

Study 27/29's approach to kernels (vllm-benchmark: study 24's kernel-bench, then the
backends and their tuned configs as study parameters) applied to the model and GPU of
vllm-benchmark's study 30, with this repo's Gatling as the load generator.

| | here | vllm-benchmark study 30 | studies 27/29 |
|---|---|---|---|
| model | `RedHatAI/gemma-4-26B-A4B-it-FP8-dynamic` | same | Qwen3-8B-FP8 |
| GPU | 1x L40S, g6e.xlarge | same | 4x L4, P/D |
| vLLM | 0.29.0 | same | same |
| load | **Gatling**, open-loop ramp, Poisson | AIPerf, open-loop ramp, gamma 4 | AIPerf, gamma 4 |
| parameters | **kernels** + their scheduler knobs (below) | base vLLM set + MTP | P/D topology + kernels |
| SLA | TTFT p95 <= 1500 ms, ITL p95 <= 300 ms (150 s, `:max`) | same | 10 s / 75 ms |

Decided with the user on 2026-10-08:
- **Kernels only**, MTP left out (a later study may add it on top of the best kernels).
- **Same node size as study 30** (g6e.xlarge) so the two studies compare.
- **Poisson arrivals**: Gatling has no gamma arrivals. Same mean, 4x the variance of the
  gaps of study 30's gamma (smoothness 4).
- **SLA**: study 30's, to be revisited once the first Gatling runs are in.
- Runs on the dedicated `vllm-bench-gatling` cluster, never on `vllm-bench`.

## Steps

1. **Tune** the one kernel with tunable configs: vLLM's Triton fused-MoE, for Gemma 4's
   expert shape (E=128, N=704, K=2816, fp8 per-channel / per-token). vLLM 0.29.0 ships
   no L40S config for it, so serving uses the default. `kernel-bench/tune_moe.py`, output in
   `kernel-bench/tuned-configs/`. Linear (cutlass / torch / marlin / humming) and attention
   (TRITON_ATTN / FLASHINFER) kernels have no tunable configs in vLLM 0.29.0.
2. **Probe** every backend: `kernel-bench/probe.sh` starts vLLM once per backend and runs
   `bench_in_pod.py` (study 30's, plus a ShareGPT phase at 128 concurrent requests, the
   study's token mix) in the pod. Groups X- (MoE, incl. Triton tuned), L- (linear), A-/K-
   (attention, fp8 KV). No automatic admission rule (study 30's 15 % rule was dropped on
   2026-10-08: the probe's synthetic tokens are not the study's): the domains are decided on
   the numbers, `summarize.py` shows each backend against B-default.
3. **Study** (`akamas/2-Gemma4-L40S-Kernels.yaml`): the backends that start as categorical
   parameters (MoE auto/marlin/humming, tuned MoE configs, linear auto/torch/marlin/humming,
   attention auto/FLASHINFER), with `kv_cache_dtype` and the batch knobs
   (`gpu_memory_utilization`, `max_num_seqs`, `max_num_batched_tokens`). Study 30's goal,
   SLA, windowing and KPIs. Steps: baseline twice (vLLM's own choices: the repeat measures
   the noise), 5 RANDOM experiments, 60 AKAMAS experiments, 20 failures max. **No
   hand-picked presets** (decided 2026-10-08): the study is a demo of Akamas finding the
   configuration, so nothing in it comes from the probe's winners; the probe only decides
   which backends can start.

## Layout

```
kernel-bench/tune_moe.py        fused-MoE Triton tuning (vLLM's search space, Gemma 4's quantization)
kernel-bench/probe.sh           one vLLM start + benchmark per backend combination
kernel-bench/bench_in_pod.py    the in-pod benchmark (study 30's, plus a ShareGPT phase)
kernel-bench/summarize.py       one row per combination, against B-default
k8s/01-statefulset_template.yaml, render_statefulset.sh, apply_config.sh, lib_health.sh
                                vLLM serving, ported from study 30 (context gatling,
                                namespace llm-serving, node label gpu=l40s, MoE flags)
../src/vllmOpenLoopRamp.gatling.ts   the load: warm-up, ramp, in-generator watchdog
```

## Before starting the study

- [ ] `AlwaysOn=true` on BOTH node groups (`llm-serving-l40s` and `system`: the generator
      runs there), on the ASG with PropagateAtLaunch and on the running instances. The
      account's `StopEC2Instances` Lambda (EventBridge, 17:00 UTC daily) stops every instance
      without it and the ASG replaces it: a running trial dies. **Remove the tags when the
      study ends**: the Lambda is the safety net for a forgotten throwaway cluster.
- [ ] `moe_backend` available as a vLLM pack parameter (pack 1.12.0 has `linear_backend`,
      `attention_backend`, `tuned_kernel_configs`, not `moe_backend`).
- [ ] Gatling package re-deployed with `vllmOpenLoopRamp` (`k8s/deploy_enterprise.sh`), its
      simulation id in `/work/.gatling-env` on toolbox.

## Cluster notes

- Node group `llm-serving-l40s` (g6e.xlarge, us-east-2c, `gpu: l40s`, min 0). It shares
  `node-role: llm-serving` with the g5 group so dcgm-exporter covers it.
- Study 1's `vllm` Deployment in `llm-serving` must stay at 0 replicas: it selects
  `node-role: llm-serving` and would land on the L40S.
- The nightly stop Lambda (17:00 UTC) stops every instance without `AlwaysOn`, including
  this cluster's `system` node (replaced by the ASG every evening since 2026-10-05). Tag
  both node groups before an unattended run, or a trial dies at 17:00.
