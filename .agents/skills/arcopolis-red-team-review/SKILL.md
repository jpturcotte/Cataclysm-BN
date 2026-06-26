---
name: arcopolis-red-team-review
description: Adversarial review skill for Arcopolis (Cataclysm-BN simulation-backend) prompts, plans, patches, and PRs. Use when the user says "review this PR/plan/prompt", "red team this", "are we sure?", "does this overclaim equivalence?", or "what could go wrong?". Its job is to reject false confidence — false-green equivalence, seam bypass, silent prompt defaults, overbroad claims, unapproved fixture/baseline edits, and prompt-class generalization. Review only — do not implement fixes unless explicitly asked.
---

# Arcopolis Red-Team Review

Read `AGENTS.md` and `docs/arcopolis/ARCOPOLIS_STATE.md` first. Review only; do not
fix unless asked. Open and read every file/line a claim depends on before agreeing or
flagging — confident-but-wrong `file:line`/existence claims are common, including from
review bots and verify subagents.

## Reject or flag if

- same final state is used as L4 proof;
- a shared `do_turn`/finalization path is used as L4 proof without registered inputs;
- prompt/menu/selector state is directly edited, or a selector return value is forced;
- a per-transaction gate becomes a session-wide gate, or a served category reuses a
  sibling family's gate instead of its own;
- an unsupported prompt silently defaults / cancels / quits and is treated as success;
- one witnessed path is generalized into prompt-class support;
- L4 is claimed without naming the exact active mechanism that consumes the inputs;
- docs/PR text claim support broader than the fixture/protocol witness;
- the capability is only CONSISTENT WITH the cited goal, not SUFFICIENT FOR it (e.g.
  a flat/top-level observation surface offered as proof of a predicate the engine
  evaluates by a deeper, recursing mechanism);
- a PROXY surface (one re-derived from a partial or top-level view, NOT the engine
  predicate's own returned result) is offered as proof of an engine-computed predicate
  with no named state where proxy and predicate DISAGREE (a counterexample), OR that
  counterexample is asserted but never exercised by the witness — a happy-path-only
  "divergence" filed as a footnote is the Spike-25 failure. Exposing the predicate's
  OWN result is the correct fix and needs no counterexample (it cannot diverge from
  itself); the exemption does NOT cover a surface merely ASSERTED equal to the
  predicate;
- a surface a CITED goal consumes as an engine-computed predicate is classified
  display/observation-only — or its consuming goal is left unnamed — to dodge the
  divergence test; the class follows the downstream consumer's authority, not the
  author's framing. (A surface with NO cited predicate consumer is legitimately
  display-only — do not invent a "foreseeable" one to block honest display work;
  Spike 25's resolution was that a carried-items list IS fine AS display);
- backend/headless code depends on curses/window/render behavior in any build;
- baseline/fixture files are changed without explicit approval;
- tests, fixtures, or baselines are weakened, deleted, or rewritten to make a green
  result easier;
- a PR/commit/doc cites local-only or manual evidence (e.g. an uncommitted benchmark)
  as if it were committed, reproducible repo evidence;
- after an upstream sync, `main.cpp`'s `<arg_handler, N>` literal or the array entry
  count is wrong;
- a local spec, user instruction, or per-skill specialization is followed faithfully but
  WEAKENS a canonical Arcopolis invariant — especially the native-authority class /
  downstream-consumer / active-mechanism axes (omitting, narrowing, or contradicting one;
  additive specialization that drops nothing is fine). "Matches the spec" is not a defense
  when the spec is the object under review (see "Spec-frame challenge").

## Author-frame removal + orthogonal reframe lenses

Run this FIRST; it sets up what the adversarial pass refutes. Anchoring on the author's
framing is the single most expensive review failure in this repo's record (the Spike-25
0%-catch loop), so this section is mandatory, not optional.

**Restate the claim from ground truth, not the author's framing.** Before reviewing,
re-derive what is ACTUALLY claimed from the DIFF (or, for a plan/prompt review with no patch
yet, the proposed plan/prompt text), the WITNESS, the named downstream consumer, and
`AGENTS.md`/`ARCOPOLIS_STATE.md` — never from the PR title/body's framing (or the author's
pitch).
The title/body is the author's frame; reviewing inside it is how a reviewer who shares the
author's conflation passes a broken claim.

**Reframe on a different axis than the author used.** The adversarial pass below requires at
least THREE independent refute-lenses; AT LEAST ONE of them must explicitly REFRAME the
claim on a different decision _axis_ than the author argued. An **orthogonal reframe**
changes the axis, not the size of the claim, and must name what it changes: route,
downstream consumer, native-authority class guess, active mechanism, witness, stop
condition, or scope. One constructed divergence from ANY reframe is decisive (the survival
rule below). A "reframe" that changes none of those axes is the author's frame restated, not
a lens.

Draw the reframe lens(es) from these families (pick the axes the claim actually rides):

- **Downstream-consumer lens.** Reframe "what was built?" as "WHO or WHAT consumes this, and
  what question are they asking?" (a display to show · a predicate to evaluate · an action to
  drive · a menu to answer · raw state to read).
- **Authority-class lens.** Reframe the A/B/C/D/S class from the downstream consumer's
  authority, NOT the field shape or author wording — a possession / mission / objective
  surface is C whatever it is labelled (the Spike-25 trap).
- **Active-mechanism lens.** Reframe "same final state" / "same `do_turn`" as "WHICH active
  engine loop/mechanism consumed the registered input, at which line?" — an action merely
  injected at the `handle_action` seam that never enters `input_context::handle_input` is
  level 3, NOT L4 (the _accepted_ planar-move / Spike-24 design, not a defect); the Spike-3
  _failure_ was the distinct turn-ordering inversion — driving `avatar_action::move` BEFORE
  `do_turn` instead of letting the seam consume the action (`docs/arcopolis/08`,
  `arcopolis-claim-plan` item 3).
- **Witness-divergence lens.** Reframe "the test passed" as "what DIVERGENCE state would
  falsify this, and did the witness actually EXERCISE it?" — a happy-path-only counterexample
  filed as a footnote is the Spike-25 failure.
- **Stage/scope lens.** Reframe the product ambition as Stage A proof vs Stage B deferral vs
  audit-only vs an unsupported adjacent path — and flag any claim that quietly widens one
  witnessed path into prompt-class support.
- **Future-reader lens.** Ask what a future agent or reviewer would FALSELY believe this PR
  proves, reading only its title/body/docs — the gap between that belief and what the witness
  actually exercises is the overclaim to flag.

## Spec-frame challenge

Author-frame removal strips the PR title/body. This strips the next layer: the SPEC itself.
When reviewing a plan, skill edit, prompt, or PR, do NOT treat the author's / user's stated
spec, step, or instruction as ground truth merely because the patch faithfully follows it —
the spec is the object under review. Spike 25 was this failure one level down: faithfulness
to the local instruction laundered the wrong frame.

Before accepting "matches the spec" as evidence, ask:

1. What cross-skill invariant or Arcopolis rule is this spec meant to preserve?
2. Does the spec preserve the canonical reframe axis set and the downstream-consumer
   discipline?
3. Is the patch faithful to the spec yet still able to reproduce a Spike-3 or Spike-25
   FAILURE SHAPE (seam inversion; display-D laundered as predicate-C)?
4. Did the author / user carve a per-skill exception that WEAKENS the shared invariant?

If the patch matches the local spec but the spec OMITS, NARROWS, or CONTRADICTS a canonical
invariant, grade `needs revision` or stronger. Do NOT downgrade because a downstream skill
"stops conservatively" — conservative stop behaviour does not repair a missing or weakened
detection axis. NOT a trigger: a per-skill specialization that ADDS detail without dropping
or narrowing a canonical axis (e.g. build's labelled equivalence-level / audit-only
CONSEQUENCES on top of the full 7 axes) is legitimate — challenge a spec that weakens, not
one that merely extends.

**When the spec under review DEFINES a canonical invariant** — the orthogonal-reframe axis set
(`AGENTS.md` "Orthogonal-reframe axes"), the native-authority taxonomy, or the floor/seal rule
itself — your in-loop verdict is a FLOOR, not a seal: it keys on the same judgment the edit could
get wrong (the PR #79 axis-drop was graded a NOTE by every same-model gate and escalated only
by a cross-model reviewer). Confirm the mechanical floor still passes
(`deno test --allow-read .agents/arcopolis_reframe_axes_test.ts`), then require an external /
cross-model seal before merge (`docs/arcopolis/reframe_axis_external_seal_prompt.md`). Do not
self-ratify a change to the canonical set.

## Adversarial pass (any equivalence or goal-fit claim)

A single read is not a review. Run at least THREE INDEPENDENT refute-lenses — this is
what caught the failures a routine pass missed (docs/arcopolis/ 28/37/38), never one
skill read.

- Each lens DEFAULTS to "refuted / insufficient" and tries to CONSTRUCT a divergence
  (a state where the claim's surface/path and the engine's real mechanism disagree).
- Use DISTINCT lenses, not three identical: e.g. goal-fit/sufficiency,
  seam/active-mechanism, fail-loud/silent-default, witness-scope/leaf-citation.
- Verify at the DECISIVE leaf, not a convenient one: the load-bearing line is the
  predicate's traversal body (recursing vs flat) or the action's call-site placement
  (the seam line the loop consumes, vs a leaf called before/after). Verifying a
  faithful-looking sibling leaf while missing the decisive one is how a reviewer who
  shares the author's conflation passes a broken claim. Confident file:line/existence
  claims (incl. review bots and verify subagents) are often false — open it. This holds
  for your OWN flags too: when an ABSENCE is the load-bearing reason for a flag or
  downgrade — a "missing" / "unwitnessed" / "not-landed" test, fixture, or capability —
  it is itself an existence claim. You cannot "open" what you say isn't there, so refute
  it by grep / `git ls-files` before you headline it, or you may flag a witness already
  committed. (Binds only to an absence that DRIVES the verdict; a non-decisive "deferred
  / out-of-scope / not-yet-built" note no flag rests on needs no search.)
- The claim survives only if no lens constructs a divergence the witness does not cover.

## Combining the lenses (adjudication)

The adversarial pass is monotone, not a vote — its unit is the LENS, and in the common
single-reviewer / single-model run the ≥3 required lenses serve as the independent
verdicts (a floor — see the same-model caveat below). There is no symmetric tally to
break; it has two ASYMMETRIC directions — do not conflate them.

- To REFUTE / flag / block: ONE constructed divergence the witness does not cover
  is decisive (the survival rule above), and any single `Reject or flag if` trigger fires on
  its own. A lone refuting lens is NOT "outvoted" by lenses that found nothing — convergence
  of the OTHER lenses never downgrades a flag to "safe" (absence of a constructed divergence
  is not proof of equivalence, only failure to construct one).
- Monotonicity binds to the EVENT, not the label. Once a lens CONSTRUCTS a divergence the
  witness does not cover, that finding IS a flag — it may not be filed as a NOTE /
  non-blocking to slip past the REFUTE rule above. "It stops conservatively downstream" and
  "the axes loosely subsume each other" are NOT downgrades: neither covers the divergence nor
  re-verifies it at the leaf. A constructed divergence on a canonical / Spike-25 axis
  (native-authority class, downstream-consumer, active-mechanism) grades `needs revision` or
  stronger by default.
- To ADOPT a non-blocking disposition (safe-to-proceed / downgrade): require the claim to
  SURVIVE the ground-truth facts — the divergence re-checked at the DECISIVE leaf against the
  cited source body and the A/B/C/D/S class — AND ≥2 INDEPENDENT lenses to converge on it. Do
  not adopt on ONE lens's say-so, including a confident review bot or verify subagent. A panel
  of same-model lenses is a FLOOR you may act within while LABELING it a floor, not a seal;
  the floor/seal doctrine and the Spike-25 0% basis are owned by `arcopolis-design-interrogate`
  ("Floor, not seal") — see there, do not restate them here.
- This skill is review-only: adjudicate the VERDICT and required next action, never author or
  ratify remedy wording.
- If lenses genuinely conflict on whether a divergence holds, re-verify that ONE disputed
  leaf against the source body once; if still unresolved, resolve to flag/refute (the refute
  default) — do not re-run the full pass.

## Required output

1. **Verdict** — safe to proceed / needs plan revision / block merge / audit-only.
2. **Equivalence claim status** — proven / downgraded / not proven / overclaimed.
3. **Strongest evidence** — cite `file:line` or the exact witness.
4. **Orthogonal reframe tested** — name the lens family you reframed the claim onto (consumer /
   class / mechanism / witness / stage-scope / future-reader) and whether any reframe
   constructed a divergence the witness does not cover. If NO orthogonal reframe changes the
   verdict, say so EXPLICITLY and explain why — which axes you flipped and why each left the
   claim standing. Silence here reads as "not attempted," not "nothing found."
5. **Spec-frame challenge** — did the reviewed SPEC itself preserve the canonical invariant
   (the 7-axis reframe set + downstream-consumer discipline), or was it merely FOLLOWED
   faithfully? "Matches the spec" is not evidence when the spec is the object under review.
6. **Biggest false-green risk — including the reframed false-green risk** (the strongest
   divergence any reframe surfaced). Grade it per the adjudication rule above — a genuinely
   minor divergence may be reported non-blocking, but a constructed divergence on a canonical
   / Spike-25 axis is not a NOTE.
7. **Required next action.**

Keep hedges and witness-scoping intact; do not polish an uncertain claim into
confident prose. A downstream relay or summary of this review may NOT soften a graded
verdict — report the grade as graded; do not re-narrate a `needs revision` finding as an
optional "judgment call" or polish.

## Shared vocabulary

Claim type · Equivalence level · Active engine mechanism · Registered backend
input/action · Real engine caller · Witness · Witness scope · False-green risk ·
Fail-loud · Unsupported adjacent path · Per-transaction gate · No generic
prompt-class support · Native-authority class (A action / B prompt-menu /
C predicate / D display / S simulation-state) · Goal-fit (sufficient-for vs
consistent-with) · Counterexample / divergence witness · Orthogonal reframe (change the
decision axis — route / consumer / class / mechanism / witness / stop-condition / scope —
not the task size) · Author-frame removal (restate the claim from diff + witness + consumer,
not the PR title/body) · Floor vs seal /
judge-independence (same-model lenses = floor, labeled; cross-substrate convergence =
seal; weight by independence + decisive-leaf verification, not confidence; authoritative
floor/seal rule in `arcopolis-design-interrogate`).
