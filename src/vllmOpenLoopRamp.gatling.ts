import {
  simulation,
  scenario,
  jsonFile,
  feed,
  exec,
  StringBody,
  getParameter,
  constantConcurrentUsers,
  rampUsersPerSec,
  atOnceUsers,
  substring,
  jsonPath,
  during,
  stopLoadGeneratorIf,
  details,
} from "@gatling.io/core";
import { http, status } from "@gatling.io/http";

// Study 2 (Gemma 4 26B-A4B FP8 on one L40S, kernels): the open-loop load of
// vllm-benchmark's studies 27/29/30, on Gatling instead of AIPerf.
//
// - Warm-up: 60 s at concurrency 4 (closed), discarded, as study 30.
// - Measured run: a linear arrival-rate ramp 0 -> R req/s over D s. Open loop: arrivals do
//   not wait for responses, so past the server's capacity the queue grows and TTFT shows it.
//   Arrivals are Poisson (`.randomized()`, exponential gaps). Studies 27/29/30 use gamma
//   arrivals with smoothness 4, which Gatling does not offer; Poisson has the same mean
//   and 4x the variance of the gaps (study 27's first run used Poisson too).
// - Watchdog: a third scenario reads vLLM's TTFT and ITL p95 over 150 s from Prometheus every
//   15 s, from the measured run's start + 150 s. Over 2x the SLA for 120 s, it stops the load
//   generator with a SUCCESS status: past an open loop's capacity every later scoring window
//   is invalid anyway. Same rule as study 30's run_test.sh, but inside the generator pod, so
//   a restart of the Akamas toolbox cannot leave the ramp running (study 30's incident of
//   2026-10-06).
//
// Akamas scores from vLLM's own Prometheus metrics, not from this report: the best valid
// 3-minute window before the SLA breaks.

const config = {
  baseUrl: getParameter("base.url", "http://vllm.llm-serving.svc.cluster.local:8000"),
  // MUST match --served-model-name of study 2's vLLM (and "model" in .gatling/package.conf).
  model: getParameter("model", "gemma4-26b-l40s"),
  defaultMaxTokens: parseInt(getParameter("default.maxTokens", "256"), 10),

  warmupConcurrency: parseInt(getParameter("warmup.concurrency", "4"), 10),
  warmupS: parseInt(getParameter("warmup.durationSeconds", "60"), 10),
  // Study 30's ramp: 0 -> 40 req/s over 6000 s (0.4 req/s per minute).
  rampRate: parseFloat(getParameter("ramp.rate", "40")),
  rampS: parseInt(getParameter("ramp.durationSeconds", "6000"), 10),

  // Watchdog. Thresholds are 2x study 30's SLA (TTFT p95 1500 ms, ITL p95 300 ms).
  watchdogEnabled: getParameter("watchdog.enabled", "true") === "true",
  prometheusUrl: getParameter(
    "watchdog.prometheusUrl",
    "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
  ),
  ttftLimitMs: parseFloat(getParameter("watchdog.ttftMs", "3000")),
  itlLimitMs: parseFloat(getParameter("watchdog.itlMs", "600")),
  holdS: parseInt(getParameter("watchdog.holdSeconds", "120"), 10),
  armDelayS: parseInt(getParameter("watchdog.armDelaySeconds", "150"), 10),
  periodS: parseInt(getParameter("watchdog.periodSeconds", "15"), 10),

  // Load-generator health gate on the chat requests only (the watchdog's Prometheus calls
  // are excluded). vLLM queues rather than rejects, so past the knee the requests get slow,
  // not KO: a failure here is a broken generator or server, not saturation.
  maxFailedPercent: parseFloat(getParameter("assert.maxFailedPercent", "5")),
  checkStreamDone: getParameter("check.streamDone", "true") === "true",
};

const httpProtocol = http
  .baseUrl(config.baseUrl)
  .acceptHeader("application/json")
  .contentTypeHeader("application/json")
  .shareConnections();

// Real ShareGPT (prompt, target_output_tokens) pairs, see resources/prompts.json.
const promptFeeder = jsonFile("prompts.json").random();

const chatRequestBody = StringBody((session) =>
  JSON.stringify({
    model: config.model,
    messages: [{ role: "user", content: session.get("prompt") }],
    max_tokens: session.get("max_tokens") ?? config.defaultMaxTokens,
    stream: true,
  })
);

const chatCompletion = http("Chat completion")
  .post("/v1/chat/completions")
  .body(chatRequestBody)
  .check(status().is(200), ...(config.checkStreamDone ? [substring("[DONE]").exists()] : []));

// One request per virtual user: with injectOpen each arrival is one request.
const oneRequest = exec(feed(promptFeeder), exec(chatCompletion));
const warmup = scenario("Warm-up").exec(oneRequest);
const ramp = scenario("Open-loop ramp").exec(oneRequest);

// --- Watchdog ---------------------------------------------------------------------------
const p95 = (metric: string) =>
  `histogram_quantile(0.95, sum by(le)(rate(vllm:${metric}_seconds_bucket{model_name="${config.model}"}[150s])))*1000`;

// Prometheus returns NaN (no traffic) or nothing (no series) as "no data": never over.
const promQuery = (name: string, metric: string, key: string) =>
  http(name)
    .get(`${config.prometheusUrl}/api/v1/query`)
    .queryParam("query", p95(metric))
    .check(status().is(200), jsonPath("$.data.result[0].value[1]").optional().saveAs(key));

const isOver = (raw: unknown, limit: number) => {
  const v = parseFloat(String(raw));
  return Number.isFinite(v) && v > limit;
};

const watchdogLoop = during(config.rampS).on(
  exec(promQuery("Watchdog TTFT p95", "time_to_first_token", "ttft"))
    .exec(promQuery("Watchdog ITL p95", "inter_token_latency", "itl"))
    .exec((session) => {
      const now = Date.now();
      const over =
        isOver(session.contains("ttft") ? session.get("ttft") : null, config.ttftLimitMs) ||
        isOver(session.contains("itl") ? session.get("itl") : null, config.itlLimitMs);
      // 0 = under the limits at the previous reading.
      const prev = session.contains("overSince") ? session.get<number>("overSince") : 0;
      const since = over ? prev || now : 0;
      const fired = over && now - since >= config.holdS * 1000;
      if (fired) {
        console.log(
          `WATCHDOG ${(Date.now()/1000).toFixed(1)}: TTFT p95 ${session.get("ttft")} ms / ITL p95 ${session.get("itl")} ms over ` +
            `${config.ttftLimitMs}/${config.itlLimitMs} ms for ${config.holdS} s: stopping the ramp`
        );
      }
      return session
        .remove("ttft")
        .remove("itl")
        .set("overSince", since)
        .set("fired", fired);
    })
    .exec(stopLoadGeneratorIf("SLA broken past 2x for the hold time: end of the measured run", "#{fired}"))
    .pause(config.periodS)
);

// Starts with the measured run (after the warm-up), armed armDelayS later: the first 150 s
// p95 of the ramp would still contain the warm-up's requests.
const watchdog = scenario("Watchdog").pause(config.armDelayS).exec(watchdogLoop);

export default simulation((setUp) => {
  const rampStep = ramp
    .injectOpen(rampUsersPerSec(0).to(config.rampRate).during(config.rampS).randomized())
    .protocols(httpProtocol);
  const measured = config.watchdogEnabled
    ? [rampStep, watchdog.injectOpen(atOnceUsers(1)).protocols(httpProtocol)]
    : [rampStep];

  setUp(
    warmup
      .injectClosed(constantConcurrentUsers(config.warmupConcurrency).during(config.warmupS))
      .protocols(httpProtocol)
      .andThen(...measured)
  )
    // Hard stop: the ramp, plus room for requests still in flight at its end.
    .maxDuration(config.warmupS + config.rampS + 600)
    .assertions(details("Chat completion").failedRequests().percent().lte(config.maxFailedPercent));
});
