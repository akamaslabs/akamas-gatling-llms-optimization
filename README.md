# akamas-gatling-llms-optimization

A Gatling load generator for vLLM: a **closed-loop concurrency sweep**
(N virtual users, each waiting for its own response before sending the next) across 12 log-spaced levels (150→1024), 300s per level, driving real
variable-length prompts through the OpenAI-compatible `/v1/chat/completions` endpoint.

Ships as a standalone artifact: simulation + prompt corpus + Kubernetes Job + wrapper
script. It doesn't provision infrastructure or deploy vLLM — point it at any running vLLM
service and it drives load against it. The wrapper script (`k8s/run_test_gatling.sh`) is
shaped to be called as a step from any external orchestrator (e.g. an Akamas workflow
task), but nothing in this repo assumes a specific one.

## Layout

```
src/vllmConcurrencySweep.gatling.ts     the closed-workload simulation
resources/prompts.json                  real ShareGPT (prompt, target_output_tokens) corpus
scripts/prepare-dataset.mjs              regenerates resources/prompts.json (offline, one-time)
docker/Dockerfile, docker/entrypoint.sh  the container image
.github/workflows/build-and-push.yml    builds + pushes the image to GHCR on every push to main
k8s/job.yaml, k8s/00-pvc.yaml            the Kubernetes Job + its PVC
k8s/run_test_gatling.sh                  delete/apply/wait/dump-logs wrapper for the Job
```

## Key design decisions

**Closed-loop load, not open-loop.** Verified against the real `@gatling.io/core`
TypeScript definitions: `constantConcurrentUsers(n).during(seconds)` chained via
`injectClosed(...)` for each concurrency level. Each virtual user executes exactly **one**
request-response cycle — no explicit loop in the scenario body. That's deliberate:
`injectClosed` already replaces a finished user instantly to keep exactly `n` concurrent,
which is the actual closed-loop guarantee. An earlier version wrapped requests in a
`forever()` loop and it **hung indefinitely past the first concurrency level** (a virtual
user stuck in an unconditional loop never finishes, so it's never replaced, and the
simulation never advances) — found by actually running it against a mock server, not
assumed. Fixed by removing the loop.

**Real per-request `max_tokens`, never a flat constant.** The request body sets
`max_tokens` from each feeder row's real target output length. A flat cap silently
produces uniform, unrealistic output lengths regardless of how long a response should be
— easy to get wrong and easy to miss without checking actual output-length stats.

**`"stream": true` without Gatling's SSE protocol.** A plain `http().post()` already
blocks until the chunked `text/event-stream` response completes, which is exactly the
wait-for-full-response semantics the closed-loop model needs — no need to parse the
`data: {...}` chunks, since this load generator's own report isn't the scoring source of
truth for whatever system consumes vLLM's metrics (typically its own Prometheus
`/metrics`, read directly by the orchestrator).

**Dataset: real ShareGPT, tokenized and filtered offline, committed to the repo.**
`scripts/prepare-dataset.mjs` downloads ShareGPT_V3 (~670MB, streamed — too large for a
single `JSON.parse`), tokenizes the first human→gpt turn of each conversation with
`@huggingface/transformers` (pure JS/WASM, loading `Qwen/Qwen2.5-7B-Instruct`), and filters
to `min_seq_len=4` / `max_prompt_len=1024` / `max_total_len=2048` (the same bounds vLLM's
own `benchmark_dataset.py` and AIPerf use). Stops at 8,000 valid entries — enough that the
feeder's `.random()` strategy won't visibly repeat even at 1024 concurrent users, while
keeping the one-time tokenization pass fast to re-run. Measured on the committed corpus:
mean target output length 280.6 tokens, min 4, max 1445. No runtime HuggingFace/tokenizer
dependency inside the Job itself — it's a static JSON file the feeder reads.

**Container: prebuilt image, pushed to GHCR by CI.** `.github/workflows/build-and-push.yml`
builds `docker/Dockerfile` (`node:22-slim`, code + deps + a pre-baked `gatling build`)
and pushes `ghcr.io/akamaslabs/akamas-gatling-llms-optimization:latest` on every push to
`main`, using the workflow's own `GITHUB_TOKEN` — no PAT or manual `docker login` needed.
`k8s/job.yaml` just pulls that image and runs it; no git clone, no `npm ci`, no per-run
build step inside the Job at all. Revised from an earlier git-clone-at-start design (no
registry needed, simplest to operate) once actually testing against the cluster made the
tradeoff clear: cloning requires the exact commit under test to already be pushed, which
blocks testing a local change and adds a runtime GitHub-egress + repo-visibility
dependency to every single trial. A prebuilt image only needs to be pushed once per
change and pulled like any other image.

Building on GitHub Actions' own `linux/amd64` runners (matching the target cluster's node
architecture) also means the Dockerfile can bake in Gatling's own runtime bundle (a full
GraalVM JDK + Java libs, measured at **376MB**) at image-build time via `RUN npx gatling
build --typescript` — so there's no first-run download at all inside the Job, and no
separate cache PVC is needed for it (an earlier version of this repo had one).

The image needs to be pullable by the cluster with no credentials, so the GHCR package
must be **public** — note this doesn't auto-follow from the repo's own visibility, and
only takes effect from the first publish going forward, not retroactively (see the
package's own Settings → Change visibility if it doesn't already show as public).

**Versioned releases.** `scripts/release.sh [patch|minor|major]` bumps `package.json`'s
version (via `npm version`, which also commits and tags), pushes the tag, and CI
(`.github/workflows/build-and-push.yml`) then builds and pushes
`ghcr.io/akamaslabs/akamas-gatling-llms-optimization:<version>` (plus `:<major>.<minor>`)
and cuts a GitHub Release from it. A plain push to `main` still updates `:latest` and a
`:<short-sha>` tag, without needing a release for every commit — pin `k8s/job.yaml` to a
specific version tag instead of `:latest` once a known-good release exists to depend on.

**Resource sizing is a starting point, not verified.** `requests: cpu 2, memory 4Gi`,
`limits: cpu 4, memory 8Gi` — untested at 1024 concurrent closed-loop virtual users on a
Node event loop. Load-test the load generator itself before trusting latency numbers near
the top of the sweep: a resource-starved client can look identical to a slow server.

## Running locally

```bash
npm install
npx gatling build --typescript

# fast smoke test against any local server returning 200 for POST /v1/chat/completions
npx gatling run --typescript --simulation vllmConcurrencySweep \
  sweep.levels=2,3 sweep.durationSeconds=5 base.url=http://127.0.0.1:8000

# full sweep (all 12 levels, 60 minutes) against a real vLLM instance
npx gatling run --typescript --simulation vllmConcurrencySweep \
  base.url=http://<vllm-host>:8000
```

`sweep.levels` / `sweep.durationSeconds` / `base.url` are optional overrides — omit them
for the production sweep (150→1024, log-spaced, 300s/level).

Regenerate `resources/prompts.json` (only needed if the corpus strategy or target model
changes) with `npm run prepare-dataset`.

## Deploying

Push to `main` first (CI builds and pushes the image — see "Container build" above), and
make the `akamas-gatling-llms-optimization` GHCR package public on GitHub the first time
(Package settings → Change visibility), so the cluster can pull it without a secret.

```bash
kubectl apply -f k8s/00-pvc.yaml
kubectl apply -f k8s/job.yaml
bash k8s/run_test_gatling.sh   # delete+apply, wait for completion, dump logs, exit with its code
```

`k8s/job.yaml` assumes a `llm-benchmark` namespace, an in-cluster vLLM reachable at
`vllm.llm-serving.svc.cluster.local:8000`, and a `system` node group for the Job itself —
adjust to your own cluster's naming. To call this from an external orchestrator (e.g. as
one step of a larger pipeline), point it at `k8s/run_test_gatling.sh`.

**Image pinning.** `k8s/job.yaml` currently pulls `:latest` rather than a version tag.
`v0.1.0` was tagged locally (2026-08-17) but pushing the tag is blocked by an
`akamaslabs` org/repo write-permission issue (git push denied to the account in use) —
once that's resolved, push the tag (`git push origin v0.1.0`) and repoint `k8s/job.yaml`
at `ghcr.io/akamaslabs/akamas-gatling-llms-optimization:0.1.0`.

## Akamas study (self-contained)

2026-08-17 decision: the Akamas study definition and vLLM's own deployment config are
copied into this repo (`akamas/`, plus `k8s/01-deployment_template.yaml`,
`k8s/02-service.yaml`, `k8s/01-pvc-model-cache.yaml`, `k8s/03-hf-secret.yaml`,
`k8s/apply_config.sh`) rather than left in `vllm-benchmark`, so `toolbox` only needs
this one repo checked out to run the study end-to-end — `vllm-benchmark` is no longer
needed for this study once this repo is cloned there. Everything under `akamas/` and
these `k8s/*.yaml` files is copied, as of that date, from
`vllm-benchmark/studies/1-goodput-realistic-load/` (system, components, telemetry,
study, and vLLM's deployment/service/PVC/secret templates) — re-sync manually if that
study's own calibration changes later; nothing here pulls from it automatically.

**Named separately, not reused.** System `vLLM_Benchmark_1_Goodput_Realistic_Load_Gatling`,
study `1-Goodput-Realistic-Load-Gatling`, workflow
`1-Goodput-Realistic-Load-Gatling-Workflow` — distinct from the source study's own
`vLLM_Benchmark_1_Goodput_Realistic_Load` / `1-Goodput-Realistic-Load` /
`1-Goodput-Realistic-Load-Workflow-v2`. This lets both run side-by-side against the same
cluster for comparison before any cutover, per this repo's own CLAUDE.md §9 guidance —
goal, windowing, parametersSelection, and parameterConstraints are otherwise carried
over unchanged, since none of that depends on which load generator drives the traffic.

**What's intentionally NOT copied**: `infra/` (EKS cluster provisioning) and
`k8s/monitoring/` (DCGM/Grafana/kube-prometheus-stack setup) — both are shared,
already-running cluster infrastructure, not something tied to "this study" or to which
load generator runs. This repo assumes that cluster and its monitoring stack already
exist, same as the load generator itself assumes a running vLLM (see top of this file).

**SSH key is never committed.** `akamas/id_rsa` (referenced by every task in
`1-Goodput-Realistic-Load-Gatling-Workflow.yaml`) is gitignored, same as the root
`.gitignore`'s existing `id_rsa`/`id_rsa.*` pattern — place the actual private key for
`akamas@toolbox` at that exact path manually on the toolbox host after cloning this
repo there, don't add it to git. (`vllm-benchmark`'s own copy of this key is tracked in
that repo's git history despite its `.gitignore` also excluding `id_rsa` — a pre-existing,
already-flagged issue there, not repeated here.)

**Deploying the study:**

```bash
# On toolbox, once this repo is cloned to /work/akamas-gatling-llms-optimization and
# akamas/id_rsa is placed manually (see above):
akamas create -f akamas/system.yaml
akamas create -f akamas/components/container.yaml
akamas create -f akamas/components/gpu.yaml
akamas create -f akamas/components/vllm.yaml
akamas create -f akamas/telemetry/prometheus.yaml
akamas create -f akamas/1-Goodput-Realistic-Load-Gatling-Workflow.yaml
akamas create -f akamas/1-Goodput-Realistic-Load-Gatling.yaml
akamas start study "1-Goodput-Realistic-Load-Gatling"
```

Validate every file with the `akamas` CLI before trusting it — don't assume a
hand-copied file is still valid against the live pack version (`akamas list
optimization-pack`) without checking.

## Results

<Filled in once this load generator has actually run a trial against a real cluster.>
