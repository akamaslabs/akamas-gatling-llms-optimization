#!/bin/bash
# Enterprise / private-location variant of run_test_gatling.sh.
#
# Instead of applying a raw Kubernetes Job, this deploys the package and starts a
# Gatling Enterprise run on the in-cluster Kubernetes private location
# (prl_akamas_vllm_k8s). The control plane turns that run into a batch Job in the
# cluster -- same in-cluster execution as the fallback, but with Enterprise
# reporting/assertions and no hand-rolled kubectl orchestration.
#
# The raw-Job path (run_test_gatling.sh + k8s/job.yaml) is kept as a fallback: point
# the workflow's RunTest command back at it if the control plane is unavailable.
#
# Requires on the runner (toolbox):
#   - Node + this repo's npm deps (`npm ci`, same as local runs)
#   - GATLING_ENTERPRISE_API_TOKEN in the environment (Configure role or higher).
#     Store it like akamas/id_rsa -- never commit it.
#
# NOTE: confirm the enterprise-start flags against `npx gatling enterprise-start --help`
# for your @gatling.io/cli version (3.15.x) before the first live trial.
set -euo pipefail

REPO=/work/akamas-gatling-llms-optimization
cd "$REPO"

: "${GATLING_ENTERPRISE_API_TOKEN:?set GATLING_ENTERPRISE_API_TOKEN on the runner}"

# Upsert the package/simulation from .gatling/package.conf. Idempotent once the
# package id is pinned there after the first deploy.
npx gatling enterprise-deploy

# Start the sweep and BLOCK until it finishes, so this task's exit status (and thus
# the Akamas RunTest task's) reflects the run. Per the docs, --enterprise-simulation
# takes the simulation's DISPLAY NAME (the `name` field in .gatling/package.conf), not
# the class name. --wait-for-run-end exits non-zero if any assertion fails, so the
# load-generator-health assertion in the simulation propagates to Akamas as a failed
# trial. --non-interactive so it never prompts on the runner.
npx gatling enterprise-start \
  --enterprise-simulation="vLLM goodput concurrency sweep" \
  --run-title "akamas-trial-$(date -u +%Y%m%dT%H%M%SZ)" \
  --non-interactive \
  --wait-for-run-end
