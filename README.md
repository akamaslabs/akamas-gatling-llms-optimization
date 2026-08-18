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
```

## Running locally

```bash
npm install
npx gatling build --typescript
npx gatling run --typescript --simulation vllmConcurrencySweep \
  base.url=http://<vllm-host>:8000
```

## Deploying the load generator

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
