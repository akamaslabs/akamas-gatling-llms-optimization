import {
  simulation,
  scenario,
  jsonFile,
  feed,
  exec,
  StringBody,
  getParameter,
  constantConcurrentUsers,
  substring,
  global,
} from "@gatling.io/core";
import { http, status } from "@gatling.io/http";

// Replaces NVIDIA AIPerf's `aiperf profile --concurrency <list> --benchmark-duration 300`
// (see graz-dev/vllm-benchmark studies/1-goodput-realistic-load/k8s/05-job.yaml). Structural
// equivalent: a closed workload model (N virtual users, each waiting for its own previous
// response before sending the next) at each of the same 12 log-spaced concurrency levels,
// 300s per level. See this repo's README "Closed-loop load model" for why an open-loop
// injection profile (rampUsersPerSec/constantUsersPerSec) is not an option here, and for how
// this scenario achieves closed-loop semantics without an explicit loop in its body.

// --- Configuration ------------------------------------------------------------------
// Every knob is a getParameter() override so the same image runs unchanged in all three
// contexts: local smoke test (`gatling run sweep.levels=2,4 ...`), the raw-Job fallback
// (passed through docker/entrypoint.sh from env), and Gatling Enterprise (systemProperties
// in .gatling/package.conf). Defaults are the real study's production sweep.
const config = {
  // Overridable via `gatling run sweep.levels=2,4 sweep.durationSeconds=10` for a fast
  // local smoke test (see README "Running locally").
  levels: getParameter("sweep.levels", "150,179,213,253,302,359,428,509,606,722,860,1024")
    .split(",")
    .map((n) => parseInt(n.trim(), 10)),
  levelDurationS: parseInt(getParameter("sweep.durationSeconds", "300"), 10),

  baseUrl: getParameter("base.url", "http://vllm.llm-serving.svc.cluster.local:8000"),

  // The model name sent in each request's `model` field. MUST match --served-model-name
  // in k8s/01-deployment_template.yaml (and "model" in .gatling/package.conf). This was
  // previously hardcoded to "qwen2.5-7b"; it is now a parameter so the H100 model switch
  // is a config change, not a code edit -- change it here's default AND in those two
  // files together.
  model: getParameter("model", "qwen2.5-7b"),

  // Fallback output length if a feeder row is ever missing target_output_tokens. The
  // corpus always carries it (see scripts/prepare-dataset.mjs), but a null max_tokens
  // silently caps generation -- so guard rather than trust.
  defaultMaxTokens: parseInt(getParameter("default.maxTokens", "256"), 10),

  // Fail the whole run if more than this % of requests error. This is a LOAD-GENERATOR
  // HEALTH gate, not an SLA: Akamas scores from vLLM's Prometheus metrics, but a run
  // whose generator was throwing connection errors (or hitting the requestTimeout dead-
  // connection net in resources/gatling.conf) produced junk concurrency and must not be
  // scored as a valid trial. Surfaced as a red/failed run in Enterprise.
  maxFailedPercent: parseFloat(getParameter("assert.maxFailedPercent", "5")),

  // Verify each streamed response actually ran to completion (vLLM emits a terminal
  // `data: [DONE]` sentinel). A bare status-200 check can pass on a response whose stream
  // was cut short, which would understate real per-request latency and break the closed-
  // loop invariant (the user is "freed" early). Toggle off only if a target server does
  // not emit the OpenAI [DONE] sentinel.
  checkStreamDone: getParameter("check.streamDone", "true") === "true",
};

const httpProtocol = http
  .baseUrl(config.baseUrl)
  .acceptHeader("application/json")
  .contentTypeHeader("application/json")
  .shareConnections();

// Real ShareGPT (prompt, target_output_tokens) pairs -- see resources/prompts.json and this
// repo's README "Dataset strategy". `.random()` so successive
// virtual users (see the closed-loop note below) each draw an independent prompt rather
// than replaying the corpus in a fixed order.
const promptFeeder = jsonFile("prompts.json").random();

// `max_tokens` MUST be set per-request from the real target output length
// carried by the feeder row -- never a flat constant. The study this replaces already hit
// this exact bug once (silently capped at 30 output tokens regardless of real length).
// The `?? defaultMaxTokens` is defense-in-depth for a malformed row, not the normal path.
const chatRequestBody = StringBody((session) =>
  JSON.stringify({
    model: config.model,
    messages: [{ role: "user", content: session.get("prompt") }],
    max_tokens: session.get("max_tokens") ?? config.defaultMaxTokens,
    stream: true,
  })
);

// `stream: true` mirrors AIPerf's own `--streaming` flag (real interactive-chat client
// behavior) without needing Gatling's SSE protocol: a plain http() POST already blocks
// until the chunked text/event-stream response completes, which is exactly the
// wait-for-full-response semantics the closed-loop model needs. Gatling does not parse the
// individual `data: {...}` chunks -- Akamas scores from vLLM's own
// Prometheus metrics, not from this load generator's report, so there is no need to
// reproduce AIPerf's own client-side TTFT/ITL formulas here. The optional [DONE] check
// (config.checkStreamDone) only confirms the stream wasn't truncated -- see config above.
const responseChecks = [
  status().is(200),
  ...(config.checkStreamDone ? [substring("[DONE]").exists()] : []),
];
const chatCompletion = http("Chat completion")
  .post("/v1/chat/completions")
  .body(chatRequestBody)
  .check(...responseChecks);

// Each virtual user executes exactly ONE request-response cycle, then finishes -- no
// explicit loop in the scenario body. This (not a `forever()` loop) is what actually
// implements the closed-loop model with `injectClosed` below: `constantConcurrentUsers(n)`
// injects a replacement user the instant one finishes, to keep exactly n concurrently
// in flight for the whole level duration -- i.e. a new request is only ever sent once a
// previous one has fully completed, which is the defining property of closed-loop load,
// identical in effect to AIPerf's own N-virtual-user model.
//
// A `forever()` loop was tried first and is deliberately NOT used here: verified locally
// (`gatling run` against a local mock server) that it hangs indefinitely past the very
// first concurrency level. A virtual user stuck in an unconditional infinite loop never
// finishes, so it's never replaced and the simulation never advances to the next
// `constantConcurrentUsers` step -- `injectClosed`'s per-step `duration` only bounds when
// the injector STOPS ADDING new users, not when already-running ones must stop.
const sweepScenario = scenario("vLLM concurrency sweep").exec(
  feed(promptFeeder),
  exec(chatCompletion)
);

export default simulation((setUp) => {
  setUp(
    sweepScenario
      .injectClosed(
        ...config.levels.map((n) =>
          constantConcurrentUsers(n).during(config.levelDurationS)
        )
      )
      .protocols(httpProtocol)
  ).assertions(
    // Load-generator health gate -- see config.maxFailedPercent. Marks the Enterprise
    // run failed (and exits run_test_enterprise.sh non-zero) if the generator itself
    // misbehaved, so Akamas never records a trial built on corrupt concurrency.
    global().failedRequests().percent().lte(config.maxFailedPercent)
  );
});
