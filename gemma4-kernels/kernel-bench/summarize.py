"""Kernel probe summary for study 2: one row per combination, from <dir>/<name>.json.

Ported from vllm-benchmark study 30's probe/summarize.py. Each started combination is shown
with its startup time, prefill step (median of 4, ~2000-token prompt), tokens/s per request
at batch 1, generated tokens/s at 64 concurrent long decodes, and total tokens/s of the
ShareGPT phase, and against B-default (positive = better). Usage: summarize.py <results dir>
"""
import glob
import json
import os
import statistics
import sys

rows = {json.load(open(p))['name']: json.load(open(p)) for p in sorted(glob.glob(os.path.join(sys.argv[1], '*.json')))}
ok = {n: r for n, r in rows.items() if r.get('started') and r.get('bench')}
# The prefill step is the MEDIAN of its 4 samples, not the mean: on 2026-10-06 one sample in
# four took ~0.9 s instead of ~0.1 s in 4 combinations out of 8 (first use of a new batch
# shape), which tripled the mean and made identical kernels look 3x apart.
for r in ok.values():
    if r['bench'].get('prefill_s'):
        r['bench']['summary']['prefill_mean_s'] = statistics.median(r['bench']['prefill_s'])
def pct(x):
    return '%+.0f%%' % (100 * x) if x is not None else 'n/a'


# Study 2: no admission rule (decided with the user 2026-10-08: the probe's synthetic token
# mix is not the study's). Every backend is shown against B-default on three measures:
# prefill step, 64 concurrent long decodes, and the ShareGPT phase (the study's token mix).
ref = ok.get('B-default', {}).get('bench', {}).get('summary')


def vs(s, k, lower_is_better=False):
    if not ref or s.get(k) is None or not ref.get(k):
        return 'n/a'
    x = s[k] / ref[k] - 1
    return pct(-x if lower_is_better else x)


print('%-17s %7s %7s %8s %9s %10s   %-22s %s' % (
    'name', 'start_s', 'pf_s', 'tok/s@1', 'tok/s@64', 'sgpt tok/s', 'vs default pf/@64/sgpt', 'overrides'))
for n, r in rows.items():
    if n not in ok:
        print('%-17s did not start (apply exit %s)  %s' % (n, r.get('apply_exit'), r.get('overrides')))
        continue
    s = r['bench']['summary']
    sg = s.get('sharegpt_c128_total_tok_per_s')
    print('%-17s %7d %7.3f %8.1f %9.0f %10s   %-22s %s' % (
        n, r['startup_s'], s['prefill_mean_s'], s['tok_per_s_single'], s['c64_gen_tok_per_s'],
        '%.0f' % sg if sg else '-',
        '/'.join((vs(s, 'prefill_mean_s', True), vs(s, 'c64_gen_tok_per_s'), vs(s, 'sharegpt_c128_total_tok_per_s'))),
        r.get('overrides')))
