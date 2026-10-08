"""Runs inside vllm-0 (study 2), started with --enable-return-routed-experts. Records the
experts Gemma 4's router really picks on ShareGPT traffic, for tune_moe.py --routing.

Sends ShareGPT prompts (/tmp/prompts.json, the load generator's corpus) with their own
max_tokens, 16 at a time, and decodes each response's `routed_experts` field (vLLM 0.29.0:
base64 .npy, shape (tokens - 1, layers, top_k), prompt and generated tokens alike). Writes
/tmp/routing.npy: all requests' rows concatenated, uint8, shape (T, 30, 8).

Why: the fused-MoE kernel's best tile size depends on how many tokens land on each expert,
and the router is skewed (hot experts). vLLM's benchmark_moe draws random gating, i.e. near
uniform routing: tokens per expert in the benchmark differ from serving (at M=64 the most
loaded expert gets ~10 tokens with random gating, ~21 with the real router). Whether this
changes the end-to-end result is open: README, "MoE tuning".
"""
import base64
import io
import json
import random
import sys
import threading
import urllib.request

import numpy as np

URL = 'http://127.0.0.1:8000/v1/chat/completions'
MODEL = 'gemma4-26b-l40s'
N = int(sys.argv[1]) if len(sys.argv) > 1 else 400
rows = json.load(open('/tmp/prompts.json'))
rnd = random.Random(30)
picked = [rows[rnd.randrange(len(rows))] for _ in range(N)]
out, lock, errors = [], threading.Lock(), [0]


def worker(chunk):
    for r in chunk:
        body = {'model': MODEL, 'messages': [{'role': 'user', 'content': r['prompt']}],
                'max_tokens': r['max_tokens']}
        try:
            resp = json.loads(urllib.request.urlopen(urllib.request.Request(
                URL, json.dumps(body).encode(), {'Content-Type': 'application/json'}), timeout=600).read())
            a = np.load(io.BytesIO(base64.b64decode(resp['choices'][0]['routed_experts'])))
        except Exception as e:  # count and go on: a few lost requests do not bias the sample
            with lock:
                errors[0] += 1
                if errors[0] <= 3:
                    print('request failed:', repr(e)[:300], flush=True)
            continue
        with lock:
            out.append(a.astype(np.uint8))


ts = [threading.Thread(target=worker, args=(picked[i::16],)) for i in range(16)]
[t.start() for t in ts]
[t.join() for t in ts]
allr = np.concatenate(out)
np.save('/tmp/routing.npy', allr)
# Skew check: share of the routed slots taken by the 8 / 16 most used experts, per layer.
counts = np.stack([np.bincount(allr[:, l, :].ravel(), minlength=128) for l in range(allr.shape[1])])
srt = -np.sort(-counts, axis=1) / counts.sum(axis=1, keepdims=True)
print(json.dumps({'requests': len(out), 'failed': errors[0], 'shape': list(allr.shape),
                  'top8_share_median': float(np.median(srt[:, :8].sum(1))),
                  'top16_share_median': float(np.median(srt[:, :16].sum(1))),
                  'uniform_top8_share': 8 / 128}))
