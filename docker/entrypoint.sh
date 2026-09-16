#!/bin/sh
set -e

# Same cleanup discipline as the AIPerf job this replaces: prune this job's own
# previous run's output before writing new output, so a long optimize step can't
# fill /results the same way that job's own PVC once did.
find /results -mindepth 1 -maxdepth 1 -name 'gatling-sweep-*' -exec rm -rf {} + 2>/dev/null || true

# base.url, model, and any other getParameter() override (e.g. sweep.levels=2,3 for a
# smoke test) can be passed as extra args to `docker run`/the container's own `args:`.
# MODEL must match --served-model-name in k8s/01-deployment_template.yaml; keep this
# default in sync with the simulation's own `model` default when switching models.
exec npx gatling run --typescript \
  --simulation vllmConcurrencySweep \
  --non-interactive \
  --results-folder "/results/gatling-sweep-$(date +%s)" \
  "base.url=${BASE_URL:-http://vllm.llm-serving.svc.cluster.local:8000}" \
  "model=${MODEL:-qwen2.5-7b}" \
  "$@"
