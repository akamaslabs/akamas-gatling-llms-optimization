# Gatling Enterprise control plane (in-cluster Kubernetes private location)

This directory sets up a **Gatling Enterprise Kubernetes private location** so the
load test runs as a **Kubernetes batch Job inside this cluster**, next to vLLM,
reaching it over internal Service DNS — while giving you Enterprise reporting,
assertions, and run-over-run trends instead of the hand-rolled `kubectl` glue in
[`../run_test_gatling.sh`](../run_test_gatling.sh).

## How it works

The control plane runs in-cluster as a `Deployment`. It polls Gatling Enterprise,
and for each run it **creates a batch `Job`** (container `gatling-container`) in the
`llm-benchmark` namespace, streams its logs, and deletes it when the run ends. A
managed cloud location could not do this — it cannot reach
`vllm.llm-serving.svc.cluster.local`.

```
Gatling Enterprise  ──polls──►  control-plane (Deployment)  ──creates──►  load-gen Job(s)
                                                                              │
                                                                              ▼
                                                          vllm.llm-serving.svc.cluster.local:8000
```

## Files

| File | What |
|------|------|
| `control-plane.conf` | Defines the private location `prl_akamas_vllm_k8s` (type `kubernetes`, JS engine). |
| `job.json` | Per-generator pod spec (resources, node placement) merged onto the Job. |
| `rbac.yaml` | ServiceAccount + namespace-scoped Role/RoleBinding (jobs, configmaps, pods, pod logs). |
| `secret.example.yaml` | Template for the control-plane token Secret — **create the real one manually**. |
| `deployment.yaml` | The control-plane Deployment; injects the token from the Secret. |
| `install.sh` | Applies RBAC, builds the ConfigMap from the two HOCON files, deploys, restarts. |

## Install

```bash
# 1. Create a control plane in Gatling Enterprise (Admin > Private Locations >
#    Control Planes) and copy its cpt_ token.
# 2. Create the token Secret (NOT committed — see secret.example.yaml):
kubectl create secret generic gatling-control-plane-token \
  -n llm-benchmark --from-literal=token="cpt_...your_token..."
# 3. Install:
bash k8s/gatling-control-plane/install.sh
```

Then confirm `prl_akamas_vllm_k8s` shows up under Admin > Private Locations, and
reference that same id in [`../../.gatling/package.conf`](../../.gatling/package.conf).

## Alternative: run the control plane OUTSIDE the cluster

Per the Gatling docs, the control plane does not have to run in-cluster — it can run
anywhere (a laptop, CI, a bastion) as long as it has a **kubeconfig** that can create
Jobs in the `llm-benchmark` namespace of the lab cluster. It then creates the same
in-cluster load-generator Jobs remotely. Load still runs *inside* the cluster; only the
control plane sits outside. Useful when you have a kubeconfig but no in-cluster deploy path:

```bash
docker run -d --name gatling-control-plane \
  -e CONTROL_PLANE_TOKEN="cpt_...your_token..." \
  -e KUBECONFIG=/app/.kube/config \
  -v "$PWD/control-plane.conf:/app/conf/control-plane.conf:ro" \
  -v "$PWD/job.json:/app/conf/job.json:ro" \
  -v "$HOME/.kube:/app/.kube:ro" \
  gatlingcorp/control-plane:latest
```

The RBAC in `rbac.yaml` is only needed for the in-cluster deployment; out-of-cluster,
the kubeconfig's own identity must hold the equivalent namespace permissions.

## ⚠️ Resource sizing is unverified

`job.json` requests/limits (4 CPU / 8Gi, aligned per Gatling's recommendation) are
carried over from the raw Job's floor and are **NOT yet load-tested at 1024
concurrent closed-loop virtual users on a JS event loop** — same caveat as
[`../job.yaml`](../job.yaml). If the generator saturates before vLLM does, trial
data near the top of the sweep is invalid. Raise these (and re-verify) before
trusting top-of-sweep results, especially for the larger H100 model.
