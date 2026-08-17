import {
  simulation,
  scenario,
  jsonFile,
  feed,
  exec,
  StringBody,
  getParameter,
  constantConcurrentUsers,
} from "@gatling.io/core";
import { http, status } from "@gatling.io/http";

// Replaces NVIDIA AIPerf's `aiperf profile --concurrency <list> --benchmark-duration 300`
// (see graz-dev/vllm-benchmark studies/1-goodput-realistic-load/k8s/05-job.yaml). Structural
// equivalent: a closed workload model (N virtual users, each waiting for its own previous
// response before sending the next) at each of the same 12 log-spaced concurrency levels,
// 300s per level. See this repo's README "Closed-loop load model" for why an open-loop
// injection profile (rampUsersPerSec/constantUsersPerSec) is not an option here, and for how
// this scenario achieves closed-loop semantics without an explicit loop in its body.
//
// Overridable via `gatling run sweep.levels=2,4 sweep.durationSeconds=10` for a fast local
// smoke test (see README "Running locally") — defaults are the real study's production sweep.
const CONCURRENCY_LEVELS = getParameter("sweep.levels", "150,179,213,253,302,359,428,509,606,722,860,1024")
  .split(",")
  .map((n) => parseInt(n.trim(), 10));
const LEVEL_DURATION_S = parseInt(getParameter("sweep.durationSeconds", "300"), 10);

const baseUrl = getParameter("base.url", "http://vllm.llm-serving.svc.cluster.local:8000");

const httpProtocol = http
  .baseUrl(baseUrl)
  .acceptHeader("application/json")
  .contentTypeHeader("application/json")
  .shareConnections();

// Real ShareGPT (prompt, target_output_tokens) pairs — see resources/prompts.json and this
// repo's README "Dataset strategy" (CLAUDE.md §6, approach 2). `.random()` so successive
// virtual users (see the closed-loop note below) each draw an independent prompt rather
// than replaying the corpus in a fixed order.
const promptFeeder = jsonFile("prompts.json").random();

// CLAUDE.md §5: `max_tokens` MUST be set per-request from the real target output length
// carried by the feeder row — never a flat constant. The study this replaces already hit
// this exact bug once (silently capped at 30 output tokens regardless of real length).
const chatRequestBody = StringBody(
  (session) =>
    JSON.stringify({
      model: "qwen2.5-7b",
      messages: [{ role: "user", content: session.get("prompt") }],
      max_tokens: session.get("max_tokens"),
      stream: true,
    })
);

// `stream: true` mirrors AIPerf's own `--streaming` flag (real interactive-chat client
// behavior) without needing Gatling's SSE protocol: a plain http() POST already blocks
// until the chunked text/event-stream response completes, which is exactly the
// wait-for-full-response semantics the closed-loop model needs. Gatling does not parse the
// individual `data: {...}` chunks — per CLAUDE.md §2/§10, Akamas scores from vLLM's own
// Prometheus metrics, not from this load generator's report, so there is no need to
// reproduce AIPerf's own client-side TTFT/ITL formulas here.
const chatCompletion = http("Chat completion")
  .post("/v1/chat/completions")
  .body(chatRequestBody)
  .check(status().is(200));

// Each virtual user executes exactly ONE request-response cycle, then finishes — no
// explicit loop in the scenario body. This (not a `forever()` loop) is what actually
// implements the closed-loop model with `injectClosed` below: `constantConcurrentUsers(n)`
// injects a replacement user the instant one finishes, to keep exactly n concurrently
// in flight for the whole level duration — i.e. a new request is only ever sent once a
// previous one has fully completed, which is the defining property of closed-loop load,
// identical in effect to AIPerf's own N-virtual-user model.
//
// A `forever()` loop was tried first and is deliberately NOT used here: verified locally
// (`gatling run` against a local mock server) that it hangs indefinitely past the very
// first concurrency level. A virtual user stuck in an unconditional infinite loop never
// finishes, so it's never replaced and the simulation never advances to the next
// `constantConcurrentUsers` step — `injectClosed`'s per-step `duration` only bounds when
// the injector STOPS ADDING new users, not when already-running ones must stop.
const sweepScenario = scenario("vLLM concurrency sweep").exec(
  feed(promptFeeder),
  exec(chatCompletion)
);

export default simulation((setUp) => {
  setUp(
    sweepScenario
      .injectClosed(
        ...CONCURRENCY_LEVELS.map((n) =>
          constantConcurrentUsers(n).during(LEVEL_DURATION_S)
        )
      )
      .protocols(httpProtocol)
  );
});
