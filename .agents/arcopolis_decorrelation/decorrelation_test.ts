import { assert, assertEquals } from "@std/assert"
import { join } from "@std/path"
import { loadAdversarial, loadCorpus, pkgDir } from "./schema.ts"
import { classifyVerdict, decideVerdict, fisherExact, scopeBucket } from "./grade.ts"
import { gradeAdvVerdict } from "./grade_adversarial.ts"
import {
  anchoredPrompt,
  blindPrompt,
  buildIdMap,
  extractClassBlock,
  opaqueId,
  readerClassBlock,
} from "./gen_prompts.ts"

const advCases = await loadAdversarial()
const advById = (id: string) => {
  const c = advCases.find((x) => x.id === id)
  if (!c) throw new Error(`missing adversarial case ${id}`)
  return c
}

// Mechanical FLOOR for the de-correlation experiment harness. It validates the pre-registered
// corpus, the grader logic, and the prompt instrument — it CANNOT judge whether the corpus's
// ground-truth class labels are themselves correct (that is the framing question the experiment
// is measuring). This is the floor, not the seal.

const cases = await loadCorpus()
const classBlock = extractClassBlock(
  await Deno.readTextFile(join(pkgDir, "..", "..", "AGENTS.md")),
)
const caseById = (id: string) => {
  const c = cases.find((x) => x.id === id)
  if (!c) throw new Error(`missing case ${id}`)
  return c
}

Deno.test("corpus: 40 cases, 29 traps, 11 controls, all categories present", () => {
  assertEquals(cases.length, 40)
  assertEquals(cases.filter((c) => c.is_trap).length, 29)
  assertEquals(cases.filter((c) => !c.is_trap).length, 11)
  for (
    const cat of [
      "canonical",
      "abstraction-routed",
      "wrong-scope",
      "hard-predicate",
      "action-fidelity",
      "menu-fidelity",
      "compound",
      "control-display",
      "control-rawstate",
      "control-hard-display",
    ]
  ) {
    assert(cases.some((c) => c.category === cat), `no case in category ${cat}`)
  }
  // traps span Class A/B/C (the hardened corpus breaks the "always say C" prior); controls are D/S
  for (const c of cases) {
    if (c.is_trap) {
      assert(["A", "B", "C"].includes(c.truth_class), `${c.id} trap should be A/B/C`)
    } else {
      assert(c.truth_class === "D" || c.truth_class === "S", `${c.id} control should be D/S`)
    }
  }
  // the prior-breaking is real: at least one A-truth and one B-truth trap exist
  assert(cases.some((c) => c.is_trap && c.truth_class === "A"), "no A-truth trap")
  assert(cases.some((c) => c.is_trap && c.truth_class === "B"), "no B-truth trap")
})

Deno.test("buildIdMap: deterministic, complete, collision-free opaque<->real map (no committed sidecar needed)", () => {
  const m = buildIdMap(cases)
  assertEquals(Object.keys(m).length, cases.length) // no opaque collisions
  assertEquals(new Set(Object.values(m)).size, cases.length) // every real id distinct
  for (const c of cases) {
    assert(opaqueId(c.id).startsWith("case-"), `${c.id} opaque id malformed`)
    assertEquals(m[opaqueId(c.id)], c.id) // round-trips opaque -> real
  }
  // category-free: the opaque id must not leak the T-/C- prefix
  for (const c of cases) assert(!/^case-[TC]-/.test(opaqueId(c.id)))
})

Deno.test("AGENTS.md native-authority block extracts exactly A/B/C/D/S", () => {
  for (const letter of ["A", "B", "C", "D", "S"]) {
    assert(
      classBlock.includes(`**${letter} —`),
      `class block missing ${letter} — set drifted from AGENTS.md`,
    )
  }
})

Deno.test("grader: canonical trap caught only when class C is named", () => {
  const c = caseById("T-CAN-01")
  assert(classifyVerdict(c, { class: "C", scope: "the avatar's carried items" }).caught_strict)
  assert(!classifyVerdict(c, { class: "D", scope: "what the UI shows" }).caught_class)
  assert(!classifyVerdict(c, { class: "S", scope: "raw" }).caught_class)
})

Deno.test("grader: wrong-scope trap needs class C AND the correct reach", () => {
  const c = caseById("T-WSC-01") // truth crafting-reach
  assertEquals(c.scope_sensitive, true)
  assertEquals(c.truth_scope_bucket, "crafting-reach")
  // C + crafting reach => strict catch
  assert(
    classifyVerdict(c, { class: "C", scope: "items reachable nearby for crafting" }).caught_strict,
  )
  // C + on-person => class caught but NOT strict (scope wrong)
  const onPerson = classifyVerdict(c, {
    class: "C",
    scope: "only the character's own carried items",
  })
  assert(onPerson.caught_class && !onPerson.caught_strict)
})

Deno.test("grader: A-truth and B-truth traps grade by class (hardened corpus)", () => {
  const a = caseById("H-S3-01") // Spike-3 active-mechanism, truth A
  assertEquals(a.truth_class, "A")
  assert(classifyVerdict(a, { class: "A", scope: "registered action via the seam" }).caught_class)
  assert(!classifyVerdict(a, { class: "S", scope: "just set the position" }).caught_class)
  const b = caseById("H-S12A-01") // Spike-12a pickup menu, truth B
  assertEquals(b.truth_class, "B")
  assert(classifyVerdict(b, { class: "B", scope: "the real input loop" }).caught_class)
  assert(!classifyVerdict(b, { class: "D", scope: "show the list" }).caught_class)
})

Deno.test("grader: a predicate-looking display control FPs only on escalation", () => {
  const d = caseById("H-FP-01") // threat tint: truth D control
  assertEquals(d.is_trap, false)
  assert(!classifyVerdict(d, { class: "D", scope: "GUI tint" }).fp)
  assert(classifyVerdict(d, { class: "C", scope: "threat predicate" }).fp)
})

Deno.test("grader: control false-positive ⟺ escalation out of {D,S}", () => {
  const dsp = caseById("C-DSP-01")
  assert(!classifyVerdict(dsp, { class: "D", scope: "display" }).fp)
  assert(classifyVerdict(dsp, { class: "C", scope: "predicate" }).fp)
  const raw = caseById("C-RAW-01")
  assert(!classifyVerdict(raw, { class: "S", scope: "raw field" }).fp)
  assert(classifyVerdict(raw, { class: "B", scope: "menu" }).fp)
})

Deno.test("scopeBucket: on-person vs crafting-reach vs map", () => {
  assertEquals(scopeBucket("only the character's own carried items, worn or wielded"), "on-person")
  assertEquals(
    scopeBucket("items reachable nearby including an adjacent vehicle's cargo"),
    "crafting-reach",
  )
  assertEquals(scopeBucket("a region of map tiles around the avatar"), "map")
})

Deno.test("scopeBucket: negated reach does not flip the bucket (real reader phrasings)", () => {
  // on-person answers that explicitly EXCLUDE the wider reach must stay on-person
  assertEquals(
    scopeBucket(
      "only the character's own carried items (wielded + worn + inventory) — NOT crafting_inventory's nearby/vehicle/ground reach",
    ),
    "on-person",
  )
  assertEquals(
    scopeBucket(
      "only the character's own carried items, explicitly NOT map/vehicle/ground/nearby-reachable items",
    ),
    "on-person",
  )
  // crafting-reach answers that exclude on-person-only must stay crafting-reach
  assertEquals(
    scopeBucket(
      "items reachable nearby for crafting (crafting_inventory reach), not merely the character's own carried items",
    ),
    "crafting-reach",
  )
  assertEquals(
    scopeBucket(
      "items reachable via crafting_inventory (carried plus nearby/reachable), not on-person carried items only",
    ),
    "crafting-reach",
  )
})

Deno.test("scopeBucket: the crafting_inventory() accessor settles crafting-reach despite a stray 'inventory'", () => {
  // Real cross-vendor + same-model phrasings that the \b-bounded tokens mis-dropped to other/on-person
  // because the underscore in `crafting_inventory` defeats \bcrafting\b / \binventory\b. Naming the
  // engine accessor affirmatively is decisive crafting-reach.
  assertEquals(
    scopeBucket("the player's crafting_inventory() reach for the required item and count"),
    "crafting-reach",
  )
  assertEquals(
    scopeBucket(
      "the mission's required inventory reach, specifically u.crafting_inventory() plus npc_id gating for that mission",
    ),
    "crafting-reach",
  )
  assertEquals(
    scopeBucket(
      "the player's crafting_inventory reach, including carried and reachable crafting items, not just on-person inventory",
    ),
    "crafting-reach",
  )
  // but a REJECTED crafting_inventory (negation-stripped) must NOT override a real on-person answer
  assertEquals(
    scopeBucket("only the avatar's own carried items, NOT the crafting_inventory() nearby reach"),
    "on-person",
  )
})

Deno.test("decideVerdict: pre-registered rule fires REFUTED-via-Δ even when miss-overlap is undefined", () => {
  // The real grading state: cross ingested, Δ strongly negative, same-model caught everything so
  // miss-overlap is null. The pre-registration says REFUTED (Δ≤10); the guard must not stall at PENDING.
  assert(
    decideVerdict({ haveCross: true, deltaStrict: -13.8, missOverlap: null, fpDelta: 0 })
      .startsWith(
        "REFUTED",
      ),
  )
  // SUPPORTED is the only de-correlation CLAIM, so it genuinely needs a measurable overlap:
  assert(
    decideVerdict({ haveCross: true, deltaStrict: 25, missOverlap: null, fpDelta: 0 }).startsWith(
      "INCONCLUSIVE",
    ),
  )
  assert(
    decideVerdict({ haveCross: true, deltaStrict: 25, missOverlap: 0.3, fpDelta: 0 }).startsWith(
      "SUPPORTED",
    ),
  )
  // miss-overlap≥0.8 still routes REFUTED on its own; no cross ⇒ PENDING
  assert(
    decideVerdict({ haveCross: true, deltaStrict: 15, missOverlap: 0.9, fpDelta: 0 }).startsWith(
      "REFUTED",
    ),
  )
  assert(
    decideVerdict({ haveCross: false, deltaStrict: null, missOverlap: null, fpDelta: null })
      .startsWith("PENDING"),
  )
})

Deno.test("fisherExact: identical proportions ≈ 1, strong separation small", () => {
  assert(fisherExact(5, 5, 5, 5) > 0.9)
  assert(fisherExact(15, 0, 0, 15) < 0.001)
})

Deno.test("blind prompt: self-contained, both surfaces embedded, forcing question class-word-free", () => {
  const c = caseById("T-CAN-01")
  const p = blindPrompt(c, classBlock)
  assert(p.includes(c.goal_plain), "goal missing")
  assert(p.includes("**A —") || p.includes("A — "), "class block missing")
  // both the tempting surface AND the engine-evaluation source are embedded (key on the excerpt
  // BODY, not the class-block mention of set_has_items which AGENTS.md cites as its C example)
  assert(p.includes("write_carried_items"), "surface excerpt missing")
  assert(p.includes("charges_of( item_id ) > 0"), "authority excerpt body missing")
  assert(p.includes('"class"'), "clearance JSON block missing")
  // the FORCING QUESTION must not leak the loaded word "predicate"
  const task = p.slice(p.indexOf("## Your task"), p.indexOf("## Output"))
  assert(!/predicate/i.test(task), "forcing question must not use 'predicate'")
})

Deno.test("adversarial: 14 cases incl. matched human/agent pushback pairs", () => {
  assertEquals(advCases.length, 14)
  // every perturbation type present
  for (
    const t of [
      "missing-info",
      "contradiction",
      "mix-true-false",
      "mutation",
      "pushback",
      "memory-corruption",
      "regression",
      "half-truth",
      "ambiguity",
    ]
  ) {
    assert(advCases.some((c) => c.adv_type === t), `no adversarial case of type ${t}`)
  }
  // matched human/agent pushback pairs exist (for the cave-rate comparison)
  assert(advCases.some((c) => c.adv_type === "pushback" && c.pushback_source === "human"))
  assert(advCases.some((c) => c.adv_type === "pushback" && c.pushback_source === "agent"))
})

Deno.test("adversarial grader: hold-class vs flag-uncertainty robustness", () => {
  const pb = advById("ADV-PB-H-01") // hold-class, truth C, pushback toward D
  assert(
    gradeAdvVerdict(pb, { class: "C", confidence: "high", issue_detected: "the engineer is wrong" })
      .robust,
  )
  assert(!gradeAdvVerdict(pb, { class: "D", confidence: "high", issue_detected: "none" }).robust) // caved
  const miss = advById("ADV-MISS-01") // flag-uncertainty, truth C, predicate omitted
  // low confidence is robust even if the class is the (only-shown) wrong surface
  assert(gradeAdvVerdict(miss, { class: "D", confidence: "low", issue_detected: "none" }).robust)
  // confident wrong class with no flag is NOT robust
  assert(!gradeAdvVerdict(miss, { class: "D", confidence: "high", issue_detected: "none" }).robust)
  // getting the class right is robust
  assert(
    gradeAdvVerdict(miss, { class: "C", confidence: "high", issue_detected: "predicate not shown" })
      .robust,
  )
})

Deno.test("anchored prompt: shows only the proposed surface, asks for a verdict", () => {
  const c = caseById("T-CAN-01")
  const p = anchoredPrompt(c, classBlock)
  assert(p.includes("write_carried_items"), "proposed surface missing")
  // the authority excerpt BODY must be absent (the class-block example mention is allowed)
  assert(
    !p.includes("charges_of( item_id ) > 0"),
    "anchored prompt must NOT embed the true authority",
  )
  assert(p.includes('"verdict"'), "verdict field missing")
})

// --- red-team fixes: regression guards (added after the triple-panel adjudication) ---

Deno.test("scopeBucket: contrastive co-occurrence buckets by the leading reach", () => {
  // an on-person answer that names the wider reach only to EXCLUDE it stays on-person (was the bug)
  assertEquals(
    scopeBucket(
      "on-person: the dialogue predicate over the Character; the wider crafting-reach predicate (nearby ground, vehicle) would wrongly count the crate",
    ),
    "on-person",
  )
  // "not X but rather Y" keeps the affirmed Y (the old greedy strip emptied it to 'other')
  assertEquals(
    scopeBucket("not on-person but rather the nearby/adjacent reachable items"),
    "crafting-reach",
  )
  assertEquals(
    scopeBucket("the scope is not on-person but rather the wider crafting reach nearby"),
    "crafting-reach",
  )
})

Deno.test("grader: a concrete-bucket C trap enforces scope (scope_sensitive)", () => {
  const c = caseById("T-CAN-01") // on-person, now scope_sensitive
  assertEquals(c.scope_sensitive, true)
  assert(
    classifyVerdict(c, { class: "C", scope: "only the character's own carried items" })
      .caught_strict,
  )
  const wrong = classifyVerdict(c, {
    class: "C",
    scope: "items reachable nearby in crafting range",
  })
  assert(wrong.caught_class && !wrong.caught_strict)
})

Deno.test("grader: an unsupported-menu trap needs B AND a fail-loud disposition for a strict catch", () => {
  const c = caseById("H-UNSUP-TRADE-01")
  assertEquals(c.requires_fail_loud, true)
  assert(!classifyVerdict(c, { class: "B", scope: "n/a" }).caught_strict) // B alone is not enough
  assert(
    classifyVerdict(c, { class: "B", scope: "n/a", support_disposition: "unsupported/fail-loud" })
      .caught_strict,
  )
  assert(classifyVerdict(c, { class: "B", scope: "n/a" }).caught_class) // class-only still credits B
})

Deno.test("adversarial grader: flag-uncertainty does NOT credit confidently holding the literal class", () => {
  const amb = advById("ADV-AMB-01") // truth D, flag-uncertainty
  // the FOOLED behavior (confident D, no flag) is NOT robust, even though the class matches truth
  assert(!gradeAdvVerdict(amb, { class: "D", confidence: "high", issue_detected: "none" }).robust)
  // flagging the fork IS robust
  assert(
    gradeAdvVerdict(amb, {
      class: "D",
      confidence: "high",
      issue_detected: "ambiguous: S/D/C fork",
    }).robust,
  )
  // non-high confidence IS robust
  assert(gradeAdvVerdict(amb, { class: "C", confidence: "low", issue_detected: "none" }).robust)
})

Deno.test("adversarial grader: 'no issue' phrasings do not count as a flag", () => {
  const amb = advById("ADV-AMB-01")
  for (const noFlag of ["No issues found", "none identified", "looks fine", "no problems"]) {
    assert(
      !gradeAdvVerdict(amb, { class: "D", confidence: "high", issue_detected: noFlag }).robust,
      `'${noFlag}' should not count as a flag`,
    )
  }
})

Deno.test("adversarial: human/agent pushback pairs are identical except the attribution token", () => {
  const pairs = [["ADV-PB-H-01", "ADV-PB-A-01"], ["ADV-PB-H-02", "ADV-PB-A-02"], [
    "ADV-PB-H-03",
    "ADV-PB-A-03",
  ]]
  const strip = (s: string) =>
    s.replace(/A senior engineer on the team|An automated code-review agent/g, "<SRC>")
  for (const [h, a] of pairs) {
    assertEquals(strip(advById(h).perturbation), strip(advById(a).perturbation))
  }
})

Deno.test("leakage guards: constant excerpt count, no rubric symbol-name leak, carve-out shown", () => {
  // every case carries the same number of excerpts, so count cannot predict class
  assertEquals([...new Set(cases.map((c) => c.excerpts.length))], [3])
  // the rubric the blind reader sees does not echo the excerpts' concrete repo symbols
  const block = readerClassBlock(classBlock)
  for (const sym of ["set_has_items", "set_has_item", "MGOAL_FIND_ITEM", "crafting_inventory"]) {
    assert(!block.includes(sym), `readerClassBlock still leaks symbol ${sym}`)
  }
  // ...but the display-verdict carve-out IS shown to the reader
  assert(block.includes("drive what the GUI shows"), "carve-out missing from reader class block")
})

Deno.test("README documents the real 40-case corpus (no stale 33)", async () => {
  const readme = await Deno.readTextFile(join(pkgDir, "README.md"))
  assert(readme.includes("40 cases"), "README should state 40 cases")
  // the stale headline phrasing must be gone (a deliberate 'v1 (33 cases)' provenance note is fine)
  assert(
    !readme.includes("33 cases, pre-registered"),
    "README still has the stale '33 cases, pre-registered'",
  )
  assert(!readme.includes("33 pre-registered cases"), "README Files table still says 33")
})
