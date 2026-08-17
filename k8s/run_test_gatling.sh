#!/bin/bash

BENCH_FILE=/work/akamas-gatling-llms-optimization/k8s/job.yaml

# Delete-then-apply (not just apply), same as run_test_goodput.sh, so a manifest edit
# takes effect on the next trial without a stale prior Job blocking the name.
kubectl delete -f "$BENCH_FILE" ; kubectl apply -f "$BENCH_FILE"

# Same rationale as run_test_goodput.sh: don't exit immediately on a failed wait — print
# the job's own container logs first, so they land in this task's stdout and show up in
# the Akamas UI without needing separate kubectl access.
#
# Timeout sizing: 12 x 300s = 60min sweep, plus first-ever-run overhead (git clone,
# `npm ci`, GraalVM/Gatling bundle download — cached on the gatling-runtime-cache PVC
# after the first trial, see k8s/00-pvc.yaml). --timeout=4500s (75m) mirrors
# run_test_goodput.sh's own margin, safely under the workflow's RunTest task timeout
# (90m at time of writing — confirm the live value in
# 1-Goodput-Realistic-Load-Workflow-v2.yaml before trusting this, per CLAUDE.md §8).
set +e
kubectl wait --for=condition=complete job/gatling-benchmark -n llm-benchmark --timeout=4500s
WAIT_EXIT=$?
set -e

echo "--- wait-for-vllm init container logs ---"
kubectl logs job/gatling-benchmark -n llm-benchmark -c wait-for-vllm --tail=200 || true
echo "--- gatling container logs ---"
kubectl logs job/gatling-benchmark -n llm-benchmark -c gatling --tail=500 || true

exit $WAIT_EXIT
