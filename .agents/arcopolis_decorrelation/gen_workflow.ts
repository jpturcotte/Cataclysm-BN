#!/usr/bin/env -S deno run --allow-read --allow-write
/**
 * @module
 *
 * Emits the same-model classification workflow script for the Workflow tool.
 *
 * The de-correlation experiment's same-model arms must each be a FRESH, BLIND, same-substrate
 * (Claude) reasoner on one prompt. Each (case × condition × sample) becomes one subagent. To keep
 * the workflow script small, the prompts are NOT inlined: each is written to an OPAQUE-named file
 * under out/tasks/, and the agent is told to read EXACTLY that one file (its task), reason from it
 * ALONE (no other file, no repo, no web), and write ONLY its one-line verdict. The opaque file name
 * means reading the task path never leaks the real T-/C- case id (which encodes trap-vs-control);
 * out/id_map.json resolves it back and collect.ts remaps it before grading.
 *
 * The run is IDEMPOTENT: only slots WITHOUT an existing raw file are scheduled, so a re-run backfills
 * a partial (rate-limited) run. Agents run in small serial chunks to stay under rate limits. Run
 * collect.ts afterwards.
 *
 * Usage: gen_workflow.ts [blindSamples=5] [anchoredSamples=3] [chunk=5]
 */

import { join } from "@std/path"
import { ensureDir } from "@std/fs"
import { pkgDir } from "./schema.ts"
import { opaqueId } from "./gen_prompts.ts"

const blindSamples = Number(Deno.args[0] ?? 5)
const anchoredSamples = Number(Deno.args[1] ?? 3)
const chunk = Number(Deno.args[2] ?? 5)

const prompts = (await Deno.readTextFile(join(pkgDir, "out", "prompts.jsonl")))
  .trim().split("\n").map((l) => JSON.parse(l))

// write each prompt to an opaque-named task file (the agent reads exactly this one file)
const taskDir = join(pkgDir, "out", "tasks")
await ensureDir(taskDir)
for (const p of prompts) {
  await Deno.writeTextFile(join(taskDir, `${opaqueId(p.case_id)}__${p.condition}.txt`), p.prompt)
}

// which (opaque, condition, sample) slots already have a raw verdict file?
const rawDir = join(pkgDir, "verdicts", "raw")
const present = new Set<string>()
try {
  for (const e of Deno.readDirSync(rawDir)) {
    if (e.isFile && e.name.endsWith(".json")) present.add(e.name.replace(/\.json$/, ""))
  }
} catch (_) { /* dir may not exist yet */ }

const samplesFor = (cond: string) => cond === "blind_same_model" ? blindSamples : anchoredSamples
const tasks: { opaque: string; condition: string; sample: number }[] = []
for (const p of prompts) {
  const opaque = opaqueId(p.case_id)
  for (let s = 1; s <= samplesFor(p.condition); s++) {
    if (!present.has(`${opaque}__${p.condition}__${s}`)) {
      tasks.push({ opaque, condition: p.condition, sample: s })
    }
  }
}

// sidecar: opaque id -> real case id (read by collect.ts; NEVER embedded in an agent prompt)
const idMap = Object.fromEntries(prompts.map((p) => [opaqueId(p.case_id), p.case_id]))
await Deno.writeTextFile(join(pkgDir, "out", "id_map.json"), JSON.stringify(idMap, null, 2) + "\n")

const script = `export const meta = {
  name: "arcopolis-decorrelation-same-model",
  description: "Blind + anchored same-model classification arms (Arcopolis de-correlation experiment)",
  phases: [{ title: "blind_same_model" }, { title: "anchored_same_model" }],
}

const CHUNK = ${chunk}
const DIR = ".agents/arcopolis_decorrelation"
const TASKS = ${JSON.stringify(tasks)}

log("scheduling " + TASKS.length + " missing same-model classification(s) in chunks of " + CHUNK)

const runOne = (t) => {
  const promptPath = DIR + "/out/tasks/" + t.opaque + "__" + t.condition + ".txt"
  const rawPath = DIR + "/verdicts/raw/" + t.opaque + "__" + t.condition + "__" + t.sample + ".json"
  const line =
    '{"case_id":' + JSON.stringify(t.opaque) +
    ',"condition":' + JSON.stringify(t.condition) +
    ',"model":"claude-opus-4-8","sample":' + t.sample +
    ',"consumer":"<one sentence>","class":"<A|B|C|D|S>","scope":"<the reach>","decisive_source":"<file::function + what it does>","divergence":"<one state>","support_disposition":"<unsupported/fail-loud | supported | n/a>"}'
  const instr =
    "You are a BLIND classifier in a research measurement. Your task is in EXACTLY ONE file.\\n\\n" +
    "1. Use the Read tool ONCE to read your task prompt:\\n" + promptPath + "\\n\\n" +
    "2. Reason ONLY from that file's contents and your own knowledge. Do NOT read any other file, do " +
    "NOT search the web or any repository, do NOT inspect a codebase, do NOT ask questions. Use NO " +
    "tool other than that single Read and a single Write.\\n\\n" +
    "3. Use the Write tool EXACTLY ONCE to create this file (overwrite if it exists):\\n" + rawPath +
    "\\n\\nIts ENTIRE contents must be ONE line of strict JSON — no code fences, no prose, no extra " +
    "keys, exactly this shape:\\n" + line + "\\n\\n" +
    "Replace consumer/class/scope/decisive_source/divergence/support_disposition with your own " +
    "analysis (class is ONE letter: A, B, C, D, or S). Keep case_id/condition/model/sample EXACTLY " +
    "as given above. Escape any quotes inside string values so the line stays valid JSON. Then stop."
  const short = t.condition === "blind_same_model" ? "blind" : "anchored"
  return agent(instr, { label: short + ":" + t.opaque + "#" + t.sample, phase: t.condition })
}

let done = 0
for (let i = 0; i < TASKS.length; i += CHUNK) {
  await parallel(TASKS.slice(i, i + CHUNK).map((t) => () => runOne(t)))
  done += Math.min(CHUNK, TASKS.length - i)
  log("completed " + done + " / " + TASKS.length)
}
return { scheduled: TASKS.length }
`

const outPath = join(pkgDir, "out", "run_same_model.workflow.js")
await Deno.writeTextFile(outPath, script)
console.log(
  `wrote ${outPath} (${
    (script.length / 1024).toFixed(0)
  } KB)\n  ${tasks.length} MISSING slots (of ${
    prompts.filter((p) => p.condition === "blind_same_model").length * blindSamples +
    prompts.filter((p) => p.condition === "anchored_same_model").length * anchoredSamples
  }), chunk=${chunk}`,
)
