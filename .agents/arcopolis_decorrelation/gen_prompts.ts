#!/usr/bin/env -S deno run --allow-read --allow-write
/**
 * @module
 *
 * Generates the classification prompts for the de-correlation experiment from corpus.jsonl.
 *
 * Two prompt shapes, both requesting the SAME structured clearance block so all conditions are
 * gradeable identically:
 *
 *   - BLIND (conditions: blind_same_model, cross_model) — implements the
 *     `arcopolis-external-seal-prompt` frame-removal: the raw goal, the A/B/C/D/S class block
 *     quoted verbatim from AGENTS.md, BOTH the tempting surface AND the engine-evaluation source
 *     embedded as neutrally-labelled excerpts (order shuffled per case so position never leaks the
 *     answer), and a forcing question phrased functionally (SHOW / EVALUATE / hold / perform /
 *     present) with no class words and no "predicate". Self-contained: a reader with no repo can
 *     answer it. This is the input that makes same-model and cross-model COMPARABLE.
 *
 *   - ANCHORED (condition: anchored_same_model) — deliberately the OPPOSITE: it shows ONLY the
 *     author's proposed surface and asks an in-loop reviewer to ratify/flag it. This reproduces the
 *     deployed same-model in-loop gate the doctrine treats as a FLOOR (documented 0% catch on
 *     Spike-25). It is a within-same-model sanity anchor, not the de-correlation comparison.
 *
 * Outputs (under --out, default ./out):
 *   prompts.jsonl                  one {case_id, condition, prompt} per blind+anchored prompt
 *   blind/<id>.txt, anchored/<id>.txt   individual prompt files
 *
 * The cross-model arm runs the same blind prompts through a non-Claude frontier model agentically in
 * the worktree (see `corpus_classify_brief.md`): the agent reads one opaque-named task file under
 * `out/tasks/` and writes one verdict line — it never sees the real T-/C- case id. `opaqueId` /
 * `buildIdMap` below define that stable category-free mapping (derivable from `corpus.jsonl` alone, so
 * no committed sidecar is required to re-grade).
 */

import { Command } from "@cliffy/command"
import { ensureDir } from "@std/fs"
import { join } from "@std/path"
import { type Case, loadCorpus, pkgDir } from "./schema.ts"
import { type Excerpt, EXCERPTS } from "./excerpts.ts"

/** Quote the canonical A/B/C/D/S native-authority class block verbatim from AGENTS.md. */
export const extractClassBlock = (agentsText: string): string => {
  // Normalize CRLF -> LF first: on an autocrlf checkout the `\n\n` bullet terminator below would not
  // match `\r\n\r\n`, dropping the last bullet and throwing a spurious "expected 5 bullets".
  const text = agentsText.replace(/\r\n/g, "\n")
  const section = text.match(
    /### Native-authority class[\s\S]*?(?=\n### )/,
  )
  if (!section) throw new Error("AGENTS.md: 'Native-authority class' section not found")
  const bullets = section[0].match(/- \*\*[ABCDS] —[\s\S]*?(?=\n- \*\*|\n\n)/g)
  if (!bullets || bullets.length !== 5) {
    throw new Error(
      `AGENTS.md: expected 5 native-authority class bullets (A/B/C/D/S), found ${
        bullets?.length ?? 0
      }`,
    )
  }
  return bullets.map((b) => b.trim()).join("\n")
}

/**
 * The class block as shown to a BLIND reader, de-leaked. Two changes vs the raw AGENTS.md bullets:
 *   1. The rubric's concrete repo symbols (`set_has_items`, `MGOAL_FIND_ITEM`, `crafting_inventory`,
 *      `ACTION_MOVE_*`, `uilist::query`, ...) are abstracted — those exact tokens also appear as the
 *      excerpts' cited symbols, so leaving them lets a reader lexically match the answer instead of
 *      reasoning about the consumer.
 *   2. The display-verdict carve-out (a verdict computed purely to drive the GUI is D, even though it
 *      is computed) is appended — it governs how the controls are graded but lives only in the
 *      design-interrogate skill, not the AGENTS.md bullet, so a blind reader judged on it must see it.
 */
export const readerClassBlock = (classBlock: string): string => {
  const neutral = classBlock
    .replace(/`condition\.cpp`'s `set_has_items`/g, "a dialogue possession check")
    .replace(
      /`MGOAL_FIND_ITEM` over `crafting_inventory\(\)`/g,
      "a find-item objective over the reachable inventory",
    )
    .replace(/`crafting_inventory\(\)`/g, "the reachable inventory")
    .replace(/`MGOAL_FIND_ITEM`/g, "a find-item objective")
    .replace(/`set_has_items?`/g, "a possession check")
    .replace(/`ACTION_MOVE_\*`/g, "a registered movement action")
    .replace(/`game::handle_action\(\)`/g, "the engine's input-dispatch site")
    .replace(/`input_context::handle_input\(\)`/g, "the real input loop")
    .replace(/`uilist::query\(\)`/g, "an interactive menu query")
    .replace(/`query_popup`\/`query_yn`/g, "a yes/no prompt")
  return neutral +
    "\n\n_Class follows the CONSUMER, not whether a value is computed:_ a verdict computed PURELY to " +
    "drive what the GUI shows — an is-low colour, a threat tint, a remembered-vs-visible shading — is " +
    "**D** even though it is computed; a verdict an engine condition/mission/dialogue/eligibility check " +
    "consumes is **C**."
}

// --- deterministic per-case shuffle (so excerpt position never leaks the answer) ---

const cyrb53 = (str: string, seed = 0): number => {
  let h1 = 0xdeadbeef ^ seed, h2 = 0x41c6ce57 ^ seed
  for (let i = 0; i < str.length; i++) {
    const ch = str.charCodeAt(i)
    h1 = Math.imul(h1 ^ ch, 2654435761)
    h2 = Math.imul(h2 ^ ch, 1597334677)
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909)
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909)
  return 4294967296 * (2097151 & h2) + (h1 >>> 0)
}

const mulberry32 = (seed: number): () => number => {
  let a = seed >>> 0
  return () => {
    a |= 0
    a = (a + 0x6d2b79f5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const shuffled = <T>(items: T[], seed: number): T[] => {
  const rng = mulberry32(seed)
  const out = [...items]
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1))
    ;[out[i], out[j]] = [out[j], out[i]]
  }
  return out
}

const renderExcerpt = (ex: Excerpt, n: number): string =>
  `### Excerpt ${n} — ${ex.neutral_desc}\n` +
  `(\`${ex.file}\` :: \`${ex.symbol}\`, lines ${ex.lines})\n\n` +
  "```" + ex.lang + "\n" + ex.text + "\n```"

const CLEARANCE_BLOCK = `{
  "consumer": "<the concrete engine caller/site that reads this, and the question it asks>",
  "class": "<A | B | C | D | S>",
  "scope": "<the reach the consumer needs: e.g. only the character's own carried items / items reachable nearby / a map region / not applicable>",
  "decisive_source": "<the file::function whose body you relied on, and what its body does>",
  "divergence": "<one concrete game state where a WRONG answer would be exposed, appropriate to the class you named>",
  "support_disposition": "<if the authority is an interactive prompt/menu the backend cannot currently drive, 'unsupported/fail-loud'; if it can be driven, 'supported'; otherwise 'n/a'>"
}`

const PREAMBLE = (classBlock: string): string =>
  `You are reviewing a small but load-bearing design decision for the **Arcopolis** project.
Default skeptical: your job is to CLASSIFY FROM SCRATCH, not to bless a framing. "It looks
reasonable" is not a useful answer.

## Standing context

Arcopolis runs Cataclysm: Bright Nights (a roguelike survival game engine) **headless** as a
simulation backend for a separate mouse-first frontend. The whole project is organized around
**equivalence**: a backend capability must behave like the real game would, proven by driving the
engine's own code paths — never by reproducing an end state through a convenient shortcut.

Every backend surface or action answers to exactly one **native-authority class**, derived from the
**downstream consumer** (what ultimately reads the surface, or what the goal needs) — never from the
wording of the request:

${classBlock}`

export const blindPrompt = (c: Case, classBlock: string): string => {
  const order = shuffled(c.excerpts, cyrb53(c.id))
  const excerpts = order.map((id, i) => renderExcerpt(EXCERPTS[id], i + 1)).join("\n\n")
  return `${PREAMBLE(readerClassBlock(classBlock))}

## The goal

> ${c.goal_plain}

## Source you may rely on

Below are real, trimmed excerpts of Bright Nights engine source, given to you **neutrally** — which
(if any) is the right authority for the goal above is exactly what you must decide. You have no repo
checkout; reason from these excerpts. If you believe a decisive routine is NOT shown here, say so.

${excerpts}

## Your task

Name the concrete downstream engine consumer for this goal, and say what the engine DOES with the
value: does it **SHOW** it, **EVALUATE** a yes/no it computes from it, hold it as **raw state**,
**perform** it as an action, or **present** it as a menu? Derive the native-authority class
(A/B/C/D/S) from THAT consumer — not from the shape of any surface above. State the reach/scope the
consumer needs. Then give ONE concrete game state that would prove a wrong answer wrong, appropriate
to the class you named.

If the goal serves MORE THAN ONE consumer (e.g. render a panel AND answer a check), classify the
LOAD-BEARING one — the authority whose wrong answer breaks gameplay — not the most prominent display.
If that authority is an interactive prompt/menu the backend cannot currently drive, say so in
\`support_disposition\`: an unsupported menu must FAIL LOUD, never silently no-op.

## Output

Return EXACTLY this JSON object and nothing else:

${CLEARANCE_BLOCK}`
}

export const anchoredPrompt = (c: Case, classBlock: string): string => {
  const surface = EXCERPTS[c.surface_excerpt]
  return `You are an **in-loop reviewer** on the **Arcopolis** project. A teammate has proposed how to
satisfy a goal and you are reviewing their proposal before it ships.

## Standing context

Arcopolis runs Cataclysm: Bright Nights headless as a simulation backend for a separate frontend,
organized around **equivalence** (drive the engine's own paths; never reproduce an end state by a
shortcut). Every backend surface answers to one **native-authority class**, derived from the
**downstream consumer**, never the request's wording:

${readerClassBlock(classBlock)}

## The proposal under review

**Goal:** ${c.goal_plain}

**Proposed solution:** expose the backend surface below and treat what it reports as the answer to
the goal.

### The proposed surface — ${surface.neutral_desc}
(\`${surface.file}\` :: \`${surface.symbol}\`, lines ${surface.lines})

\`\`\`${surface.lang}
${surface.text}
\`\`\`

## Your task

Review the proposal. Is exposing this surface the correct, equivalence-faithful way to answer the
goal? Decide the goal's true native-authority class from its downstream consumer. If the proposal is
wrong, say what the correct class and authority are, and give one concrete game state that exposes
the error.

## Output

Return EXACTLY this JSON object and nothing else:

{
  "consumer": "<the concrete engine caller/site that reads this, and the question it asks>",
  "class": "<A | B | C | D | S>",
  "scope": "<the reach the consumer needs>",
  "decisive_source": "<the file::function whose body you relied on, and what it does>",
  "divergence": "<one concrete state where a wrong answer would be exposed>",
  "verdict": "<ratify | flag>"
}`
}

/** A stable, category-free id (so a task filename / heading never leaks trap-vs-control). */
export const opaqueId = (id: string): string => "case-" + (cyrb53(id, 9176) >>> 0).toString(36)

/**
 * The opaque-id → real-case-id map, derived from the corpus alone. The blind cross-model + same-model
 * agents write the OPAQUE id; collect.ts / grade.ts remap it back with this. Because it is a pure
 * function of `corpus.jsonl`, re-grading needs no committed sidecar — `out/id_map.json` is just a
 * convenience cache that gen_workflow.ts writes for the running agents.
 */
export const buildIdMap = (cases: { id: string }[]): Record<string, string> =>
  Object.fromEntries(cases.map((c) => [opaqueId(c.id), c.id]))

/**
 * The opaque→real map for remapping verdicts: prefer the cached `out/id_map.json` sidecar, else rebuild
 * it from the corpus via {@link buildIdMap}. This is the one place collect.ts / grade.ts get the map, so
 * re-grading from a fresh checkout (out/ is git-ignored) needs no extra step.
 */
export const loadOrBuildIdMap = async (
  cases: { id: string }[],
): Promise<Record<string, string>> => {
  try {
    return JSON.parse(await Deno.readTextFile(join(pkgDir, "out", "id_map.json")))
  } catch (_) {
    return buildIdMap(cases)
  }
}

const main = new Command()
  .name("gen_prompts")
  .description("Generate blind + anchored classification prompts for the de-correlation experiment")
  .option("-o, --out <dir:string>", "output directory", { default: join(pkgDir, "out") })
  .action(async ({ out }) => {
    const cases = await loadCorpus()
    const agents = await Deno.readTextFile(join(pkgDir, "..", "..", "AGENTS.md"))
    const classBlock = extractClassBlock(agents)

    await ensureDir(join(out, "blind"))
    await ensureDir(join(out, "anchored"))

    const prompts: string[] = []
    for (const c of cases) {
      const blind = blindPrompt(c, classBlock)
      const anchored = anchoredPrompt(c, classBlock)
      await Deno.writeTextFile(join(out, "blind", `${c.id}.txt`), blind)
      await Deno.writeTextFile(join(out, "anchored", `${c.id}.txt`), anchored)
      prompts.push(JSON.stringify({ case_id: c.id, condition: "blind_same_model", prompt: blind }))
      prompts.push(
        JSON.stringify({ case_id: c.id, condition: "anchored_same_model", prompt: anchored }),
      )
    }
    await Deno.writeTextFile(join(out, "prompts.jsonl"), prompts.join("\n") + "\n")

    console.log(
      `generated ${cases.length} cases x 2 prompts -> ${out}\n` +
        `  prompts.jsonl, blind/, anchored/`,
    )
  })

if (import.meta.main) {
  await main.parse(Deno.args)
}
