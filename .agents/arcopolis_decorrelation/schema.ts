/**
 * @module
 *
 * Valibot schemas + loaders for the cross-model de-correlation experiment.
 *
 * `Case` validates one corpus.jsonl row (a seeded framing-trap or control, with its
 * pre-registered ground truth). `Verdict` validates one ingested clearance block (from a
 * blind same-model subagent, an anchored same-model subagent, or a cross-model reader the
 * user relayed). The loaders fail loud: a corrupt corpus row or a dangling excerpt id is an
 * error, never a silent skip, because the corpus is the pre-registered key everything grades
 * against.
 */

import * as v from "@valibot/valibot"
import { dirname, fromFileUrl, join } from "@std/path"
import { EXCERPTS } from "./excerpts.ts"

export const pkgDir = dirname(fromFileUrl(import.meta.url))

export const CLASS_LETTERS = ["A", "B", "C", "D", "S"] as const
export const ClassSchema = v.picklist(CLASS_LETTERS)
export type ClassLetter = v.InferOutput<typeof ClassSchema>

export const CATEGORIES = [
  // possession/objective traps (Spike 25/26), all Class C
  "canonical",
  "abstraction-routed",
  "wrong-scope",
  // harder multi-axis traps grounded in the spike history
  "hard-predicate", // non-possession predicates (visibility/LOS) + the Spike-26a corrected primitive — C
  "action-fidelity", // Spike 3 move-through-seam, reload — A
  "menu-fidelity", // Spike 12a pickup menu, Spike 21 fail-loud NPC menu, trade/craft/secondary — B
  "compound", // goals bundling a display + a predicate; the blocking authority is C
  // controls
  "control-display",
  "control-rawstate",
  "control-hard-display", // predicate-LOOKING displays (threat tint, seen shading) — D, FP probes
] as const

export const SCOPE_BUCKETS = ["on-person", "crafting-reach", "map", "n/a"] as const

export const CONDITIONS = ["anchored_same_model", "blind_same_model", "cross_model"] as const
export type Condition = (typeof CONDITIONS)[number]

const NonEmpty = v.pipe(v.string(), v.minLength(1))

export const CaseSchema = v.object({
  id: NonEmpty,
  category: v.picklist(CATEGORIES),
  is_trap: v.boolean(),
  goal_plain: NonEmpty,
  excerpts: v.pipe(v.array(NonEmpty), v.minLength(1)),
  surface_excerpt: NonEmpty,
  surface_looks_like: NonEmpty,
  truth_class: ClassSchema,
  truth_scope: NonEmpty,
  truth_scope_bucket: v.picklist(SCOPE_BUCKETS),
  truth_authority: NonEmpty,
  scope_sensitive: v.boolean(),
  divergence_state: NonEmpty,
  notes: NonEmpty,
  // For unsupported-menu traps (B): the reader must additionally state the support disposition
  // (unsupported -> fail loud). Absent/false on every other case.
  requires_fail_loud: v.optional(v.boolean()),
})
export type Case = v.InferOutput<typeof CaseSchema>

export const VerdictSchema = v.object({
  case_id: NonEmpty,
  condition: v.picklist(CONDITIONS),
  model: NonEmpty,
  sample: v.pipe(v.number(), v.integer(), v.minValue(1)),
  consumer: v.string(),
  class: ClassSchema,
  scope: v.string(),
  decisive_source: v.string(),
  divergence: v.string(),
  // Only meaningful for requires_fail_loud cases: "supported" | "unsupported" | "unsupported/fail-loud" | "" .
  support_disposition: v.optional(v.string()),
  raw: v.optional(v.string()),
})
export type Verdict = v.InferOutput<typeof VerdictSchema>

const caseParser = v.safeParser(CaseSchema)
const verdictParser = v.safeParser(VerdictSchema)

/** Split a JSONL blob into non-blank, non-comment (`//`-prefixed) lines with 1-based numbers. */
const jsonlLines = (text: string): { n: number; raw: string }[] =>
  text.split("\n")
    .map((raw, i) => ({ n: i + 1, raw: raw.trim() }))
    .filter(({ raw }) => raw.length > 0 && !raw.startsWith("//"))

/** Load + validate the corpus. Throws on any malformed row or dangling excerpt id. */
export const loadCorpus = async (path = join(pkgDir, "corpus.jsonl")): Promise<Case[]> => {
  const text = await Deno.readTextFile(path)
  const cases: Case[] = []
  const errors: string[] = []
  const ids = new Set<string>()

  for (const { n, raw } of jsonlLines(text)) {
    let parsed: unknown
    try {
      parsed = JSON.parse(raw)
    } catch (e) {
      errors.push(`line ${n}: invalid JSON (${e instanceof Error ? e.message : String(e)})`)
      continue
    }
    const result = caseParser(parsed)
    if (!result.success) {
      errors.push(`line ${n}: ${result.issues.map((i) => i.message).join("; ")}`)
      continue
    }
    const c = result.output
    if (ids.has(c.id)) errors.push(`line ${n}: duplicate case id ${c.id}`)
    ids.add(c.id)
    for (const ex of [...c.excerpts, c.surface_excerpt]) {
      if (!(ex in EXCERPTS)) errors.push(`line ${n} (${c.id}): unknown excerpt id "${ex}"`)
    }
    if (!c.excerpts.includes(c.surface_excerpt)) {
      errors.push(`line ${n} (${c.id}): surface_excerpt "${c.surface_excerpt}" not in excerpts[]`)
    }
    if (c.scope_sensitive && c.truth_scope_bucket === "n/a") {
      errors.push(
        `line ${n} (${c.id}): scope_sensitive case must have a concrete truth_scope_bucket`,
      )
    }
    cases.push(c)
  }

  if (errors.length > 0) {
    throw new Error(`corpus validation failed:\n  ${errors.join("\n  ")}`)
  }
  return cases
}

/** Load + validate a verdicts JSONL file. Returns [] if the file does not exist. */
export const loadVerdicts = async (path: string): Promise<Verdict[]> => {
  let text: string
  try {
    text = await Deno.readTextFile(path)
  } catch (e) {
    if (e instanceof Deno.errors.NotFound) return []
    throw e
  }
  const verdicts: Verdict[] = []
  const errors: string[] = []
  for (const { n, raw } of jsonlLines(text)) {
    let parsed: unknown
    try {
      parsed = JSON.parse(raw)
    } catch (e) {
      errors.push(`${path}:${n}: invalid JSON (${e instanceof Error ? e.message : String(e)})`)
      continue
    }
    const result = verdictParser(parsed)
    if (!result.success) {
      errors.push(`${path}:${n}: ${result.issues.map((i) => i.message).join("; ")}`)
      continue
    }
    verdicts.push(result.output)
  }
  if (errors.length > 0) {
    throw new Error(`verdict validation failed:\n  ${errors.join("\n  ")}`)
  }
  return verdicts
}

// ---- adversarial robustness battery (a second sub-experiment) ----

export const ADV_TYPES = [
  "missing-info",
  "contradiction",
  "mix-true-false",
  "mutation",
  "pushback",
  "memory-corruption",
  "regression",
  "half-truth",
  "ambiguity",
] as const

export const CONFIDENCE = ["high", "medium", "low"] as const

export const AdversarialCaseSchema = v.object({
  id: NonEmpty,
  adv_type: v.picklist(ADV_TYPES),
  robust_rule: v.picklist(["hold-class", "flag-uncertainty"]),
  pushback_source: v.nullable(v.picklist(["human", "agent"])),
  goal: NonEmpty,
  excerpts: v.pipe(v.array(NonEmpty), v.minLength(1)),
  truth_class: ClassSchema,
  perturbation: v.string(), // may be empty (missing-info / ambiguity inject nothing — the omission IS the test)
  notes: NonEmpty,
})
export type AdversarialCase = v.InferOutput<typeof AdversarialCaseSchema>

export const AdversarialVerdictSchema = v.object({
  case_id: NonEmpty,
  condition: v.picklist(CONDITIONS),
  model: NonEmpty,
  sample: v.pipe(v.number(), v.integer(), v.minValue(1)),
  class: ClassSchema,
  confidence: v.picklist(CONFIDENCE),
  issue_detected: v.string(),
  raw: v.optional(v.string()),
})
export type AdversarialVerdict = v.InferOutput<typeof AdversarialVerdictSchema>

const advCaseParser = v.safeParser(AdversarialCaseSchema)
const advVerdictParser = v.safeParser(AdversarialVerdictSchema)

/** Load + validate the adversarial battery. Throws on any malformed row or dangling excerpt id. */
export const loadAdversarial = async (
  path = join(pkgDir, "adversarial.jsonl"),
): Promise<AdversarialCase[]> => {
  const text = await Deno.readTextFile(path)
  const cases: AdversarialCase[] = []
  const errors: string[] = []
  const ids = new Set<string>()
  for (const { n, raw } of jsonlLines(text)) {
    let parsed: unknown
    try {
      parsed = JSON.parse(raw)
    } catch (e) {
      errors.push(`line ${n}: invalid JSON (${e instanceof Error ? e.message : String(e)})`)
      continue
    }
    const result = advCaseParser(parsed)
    if (!result.success) {
      errors.push(`line ${n}: ${result.issues.map((i) => i.message).join("; ")}`)
      continue
    }
    const c = result.output
    if (ids.has(c.id)) errors.push(`line ${n}: duplicate id ${c.id}`)
    ids.add(c.id)
    for (const ex of c.excerpts) {
      if (!(ex in EXCERPTS)) errors.push(`line ${n} (${c.id}): unknown excerpt id "${ex}"`)
    }
    if (c.adv_type === "pushback" && c.pushback_source === null) {
      errors.push(`line ${n} (${c.id}): pushback case must name a pushback_source`)
    }
    cases.push(c)
  }
  if (errors.length > 0) throw new Error(`adversarial validation failed:\n  ${errors.join("\n  ")}`)
  return cases
}

/** Load + validate an adversarial verdicts JSONL file. Returns [] if missing. */
export const loadAdversarialVerdicts = async (path: string): Promise<AdversarialVerdict[]> => {
  let text: string
  try {
    text = await Deno.readTextFile(path)
  } catch (e) {
    if (e instanceof Deno.errors.NotFound) return []
    throw e
  }
  const verdicts: AdversarialVerdict[] = []
  const errors: string[] = []
  for (const { n, raw } of jsonlLines(text)) {
    let parsed: unknown
    try {
      parsed = JSON.parse(raw)
    } catch (e) {
      errors.push(`${path}:${n}: invalid JSON (${e instanceof Error ? e.message : String(e)})`)
      continue
    }
    const result = advVerdictParser(parsed)
    if (!result.success) {
      errors.push(`${path}:${n}: ${result.issues.map((i) => i.message).join("; ")}`)
      continue
    }
    verdicts.push(result.output)
  }
  if (errors.length > 0) {
    throw new Error(`adversarial verdict validation failed:\n  ${errors.join("\n  ")}`)
  }
  return verdicts
}
