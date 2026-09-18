DEPLOY_FILE=/work/akamas-gatling-llms-optimization/k8s/01-deployment.yaml

# Cluster targeting — DO NOT remove, and do not rely on toolbox's current context.
#
# toolbox can reach TWO clusters: its in-cluster context `default` is the shared
# `vllm-bench` cluster (where Akamas itself runs, and where other studies measure), and
# `gatling` is this study's own `vllm-bench-gatling` cluster. A bare `kubectl` here
# resolves to `default` — i.e. it would deploy this study's vLLM on top of whatever
# another study is currently measuring, and it would SUCCEED while doing it. Nothing
# would error; the damage would only show up as someone else's corrupted results.
#
# Hence every kubectl call below goes through $KUBECTL with an explicit --context.
# Override with KUBE_CONTEXT=... only if the cluster is ever rebuilt under a new alias.
KUBE_CONTEXT="${KUBE_CONTEXT:-gatling}"
KUBECTL="kubectl --context ${KUBE_CONTEXT}"

# --- Step 1: boolean CLI flags ---
# vLLM's boolean flags (enforce-eager, disable-cascade-attn, async-scheduling,
# enable-expert-parallel, disable-custom-all-reduce) use argparse.BooleanOptionalAction,
# which rejects an explicit "--flag=value" form — only bare --flag / --no-flag is
# accepted. The Akamas vLLM pack declares these as categorical "true"/"false" string
# parameters, so FileConfigurator renders "--flag=true"/"--flag=false" into the
# deployment args; rewrite those into the accepted form here, right before applying.
for flag in enforce-eager disable-cascade-attn async-scheduling enable-expert-parallel disable-custom-all-reduce; do
  sed -i "s/--${flag}=true/--${flag}/" "$DEPLOY_FILE"
  sed -i "s/--${flag}=false/--no-${flag}/" "$DEPLOY_FILE"
done

# --- Step 2: strip any vLLM parameter flag left with no rendered value (baseline step) ---
# The baseline step excludes most vLLM.* parameters via doNotRenderParameters (see
# akamas/1-Goodput-Realistic-Load-Gatling.yaml) so the baseline is a genuinely "bare"
# vLLM startup. An excluded parameter's ${vLLM.*} token is substituted with an EMPTY
# STRING (not left as literal unsubstituted text), e.g.
# `- "--max-num-seqs=${vLLM.max_num_seqs}"` renders to `- "--max-num-seqs="` — vLLM's
# argparse rejects an empty value for any int/float/enum flag, so both the empty-value
# pattern and the literal-unsubstituted-token pattern (defense-in-depth) are stripped
# below. No-op on optimize-step trials, where every token gets a real value.
sed -i -E '/\$\{vLLM\./d; /^[[:space:]]*-[[:space:]]*"--[A-Za-z0-9_-]+="[[:space:]]*$/d' "$DEPLOY_FILE"

$KUBECTL apply -f "$DEPLOY_FILE" -n llm-serving

# Don't let a failed rollout exit immediately — print vLLM's own container logs first,
# so they land in this task's stdout and show up in the Akamas UI (experiment/trial
# view) without needing separate cluster access.
set +e
$KUBECTL rollout status deployment/vllm -n llm-serving --timeout=1200s
ROLLOUT_EXIT=$?
set -e

echo "--- vLLM container logs (current pod) ---"
$KUBECTL logs deployment/vllm -n llm-serving --tail=200 || true
echo "--- vLLM container logs (previous pod, if it crashed and restarted) ---"
$KUBECTL logs deployment/vllm -n llm-serving --tail=200 --previous 2>/dev/null || true

exit $ROLLOUT_EXIT
