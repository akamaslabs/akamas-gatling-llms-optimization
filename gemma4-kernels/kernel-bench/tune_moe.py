"""Tune vLLM's Triton fused-MoE kernel for Gemma 4 26B-A4B FP8 on one L40S (study 2).

Runs inside the vllm/vllm-openai:v0.29.0 image and reuses vLLM's own tuning script
(/vllm-workspace/benchmarks/kernels/benchmark_moe.py) for its search space and config
sorting. It does NOT use that script's main() or benchmark_config():
- main() does not know Gemma4ForConditionalGeneration (get_model_params falls through to the
  Mixtral branch and looks for num_local_experts, which Gemma 4's config does not have);
- benchmark_config() quantizes as a per-tensor checkpoint (one weight scale per expert, a
  static activation scale). RedHatAI/gemma-4-26B-A4B-it-FP8-dynamic is per-channel weights
  with per-token dynamic activations, which is a different kernel epilogue and a different
  activation-quant step. Here the benchmark builds the same FusedMoEQuantConfig the model
  does (per_out_ch_quant, per_act_token_quant, no a1/a2 scale) and Gemma 4's activation
  (gelu_tanh, vllm/model_executor/models/gemma4.py).

vLLM looks the file up by E, N (= w2.shape[2], the intermediate size), the device and the
dtype only, so the per-channel tuning lands under the same name a per-tensor one would:
E=128,N=704,device_name=NVIDIA_L40S,dtype=fp8_w8a8.json. vLLM 0.29.0 ships no file for this
shape on L40S, so serving uses the default config. The serving pod reads the tuned file
through VLLM_TUNED_CONFIG_FOLDER (see ../k8s/01-statefulset_template.yaml).

Routing (--routing, tuning v2): the kernel's best tile size depends on how many tokens land on
each expert, and the router is skewed. Random gating (vLLM's benchmark, and this script
without --routing) is near uniform: v1 picked BLOCK_SIZE_M=16 up to M=256 and lost 9 % on a
real 64-request decode, while gaining 4 % on ShareGPT (README, "MoE tuning"). With --routing
each iteration takes one layer at random and M token rows at random from the experts the
model really picked on ShareGPT (capture_routing.py), and no BLOCK_SIZE_M is pruned.

Same approach as vllm-benchmark study 24's tune_fp8_block.py (Triton W8A8 block-FP8 for
the dense layers of Qwen3-8B on L4).
"""

import argparse
import json
import os
import sys
import time

import types  # noqa: E402

# The image has no ray. benchmark_moe imports it only for its multi-GPU worker class
# (@ray.remote) and a tqdm; neither is used here, so stub both before the import.
_ray = types.ModuleType("ray")
_ray.remote = lambda *a, **k: (lambda cls: cls)
_exp = types.ModuleType("ray.experimental")
_tq = types.ModuleType("ray.experimental.tqdm_ray")
_tq.tqdm = lambda it, *a, **k: it
sys.modules.update({"ray": _ray, "ray.experimental": _exp, "ray.experimental.tqdm_ray": _tq})

sys.path.insert(0, "/vllm-workspace/benchmarks/kernels")
import benchmark_moe as bench  # noqa: E402

import numpy as np  # noqa: E402
import torch  # noqa: E402
from vllm.model_executor.layers.fused_moe import fused_topk, override_config  # noqa: E402
from vllm.model_executor.layers.fused_moe.activation import MoEActivation  # noqa: E402
from vllm.model_executor.layers.fused_moe.config import fp8_w8a8_moe_quant_config  # noqa: E402
from vllm.model_executor.layers.fused_moe.fused_moe import (  # noqa: E402
    fused_experts,
    get_config_file_name,
)
from vllm.platforms import current_platform  # noqa: E402
from vllm.triton_utils import triton  # noqa: E402

FP8 = current_platform.fp8_dtype()

# google/gemma-4-26B-A4B-it text_config (checked on the RedHat FP8 checkpoint, 2026-10-08):
# num_experts 128, top_k_experts 8, moe_intermediate_size 704, hidden_size 2816. TP=1.
E, TOPK, N, K = 128, 8, 704, 2816

# M = tokens in one forward step: one per decoding sequence plus the prompt tokens scheduled
# in that step. With ShareGPT (prompts of 41 tokens median, 794 p99 with Gemma 4's tokenizer)
# at 10-20 req/s a step holds ~100-600 tokens, rarely ~1000; vLLM uses the config of the
# closest tuned M, so 2048 covers everything above. Larger M (long prompts, as study 27's
# 4096-token ones) cost ~2 h more: pass --batch-sizes 4096,8192,16384 if a load needs them.
DEFAULT_BATCH_SIZES = [
    1, 2, 4, 8, 16, 24, 32, 48, 64, 96, 128, 256, 512, 1024, 2048,
]
# Two-stage search: every config is screened with SCREEN_ITERS, the best FINALISTS are
# measured again with vLLM's 20 iterations and the winner is picked on that measure only.
SCREEN_ITERS, FINALISTS = 2, 20


ROUTING = None  # (T, layers, top_k) uint8 from capture_routing.py, or None for random gating


def real_topk(m, num_iters, seed=0):
    """num_iters (topk_ids) samples of M tokens: one random layer each, M random token rows."""
    g = np.random.default_rng(seed + m)
    t, layers, _ = ROUTING.shape
    return [torch.from_numpy(ROUTING[g.integers(0, t, m), g.integers(0, layers)].astype(np.int32))
            for _ in range(num_iters)]


def bench_one(config, m, num_iters=20):
    """Mean time (us) of one fused-MoE call on Gemma 4's shapes with config. Mirrors
    benchmark_moe.benchmark_config's timing (CUDA graph of 10 calls), with the model's
    quantization and activation."""
    dtype = torch.bfloat16
    x = torch.randn(m, K, dtype=dtype)
    w1 = torch.randn(E, 2 * N, K, dtype=torch.float16).to(FP8)
    w2 = torch.randn(E, K, N, dtype=torch.float16).to(FP8)
    # Per output channel weight scales, as the compressed-tensors FP8 MoE method holds them.
    w1_scale = torch.rand(E, 2 * N, 1, dtype=torch.float32) * 1e-2
    w2_scale = torch.rand(E, K, 1, dtype=torch.float32) * 1e-2
    quant_config = fp8_w8a8_moe_quant_config(
        w1_scale=w1_scale,
        w2_scale=w2_scale,
        a1_scale=None,
        a2_scale=None,
        per_act_token_quant=True,
        per_out_ch_quant=True,
    )
    if ROUTING is not None:
        # The model's own routing; the weights do not change the kernel's time.
        samples = real_topk(m, num_iters)
        topk_ids = samples[0].cuda().clone()
        topk_weights = torch.full((m, TOPK), 1.0 / TOPK, dtype=torch.float32)

        def prepare(i):
            topk_ids.copy_(samples[i])

        def run():
            with override_config(config):
                return fused_experts(
                    x, w1, w2, topk_weights, topk_ids,
                    activation=MoEActivation.GELU_TANH, quant_config=quant_config,
                )
    else:
        gating = torch.randn(num_iters, m, E, dtype=torch.float32)
        input_gating = torch.empty(m, E, dtype=torch.float32)

        def prepare(i):
            input_gating.copy_(gating[i])

        def run():
            with override_config(config):
                topk_weights, topk_ids, _ = fused_topk(x, input_gating, TOPK, renormalize=True)
                return fused_experts(
                    x, w1, w2, topk_weights, topk_ids,
                    activation=MoEActivation.GELU_TANH, quant_config=quant_config,
                )

    prepare(0)
    run()
    torch.accelerator.synchronize()
    graph = torch.cuda.CUDAGraph()
    with torch.cuda.graph(graph):
        for _ in range(10):
            run()
    torch.accelerator.synchronize()
    for _ in range(5):
        graph.replay()
    torch.accelerator.synchronize()
    start, end = torch.Event(enable_timing=True), torch.Event(enable_timing=True)
    lat = []
    for i in range(num_iters):
        prepare(i)
        torch.accelerator.synchronize()
        start.record()
        graph.replay()
        end.record()
        end.synchronize()
        lat.append(start.elapsed_time(end))
    graph.reset()
    return sum(lat) / (num_iters * 10) * 1000


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--save-path", default="/out")
    p.add_argument("--batch-sizes", default=",".join(map(str, DEFAULT_BATCH_SIZES)),
                   help="comma-separated M values; a short list for a smoke run")
    p.add_argument("--routing", default=None,
                   help="routing.npy from capture_routing.py: real expert choices, no pruning")
    p.add_argument("--max-configs", type=int, default=0,
                   help="only the first N configs of the search space (smoke run)")
    args = p.parse_args()

    global ROUTING
    if args.routing:
        ROUTING = np.load(args.routing)
        print(f"routing: {ROUTING.shape} real token rows (layers x top_k), no BLOCK_SIZE_M pruning", flush=True)
    torch.set_default_device("cuda")
    batch_sizes = [int(x) for x in args.batch_sizes.split(",")]
    space = bench.get_configs_compute_bound(False, None)
    if args.max_configs:
        space = space[: args.max_configs]
    name = get_config_file_name(E, N, "fp8_w8a8", None)
    os.makedirs(args.save_path, exist_ok=True)
    out_file = os.path.join(args.save_path, name)
    print(f"device {torch.cuda.get_device_name()}, {len(space)} configs x {len(batch_sizes)} M -> {name}", flush=True)

    best = {}
    # The default config's time at each M, for the gain the tuning buys.
    default_us = {}
    from vllm.model_executor.layers.fused_moe.fused_moe import get_default_config
    t_all = time.time()
    for m in batch_sizes:
        t0 = time.time()
        try:
            dflt = get_default_config(m, E, N, K, TOPK, "fp8_w8a8", None)
            default_us[m] = bench_one(dflt, m)
        except Exception as e:  # noqa: BLE001  the default may need arguments this version renamed
            print(f"M={m}: default config not measured ({e})", flush=True)
        # Routed tokens per expert ~ M * topk / E. A BLOCK_SIZE_M above twice that (16 at
        # least) only computes padding rows, so it cannot win: skip it. Cuts small-M runs
        # from 1920 configs to a few hundred; from M=512 on nothing is skipped.
        cap = max(16, 2 * triton.next_power_of_2(max(1, m * TOPK // E)))
        if ROUTING is not None:  # real routing is skewed: the uniform estimate does not hold
            cap = 1 << 30
        screened = []
        for c in (c for c in space if c["BLOCK_SIZE_M"] <= cap):
            try:
                screened.append((bench_one(c, m, num_iters=SCREEN_ITERS), c))
            except triton.runtime.autotuner.OutOfResources:
                continue
        screened.sort(key=lambda tc: tc[0])
        best_t, best_c = min(
            ((bench_one(c, m), c) for _, c in screened[:FINALISTS]), key=lambda tc: tc[0]
        )
        best[m] = bench.sort_config(best_c)
        d = default_us.get(m)
        gain = f", default {d:.1f} us ({(best_t / d - 1) * 100:+.1f} %)" if d else ""
        print(f"M={m}: {best[m]} {best_t:.1f} us{gain} ({time.time() - t0:.0f} s)", flush=True)
        # Written after every M, so an interrupted run keeps what it measured.
        with open(out_file, "w") as f:
            json.dump({str(k): v for k, v in best.items()}, f, indent=4)
            f.write("\n")
    print(f"done in {time.time() - t_all:.0f} s: {out_file}", flush=True)


if __name__ == "__main__":
    main()
