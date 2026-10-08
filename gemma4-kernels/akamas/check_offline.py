"""Offline checks of study 2's Akamas files (run from gemma4-kernels/: python3 akamas/check_offline.py).

- every vllm token of k8s/params.env.template is in parametersSelection, and vice versa
  (the workflow's FileConfigurator runs with ignoreUnsubstitutedTokens false);
- every selected parameter exists in the local vLLM pack checkout, its domain and categories
  inside the pack's (PACK env var, default the optimization-packs/vllm checkout);
- every baseline/preset renders every parameter, inside its domain, satisfying the study's
  parameterConstraints, and through the real k8s/render_statefulset.sh;
- at most 8 KPIs.
Exit code 1 on any failure. Ported in spirit from vllm-benchmark study 30's check_offline.py.
"""
import os
import re
import subprocess
import sys
import tempfile

import yaml

PACK = os.environ.get('PACK', os.path.expanduser('~/workspace/akamas/optimization-packs/vllm'))
st = yaml.safe_load(open('akamas/2-Gemma4-L40S-Kernels.yaml'))
ct = {p['name']: p for p in yaml.safe_load(open(f'{PACK}/component-types/vllm.yaml'))['parameters']}
tpl = open('k8s/params.env.template').read()
sel = {p['name']: p for p in st['parametersSelection']}
failures = []


def bad(msg):
    failures.append(msg)
    print('FAIL', msg)


tokens = set(re.findall(r'\$\{(vllm\.[a-z_]+)\}', tpl))
if tokens != set(sel):
    bad(f'template tokens vs parametersSelection: {sorted(tokens ^ set(sel))}')
for n, p in sel.items():
    pk = ct.get(n.split('.', 1)[1])
    if not pk:
        bad(f'{n} is not a parameter of the pack')
        continue
    d = pk['domain']
    if 'categories' in p and not set(p['categories']) <= set(map(str, d['categories'])):
        bad(f'{n} categories outside the pack')
    if 'domain' in p and (p['domain'][0] < d['domain'][0] or p['domain'][1] > d['domain'][1]):
        bad(f'{n} domain outside the pack {d["domain"]}')

for s in st['steps']:
    v = s.get('values')
    if v is None:
        continue
    if set(v) != set(sel):
        bad(f'step {s["name"]} does not render exactly the selected parameters: {sorted(set(v) ^ set(sel))}')
        continue
    for n, x in v.items():
        p = sel[n]
        if 'categories' in p and str(x) not in p['categories']:
            bad(f'{s["name"]}: {n}={x} not in the categories')
        if 'domain' in p and not p['domain'][0] <= x <= p['domain'][1]:
            bad(f'{s["name"]}: {n}={x} outside the domain')
    g = lambda k: str(v['vllm.' + k])  # noqa: E731
    if not v['vllm.max_num_batched_tokens'] >= v['vllm.max_num_seqs']:
        bad(f'{s["name"]}: max_num_batched_tokens < max_num_seqs')
    if not (g('tuned_kernel_configs') == 'false' or g('moe_backend') == 'auto'):
        bad(f'{s["name"]}: tuned configs without the Triton experts')
    if not (g('attention_backend') != 'FLASHINFER' or g('kv_cache_dtype') == 'auto'):
        bad(f'{s["name"]}: FLASHINFER with an fp8 KV cache')
    env = tpl
    for n, x in v.items():
        env = env.replace('${' + n + '}', str(x))
    with tempfile.TemporaryDirectory() as d:
        open(f'{d}/p.env', 'w').write(env)
        r = subprocess.run(['bash', 'k8s/render_statefulset.sh', f'{d}/p.env',
                            'k8s/01-statefulset_template.yaml', f'{d}/s.yaml'],
                           capture_output=True, text=True)
        if r.returncode:
            bad(f'{s["name"]}: render failed: {r.stderr.strip()}')
            continue
        y = open(f'{d}/s.yaml').read()
        yaml.safe_load(y)
        flags = [l.strip()[3:-1] for l in y.splitlines()
                 if l.strip().startswith('- "--') and ('backend' in l or 'kv-cache' in l)]
        tuned = '  +VLLM_TUNED_CONFIG_FOLDER' if 'name: VLLM_TUNED_CONFIG_FOLDER' in y else ''
        print(f'ok   {s["name"]:26s} {" ".join(flags)}{tuned}')

if len(st['kpis']) > 8:
    bad(f'{len(st["kpis"])} KPIs (at most 8)')
print(f'{len(failures)} failure(s)')
sys.exit(1 if failures else 0)
