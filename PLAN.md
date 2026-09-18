# Plan: run the Gatling Enterprise study on its own cluster

This study runs on a dedicated, throwaway EKS cluster rather than the shared
`vllm-bench` one: a Gatling Enterprise private location is an inbound channel, so anyone
with Gatling UI access could start a load run against whatever cluster it points at.
Akamas stays on the old cluster and drives this one remotely.

✅ = verified against the live clusters, not assumed.

---

## State

### Cluster `vllm-bench-gatling` (us-east-2) — up ✅

kubectl context `lab-vllm-bench-gatling`. Built by `infra/eks/provision.sh` from
`infra/eks/cluster.yaml`.

| | |
|---|---|
| node `system` | `m6i.2xlarge`, 7910m CPU / ~30 GiB allocatable — **UP** |
| nodegroup `llm-serving` | `g5.2xlarge` (1× A10G), **desired capacity 0** — scaled down to stop billing |
| namespaces | `llm-serving`, `llm-benchmark`, `monitoring` |
| StorageClasses | `gp3` (default, Retain), `gp3-ephemeral` (Delete) |
| monitoring | kube-prometheus-stack 91.4.1 + dcgm-exporter 4.8.3, all targets `up` ✅ |
| VPC | shared with `vllm-bench` (`vpc-098d70b16dd296bf3`) so Akamas can reach it privately |

Cost: ~$0.38/h with the GPU node down, ~$1.60/h with it up.

```bash
# GPU node up / down
eksctl scale nodegroup --cluster vllm-bench-gatling --region us-east-2 \
  --name llm-serving --nodes 1 --profile lab
```

### Akamas — on the old cluster ✅

Context `lab-vllm-bench`, namespace `akamas`, CLI only from the `toolbox` pod.

This study gets its **own** system, components and telemetry instance, per this lab's
one-system-per-study convention (16 systems exist, one per study). In Akamas components
and telemetry instances belong to a system, so a separate system means a fully
independent set:

| | This study (**to create**, A7) | August reference run | Concurrently-running study |
|---|---|---|---|
| system | `..._Gatling_Enterprise` | `..._Gatling` | `vLLM_Benchmark_15_Qwen3_30B_A3B` |
| telemetry → Prometheus on | `vllm-bench-gatling` (via NLB) | old cluster, in-cluster DNS | old cluster |
  
Defined in `akamas/enterprise/` (system, components, telemetry) — a copy of `akamas/`
bound to the new system name. **The August run's own objects are left untouched**: had we
reused its system, repointing its telemetry at the new cluster would leave that study
unable to be re-run against the cluster it was measured on.

### toolbox ✅

- two kubectl contexts: `default` → old cluster (**stays current**), `gatling` → new one
- on branch `feat/gatling-enterprise-dedicated-cluster`, with every Enterprise file and
  `akamas/id_rsa` in place
- `k8s/apply_config.sh` routes every call through `$KUBECTL` with an explicit
  `--context` (override with `KUBE_CONTEXT`) — verified it resolves to the new cluster
  while a bare `kubectl` still resolves to the old one ✅

> `aws eks update-kubeconfig` always makes the new context **current**. If it is ever
> re-run on toolbox, append `kubectl config use-context default` in the same command —
> otherwise another study's next "Apply config" lands on this cluster.

### Done

A1 toolbox cluster access · A2 branch on toolbox · A3 monitoring stack ·
A4 Prometheus exposed to Akamas · A5 Gatling control plane · A7 Akamas objects.

---

## Phase A — remaining, all doable with the GPU off

### A4. Expose Prometheus to Akamas — ✅ DONE

Internal NLB `a2e152afd47944cd6a9e3b27dcc70180-de2ee87c41d70dfd.elb.us-east-2.amazonaws.com`,
`Scheme: internal` on the three private subnets ✅, reachable from the toolbox pod on the
old cluster: `HTTP 200`, query round-trip ~64 ms ✅. Its hostname is now
`config.address` in `akamas/enterprise/telemetry/prometheus.yaml`.

**Cross-zone load balancing had to be enabled** — it is off by default and this is not an
optimisation. An NLB puts one node in every subnet it is given (three AZs here), but with
cross-zone off each node only reaches targets in its own AZ, and this cluster has a single
worker in one AZ. Two of the three NLB IPs therefore had no reachable target; DNS
round-robins across all three, so a client landing on a dead one stalled ~7 s
retransmitting SYNs before failing over. Measured from toolbox before the fix: connect
times of 7.50 / 0.003 / 0.002 / 5.00 / 7.50 s. After:
1.6–5 ms. The annotation is in `k8s/monitoring/prometheus-internal-lb.yaml`.

If the cluster is ever rebuilt, this is the first thing to re-check — it looks like it
works, just slowly and erratically, which is worse than an outright failure.

#### How it was done

```bash
kubectl --context=lab-vllm-bench-gatling apply -f k8s/monitoring/prometheus-internal-lb.yaml
kubectl --context=lab-vllm-bench-gatling get svc prometheus-akamas -n monitoring -w
```

The Service uses the **legacy** NLB annotations (`aws-load-balancer-type: nlb` +
`aws-load-balancer-internal: true`) on purpose: the AWS Load Balancer Controller is not
installed on either cluster ✅. The private subnets carry
`kubernetes.io/role/internal-elb: 1` ✅, so discovery works.

**Verify from Akamas, not from the new cluster.** Shared VPC gives routing, not
security-group permission — this is the most likely failure point:

```bash
kubectl --context=lab-vllm-bench -n akamas exec deploy/toolbox -- \
  curl -sS -m 5 http://<nlb-hostname>:9090/-/ready
```

If it hangs or is refused, open the new cluster's node SG to the old cluster's node SG
on 9090 — the NLB preserves the client IP in instance mode, so the node SG decides.

Then set that hostname as `config.address` in
`akamas/enterprise/telemetry/prometheus.yaml`, replacing the deliberately-invalid
`REPLACE_WITH_NLB_HOSTNAME_SEE_PLAN_A4` placeholder. The instance itself is created in A7,
so there is no update-in-place question to answer.

### A5. Gatling control plane — ✅ DONE

Installed and registered ✅. The pod logs confirm what matters:

```
Control plane version: 2026.38.4        Control plane ID: cp_akamas_demo
Configured locations:
  - Location prl_akamas_vllm_k8s [kubernetes]
Control plane status OK.                Starting to pull messages
```

Stable, 0 restarts. `Control plane status OK` means the token authenticated against
Gatling Enterprise; `prl_akamas_vllm_k8s` is the id `.gatling/package.conf` references.
Still worth confirming visually under Admin → Private Locations in the UI.

Needed only the `cpt_` token: `install.sh` checks for that Secret and nothing else, and
`control-plane.conf` references no team and no API token.

The token was passed as 400 characters — that is the same 200-character token pasted
twice ✅. Use **one half**.

```bash
kubectl --context=lab-vllm-bench-gatling create secret generic gatling-control-plane-token \
  -n llm-benchmark --from-literal=token="cpt_..."      # 200 chars, not 400
bash k8s/gatling-control-plane/install.sh              # KUBE_CONTEXT=... to override
```

`install.sh` now targets an explicit context (default `lab-vllm-bench-gatling`) rather
than whatever happens to be current — `llm-benchmark` exists on both clusters, so a bare
`kubectl` would install the control plane wherever the context pointed, without error.

`install.sh` refuses to run without the Secret. Then confirm `prl_akamas_vllm_k8s` appears
under Admin → Private Locations in the Gatling UI; if it does not register, nothing
downstream works.

`deployment.yaml` and `job.json` both select `node-role: system`, which matches this
cluster ✅ — the reason the combined node kept that label.

### A6. Deploy the Gatling package (one-time) — needs an API token

The only thing missing is a **Gatling Enterprise API token**: the **Configure** role to
deploy here, the **Start** role to trigger each trial (A6/Phase C). May be two tokens.
Note this is a different credential from the `cpt_` control-plane token, which is already
in place.

**The team name is NOT needed.** `team` is optional in the package descriptor: omitted, the
package goes to "the only team specified in the API Token", or "the only team in the
organization if the API Token has a global role". The placeholder has been removed from
`.gatling/package.conf` — leaving it would have failed, since it was a literal string.
Set `team` explicitly only if the deploy reports the team as ambiguous.

Needs Node, so from a dev machine, not toolbox:

```bash
GATLING_ENTERPRISE_API_TOKEN=... bash k8s/deploy_enterprise.sh
```

- copy the printed `test_...` simulation id
- paste the printed package `id` back into `.gatling/package.conf` so re-deploys update
  in place instead of creating duplicates
- `model = "qwen2.5-7b"` must match `--served-model-name` in
  `k8s/01-deployment_template.yaml` ✅ (they match today)

Then set on toolbox for user `akamas`: `GATLING_ENTERPRISE_API_TOKEN` (Start role) and
`GATLING_SIMULATION_ID=test_...`.

**Where to put them — measured on toolbox, not guessed.** Akamas opens a non-interactive
SSH session, and probing it with dummy variables gave:

| variable defined in | bare command (what Akamas does today) | wrapped in `bash -lc` |
|---|---|---|
| `~/.bashrc` | ❌ empty | ❌ empty |
| `~/.profile` | ❌ empty | ✅ set |

So **both** changes are needed, and either alone fails:

1. put the two variables in **`~/.profile`** — not `~/.bashrc`, which is the natural
   instinct and never works here (there is no `~/.bash_profile`, and `.profile` does not
   source `.bashrc`)
2. wrap the workflow's RunTest command as
   `bash -lc "bash /work/.../run_test_enterprise.sh"`

`/etc/environment` would avoid step 2 but is not writable by `akamas`, so it needs root
on the toolbox image.

Verify before the first run:
```bash
ssh akamas@toolbox 'bash -lc "echo [\$GATLING_SIMULATION_ID]"'
```
Empty brackets means the study dies on its first RunTest.

### A7. Create the system, components, telemetry, workflow and study — ✅ DONE

All created on 2026-09-18 ✅. Study `1-Goodput-Realistic-Load-Gatling-Enterprise` is
`CREATED`, bound to system `..._Gatling_Enterprise`, telemetry
`Prometheus_1_Goodput_Realistic_Load_Gatling_Enterprise` pointing at the new cluster's NLB.
Nothing here depends on the Gatling API token, so it was done ahead of A6.

Run from the toolbox pod (the Akamas CLI does not work from a dev machine here). Order
matters — components and telemetry reference the system, the study references both:

```bash
akamas create -f akamas/enterprise/system.yaml
akamas create -f akamas/enterprise/components/container.yaml
akamas create -f akamas/enterprise/components/gpu.yaml
akamas create -f akamas/enterprise/components/vllm.yaml
akamas create -f akamas/enterprise/telemetry/prometheus.yaml   # after A4 fills in address
akamas create -f akamas/1-Goodput-Realistic-Load-Gatling-Enterprise-Workflow.yaml
akamas create -f akamas/1-Goodput-Realistic-Load-Gatling-Enterprise.yaml
```

---

## Phase B — GPU on, validate before committing

Scale the GPU node up first (command above).

**B1. Sanity-check vLLM by hand.** `kubectl apply -f k8s/02-service.yaml`, render the
`${vLLM.*}` tokens in `01-deployment_template.yaml` and apply it. Confirm the GPU is
allocatable and the model loads (5–15 min first time; `vllm-model-cache` binds when the
pod mounts it). The template selects `node-role: llm-serving`, which matches ✅.

**B2. The `[DONE]` check — highest-risk item.** The simulation asserts
`substring("[DONE]").exists()`. A failed check marks the request KO, KOs feed the
5%-failure assertion, and that assertion failing exits non-zero — so if vLLM does not emit
the sentinel, **every trial fails**.

```bash
curl -sN http://vllm.llm-serving.svc.cluster.local:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-7b","messages":[{"role":"user","content":"hi"}],"max_tokens":16,"stream":true}' \
  | tail -3
```

Want `data: [DONE]` as the last line. If absent, set `check.streamDone=false` in
`package.conf` before deploying.

**B3. Short end-to-end run.** Temporarily add to `package.conf` systemProperties:
`"sweep.levels" = "2,4"`, `"sweep.durationSeconds" = "10"`. Deploy, trigger, confirm green
in Enterprise, then revert and re-deploy. Also proves `resources/prompts.json` ships inside
the Enterprise package and that `run_test_enterprise.sh` can fetch Gatling's CI zip and
authenticate against api.gatling.io from toolbox.

**B4. Confirm telemetry actually flows.** Run one trial and check
`vLLM.prefill_token_throughput` is non-zero in the Akamas UI. A silently-empty telemetry
instance would let the whole study run scoring nothing.

---

## Phase C — run it

```bash
akamas start study "1-Goodput-Realistic-Load-Gatling-Enterprise"
```

Target **~50 experiments**. At roughly an hour per trial that is a few days; size the
study's steps accordingly rather than inheriting the reference study's counts.

Then update the slides from the Gatling Enterprise dashboards and delete the cluster:

```bash
eksctl delete cluster --name vllm-bench-gatling --region us-east-2 --profile lab
```

---

## Risks

**~~The reference run failed 6 trials out of 14.~~ Investigated — it did not fail
anything.** The study listing's "# exp with errors: 6" counts experiments whose *goal
constraints* were violated, not experiments that broke. All 21 experiments of
`1-Goodput-Realistic-Load-Gatling` ran to completion; each of the six reports
`status FINISHED — the trial has completed successfully` alongside
`goal status CONSTRAINTS_VIOLATED`. The single `ABORTED` one (#21) is the study being
stopped at the end. So there is no unexplained breakage to carry into this run.

What the six *do* tell us is worth keeping: **all six violated the same constraint**,
`TTFT P95 interactive-chat SLA` (`vLLM.time_to_first_token_p95 <= 1500`). Not one tripped
the ITL constraint. Six of twenty experiments pushed past the TTFT ceiling while ITL never
bound — which is exactly the sort of signal the plan's own note about those thresholds
being unrecalibrated placeholders was waiting for. If the Enterprise run reproduces that
asymmetry, TTFT is the threshold to revisit, and the 300 ms ITL limit is doing nothing.

**Load-generator sizing is unverified** at 1024 concurrent closed-loop VUs on a JS event
loop. The node was sized at 8 vCPU so the generator can go from 4 CPU to 6–7 without
reprovisioning. If it saturates before vLLM does, top-of-sweep data is invalid — and likely
trips the 5% assertion.

**Monitoring shares the node with the load generator.** Accepted to keep the cluster
simple, but Prometheus scrape and compaction can add jitter to a p95 TTFT/ITL measurement.
First thing to suspect if top-of-sweep results look noisy; the fix is a separate
nodegroup for the generator.

**The DCGM queries in `akamas/telemetry/prometheus.yaml` filter the wrong label.** They use
`pod=~"$POD$"`, but in DCGM series `pod` is the *exporter* pod — the workload is under
`exported_pod`. Harmless with one vLLM per cluster, so it does not block this run, but it
means the `gpu` component's `pod` property does nothing. These queries are **ours**, not
the vLLM pack's (the `GPU` component type ships only metric names and units, no queries) ✅.

---

## Changes made to other people's scripts

Tracked here so they can be handed back to whoever owns the original. All are on branch
`feat/gatling-enterprise-dedicated-cluster`.

| File | Origin | Change | Why |
|---|---|---|---|
| `k8s/gatling-control-plane/job.json` | hhthacker, `924ff8b` | removed `spec.template.spec.restartPolicy: "Never"` (`c8fa778`) | The control plane validates this descriptor at boot and rejects the field — it sets the policy itself. With it present the container crash-looped and the private location never registered. Worth flagging upstream: `restartPolicy: Never` is mandatory in a normal Kubernetes Job, so this is a natural thing to write. |
| `k8s/gatling-control-plane/install.sh` | hhthacker, `924ff8b` | every `kubectl` now goes through `$KUBECTL` with an explicit `--context`, default `lab-vllm-bench-gatling`, override `KUBE_CONTEXT` (`d3532c2`) | It used bare `kubectl` against namespace `llm-benchmark`, which exists on **both** clusters — so it would have installed the control plane wherever the current context pointed, succeeding silently. Only needed because this study runs on a second cluster; not a defect in the original single-cluster setting. |
| `k8s/apply_config.sh` | Graziano, on `main` | same `$KUBECTL` + explicit `--context` treatment (`9f6c264`) | Same reason, higher stakes: run from toolbox, whose current context is the *old* cluster, it would have redeployed vLLM on top of another study's running experiment. |
| `.gatling/package.conf` | hhthacker, `924ff8b` | removed the `team = "<your Gatling Enterprise team>"` placeholder | `team` is optional and inferred from the API token; the placeholder is a literal string and would have failed the deploy. |

None of these are behaviour changes to the simulation or the study — they are cluster
targeting and descriptor validity.

---

## Open decisions

- **Gatling Enterprise API token** (Configure + Start roles) — blocks A6. The team
  name turned out not to be needed.
- **Merge this branch to `main`** once the run is proven.
- **Rotate `akamas/id_rsa`.** It was committed to this public repo in August and, although
  the history was rewritten, GitHub still serves it at the orphaned commit to anonymous
  callers. Out of scope for this run — it is shared with the other studies and one is
  running — but it should be scheduled.
