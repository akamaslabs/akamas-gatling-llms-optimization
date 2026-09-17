#!/bin/bash
# Akamas RunTest trigger: start the load test on Gatling Enterprise.
#
# This is what the Akamas workflow's RunTest step runs each experiment. It starts the
# ALREADY-DEPLOYED simulation on the in-cluster Kubernetes private location
# (prl_akamas_vllm_k8s) and blocks until the run ends, exiting non-zero if the run
# fails or the simulation's assertions fail -- so Akamas scores each experiment from
# the run result. This is the "Akamas drives Gatling" trigger.
#
# It uses Gatling's official CI shell script (start_simulation.sh), which calls the
# Gatling Enterprise public API (https://api.gatling.io) directly. The Akamas runner
# therefore needs only: bash, curl, jq, unzip, and the two env vars below -- NO Node,
# no project checkout, no per-experiment package rebuild.
#
# Deploy is a SEPARATE, one-time step (see deploy_enterprise.sh): the simulation code
# doesn't change between experiments -- only the vLLM config does, and Akamas applies
# that in the "Apply config" task. So we deploy once and trigger by simulation id here.
#
# Required env on the runner (store like akamas/id_rsa -- never commit):
#   GATLING_ENTERPRISE_API_TOKEN  API token with the Start role (api.gatling.io)
#   GATLING_SIMULATION_ID         the deployed simulation id (test_...), from the
#                                 Simulations table or deploy_enterprise.sh output
set -euo pipefail

: "${GATLING_ENTERPRISE_API_TOKEN:?set GATLING_ENTERPRISE_API_TOKEN on the runner}"
: "${GATLING_SIMULATION_ID:?set GATLING_SIMULATION_ID to the deployed simulation id (test_...)}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_VERSION="1.0.3"
CI_DIR="$HERE/.gatling-ci"
CI_SCRIPT="$CI_DIR/start_simulation.sh"

# Fetch Gatling's official CI script once (pinned), if it isn't already cached next to
# this script. Downloaded at runtime rather than committed, so we don't vendor a
# third-party script into the repo (see .gitignore: k8s/.gatling-ci/).
if [ ! -x "$CI_SCRIPT" ]; then
  echo "Fetching Gatling Enterprise CI script v${CI_VERSION}..."
  mkdir -p "$CI_DIR"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/ci.zip" \
    "https://github.com/gatling/gatling-enterprise-ci-plugins/releases/download/v${CI_VERSION}/gatling-enterprise-ci-script-${CI_VERSION}.zip"
  unzip -o -q "$tmp/ci.zip" -d "$CI_DIR"
  chmod +x "$CI_SCRIPT"
  rm -rf "$tmp"
fi

# Start the simulation and wait for the run to finish. start_simulation.sh streams live
# metrics and exits non-zero if the run crashes or an assertion fails -- that exit code
# becomes the Akamas RunTest task's result.
exec "$CI_SCRIPT" "$GATLING_SIMULATION_ID"
