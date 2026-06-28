#!/usr/bin/env -S deno run --allow-read --allow-write
/**
 * @module
 *
 * Assembles the per-agent verdict files (verdicts/raw/*.json, one written by each blind/anchored
 * same-model subagent) into verdicts/blind_same_model.jsonl and verdicts/anchored_same_model.jsonl.
 *
 * Tolerant by design: an agent may wrap its line in a code fence or add stray prose, so each file is
 * reduced to its first `{`..last `}` and parsed. Every line is then validated against VerdictSchema;
 * malformed files are reported (not silently dropped) so the count is honest.
 */

import { ensureDir, walk } from "@std/fs"
import { join } from "@std/path"
import * as v from "@valibot/valibot"
import { loadCorpus, pkgDir, VerdictSchema } from "./schema.ts"
import { loadOrBuildIdMap } from "./gen_prompts.ts"

const parse = v.safeParser(VerdictSchema)

const main = async () => {
  const rawDir = join(pkgDir, "verdicts", "raw")
  await ensureDir(rawDir) // walk() throws Deno.errors.NotFound on a missing dir
  const byCond: Record<string, string[]> = { blind_same_model: [], anchored_same_model: [] }
  const bad: string[] = []
  let n = 0

  // opaque id -> real case id (the agent only ever saw the opaque id; remap before validating).
  const idMap = await loadOrBuildIdMap(await loadCorpus())

  for await (const entry of walk(rawDir, { exts: [".json"], includeDirs: false })) {
    n++
    const text = await Deno.readTextFile(entry.path)
    const a = text.indexOf("{"), b = text.lastIndexOf("}")
    if (a < 0 || b <= a) {
      bad.push(`${entry.name}: no JSON object`)
      continue
    }
    let obj: unknown
    try {
      obj = JSON.parse(text.slice(a, b + 1))
    } catch (e) {
      bad.push(`${entry.name}: ${e instanceof Error ? e.message : String(e)}`)
      continue
    }
    // remap the opaque case_id the agent wrote back to the real corpus id
    if (obj && typeof obj === "object" && "case_id" in obj) {
      const oid = (obj as { case_id: unknown }).case_id
      if (typeof oid === "string" && idMap[oid]) (obj as { case_id: string }).case_id = idMap[oid]
    }
    const r = parse(obj)
    if (!r.success) {
      bad.push(`${entry.name}: ${r.issues.map((i) => i.message).join("; ")}`)
      continue
    }
    const cond = r.output.condition
    if (!(cond in byCond)) {
      bad.push(`${entry.name}: unexpected condition ${cond}`)
      continue
    }
    byCond[cond].push(JSON.stringify(r.output))
  }

  for (const [cond, lines] of Object.entries(byCond)) {
    lines.sort()
    await Deno.writeTextFile(join(pkgDir, "verdicts", `${cond}.jsonl`), lines.join("\n") + "\n")
    console.log(`${cond}: ${lines.length} verdicts`)
  }
  console.log(`scanned ${n} raw files`)
  if (bad.length > 0) {
    console.warn(`\n${bad.length} malformed file(s):`)
    for (const b of bad) console.warn(`  ${b}`)
  }
}

if (import.meta.main) await main()
