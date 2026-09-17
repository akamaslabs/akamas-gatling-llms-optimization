#!/bin/bash
# One-time (or on-simulation-change) deploy of the Gatling package to Enterprise.
#
# Run this ONCE to create/update the simulation on Gatling Enterprise from
# .gatling/package.conf, then copy the printed simulation id (test_...) into the
# GATLING_SIMULATION_ID env used by run_test_enterprise.sh. You do NOT run this every
# experiment -- the simulation code is stable; only the vLLM config changes per trial.
#
# Unlike the per-experiment trigger, this step DOES need Node + this project checked
# out (it bundles and uploads the package). Run it from your machine or a build host,
# not necessarily the Akamas runner.
#
# Required env:
#   GATLING_ENTERPRISE_API_TOKEN  API token with the Configure role (api.gatling.io)
#
# Before running: set `team` (and, after the first deploy, the pinned package `id`) in
# .gatling/package.conf. Confirm base.url + model match the live vLLM deployment.
set -euo pipefail

: "${GATLING_ENTERPRISE_API_TOKEN:?set GATLING_ENTERPRISE_API_TOKEN}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

npx gatling enterprise-deploy

echo
echo "Deploy complete. Copy the simulation id it printed (test_...) into the runner as:"
echo "  export GATLING_SIMULATION_ID=test_xxxxxxxxxxxxxxxxxxxxxxxxxx"
echo "run_test_enterprise.sh then triggers that simulation each experiment."
