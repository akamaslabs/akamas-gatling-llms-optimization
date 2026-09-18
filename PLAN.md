# Plan: run the Gatling Enterprise study on its own cluster

Everything below marked ✅ is verified against the new gatling clusters, not assumed.

---

## Where we are

### The new cluster — provisioned and healthy ✅

`vllm-bench-gatling` (us-east-2), kubectl context **`lab-vllm-bench-gatling`**.
Created by `infra/eks/provision.sh` from `infra/eks/cluster.yaml`.

| | |
|---|---|
| node `system` | `m6i.2xlarge`, 7910m CPU / ~30 GiB allocatable — **UP** |
| nodegroup `llm-serving` | `g5.2xlarge` (1× A10G), `ACTIVE` with **desired capacity 0** — scaled down to stop billing |
| namespaces | `llm-serving`, `llm-benchmark`, `monitoring` |
| StorageClasses | `gp3` (default, Retain), `gp3-ephemeral` (Delete) |
| NVIDIA device plugin | installed; GPU showed `nvidia.com/gpu: 1` allocatable before scale-down |
| EBS CSI | addon `ACTIVE` with its IRSA role; OIDC provider present in IAM |
| VPC | **shared with `vllm-bench`** (`vpc-098d70b16dd296bf3`) so Akamas can reach it privately |

Cost while the GPU node is down: ~\$0.38/h. With it up: ~\$1.60/h.

Scale the GPU node back up with:
```bash
eksctl scale nodegroup --cluster vllm-bench-gatling --region us-east-2 \
  --name llm-serving --nodes 1 --profile lab
```

### Akamas — stays where it is ✅

Akamas keeps running on the **old** `vllm-bench` cluster (context `lab-vllm-bench`,
namespace `akamas`) and drives the new cluster remotely. It holds 28 studies of history.

**This study has its own dedicated system, components and telemetry instance. Nothing
here is shared with, or reused from, any other study — least of all the one currently
running.** In Akamas, components and telemetry instances belong to a system, so a
separate system means a separate, independent set of them. They already exist ✅ (created
for the `main`-branch run in August) and are reused *from that run*, not from anyone
else's:

| Object | This study | The currently-running study, for contrast |
|---|---|---|
| system | `vLLM_Benchmark_1_Goodput_Realistic_Load_Gatling` | `vLLM_Benchmark_15_Qwen3_30B_A3B` |
| components | `container`, `gpu`, `vLLM` | `cluster`, `cluster_loadtest`, `container`, `container_loadtest`, `gpu0`…`gpu3` |
| telemetry | `Prometheus_1_Goodput_Realistic_Load_Gatling` | `Prometheus_15_Qwen3_30B_A3B` |

Two different systems, two different sets of objects, two different Prometheus endpoints
once step A4 is done. Editing ours cannot affect theirs — which is also why the
cross-study metric-scoping problem that would have existed on a shared cluster is moot
here (see Risks).

**The one thing that must change**: our telemetry instance's `address` still points at
in-cluster DNS on the old cluster and must be repointed at the new cluster's Prometheus
(step A4). Theirs stays untouched.

Missing, to be created: the Enterprise **workflow** and the Enterprise **study**.
(`akamas/1-Goodput-Realistic-Load-Gatling-Enterprise.yaml` exists locally, untracked.
Its workflow file lives only on the `feat/enterprise-private-locations` branch.)

### The reference run

`1-Goodput-Realistic-Load-Gatling` — FINISHED 2026-08-17, 22h 58m, 14 experiments,
**6 of them with errors**. That failure rate is worth understanding before launching
(see Risks), because the Enterprise path adds assertions that make trials fail *more*
readily, not less.

---

## The blocker

**toolbox can only talk to the old cluster.** ✅ Verified: its only kubectl context is
`default` → cluster `in-cluster` → the ServiceAccount `akamas`, and that SA is
effectively cluster-admin there (`kubectl auth can-i '*' '*'` → yes).

Every Akamas workflow task SSHes into toolbox and runs `kubectl` with **no `--context`**.
`k8s/apply_config.sh` ends with:

```bash
kubectl apply -f "$DEPLOY_FILE" -n llm-serving
kubectl rollout status deployment/vllm -n llm-serving --timeout=1200s
```

Run as-is today, that deploys this study's vLLM **onto the old cluster**, on top of the
vLLM another study is measuring. It would not error — it would silently succeed against
the wrong cluster. This must be fixed before the first trial, and it is step A1.

Good news on the plumbing, both verified:

- toolbox has AWS credentials via its node instance role
  (`...nodegroup-akamas-NodeInstanceRole-LtJYj38B4zBK`) ✅
- the new cluster's API endpoint is reachable from toolbox — `curl` returns HTTP 401,
  i.e. it reached the API server and was merely unauthenticated ✅
- toolbox has `kubectl`, `aws`, `helm`, `curl`, `jq`, `unzip`, `git`, `ssh`; it does
  **not** have `node`, which is fine — `run_test_enterprise.sh` deliberately needs no
  Node (only the one-time `deploy_enterprise.sh` does, and that runs from a dev machine) ✅

---

## Phase A — everything that can be done with the GPU off

Do all of this before scaling the GPU node back up. None of it needs the GPU, and the
node costs ~$1.2/h while it runs.

### A1. Give toolbox access to the new cluster, and make it explicit — ✅ DONE

Done 2026-09-18. Verified end state:

- toolbox's kubeconfig (`/work/.kube/config`, on the PVC — `/home/akamas/.kube` is a
  symlink to it, so it survives pod restarts ✅) now has **two** contexts:
  `default` → old `vllm-bench`, `gatling` → new `vllm-bench-gatling`
- **current context is and stays `default`** ✅ — a bare `kubectl` on toolbox still hits
  the old cluster, so nothing else that uses toolbox changes behaviour
- `kubectl --context gatling` reaches the new cluster and can create Deployments in
  `llm-serving` ✅
- `k8s/apply_config.sh` now routes every call through `$KUBECTL` with an explicit
  `--context`, overridable via `KUBE_CONTEXT`

**Gotcha, hit and worth remembering:** `aws eks update-kubeconfig` **always sets the new
context as current**. On a toolbox shared with other running studies that is actively
dangerous for the ~seconds it lasts — the other study's next "Apply config" would deploy
its vLLM onto *our* cluster. If you ever re-run it, put `kubectl config use-context
default` in the same command. (It happened here; nothing leaked — verified the new
cluster's `llm-serving` namespace stayed empty and no rollout occurred in the window.)

The commands that were run, for the record:

Grant the toolbox node role an EKS access entry:

```bash
ROLE=arn:aws:iam::916205288457:role/eksctl-vllm-bench-nodegroup-akamas-NodeInstanceRole-LtJYj38B4zBK

aws eks create-access-entry --cluster-name vllm-bench-gatling --region us-east-2 \
  --profile lab --principal-arn "$ROLE" --type STANDARD

aws eks associate-access-policy --cluster-name vllm-bench-gatling --region us-east-2 \
  --profile lab --principal-arn "$ROLE" --access-scope type=cluster \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy
```

Then on toolbox, adding the context **without** leaving it selected:
```bash
aws eks update-kubeconfig --name vllm-bench-gatling --region us-east-2 --alias gatling
kubectl config use-context default
```

**Trade-off accepted knowingly:** this grants the *node* instance role access, so any
pod on that node can reach the new cluster via IMDS. Acceptable for a throwaway lab
cluster; if that is not acceptable, the alternative is a dedicated ServiceAccount in the
new cluster plus a long-lived token kubeconfig on toolbox — more setup, no IMDS exposure.

**Verification** — the first must print the OLD cluster's 3 nodes, the second the NEW
cluster's single `system` node:
```bash
kubectl --context=lab-vllm-bench -n akamas exec deploy/toolbox -- kubectl get nodes -L node-role
kubectl --context=lab-vllm-bench -n akamas exec deploy/toolbox -- kubectl --context gatling get nodes -L node-role
```

### A2. Get the branch onto toolbox — ⚠️ PARTIAL

toolbox is now on `feat/enterprise-private-locations` at `1ec4a08` ✅, which brings every
Enterprise file it needs: `run_test_enterprise.sh`, `deploy_enterprise.sh`,
`.gatling/package.conf`, all of `k8s/gatling-control-plane/`, the Enterprise workflow
YAML, and `01-deployment_template.yaml` ✅.

Our own branch `feat/gatling-enterprise-dedicated-cluster` (commit `9f6c264`) could **not**
be pushed: `stefanocereda` has only `pull` on this repo — org membership alone grants no
repo access, and no commit here was ever authored by them. Waiting on an admin (Graziano)
to grant Write.

**Three things are therefore still missing on toolbox, and two of them are blocking:**

1. ~~**`akamas/id_rsa`**~~ — ✅ RESOLVED. Restored from history and verified: `ssh -i` on
   port 2222 authenticates to toolbox as `akamas`. It was deleted by the branch switch: it
   was a
   *tracked* file at `b3b6798` (the commit toolbox sat on) and is untracked from `3bb4ad8`
   onward (the security scrub), so checking out the Enterprise branch removed it. Every
   workflow task authenticates with it at
   `/work/akamas-gatling-llms-optimization/akamas/id_rsa`; without it every task fails to
   SSH. Restore from history:
   ```bash
   kubectl --context=lab-vllm-bench -n akamas exec deploy/toolbox -- bash -lc \
     'cd /work/akamas-gatling-llms-optimization && \
      git show b3b6798:akamas/id_rsa > akamas/id_rsa && chmod 600 akamas/id_rsa'
   ```
   Note it is now gitignored, so once restored it survives further branch switches.

   Two gotchas met while verifying, worth recording:
   - **The file has no trailing newline**, so the OpenSSH *CLI* rejects it with
     `Load key: error in libcrypto`. That is not a corrupt key — it is byte-identical to
     the copies every other study uses, including the one running right now, and Akamas'
     own SSH library accepts it. Do not "fix" it; verify with a newline-added *copy*
     instead, which authenticates fine.
   - toolbox's sshd listens on **port 2222**, not 22 (the `toolbox` Service maps 22 → it).
     Any manual `ssh` test needs `-p 2222`.

   Side note, pre-existing and not fixed by the scrub: the key is still retrievable from
   git history at `b3b6798` — untracking removed it from the tip, not from the past, and
   `main` was force-pushed so that commit is now orphaned but still in local object
   stores. The key should be rotated at some point.

2. **`k8s/apply_config.sh` has no `--context`** — the A1 fix lives only on our unpushed
   branch. Until it lands, the copy on toolbox targets whatever context is current, i.e.
   the **old** cluster. **Do not start the study before this is on toolbox**: the first
   trial would reconfigure the vLLM another study is measuring, and would succeed quietly
   while doing it.

3. `akamas/1-Goodput-Realistic-Load-Gatling-Enterprise.yaml` (the study definition) is
   also only on our branch — needed for A7, not before.

`k8s/monitoring/` is likewise absent there, but that is fine: the helm commands in A3 run
from a dev machine against `--context lab-vllm-bench-gatling`, not from toolbox.

#### Original notes

toolbox's checkout is at `/work/akamas-gatling-llms-optimization`, currently on **`main`**
at `b3b6798` ✅ — behind local `main` and missing the Enterprise files entirely.

`run_test_enterprise.sh`, `k8s/gatling-control-plane/` and `.gatling/package.conf` exist
only on `feat/enterprise-private-locations`. Either merge that branch to `main` or check
it out at that path on toolbox. Also push the currently-untracked local work (`infra/`,
`k8s/monitoring/`, the Enterprise study YAML) so toolbox can see it.

### A3. Monitoring stack on the new cluster — ✅ DONE

Done 2026-09-18, run from a dev machine with `--kube-context=lab-vllm-bench-gatling`
(not from toolbox — these need only helm + the files in this repo).

- `kube-prometheus-stack` 91.4.1 (Prometheus operator v0.94.0) — **deployed** ✅.
  6 pods Running, all on the `system` node: Prometheus, Grafana, alertmanager,
  operator, kube-state-metrics, node-exporter.
- `dcgm-exporter` 4.8.3 — **deployed** ✅, DaemonSet at **0/0** with
  `nodeSelector node-role=llm-serving`. Correct, not a failure: the GPU node is scaled
  to zero. It will schedule the moment that node comes back.
- `servicemonitor.yaml` (vLLM) applied ✅ — 15 ServiceMonitors total.
- PVCs **Bound**: Grafana 10Gi, Prometheus 20Gi, both on `gp3` ✅. This also proves the
  EBS CSI driver's IRSA role works end to end, which was the open question from the
  provisioning warnings.
- Prometheus reports **Ready**, and **every active target is `up`** — 0 down ✅.

The `vllm` and `dcgm-exporter` jobs are absent from the target list so far, as expected:
no vLLM pod and no GPU node yet. Both appear in Phase B.

**Ordering gotcha:** install kube-prometheus-stack *before* dcgm-exporter. DCGM's chart
creates a `ServiceMonitor`, so without the Prometheus operator CRDs it fails with
`no matches for kind "ServiceMonitor"`. Hit here; retried after the CRDs landed.

Note `values-kube-prometheus.yaml` still carries `grafana.adminPassword: "changeme"`,
inherited from the source study. Harmless while Grafana is only reachable in-cluster —
change it if Grafana is ever exposed.

#### Commands

```bash
# DCGM exporter
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update
kubectl create configmap dcgm-custom-metrics \
  --from-file=metrics=k8s/monitoring/dcgm_counters.csv -n monitoring
helm upgrade --install dcgm-exporter gpu-helm-charts/dcgm-exporter \
  --namespace monitoring -f k8s/monitoring/dcgm-exporter-values.yaml

# Prometheus + Grafana
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring -f k8s/monitoring/values-kube-prometheus.yaml
kubectl apply -f k8s/monitoring/servicemonitor.yaml
```

Expect **DCGM exporter to sit at 0 pods** — it is a DaemonSet and there is no GPU node
right now. That is correct, not a failure. GPU metrics only become verifiable in Phase B.

`values-kube-prometheus.yaml` pins Prometheus, Grafana, alertmanager, the operator and
kube-state-metrics to `node-role: system`, which matches the new cluster's node label —
no edit needed.

### A4. Expose Prometheus to Akamas, and repoint the telemetry instance

This step has no equivalent in a single-cluster setup and is the one genuinely new piece
of engineering.

```bash
kubectl apply -f k8s/monitoring/prometheus-internal-lb.yaml
kubectl get svc prometheus-akamas -n monitoring -w   # wait for EXTERNAL-IP
```

The Service uses the **legacy** NLB annotations (`aws-load-balancer-type: nlb` +
`aws-load-balancer-internal: true`) on purpose — the AWS Load Balancer Controller is not
installed on either cluster, and these are what the working NLBs on `vllm-bench` use ✅.
The private subnets carry `kubernetes.io/role/internal-elb: 1` ✅, so discovery will work.

**Verify from Akamas, not from the new cluster.** Same VPC gives routing; it does not
give security-group permission, and this is where it is most likely to fail:

```bash
kubectl --context=lab-vllm-bench -n akamas exec deploy/toolbox -- \
  curl -sS -m 5 http://<nlb-hostname>:9090/-/ready
```

If that hangs or is refused, open the new cluster's node security group to the old
cluster's node security group on 9090 — the NLB preserves the client IP in instance
mode, so the node SG is what decides.

Then put that hostname into `akamas/telemetry/prometheus.yaml` as `config.address` and
re-apply it. **To verify:** whether `akamas create` updates an existing telemetry
instance in place or whether it must be deleted and recreated first.

### A5. Gatling Enterprise — control plane

Still unknown and needed before anything else here (ask Graziano):

- the **team name** for `.gatling/package.conf` — it is an unfilled placeholder and the
  package deploy fails until it is set
- whether the API tokens have the right roles: **Configure** for deploy, **Start** for
  the per-trial trigger. May need two separate tokens.

The control plane token itself we have. **Important:** the `cpt_...` string Graziano
passed is 400 characters — it is the same 200-character token pasted twice ✅ (verified:
the two halves are byte-identical). Use **one half**.

```bash
kubectl create secret generic gatling-control-plane-token \
  -n llm-benchmark --from-literal=token="cpt_..."   # 200 chars, not 400
bash k8s/gatling-control-plane/install.sh
```

`install.sh` refuses to run without the Secret. Afterwards confirm `prl_akamas_vllm_k8s`
appears under Admin → Private Locations in the Gatling UI — if it does not register,
nothing downstream works.

The control plane's `deployment.yaml` and `job.json` both select `node-role: system`,
which matches the new cluster ✅ — this is why the combined node kept that label.

### A6. Deploy the Gatling package (one-time)

Needs Node, so run from a dev machine, not toolbox:

```bash
GATLING_ENTERPRISE_API_TOKEN=... bash k8s/deploy_enterprise.sh
```

- copy the printed `test_...` simulation id
- paste the printed package `id` back into `.gatling/package.conf` so re-deploys update
  in place instead of creating duplicates
- confirm `model = "qwen2.5-7b"` in `package.conf` matches `--served-model-name` in
  `k8s/01-deployment_template.yaml` ✅ (they match today)

Then set on toolbox, for user `akamas`:
- `GATLING_ENTERPRISE_API_TOKEN` (Start role)
- `GATLING_SIMULATION_ID=test_...`

**Verify they survive a non-interactive SSH**, which is how Akamas will invoke them —
a non-login shell does not source `~/.bashrc`:
```bash
ssh akamas@toolbox 'echo "[$GATLING_SIMULATION_ID]"'
```
Empty brackets means the study dies on its first RunTest. Cleanest fix without touching
the script: wrap the workflow command as `bash -lc "bash /work/.../run_test_enterprise.sh"`.

### A7. Create the workflow and the study

```bash
akamas create -f akamas/1-Goodput-Realistic-Load-Gatling-Enterprise-Workflow.yaml
akamas create -f akamas/1-Goodput-Realistic-Load-Gatling-Enterprise.yaml
```

Run these from the toolbox pod — the Akamas CLI does not work from a dev machine here.

---

## Phase B — GPU on, validate before committing

```bash
eksctl scale nodegroup --cluster vllm-bench-gatling --region us-east-2 \
  --name llm-serving --nodes 1 --profile lab
```

### B1. Sanity-check vLLM by hand
```bash
kubectl apply -f k8s/02-service.yaml
# render the ${vLLM.*} tokens by hand and apply 01-deployment_template.yaml
```
Confirm the GPU is allocatable again and the model loads (5–15 min on first start; the
`vllm-model-cache` PVC binds the moment the pod mounts it).

`01-deployment_template.yaml` selects `node-role: llm-serving`, which matches the new
cluster ✅ — on the old cluster it did not (that node was `llm-serving-l4`), so this is
one mismatch the fresh cluster fixed for free.

### B2. The `[DONE]` check — highest-risk item on this branch
The simulation asserts `substring("[DONE]").exists()`. A failed check marks the request
KO, KOs feed the 5%-failure assertion, and that assertion failing exits non-zero — so if
vLLM does not emit the sentinel, **every trial fails**.

```bash
curl -sN http://vllm.llm-serving.svc.cluster.local:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-7b","messages":[{"role":"user","content":"hi"}],"max_tokens":16,"stream":true}' \
  | tail -3
```
Want `data: [DONE]` as the last line. If absent, set `check.streamDone=false` in
`package.conf` before deploying.

### B3. Short end-to-end run
Temporarily add to `package.conf` systemProperties:
```
"sweep.levels" = "2,4"
"sweep.durationSeconds" = "10"
```
Deploy, trigger, confirm green in Enterprise, then revert and re-deploy. This also proves
`resources/prompts.json` actually ships inside the Enterprise package (the feeder resolves
it at runtime) and that `run_test_enterprise.sh` can fetch Gatling's CI zip from github.com
and authenticate against api.gatling.io from toolbox.

### B4. Confirm telemetry is actually flowing
Before starting the real study, confirm Akamas is reading metrics from the new cluster —
run one trial and check that `vLLM.prefill_token_throughput` is non-zero in the Akamas UI.
A silently-empty telemetry instance would let the study run to completion scoring nothing.

---

## Phase C — run it

```bash
akamas start study "1-Goodput-Realistic-Load-Gatling-Enterprise"
```

Target is **~50 experiments**, not the ~1000 the old plan assumed. At roughly an hour per
trial that is a few days; size the steps in the study YAML accordingly rather than
inheriting the reference study's counts unexamined.

Then: update the slides from the Gatling Enterprise dashboards, and **delete the cluster**:
```bash
eksctl delete cluster --name vllm-bench-gatling --region us-east-2 --profile lab
```

---

## Risks

**The reference run failed 6 trials out of 14.** Unexplained so far. The Enterprise path
adds two new ways for a trial to fail (the 5% failed-request assertion and the `[DONE]`
check), so whatever caused those 6 will likely cause more here. Worth 20 minutes of
looking at that study's failed experiments before launching.

**Load-generator sizing is unverified** at 1024 concurrent closed-loop virtual users on a
JS event loop. The node has headroom to raise the generator from 4 CPU to 6–7 without
reprovisioning, which is why it was sized at 8 vCPU. If the generator saturates before
vLLM does, top-of-sweep trial data is invalid — and now also likely to trip the 5%
assertion.

**Monitoring shares the node with the load generator.** Accepted deliberately to keep the
cluster simple at this scale, but Prometheus scrape and compaction can add jitter to a
measurement whose whole point is p95 TTFT/ITL. If results look noisy at the top of the
sweep, this is the first thing to suspect — the fix is splitting the generator onto its
own nodegroup.

**The DCGM queries in `akamas/telemetry/prometheus.yaml` filter the wrong label.** They
use `pod=~"$POD$"`, but in DCGM series `pod` is the *exporter* pod; the workload is under
`exported_pod`. With one vLLM per cluster this is harmless — every series belongs to us
anyway — so it does not block this run. It is still wrong, and it means the `gpu`
component's `pod` property does nothing. Worth fixing separately; note these queries are
**ours**, not the vLLM pack's (the `GPU` component type ships only metric names and
units, no queries) ✅.

---

## Open decisions

- **Gatling team name** and API token roles — blocks A5/A6.
- **Merge `feat/enterprise-private-locations` to `main`, or check the branch out on
  toolbox?** Merging is cleaner given the branch is now the only path being used.
- **Commit the untracked work** (`infra/`, `k8s/monitoring/`, the Enterprise study YAML).
  It is currently local-only, so nothing on toolbox or in CI can see it.
