#!/usr/bin/env node
// One-time, OFFLINE dataset prep (see README "Dataset strategy" — CLAUDE.md §6, approach 2:
// "medium fidelity"). Not run by the Kubernetes Job or at container start — its output
// (resources/prompts.json) is committed into the repo and simply read by the Gatling
// simulation's feeder. Re-run this manually (`npm run prepare-dataset`) only if the corpus
// ever needs regenerating (e.g. a different target size, or the served model changes).
//
// Replicates vLLM's own benchmarks/benchmark_dataset.py ShareGPT sampling logic (single
// first human->gpt turn pair, tokenized with the real serving tokenizer, filtered to
// AIPerf's hardcoded bounds: min_seq_len=4, max_prompt_len=1024, max_total_len=2048) so the
// resulting corpus is directly comparable to what AIPerf itself would have sent.
import fs from "node:fs";
import { pipeline as pipelineCb } from "node:stream/promises";
import { chain } from "stream-chain";
import { parser } from "stream-json";
import { streamArray } from "stream-json/streamers/stream-array.js";
import { AutoTokenizer } from "@huggingface/transformers";

const DATASET_URL =
  "https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json";
const RAW_FILE = new URL("../.cache/sharegpt.json", import.meta.url);
const OUTPUT_FILE = new URL("../resources/prompts.json", import.meta.url);

const MIN_SEQ_LEN = 4;
const MAX_PROMPT_LEN = 1024;
const MAX_TOTAL_LEN = 2048;
// 8000 entries, not the full ~73k-conversation dataset: large enough that a `.random()`
// feeder won't visibly repeat within a single 300s/1024-concurrent level (see README "Sizing
// the corpus"), while keeping this script's one-time tokenization pass (the same ~4-5min-class
// cost AIPerf itself pays once, see CLAUDE.md §6) fast to re-run when needed.
const TARGET_CORPUS_SIZE = 8000;

if (!fs.existsSync(RAW_FILE)) {
  console.error(`Downloading ShareGPT dataset (~670MB) to ${RAW_FILE}...`);
  fs.mkdirSync(new URL("../.cache/", import.meta.url), { recursive: true });
  const res = await fetch(DATASET_URL);
  if (!res.ok || !res.body) {
    throw new Error(`Failed to download dataset: HTTP ${res.status}`);
  }
  await pipelineCb(res.body, fs.createWriteStream(RAW_FILE));
}

console.error("Loading Qwen2.5-7B-Instruct tokenizer (downloads once, cached under ~/.cache)...");
const tokenizer = await AutoTokenizer.from_pretrained("Qwen/Qwen2.5-7B-Instruct");

console.error("Streaming the raw dataset (too large for a single JSON.parse/readFileSync call)...");
const pipeline = chain([fs.createReadStream(RAW_FILE), parser(), streamArray()]);

const corpus = [];
let scanned = 0;
for await (const { value: conv } of pipeline) {
  scanned++;
  if (corpus.length >= TARGET_CORPUS_SIZE) break;

  const turns = conv.conversations;
  if (!Array.isArray(turns) || turns.length < 2) continue;
  const prompt = turns[0]?.value;
  const completion = turns[1]?.value;
  if (typeof prompt !== "string" || typeof completion !== "string") continue;
  if (turns[0].from !== "human" || turns[1].from !== "gpt") continue;

  const promptLen = tokenizer.encode(prompt).length;
  const outputLen = tokenizer.encode(completion).length;

  if (promptLen < MIN_SEQ_LEN || outputLen < MIN_SEQ_LEN) continue;
  if (promptLen > MAX_PROMPT_LEN) continue;
  if (promptLen + outputLen > MAX_TOTAL_LEN) continue;

  corpus.push({ prompt, max_tokens: outputLen });

  if (corpus.length % 1000 === 0) {
    console.error(`  ${corpus.length}/${TARGET_CORPUS_SIZE} valid entries (scanned ${scanned})...`);
  }
}
pipeline.destroy();

if (corpus.length < TARGET_CORPUS_SIZE) {
  console.error(
    `WARNING: only found ${corpus.length}/${TARGET_CORPUS_SIZE} valid entries in the whole dataset.`
  );
}

const outLens = corpus.map((c) => c.max_tokens);
const mean = outLens.reduce((a, b) => a + b, 0) / outLens.length;
console.error(
  `Done: ${corpus.length} entries from ${scanned} scanned conversations. ` +
    `Output-token target: mean ${mean.toFixed(1)}, min ${Math.min(...outLens)}, max ${Math.max(...outLens)}.`
);

fs.writeFileSync(OUTPUT_FILE, JSON.stringify(corpus));
console.error(`Wrote ${corpus.length} entries to ${OUTPUT_FILE.pathname}`);
