# akamas-gatling-llms-optimization

A Gatling load generator for vLLM, built to drive load against a self-hosted model for Akamas Studio. It runs a
closed-loop concurrency sweep (150→1024 users, log-spaced, 300s per level) against a
vLLM OpenAI-compatible `/v1/chat/completions` endpoint, using a corpus of real
ShareGPT prompts with realistic, variable output lengths. Ships as a standalone
artifact — it doesn't provision infrastructure or deploy vLLM, it just drives load
against whatever vLLM service you point it at.

## What's in this repo

```
src/vllmConcurrencySweep.gatling.ts   The Gatling simulation
resources/prompts.json                Real ShareGPT (prompt, target_output_tokens) corpus
resources/gatling.conf                Gatling runtime config
scripts/prepare-dataset.mjs           Regenerates resources/prompts.json
scripts/release.sh                    Cuts a versioned release
docker/                                Container image (Dockerfile, entrypoint)
.github/workflows/                    CI: builds and publishes the image to GHCR
k8s/job.yaml, k8s/00-pvc.yaml         The load-generator Kubernetes Job + its PVC
k8s/run_test_gatling.sh               Delete/apply/wait/dump-logs wrapper for the Job
k8s/01-deployment_template.yaml,      The vLLM deployment/service/PVC this load
  02-service.yaml, 01-pvc-model-cache.yaml,   generator targets, and apply_config.sh to
  03-hf-secret.yaml, apply_config.sh   render and apply them
akamas/                               Full Akamas study definition (system, components,
                                       telemetry, workflow, study) to run this as an
                                       Akamas optimization study end-to-end
.gatling/package.conf                 Gatling Enterprise package descriptor (Config as Code)
k8s/gatling-control-plane/            Gatling Enterprise control plane + Kubernetes private
                                       location, so the load test runs as an in-cluster Job
k8s/run_test_enterprise.sh            RunTest wrapper for the Enterprise/private-location path
akamas/...-Gatling-Enterprise-Workflow.yaml   Akamas workflow variant using the Enterprise path
```

## Two ways to run the load test

Both run the load generator **as a Kubernetes Job inside the cluster**, next to vLLM:

1. **Gatling Enterprise + in-cluster Kubernetes private location** (recommended) — a
   control plane in the cluster turns each run into a batch Job and reports to Gatling
   Enterprise (dashboards, assertions, trends). See
   [`k8s/gatling-control-plane/README.md`](k8s/gatling-control-plane/README.md).
2. **Raw Kubernetes Job** ([`k8s/job.yaml`](k8s/job.yaml) + `run_test_gatling.sh`) —
   the original, kept as a **fallback**. No Enterprise dependency; results go to a PVC.

## Running locally

```bash
npm install
npx gatling build --typescript
npx gatling run --typescript --simulation vllmConcurrencySweep \
  base.url=http://<vllm-host>:8000 \
  model=qwen2.5-7b \
  sweep.levels=2,4 sweep.durationSeconds=10   # fast smoke test
```

Parameters (all `getParameter()`, overridable in every run context): `base.url`,
`model` (must match vLLM's `--served-model-name`), `sweep.levels`,
`sweep.durationSeconds`, `assert.maxFailedPercent`, `check.streamDone`,
`default.maxTokens`.

## Deploying via Gatling Enterprise (in-cluster private location)

```bash
# One-time: install the control plane (see k8s/gatling-control-plane/README.md for
# the token Secret prerequisite).
bash k8s/gatling-control-plane/install.sh

# Deploy the package + start a run on the private location (needs
# GATLING_ENTERPRISE_API_TOKEN in the environment):
bash k8s/run_test_enterprise.sh
```

## Deploying the load generator (raw-Job fallback)

```bash
kubectl apply -f k8s/00-pvc.yaml
kubectl apply -f k8s/job.yaml
bash k8s/run_test_gatling.sh
```

## Running the Akamas study

```bash
cd akamas
akamas create -f system.yaml
akamas create -f components/container.yaml
akamas create -f components/gpu.yaml
akamas create -f components/vllm.yaml
akamas create -f telemetry/prometheus.yaml
akamas create -f 1-Goodput-Realistic-Load-Gatling-Workflow.yaml
akamas create -f 1-Goodput-Realistic-Load-Gatling.yaml
akamas start study "1-Goodput-Realistic-Load-Gatling"
```

Requires this repo checked out on `toolbox` and a real SSH key placed manually at
`akamas/id_rsa` (gitignored — never commit it).

## Results

<Filled in once this load generator has actually run a trial against a real cluster.>
