# Decisions and incident log

Dated record of non-obvious decisions and real bugs found, kept separate from the
README so the README can stay a short description of the repo. Newest last.

## 2026-08-14 — Closed-loop load, not open-loop

Uses `injectClosed(...)` with `constantConcurrentUsers(n).during(seconds)` per
concurrency level — verified against the real `@gatling.io/core` TypeScript
definitions. Each virtual user executes exactly **one** request-response cycle, no
explicit loop in the scenario body: `injectClosed` already replaces a finished user
instantly to keep exactly `n` concurrent, which is the actual closed-loop guarantee.
An earlier version wrapped requests in a `forever()` loop and **hung indefinitely past
the first concurrency level** (a virtual user stuck in an unconditional loop never
finishes, so it's never replaced, and the simulation never advances) — found by
actually running it against a mock server. Fixed by removing the loop.

## 2026-08-14 — Real per-request `max_tokens`

The request body sets `max_tokens` from each feeder row's real target output length,
not a flat constant — a flat cap silently produces uniform, unrealistic output lengths
regardless of how long a response should be (this is the exact bug the AIPerf
predecessor had, see the target study's own incident history).

## 2026-08-14 — Dataset: real ShareGPT, tokenized/filtered offline, committed

`scripts/prepare-dataset.mjs` downloads ShareGPT_V3, tokenizes the first human→gpt
turn with `@huggingface/transformers` (`Qwen/Qwen2.5-7B-Instruct`), and filters to
`min_seq_len=4` / `max_prompt_len=1024` / `max_total_len=2048` (same bounds vLLM's own
`benchmark_dataset.py` and AIPerf use). Stops at 8,000 entries — enough that the
feeder's `.random()` strategy won't visibly repeat even at 1024 concurrent users.
Chosen over (a) replicating AIPerf's runtime dataset-prep pipeline inside the Job
(more fidelity, more moving parts) and (b) a small hand-written corpus (fastest, but
not comparable to AIPerf's real-ShareGPT-driven results).

## 2026-08-14 — Container: prebuilt image via CI, not git-clone-at-start

`.github/workflows/build-and-push.yml` builds `docker/Dockerfile` and pushes to GHCR
on every push to `main`. Revised from an earlier git-clone-at-start design once
testing against the cluster made the tradeoff clear: cloning requires the exact commit
under test to already be pushed, which blocks testing a local change and adds a
runtime GitHub-egress dependency to every trial. Building on `linux/amd64` GitHub
Actions runners also lets the Dockerfile bake in Gatling's own GraalVM runtime bundle
(~376MB) at image-build time — no first-run download inside the Job.

Resource sizing (`requests: cpu 2, memory 4Gi`, `limits: cpu 4, memory 8Gi`) is a
starting point copied from AIPerf's own footprint, not yet verified at 1024 concurrent
closed-loop virtual users on a Node event loop.

## 2026-08-17 — Gatling HTTP timeout raised 60s → 600s

Real run against the cluster: 100% KO at the 1024-concurrency sweep level, all
`Request timeout ... after 60000 ms`. Gatling doesn't cancel the request server-side on
timeout, it just frees the virtual user's slot for a replacement — silently pushing
real concurrent load on vLLM above the sweep's intended level and breaking the
closed-loop invariant the whole project depends on. Fixed via `resources/gatling.conf`
(`gatling.http.requestTimeout = 600000`), picked up automatically from the classpath's
`resources/` folder.

## 2026-08-17 — v0.1.0 tagged, tag push blocked by org permissions

`git push origin v0.1.0` returned `403: Permission ... denied to graz-dev` while
`git push origin main` succeeded — the cached credential's GitHub account lacks (or
lacked, at the time) write/SSO-authorized access scoped correctly for tag refs on
`akamaslabs/akamas-gatling-llms-optimization`. Root cause was a stale/mismatched
credential in the terminal's `osxkeychain` helper vs. the account actually authorized
in GitHub Desktop (Desktop has its own separate OAuth token, not shared with the CLI's
credential helper) — resolved by pushing from Desktop instead of fixing the CLI
credential. `k8s/job.yaml` pinned to `:latest` in the meantime; repoint to `:0.1.0`
once a version tag is confirmed live.

## 2026-08-17 — Akamas study definition made self-contained

Copied `vllm-benchmark`'s `studies/1-goodput-realistic-load/akamas/` (system,
components, telemetry, workflow, study) and vLLM's own deployment/service/PVC/secret
templates into this repo (`akamas/`, `k8s/01-deployment_template.yaml`,
`k8s/02-service.yaml`, `k8s/01-pvc-model-cache.yaml`, `k8s/03-hf-secret.yaml`,
`k8s/apply_config.sh`), so `toolbox` only needs this one repo checked out —
`vllm-benchmark` is no longer needed for this study once this repo is cloned there.

Named separately (`vLLM_Benchmark_1_Goodput_Realistic_Load_Gatling` /
`1-Goodput-Realistic-Load-Gatling` / `1-Goodput-Realistic-Load-Gatling-Workflow`)
rather than reusing the source study's resource names, so both can run side-by-side
against the same cluster for comparison before any cutover. Goal, windowing,
parametersSelection, and parameterConstraints are otherwise unchanged, since none of
that depends on which load generator drives the traffic.

Deliberately **not** copied: `infra/` (EKS cluster provisioning) and
`k8s/monitoring/` (DCGM/Grafana/kube-prometheus-stack) — both are shared,
already-running cluster infrastructure, not tied to this study. `02-service.yaml` and
`01-pvc-model-cache.yaml` were already applied once to the live cluster by
`vllm-benchmark`'s own provisioning script; nothing in this repo's automation applies
them (same as the source study — they don't change per trial, unlike the Deployment).

`akamas/id_rsa` (the SSH key every workflow task uses to reach `toolbox`) is
gitignored — place the real key there manually on toolbox, never commit it.

## 2026-08-18 — Real credentials found in the ShareGPT corpus; git history rewritten

`resources/prompts.json` is raw ShareGPT data — real users' original ChatGPT
conversations, unfiltered for PII/secrets. Found on inspection: a live-looking
Firebase API key, a Slack incoming webhook tied to a real company domain, a JWT, and a
token embedded in a URL, all pasted by users asking for debugging help. Known
data-quality characteristic of ShareGPT as a source, not a bug in how this repo built
the corpus — but this repo had already committed and pushed the file to a **public**
GitHub repo, redistributing third-party credentials.

Separately and more seriously: `akamas/id_rsa` (a real private SSH key for
`akamas@toolbox`) was accidentally committed and pushed to the same public repo in the
"add akamas study" commit — a `.gitignore` edit meant to add an unrelated pattern
(`k8s/01-deployment.yaml`) had dropped the existing `id_rsa`/`id_rsa.*` lines by
mistake, and the commit landed before that was caught.

Remediation:
1. Added a secret-pattern filter to `scripts/prepare-dataset.mjs` (provider key
   formats, Slack webhooks, JWTs, PEM blocks, URL-embedded tokens — with a
   markdown-unescape pass first, since ShareGPT backslash-escapes underscores in a way
   that breaks contiguous-charset regexes) and applied it retroactively:
   8000 → 7995 entries in the corpus, stats otherwise unchanged (mean 280.6 tokens,
   min 4, max 1445).
2. Restored the `.gitignore` `id_rsa`/`id_rsa.*` lines and untracked the file.
3. Rewrote git history with `git filter-repo` (`--path akamas/id_rsa --invert-paths`
   plus `--replace-text` for the leaked corpus strings) and force-pushed — verified
   afterward that neither the key nor any of the leaked strings remain in any blob
   across all history.
4. The SSH key must still be treated as compromised regardless of the history
   rewrite (it was publicly fetchable for a period) — rotate it on `toolbox`
   independent of any git cleanup.
