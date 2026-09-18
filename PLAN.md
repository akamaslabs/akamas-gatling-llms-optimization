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

This study has its **own** system, components and telemetry instance — in Akamas these
belong to a system, so nothing is shared with any other study:

| | This study | The concurrently-running study, for contrast |
|---|---|---|
| system | `vLLM_Benchmark_1_Goodput_Realistic_Load_Gatling` | `vLLM_Benchmark_15_Qwen3_30B_A3B` |
| components | `container`, `gpu`, `vLLM` | `cluster`, `container`, `gpu0`…`gpu3`, … |
| telemetry | `Prometheus_1_Goodput_Realistic_Load_Gatling` | `Prometheus_15_Qwen3_30B_A3B` |

Editing ours cannot affect theirs. Our telemetry instance's `address` still points at
in-cluster DNS and is repointed in A4.

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

A1 toolbox cluster access · A2 branch on toolbox · A3 monitoring stack.

---

## Phase A — remaining, all doable with the GPU off

### A4. Expose Prometheus to Akamas, repoint the telemetry instance

The one genuinely new piece of engineering: no equivalent exists in a single-cluster setup.

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

Then set that hostname as `config.address` in `akamas/telemetry/prometheus.yaml` and
re-apply. **To determine:** whether `akamas create` updates a telemetry instance in place
or requires delete-then-create.

### A5. Gatling control plane

Blocked on two unknowns (ask Graziano):

- the **team name** for `.gatling/package.conf` — an unfilled placeholder; package deploy
  fails until it is set
- API token roles: **Configure** to deploy, **Start** to trigger each trial. May need two.

The control plane token we have. It was passed as 400 characters — that is the same
200-character token pasted twice ✅. Use **one half**.

```bash
kubectl --context=lab-vllm-bench-gatling create secret generic gatling-control-plane-token \
  -n llm-benchmark --from-literal=token="cpt_..."      # 200 chars, not 400
bash k8s/gatling-control-plane/install.sh
```

`install.sh` refuses to run without the Secret. Then confirm `prl_akamas_vllm_k8s` appears
under Admin → Private Locations in the Gatling UI; if it does not register, nothing
downstream works.

`deployment.yaml` and `job.json` both select `node-role: system`, which matches this
cluster ✅ — the reason the combined node kept that label.

### A6. Deploy the Gatling package (one-time)

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

**Check they survive a non-interactive SSH**, which is how Akamas invokes them — a
non-login shell does not source `~/.bashrc`:

```bash
ssh akamas@toolbox 'echo "[$GATLING_SIMULATION_ID]"'
```

Empty brackets means the study dies on its first RunTest. Cleanest fix without touching
the script: wrap the workflow command as `bash -lc "bash /work/.../run_test_enterprise.sh"`.

### A7. Create the workflow and the study

From the toolbox pod (the Akamas CLI does not work from a dev machine here):

```bash
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

**The reference run failed 6 trials out of 14.** `1-Goodput-Realistic-Load-Gatling`,
FINISHED 2026-08-17, unexplained. The Enterprise path adds two new ways to fail (the 5%
assertion and the `[DONE]` check), so whatever caused those 6 will likely cause more.
Worth 20 minutes on that study's failed experiments before launching.

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

## Open decisions

- **Gatling team name and API token roles** — blocks A5 and A6.
- **Merge this branch to `main`** once the run is proven.
- **Rotate `akamas/id_rsa`.** It was committed to this public repo in August and, although
  the history was rewritten, GitHub still serves it at the orphaned commit to anonymous
  callers. Out of scope for this run — it is shared with the other studies and one is
  running — but it should be scheduled.
