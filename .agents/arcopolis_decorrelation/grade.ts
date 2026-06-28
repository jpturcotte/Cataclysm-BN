#!/usr/bin/env -S deno run --allow-read --allow-write
/**
 * @module
 *
 * Grades the de-correlation experiment and computes the pre-registered metrics.
 *
 * Grading is MECHANICAL against the committed corpus key (the pre-registered ground truth):
 *   - TRAP caught  ⟺  the reader named the correct class (C) AND, for scope-sensitive cases,
 *                     named the correct scope reach. (Reported as class-only "lenient" and
 *                     class+scope "strict".)
 *   - CONTROL false-positive  ⟺  the reader escalated a genuine display/raw surface OUT of {D,S}
 *                     (i.e. named A/B/C). This is "flagging a genuine display as a trap".
 *
 * Headline outputs:
 *   - trap catch rate + control FP rate per condition (and per trap category / control type)
 *   - Δ = cross-model − blind-same-model trap catch rate (percentage points)
 *   - case-level miss-overlap  P(cross misses | same misses)  — de-correlation proper
 *   - Fisher-exact two-tailed p on the pooled same-vs-cross 2×2 (small-N caveat applies)
 *   - the pre-registered SUPPORTED / REFUTED / INCONCLUSIVE verdict (PENDING until cross ingested)
 *
 * Scope bucketing of free-text reader answers is heuristic; every scope-sensitive decision is
 * listed in the per-case table so it can be spot-audited rather than trusted blindly.
 */

import { Command } from "@cliffy/command"
import { ensureDir } from "@std/fs"
import { join } from "@std/path"
import {
  type Case,
  type Condition,
  CONDITIONS,
  loadCorpus,
  loadVerdicts,
  pkgDir,
} from "./schema.ts"
import { loadOrBuildIdMap } from "./gen_prompts.ts"

const TRAP_CATEGORIES = [
  "canonical",
  "abstraction-routed",
  "wrong-scope",
  "hard-predicate",
  "action-fidelity",
  "menu-fidelity",
  "compound",
] as const
const CONTROL_CATEGORIES = ["control-display", "control-rawstate", "control-hard-display"] as const

/** Heuristic bucket for a reader's free-text scope answer. Audited via the per-case table. */
export const scopeBucket = (text: string): "on-person" | "crafting-reach" | "map" | "other" => {
  // Drop spans a reader names only to REJECT/contrast. Bound each negated span at a clause boundary
  // OR a contrast-resumption cue ("but"/"rather"/"whereas"/"while"), so "not on-person but rather
  // nearby" keeps the affirmed "nearby" (the old greedy strip ate the affirmed reach to empty).
  const affirmed = text.replace(
    /\b(?:not just|not merely|not only|not|never|excluding|rather than|instead of|as opposed to|other than|wider than|broader than|narrower than)\b[^.,;:()]*?(?=\b(?:but|rather|whereas|while)\b|[.,;:()]|$)/gi,
    " ",
  )
  const t = affirmed.toLowerCase()
  // Decisive override: the engine's own `crafting_inventory()` accessor IS the crafting-reach scope,
  // so naming it affirmatively (it survived the negation strip above, i.e. wasn't rejected) settles
  // the bucket. The underscore defeats the \b-bounded "crafting"/"inventory" tokens below (`_` is a
  // word char, so there is no boundary inside `crafting_inventory`), which otherwise drops these to
  // `other` or lets a stray bare "inventory" mis-fire on-person. Unlike bare "inventory", this token
  // is unambiguous.
  if (/crafting[_ ]inventory/.test(t)) return "crafting-reach"
  const at = (re: RegExp): number => {
    const i = t.search(re)
    return i < 0 ? Infinity : i
  }
  // Bucket by the FIRST-NAMED reach: a reader states their chosen reach, then may contrast the
  // rejected wider/narrower one. Co-occurrence is NOT assumed to mean the wider reach (the old bug
  // mis-graded a correct on-person answer that named crafting-reach only to exclude it).
  const nearby = at(
    /\b(craft|crafting|nearby|near by|adjacent|vehicle|on the ground|ground|within reach|reachable|surrounding|surroundings|pick.?up range)\b/,
  )
  const onPerson = at(
    /\b(on[- ]person|on their person|on the (?:character|avatar)|on their body|carried|worn|wielded|inventory|personal|their own|character'?s own|held)\b/,
  )
  const map = at(/\b(map|region|tiles?|overmap|submap)\b/)
  const min = Math.min(nearby, onPerson, map)
  if (min === Infinity) return "other"
  if (min === onPerson) return "on-person"
  if (min === nearby) return "crafting-reach"
  return "map"
}

export interface VerdictGrade {
  caught_class: boolean
  caught_strict: boolean
  fp: boolean
  scope_bucket: string
}

/** Pure grading of one reader verdict against its corpus case. */
export const classifyVerdict = (
  c: Case,
  v: { class: string; scope: string; support_disposition?: string },
): VerdictGrade => {
  const bucket = scopeBucket(v.scope)
  if (c.is_trap) {
    const classOk = v.class === c.truth_class
    const scopeOk = !c.scope_sensitive || bucket === c.truth_scope_bucket
    // For an unsupported-menu trap, naming B is necessary but not sufficient: a STRICT catch also
    // requires recognizing the path is unsupported and must fail loud (not silently transfer/no-op).
    const failLoudOk = !c.requires_fail_loud ||
      /unsupported|fail.?loud/i.test(v.support_disposition ?? "")
    return {
      caught_class: classOk,
      caught_strict: classOk && scopeOk && failLoudOk,
      fp: false,
      scope_bucket: bucket,
    }
  }
  // control: false-positive ⟺ escalated OUT of the honest {D, S} zone
  return {
    caught_class: false,
    caught_strict: false,
    fp: v.class !== "D" && v.class !== "S",
    scope_bucket: bucket,
  }
}

interface CondStat {
  n: number
  trapN: number
  trapCaughtClass: number
  trapCaughtStrict: number
  byCat: Record<string, { n: number; caughtClass: number; caughtStrict: number }>
  controlN: number
  controlFP: number
  byControl: Record<string, { n: number; fp: number }>
}

const emptyStat = (): CondStat => ({
  n: 0,
  trapN: 0,
  trapCaughtClass: 0,
  trapCaughtStrict: 0,
  byCat: Object.fromEntries(
    TRAP_CATEGORIES.map((c) => [c, { n: 0, caughtClass: 0, caughtStrict: 0 }]),
  ),
  controlN: 0,
  controlFP: 0,
  byControl: Object.fromEntries(CONTROL_CATEGORIES.map((c) => [c, { n: 0, fp: 0 }])),
})

interface CaseAgg {
  case_id: string
  category: string
  is_trap: boolean
  truth_class: string
  truth_scope_bucket: string
  scope_sensitive: boolean
  per: Record<Condition, { n: number; caughtClass: number; caughtStrict: number; fp: number }>
  scopeAudit: { condition: Condition; named: string; bucket: string; ok: boolean }[]
}

const pct = (
  num: number,
  den: number,
): number => (den === 0 ? 0 : Math.round((num / den) * 1000) / 10)

// --- Fisher exact (two-tailed) on a 2x2 via a log-factorial table ---

const logFactTable = (max: number): number[] => {
  const lf = new Array(max + 1).fill(0)
  for (let i = 2; i <= max; i++) lf[i] = lf[i - 1] + Math.log(i)
  return lf
}

export const fisherExact = (a: number, b: number, c: number, d: number): number => {
  const n = a + b + c + d
  if (n === 0) return 1
  const lf = logFactTable(n)
  const r1 = a + b, r2 = c + d, c1 = a + c, c2 = b + d
  const logConst = lf[r1] + lf[r2] + lf[c1] + lf[c2] - lf[n]
  const logP = (x: number): number =>
    logConst - lf[x] - lf[r1 - x] - lf[c1 - x] - lf[n - r1 - c1 + x]
  const pObs = Math.exp(logP(a))
  const lo = Math.max(0, c1 - r2), hi = Math.min(r1, c1)
  let sum = 0
  for (let x = lo; x <= hi; x++) {
    const p = Math.exp(logP(x))
    if (p <= pObs * (1 + 1e-7)) sum += p
  }
  return Math.min(1, sum)
}

/**
 * The pre-registered SUPPORTED / REFUTED / INCONCLUSIVE rule, as a pure function so it is unit-tested.
 * miss-overlap is null whenever the same-model arm misses NOTHING (no same-miss case to condition the
 * conditional probability on). SUPPORTED — the only affirmative de-correlation claim — genuinely needs
 * a measurable overlap, so it requires missOverlap !== null. REFUTED-via-Δ (Δ≤10pp) and INCONCLUSIVE
 * resolve on Δ alone and MUST still fire when miss-overlap is undefined. PENDING means cross-model is
 * not yet ingested. (Pre-registration: SUPPORTED iff Δ≥20 ∧ miss-overlap≤0.5 ∧ FP-delta≤15; REFUTED
 * iff Δ≤10 ∨ miss-overlap≥0.8; else INCONCLUSIVE.)
 */
export const decideVerdict = (
  p: {
    haveCross: boolean
    deltaStrict: number | null
    missOverlap: number | null
    fpDelta: number | null
  },
): string => {
  if (!(p.haveCross && p.deltaStrict !== null && p.fpDelta !== null)) {
    return "PENDING — cross-model arm not yet ingested (run the cross-model classification per corpus_classify_brief.md → verdicts/cross_model.jsonl, re-run)"
  }
  if (p.deltaStrict >= 20 && p.missOverlap !== null && p.missOverlap <= 0.5 && p.fpDelta <= 15) {
    return "SUPPORTED — cross-model meaningfully de-correlates (a real stronger floor)"
  }
  if (p.deltaStrict <= 10 || (p.missOverlap !== null && p.missOverlap >= 0.8)) {
    return "REFUTED — cross-model did NOT de-correlate upward (Δ≤10pp); here it is a WEAKER floor than blind same-model — lean on the mechanical Class-C gate, issue #76"
  }
  return "INCONCLUSIVE — between the pre-registered thresholds (small-N; collect more samples)"
}

const main = new Command()
  .name("grade")
  .description("Grade the de-correlation experiment and emit metrics")
  .option("-v, --verdicts <dir:string>", "verdicts dir", { default: join(pkgDir, "verdicts") })
  .option("-o, --out <dir:string>", "results dir", { default: join(pkgDir, "results") })
  .action(async ({ verdicts: vdir, out }) => {
    const cases = await loadCorpus()
    const byId = new Map(cases.map((c) => [c.id, c]))

    const all = (await Promise.all(
      CONDITIONS.map((cond) => loadVerdicts(join(vdir, `${cond}.jsonl`))),
    )).flat()

    // The blind cross-model + same-model agents record the OPAQUE case id (so they stay blind to the
    // T-/C- category); remap it back to the real corpus id. Real ids pass through unchanged.
    const idMap = await loadOrBuildIdMap(cases)
    for (const v of all) {
      if (idMap[v.case_id]) v.case_id = idMap[v.case_id]
    }

    const stats: Record<Condition, CondStat> = {
      anchored_same_model: emptyStat(),
      blind_same_model: emptyStat(),
      cross_model: emptyStat(),
    }
    const caseAggs = new Map<string, CaseAgg>()
    const ensureAgg = (c: Case): CaseAgg => {
      let agg = caseAggs.get(c.id)
      if (!agg) {
        agg = {
          case_id: c.id,
          category: c.category,
          is_trap: c.is_trap,
          truth_class: c.truth_class,
          truth_scope_bucket: c.truth_scope_bucket,
          scope_sensitive: c.scope_sensitive,
          per: Object.fromEntries(
            CONDITIONS.map((k) => [k, { n: 0, caughtClass: 0, caughtStrict: 0, fp: 0 }]),
          ) as CaseAgg["per"],
          scopeAudit: [],
        }
        caseAggs.set(c.id, agg)
      }
      return agg
    }

    const unknown: string[] = []
    for (const v of all) {
      const c = byId.get(v.case_id)
      if (!c) {
        unknown.push(`${v.case_id} (${v.condition})`)
        continue
      }
      const s = stats[v.condition]
      const agg = ensureAgg(c)
      s.n++
      agg.per[v.condition].n++
      const g = classifyVerdict(c, v)
      if (c.is_trap) {
        s.trapN++
        if (g.caught_class) {
          s.trapCaughtClass++
          s.byCat[c.category].caughtClass++
          agg.per[v.condition].caughtClass++
        }
        if (g.caught_strict) {
          s.trapCaughtStrict++
          s.byCat[c.category].caughtStrict++
          agg.per[v.condition].caughtStrict++
        }
        s.byCat[c.category].n++
        if (c.scope_sensitive) {
          agg.scopeAudit.push({
            condition: v.condition,
            named: v.scope,
            bucket: g.scope_bucket,
            ok: g.scope_bucket === c.truth_scope_bucket,
          })
        }
      } else {
        s.controlN++
        if (g.fp) {
          s.controlFP++
          s.byControl[c.category].fp++
          agg.per[v.condition].fp++
        }
        s.byControl[c.category].n++
      }
    }

    // ---- de-correlation analysis (blind_same vs cross_model, case-level) ----
    const trapCases = cases.filter((c) => c.is_trap)
    const caseRate = (id: string, cond: Condition): number | null => {
      const p = caseAggs.get(id)?.per[cond]
      return p && p.n > 0 ? p.caughtStrict / p.n : null
    }
    let sameMiss = 0, bothMiss = 0
    const missDetail: string[] = []
    for (const c of trapCases) {
      const rs = caseRate(c.id, "blind_same_model")
      const rc = caseRate(c.id, "cross_model")
      if (rs === null || rc === null) continue
      const sameMissed = rs < 0.5
      const crossMissed = rc < 0.5
      if (sameMissed) {
        sameMiss++
        if (crossMissed) {
          bothMiss++
          missDetail.push(c.id)
        }
      }
    }
    // Gate the verdict on a COMPLETE cross arm: every case needs >=1 cross verdict. Otherwise a partial
    // or interrupted verdicts/cross_model.jsonl would yield a definitive (sample-count-sensitive) Δ over
    // a subset instead of staying PENDING.
    const crossCasesCovered = [...caseAggs.values()].filter((a) => a.per.cross_model.n > 0).length
    const haveCross = crossCasesCovered === cases.length
    const missOverlap = sameMiss > 0 ? bothMiss / sameMiss : null

    const sameStrict = pct(stats.blind_same_model.trapCaughtStrict, stats.blind_same_model.trapN)
    const crossStrict = pct(stats.cross_model.trapCaughtStrict, stats.cross_model.trapN)
    const deltaStrict = haveCross ? Math.round((crossStrict - sameStrict) * 10) / 10 : null
    const sameFP = pct(stats.blind_same_model.controlFP, stats.blind_same_model.controlN)
    const crossFP = pct(stats.cross_model.controlFP, stats.cross_model.controlN)
    const fpDelta = haveCross ? Math.round((crossFP - sameFP) * 10) / 10 : null

    // pooled 2x2 fisher (same vs cross; caught vs missed, strict)
    let fisherP: number | null = null
    if (haveCross) {
      const a = stats.blind_same_model.trapCaughtStrict
      const b = stats.blind_same_model.trapN - a
      const c = stats.cross_model.trapCaughtStrict
      const d = stats.cross_model.trapN - c
      fisherP = fisherExact(a, b, c, d)
    }

    const verdict = decideVerdict({ haveCross, deltaStrict, missOverlap, fpDelta })

    // null-model baselines: what trivial body-free heuristics score, so real catch numbers are read
    // against a floor rather than against 0.
    const cTrapCount = trapCases.filter((c) => c.truth_class === "C").length
    const excerptCounts = [...new Set(cases.map((c) => c.excerpts.length))].sort((a, b) => a - b)
    const baselines = {
      constant_c: {
        note: "an 'always say C' reader: catches C traps by class, false-positives every control",
        trap_catch_class_pct: pct(cTrapCount, trapCases.length),
        control_fp_pct: 100,
      },
      excerpt_count: {
        note: "excerpt COUNT cannot predict class once every case is padded to a constant count",
        distinct_excerpt_counts: excerptCounts,
        count_is_constant: excerptCounts.length === 1,
      },
    }

    const results = {
      generated_against: "corpus.jsonl",
      n_cases: cases.length,
      n_traps: trapCases.length,
      n_controls: cases.length - trapCases.length,
      conditions: Object.fromEntries(CONDITIONS.map((cond) => {
        const s = stats[cond]
        return [cond, {
          n_verdicts: s.n,
          trap_catch_rate_class_pct: pct(s.trapCaughtClass, s.trapN),
          trap_catch_rate_strict_pct: pct(s.trapCaughtStrict, s.trapN),
          trap_n: s.trapN,
          per_category: Object.fromEntries(
            TRAP_CATEGORIES.map((k) => [k, {
              n: s.byCat[k].n,
              catch_class_pct: pct(s.byCat[k].caughtClass, s.byCat[k].n),
              catch_strict_pct: pct(s.byCat[k].caughtStrict, s.byCat[k].n),
            }]),
          ),
          control_fp_rate_pct: pct(s.controlFP, s.controlN),
          control_n: s.controlN,
          per_control_type: Object.fromEntries(
            CONTROL_CATEGORIES.map((k) => [k, {
              n: s.byControl[k].n,
              fp_pct: pct(s.byControl[k].fp, s.byControl[k].n),
            }]),
          ),
        }]
      })),
      decorrelation: {
        blind_same_trap_catch_strict_pct: sameStrict,
        cross_trap_catch_strict_pct: haveCross ? crossStrict : null,
        delta_pp: deltaStrict,
        same_model_missed_cases: sameMiss,
        both_missed_cases: bothMiss,
        miss_overlap: missOverlap,
        miss_overlap_cases: missDetail,
        control_fp_delta_pp: fpDelta,
        fisher_exact_two_tailed_p: fisherP,
      },
      verdict,
      baselines,
      unknown_case_ids: unknown,
    }

    await ensureDir(out)
    await Deno.writeTextFile(join(out, "results.json"), JSON.stringify(results, null, 2) + "\n")
    await Deno.writeTextFile(join(out, "results.md"), renderMarkdown(results, caseAggs, cases))

    console.log(`verdict: ${verdict}`)
    console.log(
      `blind-same trap catch (strict): ${sameStrict}%  |  cross trap catch: ${
        haveCross ? crossStrict + "%" : "PENDING"
      }  |  Δ: ${deltaStrict ?? "PENDING"}pp`,
    )
    console.log(`results -> ${join(out, "results.md")}`)
    if (unknown.length > 0) {
      console.warn(`WARNING: ${unknown.length} verdict(s) for unknown case ids`)
    }
  })

// deno-lint-ignore no-explicit-any
const renderMarkdown = (r: any, aggs: Map<string, CaseAgg>, cases: Case[]): string => {
  const condRows = CONDITIONS.map((cond) => {
    const s = r.conditions[cond]
    return `| ${cond} | ${s.n_verdicts} | ${s.trap_catch_rate_strict_pct}% (${s.trap_catch_rate_class_pct}% class-only) | ${s.control_fp_rate_pct}% |`
  }).join("\n")

  const catRows = TRAP_CATEGORIES.map((cat) => {
    const cells = CONDITIONS.map((cond) =>
      `${r.conditions[cond].per_category[cat].catch_strict_pct}%`
    )
    return `| ${cat} | ${cells.join(" | ")} |`
  }).join("\n")

  const caseRows = cases.map((c) => {
    const a = aggs.get(c.id)
    const cell = (cond: Condition) => {
      const p = a?.per[cond]
      if (!p || p.n === 0) return "–"
      const v = c.is_trap ? `${p.caughtStrict}/${p.n}` : `${p.fp}/${p.n} fp`
      return v
    }
    return `| ${c.id} | ${c.category} | ${
      c.is_trap ? c.truth_class + (c.scope_sensitive ? "*" : "") : c.truth_class
    } | ${cell("anchored_same_model")} | ${cell("blind_same_model")} | ${cell("cross_model")} |`
  }).join("\n")

  const scopeAudit = cases.filter((c) => c.scope_sensitive).flatMap((c) =>
    (aggs.get(c.id)?.scopeAudit ?? []).map((sa) =>
      `| ${c.id} | ${sa.condition} | required \`${c.truth_scope_bucket}\` | "${sa.named}" → \`${sa.bucket}\` | ${
        sa.ok ? "✓" : "✗"
      } |`
    )
  ).join("\n")

  return `# De-correlation experiment — results

> Auto-generated by \`grade.ts\`. The verdict and numbers below are computed mechanically against the
> pre-registered \`corpus.jsonl\` key. Small-N pilot — read the caveats in README.md.

**Cases:** ${r.n_cases} (${r.n_traps} traps, ${r.n_controls} controls)

## Verdict

**${r.verdict}**

| metric | value |
| --- | --- |
| blind-same-model trap catch (strict) | ${r.decorrelation.blind_same_trap_catch_strict_pct}% |
| cross-model trap catch (strict) | ${r.decorrelation.cross_trap_catch_strict_pct ?? "PENDING"}${
    r.decorrelation.cross_trap_catch_strict_pct === null ? "" : "%"
  } |
| **Δ (cross − same)** | ${
    r.decorrelation.delta_pp === null ? "PENDING" : r.decorrelation.delta_pp + "pp"
  } |
| miss-overlap P(cross misses \\| same misses) | ${
    r.decorrelation.miss_overlap !== null
      ? r.decorrelation.miss_overlap
      : (r.decorrelation.cross_trap_catch_strict_pct === null
        ? "PENDING (cross not ingested)"
        : "n/a — same-model missed nothing to condition on")
  } |
| control-FP delta (cross − same) | ${
    r.decorrelation.control_fp_delta_pp === null
      ? "PENDING"
      : r.decorrelation.control_fp_delta_pp + "pp"
  } |
| Fisher exact two-tailed p | ${
    r.decorrelation.fisher_exact_two_tailed_p === null
      ? "PENDING"
      : r.decorrelation.fisher_exact_two_tailed_p.toExponential(2)
  } |

## Null-model baselines

A body-free reader scores these for free — read the real catch rates against this floor.

- **Constant-C** ("always say C"): trap catch (class) ${r.baselines.constant_c.trap_catch_class_pct}%, control-FP ${r.baselines.constant_c.control_fp_pct}%.
- **Excerpt count**: distinct counts = ${
    r.baselines.excerpt_count.distinct_excerpt_counts.join(", ")
  } ${
    r.baselines.excerpt_count.count_is_constant
      ? "(constant — count carries no class signal)"
      : "(NOT constant — count may leak)"
  }.

## Per condition

| condition | n verdicts | trap catch (strict; class-only) | control FP rate |
| --- | --- | --- | --- |
${condRows}

## Trap catch (strict) by category

| trap category | anchored | blind-same | cross |
| --- | --- | --- | --- |
${catRows}

## Per case

\`truth\` column: trap class (\`*\` = scope-sensitive) or control class. Trap cells = caught/n (strict);
control cells = false-positives/n.

| case | category | truth | anchored | blind-same | cross |
| --- | --- | --- | --- | --- | --- |
${caseRows}

## Scope-bucketing audit (scope-sensitive traps)

Heuristic bucketing of free-text scope answers — listed so they can be spot-checked, not trusted blindly.

| case | condition | required | reader scope → bucket | ok |
| --- | --- | --- | --- | --- |
${scopeAudit || "| _(no cross/blind scope-sensitive verdicts yet)_ | | | | |"}
`
}

if (import.meta.main) {
  await main.parse(Deno.args)
}
