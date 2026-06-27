---
name: arcopolis-design-interrogate
description: >
  Pre-classification skill for Arcopolis (Cataclysm-BN simulation-backend) work.
  Use BEFORE arcopolis-claim-plan whenever the user has a vague design impulse.
  If the request is still broad roadmap/options/design exploration and no single
  actionable impulse exists, use arcopolis-design-explore first; do not turn
  broad "what should we do next?" questions directly into Task Statement Cards.
  Trigger when ANY of the following is true: (1) the impulse names no engine artifact
  (function, file, registered action, or seam); (2) the impulse names an artifact but
  its downstream consumer/class is not yet derived; (3) the impulse touches possession /
  mission / objective / inventory state and has not had its engine consumer named.
  Do NOT trigger if a Task Statement Card already exists for this impulse, or if
  arcopolis-claim-plan is already in progress with a well-formed equivalence claim.
  Produces a Task Statement Card that arcopolis-claim-plan can open with directly.
  Do not use to evaluate feasibility (arcopolis-claim-plan) or review existing work
  (arcopolis-red-team-review).
disable-model-invocation: true
---

# Arcopolis Design Interrogate

Read `AGENTS.md` and `docs/arcopolis/ARCOPOLIS_STATE.md` before running any pass.
The native-authority class vocabulary (`AGENTS.md` → "Native-authority class") and the
live capability state are required inputs. Do not run from memory.

**Routing boundary.** If the user request is still broad roadmap/options/design
exploration and no single actionable impulse exists, run `arcopolis-design-explore`
first. Use this skill only after exploration has narrowed the request to one candidate
impulse. Do not turn broad "what should we do next?" questions directly into a Task
Statement Card.

**Why user-invoked.** This skill is `disable-model-invocation: true` by design: the model
must never launch the interrogation itself. The USER invokes it, so the multi-pass
interview is always user-initiated and user-answered — a hard guarantee that the model
cannot run the interrogation autonomously. Skills that hand work here produce an impulse
the user runs `arcopolis-design-interrogate` with; they do not auto-route to it. (Removing
the flag would downgrade this to a soft, discipline-only property — do not remove it
without an explicit decision to change that guarantee.)

**Who decides what.** YOU (the user) supply the INTENT and the BOUNDARIES — what you want,
roughly who/what consumes it, and what must not change — in plain language. The AGENT
derives the native-authority class, the authority target, the scope, and the likely
mechanism from `AGENTS.md`, `ARCOPOLIS_STATE.md`, and a grounded read of the named engine
source. The agent asks you ONLY intent questions ("do you want the frontend to SHOW this,
or does the engine EVALUATE a condition over it?") — never "which class is this?" or "walk
the call path." You are the intent oracle; the agent is the classification engine; the
rules are the safety net.

**Floor, not seal (the Spike-25 honesty rule).** This skill's in-loop gates RAISE THE
FLOOR — they catch the common, lexically-marked possession/objective trap and force the
consumer-naming + source-citation discipline. They do NOT, and cannot, SEAL the Spike-25
failure. The originating impulse — "what can a frontend show about what the avatar is
holding?" — was a possession goal the agent read as display, and every in-loop
standardized gate scored 0% catch; the only real catch came from OUTSIDE the loop (a human
"equivalent to WHAT?" question, an external review, a cross-model adversarial critic). A
second pass by the SAME model shares the same prior and modally repeats the error. So any
possession / mission / objective / Stage-blocking card is marked `External-seal required:
YES` and is NOT plan-ready until an INDEPENDENT READ — a human GUI-equivalence
confirmation, or a blind cross-model read by a different reasoner (the
`arcopolis-red-team-review` / `/code-review ultra` tools are not yet a sanctioned blind
channel — see the External-seal section) — names the concrete engine consumer and reads its
body. **That independent read is a STRONGER FLOOR (independence evidence), not the seal:** a
different reasoner may share the same plausibility prior and miss the error for the same
reason (de-correlation is unmeasured). The only true SEAL is a MECHANICAL check that cannot
share the prior — a Class-C witness exercising the engine predicate's own returned result,
enforced downstream. For the framing JUDGMENT itself (is this C or D?) no mechanical check
exists — it is floors all the way up; record the independent read and acknowledge the
residual risk. Never represent any pass — in-loop OR independent — as the seal.

This skill turns a vague design impulse into a scoped, falsifiable Task Statement Card. It
does not generate implementation options, evaluate feasibility, survey the backlog, or
propose architecture.

**One follow-up question TO THE USER per pass.** The lone exception is Pass 4's non-goal
RATIFICATION — a single, bounded pick/reject on agent-proposed candidate artifacts: it
confirms the agent's read rather than eliciting new intent, never re-asks, and is itself
flag-and-advance (reject-all → `NON-GOAL-UNBOUNDED`). The agent may inspect source freely;
what is bounded is clarifying questions to the user. If the user's answer after the
follow-up is still insufficient, log the appropriate flag and advance. Do not ask a third
time. A logged flag is the correct output for an unanswerable pass — it is information for
`arcopolis-claim-plan`, not a failure of this skill.

## Pass 1 — Impulse capture

Quote the user's request verbatim. Do not paraphrase or restate it — but redact any
sensitive value (a home-directory path, token, or private environment value) with the
repo's `<user-profile>` / `<repo-root>` convention before echoing it.

**Split check (natural language).** Ask: "Does this describe more than one thing you
want the engine to do?" If yes, announce the split: "This impulse contains two goals:
[A] and [B]. I will produce one Task Statement Card per goal. Running passes for [A]
now — confirm or reorder." Run all five passes for goal A to completion, produce its
card, then begin goal B. Do not interleave questions across goals. A "no" answer does
not bypass the class-based split check in Pass 2.

**Artifact identification.** Identify what, if anything, names an existing engine
artifact (function, file, registered action). If nothing is named, ask **the single
Pass-1 follow-up** (one question, both anchors): "What specific engine behavior,
function, or file is this connected to, by name — or, if it isn't tied to one yet, which
`ARCOPOLIS_STATE.md` frontier area does it touch?"

Do not accept category-level answers. "The movement system," "the UI layer," and
"the inventory logic" are not artifact names. Require a symbol name or file:function
reference. If a name is provided, check it against `ARCOPOLIS_STATE.md` and `AGENTS.md`.
If it does not appear in either: note `ARTIFACT UNVERIFIED` and proceed.

**Already-satisfied check.** The grounding read includes `ARCOPOLIS_STATE.md`'s export
contract and capability state. Take this exit ONLY when an existing capability satisfies
the SAME downstream consumer the impulse needs — same class and scope, not merely a field
of the same name: emit `ALREADY SHIPPED — see <doc:line>; no card needed` and stop.
Existence is not sufficiency. A possession / mission / objective / state-check goal is NOT
already shipped by an existing display or raw-state field — e.g. `avatar.carried_items[]`
exists but does NOT satisfy a possession check (BN answers possession with a
container-recursing predicate, `has_amount` / `has_charges`; see `ARCOPOLIS_STATE.md`).
If the goal is possession/predicate-adjacent, do NOT take this exit — fall through to Pass
2 and let the domain override force Class C. Likewise, an impulse signaling stronger
fidelity than the existing capability provides — registered-input / "like a key press" /
"as a player would" / level-4 intent against a capability shipped only at a lower level —
is NOT already shipped: produce the card and carry the level question as an Open unknown
for `arcopolis-claim-plan` (this skill assigns no equivalence levels; it only declines the
exit when the implied level is unmet). An interrogation that finds the impulse genuinely
met (same consumer and level) is a successful outcome, not a failure.

Disposition of that one follow-up (do NOT ask again — one follow-up per pass): if it
yields a named artifact, treat it as above; if it yields only a frontier area (the doc's
own section headings — never one you pick for the user), log `TARGET UNKNOWN` and proceed
to Pass 2 using the frontier as a loose scope anchor only; if it yields neither, log
`TARGET UNKNOWN` and proceed.

## Pass 2 — Native-authority classification (agent derives; you confirm intent)

_Failure mode addressed:_ Spike 25 — a display/raw-state surface offered as proof of a
possession predicate. The root cause was a MISSING consumer check: the agent inherited the
goal's display framing and never re-asked which engine consumer answers "has the package."

Do NOT ask the user to choose A/B/C/D/S or to name the consuming call. The agent derives
the class from grounded inspection. Read the class definitions from `AGENTS.md` now (do
not enumerate from memory; the set is A/B/C/D/S and may grow).

**Primary gate — name the concrete consumer (the load-bearing floor).** For EVERY card,
the agent must answer, from `AGENTS.md` / `ARCOPOLIS_STATE.md` / a grounded source read:
WHO or WHAT consumes this surface/action, and is that consumer a player-visible DISPLAY
(D), a raw SNAPSHOT reader (S), a registered ACTION path (A), an active MENU/INPUT loop
(B), or an engine PREDICATE/CONDITION (C)? Name the exact engine call, display surface, or
state field that is authoritative. If the concrete consumer cannot be named from
docs/source, output `AUDIT ONLY` — do not guess a class. This is the "equivalent to WHAT?"
question the Spike-25 loop never asked; it is the floor, not a seal (see the external-seal
rule above).

**Reframe-before-classifying probes (agent-derived; no new user question).** Before
assigning a class, REFRAME — flip the frame the impulse arrived in, on these three axes,
and answer each from a grounded source read rather than inheriting the impulse's wording.
These are agent reasoning steps, NOT extra user questions: the one-follow-up-per-pass rule
is unchanged. (Partially addresses issue #73's A-vs-B seam probe and S/D authoritativeness
probe.)

- **SHOW vs EVALUATE.** Is this for a frontend to DISPLAY/observe (→ D/S), or does an
  engine consumer EVALUATE a condition over it (→ C)? An "acquired"/"complete"/"met"
  indicator, an eligibility / button-enable decision, or a mission/quest/objective status
  is an EVALUATE result → C, however the impulse phrases it ("show", "render",
  "scan…for"). This is the Spike-25 flip. When genuinely ambiguous between the two, the one
  Pass-2 intent question below settles INTENT (the agent still decides the class).
- **ACTION vs PROMPT/MENU.** Is the deliverable a registered ACTION consumed at
  `game::handle_action` (→ A, e.g. an `ACTION_*` keypress), or a nested menu / prompt /
  selector choice answered through an active input loop (→ B, e.g. `uilist::query`,
  `input_context::handle_input`, `query_popup`/`query_yn`)? If the impulse carries both
  (e.g. the key-press AND the menu it opens), run the class-based split check below.
- **AUTHORITATIVE STATE vs DERIVED/DISPLAY COPY.** For a candidate that looks D or S, name
  the exact engine field/mechanism read and confirm it is AUTHORITATIVE for the stated
  consumer — not a cached, derived, or display copy that can lag or differ (e.g. a
  monster's raw `hp` vs an effective-after-bonuses value vs what the GUI renders). If the
  named field is a derived/display copy standing in for the authoritative value, or you
  cannot confirm it authoritative, log `AUTHORITY UNVERIFIED` to the card's `Open unknowns`;
  do not classify S on a display proxy (this carries into Pass 3 — see the D/S skip note
  there).

**Possession-surface over-trigger (cheap backstop, NOT the guarantee).** As a cheap first
filter, scan the impulse for any reference to the avatar's/character's items or possession
state — by stem (hold/held/holding, carry/carried/carrying, have/has, possess, inventory,
on-person, package/parcel/item, deliver/delivered, acquire/acquired, complete/met,
checkmark/indicator/status, mission/quest/objective/MGOAL/Stage/goal/condition/predicate)
OR a named possession surface (`carried_items[]`, inventory). If any fires, set
`Possession-surface: touched` and default `Predicate-read owed: YES`. Deliberately
over-inclusive — a needless body-read is cheap; a missed one reopened the spike. **This is
a backstop only.** It catches the lexically-MARKED case; it does NOT catch an
abstraction-routed unmarked goal (e.g. "expose the courier job's completion flag" — no
stem, yet `mission::is_complete` → `crafting_inventory().has_amount`). The unmarked case is
caught — if at all — by the consumer-naming gate and the external independent read, NOT by the stem
list. Never advertise the keyword scan as the mechanical guarantee.

**Domain override.** A possession / mission / objective / state-check goal is Class C
regardless of the display (D) or raw (S) surface it rides on, and owes the predicate
body-read. The displayed value of an objective CONDITION RESULT — a checkmark, an
"acquired"/"complete"/"met" indicator, a button enablement, an eligibility/gate decision —
IS the predicate's result → C, even when phrased "show"/"render"/"scan…for"/"grey-out".
Carve-out (lifts C-forcing; does NOT auto-classify D): a goal that renders a raw ITEM LIST
is not forced to C ONLY when no downstream consumer evaluates membership, completion,
button-state, mission/quest status, or any objective decision over the list — a list shown
purely for a human to read. A raw list that escapes C-forcing is then classified D or S by
its consumer (GUI display = D; raw authoritative snapshot = S) — "not forced C" does NOT
mean "therefore D." Ambiguous → C. A pure raw/display list may set `Predicate-read owed:
NO` only AFTER the consumer-naming gate establishes that no downstream consumer evaluates
membership, completion, button state, mission/quest status, or any objective decision over
the list.

**Intent disambiguation (the only USER question in Pass 2, asked only when needed).** When
the consumer is genuinely ambiguous between display and condition, ask ONE plain-language
intent question: "Is this meant to SHOW a raw/display item list, or to expose whether the
ENGINE considers an objective/possession/condition satisfied?" A raw-list answer only
lifts the C-forcing; it does not by itself decide D vs S. You answer intent; the agent
decides the class.

**Class-based split check.** If the impulse plausibly carries two distinct
native-authority assignments, announce the split and produce one card per goal; else log
`SPLIT DECLINED` if the user declined an offered split.

If no class can be derived after the consumer-naming gate + one intent question: output
`AUDIT ONLY — no classifiable consumer identified.` Stop. If the consumer is named but not
yet anchored to a cited caller/surface, log `CLASS UNVERIFIED` (a risk flag, not a stop).

## Pass 3 — Authority target + discriminating source-citation (agent identifies)

_Failure mode addressed:_ the "convenient JSON proxy" (a flat surface substituted for the
recursing/scoped predicate that answers the goal) AND the wrong-SCOPE sibling (a real
predicate of the wrong reach cited for the goal — `set_has_items` on-person vs
`MGOAL_FIND_ITEM` over `crafting_inventory()`).

Do NOT ask the user to walk the call path. The agent identifies the authority target from
docs/source and writes it to the card ONLY with a cited `file:function`.

**Authority target by class:**

```
A → the registered action + its handler path
B → the active prompt/menu/input loop
C → the predicate-returning engine call (condition/mission body)
D → the native GUI/display surface
S → the raw authoritative state field
```

**Discriminating source-citation (C / `Predicate-read owed` cards).** Citing "a predicate"
is not enough. Open the named consumer's BODY and decide whether the authority is an engine
PREDICATE/CONDITION result (→ C), a DISPLAY/observability view (→ D), or RAW state emitted
verbatim (→ S). If the cited body is a predicate it remains C even when FLAT / top-level —
flatness affects only SCOPE (whether a flat proxy can mirror it), NOT class. **The
discriminator is the CONSUMER's QUESTION, not whether a verdict is computed:** a verdict
computed to answer a possession / mission / objective / condition / state-check question —
returned to an engine/eligibility consumer — is C even when it reads raw fields and returns
one flat bool; a verdict computed purely to drive what the GUI SHOWS (a tile-visibility
filter, an HP-bar "is low" colour, an "over capacity" highlight) is D, not C; S is only a raw
field emitted verbatim with no computed verdict. A flat `carried_items_contains(id)` scan of
`carried_items[]`, offered for "does the engine consider the avatar to HAVE the package?", is
a `PROXY SUBSTITUTION` from a partial view — not a licence to route the goal D/S; the
authority stays the engine predicate (`has_amount` / `has_charges` or the mission condition).
A checkmark / "complete" / "met" indicator is a CONDITION RESULT → C (the Pass-2 domain
override), never D. Cite the decisive line AND state the body's traversal SHAPE (recurses /
aggregates / scopes-wider vs flat / top-level) for the scope comparison — e.g. `has_amount`
recurses via `visitable.cpp` `visit_internal`; `write_carried_items` enumerates flat
top-level sources only. A `Predicate-read owed` card with no such body-read is NOT discharged.

**Scope-binding (the wrong-sibling fix).** A real predicate of the WRONG scope is still
wrong. Record BOTH the goal's REQUIRED scope and the cited predicate's ACTUAL scope (proven
by its body). On mismatch — e.g. on-person `set_has_items` cited for a goal needing
`MGOAL_FIND_ITEM`'s `crafting_inventory()` reach — output `AUDIT ONLY` (`SCOPE MISMATCH`);
do not write the wrong-scope predicate confidently. `SCOPE MISMATCH` requires a KNOWN
goal-required scope: if the goal-required scope is `UNKNOWN`, do not fire a mismatch — route
to the citation threshold (treat as `MECHANISM UNKNOWN` until the required scope is pinned).

**Proxy substitution.** If the only surface the agent can cite for a B/C goal is a D/S
display/raw export (no predicate/loop exposed) → log `PROXY SUBSTITUTION` and treat as
`MECHANISM UNKNOWN`. This is the Spike 25 failure reproduced inside the interrogation.

**Citation threshold.** Never write a confident-but-unverified, or wrong-scope, mechanism
to the card. If the authority cannot be cited at `file:function` with a confirmed signature
AND a matching scope → `AUDIT ONLY` with a Required Source Inspection block. An honest
"cannot identify" beats a plausible wrong symbol that seeds `claim-plan`'s body-read on the
wrong anchor.

**D/S skip (only when not forced C).** A genuine D or S goal (the carve-out lifted the
C-forcing; no `Predicate-read owed`) has no engine-computed predicate to probe — log
`PASS 3 SKIPPED — D/S` and continue. A possession/objective goal never reaches this skip.
The skip waives only the predicate body-read, NOT the Pass-2 authoritativeness probe: still
name the exported field and confirm it is the authoritative value (or the GUI-faithful
display copy the consumer wants), not a cached/derived copy substituted for it — log
`AUTHORITY UNVERIFIED` to `Open unknowns` if it cannot be confirmed.

**Resolution by class:**

```
A-class     → MECHANISM UNKNOWN: log, continue to Pass 4
B / C-class → MECHANISM UNKNOWN / PROXY SUBSTITUTION / SCOPE MISMATCH: AUDIT ONLY, stop
D / S-class → no predicate to probe (skipped), unless the domain override forced C
```

## Pass 4 — Scope bounding (Bounder)

_Failure mode addressed:_ "One witnessed path generalized into prompt-class support" —
the non-goal violation documented across Spikes 12A, 13B, and in `arcopolis-claim-plan`'s
hard rules.

Ask an intent question: "What must this change NOT do — what existing behavior, surface, or
system must it leave intact, or reuse rather than re-implement?" Plain language is the
expected answer (e.g. "don't add a parallel surface alongside the existing engine code").
The non-goal boundary is USER-OWNED (see "Who decides what"); do not demand the user name a
symbol.

Then, by what the user gives:

- **User names a concrete artifact** (a file, registered action, seam, or named capability)
  → accept it directly as the non-goal.
- **User gives a plain-language boundary** → the agent OPERATIONALIZES it by reading the
  source and PROPOSING 1-3 concrete candidate non-goal artifacts the boundary maps to (for
  "don't create a parallel surface", the existing engine path the change must route THROUGH
  rather than duplicate). Present them as proposals and STOP for the user to pick or reject —
  this single ratification turn is the one second user-interaction the pass budget permits
  beyond the intent question (one round; do not re-propose). Record ONLY the artifact the
  user explicitly confirms — an unconfirmed proposal is NOT the
  non-goal, and "I'll treat X as the non-goal" without an explicit user pick is forbidden (it
  would let the agent self-record a convenient, non-binding bound). The user, seeing a
  concrete artifact, can reject a weak choice and name the real one.
- **User states no boundary, or rejects every proposal without naming one** → log
  `NON-GOAL-UNBOUNDED` and continue. Do NOT fabricate a bound.
- **Edge — a genuine boundary with no concrete artifact in source** → say so and record the
  user's plain-language boundary as an artifact-unanchored non-goal, distinct from
  `NON-GOAL-UNBOUNDED` (which means no boundary at all).

**Actor invariant.** The user OWNS the boundary (states it; confirms or names the binding
artifact); the agent ASSISTS (proposes concrete candidates from the code; never binds).
Recording requires an explicit user decision — this keeps the non-goal an independent,
user-anchored guardrail while sparing the user from naming a symbol the agent should surface.

**Self-contradiction check.** After a specific non-goal artifact is confirmed: does it name
the exact same artifact as the goal artifact from Pass 1? If yes: output
`SELF-CONTRADICTORY SCOPE — the goal and the stated non-goal name the same artifact.
A Task Statement Card cannot be produced.` Stop. This check is name-identity only, so it
FIRES whenever Pass 1 produced a concrete goal-artifact name — including `ARTIFACT
UNVERIFIED`, where the user named a symbol that merely is not in the docs (a name is still a
name to compare). It is skipped only when Pass 1 named no artifact at all (`TARGET UNKNOWN`).

Do not prompt for a comprehensive exclusion list. That is impact mapping's job in
`arcopolis-claim-plan`.

## Pass 5 — Falsification criterion

_Failure mode addressed:_ The confirmation-question failure from PR #70 — a gate that
can be answered correctly on the happy path even when the claim is wrong.

**For A-class goals:** "What would the engine do (or fail to do) when the registered
action fires, if the implementation were wrong? Name the observable engine-state
divergence."

**For B-class goals:** "How would you know the implementation is wrong — not incomplete,
wrong? What observable behavior would diverge from what the engine does for the same
prompt/menu action in the GUI?"

**For C-class goals:** "Name a game state where the exposed or queried predicate result
would DIVERGE from the engine predicate's own result on the same engine state, if the
implementation were wrong." A C-class predicate may have no GUI player action at all —
e.g. a dialogue/mission condition; the authority is the engine call's returned value, not
a keypress. Do not demand a GUI-action witness, and do not mark `FALSIFICATION UNKNOWN`
merely because no player action exists — compare result to predicate on the same state.
The AGENT refines the user's stated divergence so the resulting state exercises the SCOPE the
goal requires (e.g. an item nested in a worn container, or off-person within crafting reach)
so a flat or wrong-scope surface is caught — the user is not asked to name that
scope-exercising state.

**For D-class goals:** "Name a game state where the export would diverge from what the
GUI would actually DISPLAY for that field — the native display mechanism, formatted /
filtered / lagged exactly as the GUI renders it — if the implementation were wrong."
(D's authority is the GUI display, not raw state: a view that intentionally formats,
filters, or lags raw state is CORRECT when it matches the GUI — comparing to the raw
in-memory value is the S-class test, not D's.)

**For S-class goals:** "Name a game state where the exported raw value would diverge from
the engine's in-memory authoritative value for the same field, if the implementation were
wrong."

The answer must reference engine state or behavior, not output appearance or aesthetic
difference. "The JSON would look different" is not a falsification criterion. "The
engine predicate would return true when the export returns false" is.

**Actor split.** The user supplies the plain-language WRONGNESS — what observable behavior
would be wrong ("the engine would say the avatar has it, but our surface would say no"). The
AGENT refines that into the scope-exercising divergence state above. Do not charge the user
with the scope-specific state — that is the agent's job.

If the user cannot state ANY behavioral wrongness after one follow-up — not merely the
scope-exercising specifics, which the agent supplies — log `FALSIFICATION UNKNOWN`. This does
not block the card, but `arcopolis-claim-plan` must address it before any witness is chosen.

## Output

### Task Statement Card (actionable impulse)

```
Task:                  [one sentence, active verb, names the engine artifact]
Downstream consumer:   [named consumer — display / snapshot / action / menu-loop / predicate — or UNKNOWN]
Native-auth class:     [A / B / C / D / S — agent-derived, CLAIMED not proven — or UNKNOWN]
Goal-required scope:   [on-person / container-deep / crafting reach / map / GUI display / raw field / UNKNOWN]
Authority target:      [cited file:function / display surface / raw field — or UNKNOWN]
Authority scope:       [scope proven by the cited body — or UNKNOWN]
Predicate-read owed:   [YES (with trigger basis) / NO]
External-seal required:[YES (possession/objective/Stage-blocking) / NO]
External-seal status:  [not required / required (pending) / cleared by human / cleared by blind cross-model read / AUDIT ONLY (reviewer disagreed or returned UNKNOWN)]
External-seal evidence:[link, quote, or reviewer-output summary — or NONE]
Must NOT touch:        [named surface, seam, or capability — or NON-GOAL-UNBOUNDED]
Falsification:         [C: vs engine predicate result on the same state · D: vs GUI display · S: vs raw state · A: engine-state/seam divergence — or UNKNOWN]
Open unknowns:         [all logged flags — or NONE]
```

The agent-derived fields (Downstream consumer, Native-auth class, Goal-required scope,
Authority target, Authority scope) are the agent's CLAIMED values from a grounded read,
NOT verified findings: `arcopolis-claim-plan` re-derives and checks them at its
Consumer/mechanism step (item 4 — including the predicate body-read and the goal-required
vs authority vs surface scope comparison) and its registered-input step (item 3). The card
front-loads them to focus the plan; a fully-filled card is well-FORMED, not proven TRUE.
**A card with `External-seal required: YES` is NOT plan-ready until the external check (next
section) is recorded.** The card's own load-bearing contributions are the consumer-naming, the
`Falsification` criterion, and the `Open unknowns` flags `arcopolis-claim-plan` must resolve.

### External seal (possession / objective / Stage-blocking cards)

Any card with `External-seal required: YES` — any possession / mission / objective /
state-check / Stage-blocking goal — is NOT plan-ready on this skill's output alone. The
independent read (name the concrete engine consumer, read its body, discriminate an
engine-computed check C from a display D on the same state) must be performed by a reasoner
that does NOT share this agent's prior: a human "equivalent to WHAT?" GUI-equivalence
confirmation, an external review, or a cross-model reasoner given the blind input below. (The
`arcopolis-red-team-review` / `/code-review ultra` TOOLS are NOT yet a sanctioned blind
channel — see the tool-channel limitation below.) It is a STRONGER FLOOR (independence
evidence), NOT the seal — the reasoner may share the prior and miss the error for the same
reason; the only true seal is the downstream MECHANICAL Class-C witness, and for the framing
judgment itself none exists. Record the `External-seal status` on the card; `arcopolis-claim-plan`
must not advance a possession/objective card to a Stage-blocking witness until that
independent read is recorded.

**The external-seal input must be BLIND.** Give the second reader ONLY the raw user impulse,
relevant repo context pointers, and the forcing question — "name the concrete downstream
engine consumer, and say what the engine does with the value: does it SHOW it, EVALUATE a
yes/no it computes from it, hold it as raw state, perform it as an action, or present it as a
menu?" Do NOT provide the first Task Statement Card, the proposed class,
authority target, scope, or rationale until AFTER the second reader has answered; otherwise
the reviewer is anchored by the first agent's framing, which is the circularity the
independent read exists to break. The repo pointers are agent-selected, so constrain them to NEUTRALITY:
point at BOTH any display/raw surface AND any suspected predicate/condition source the
impulse could touch (or grant the reviewer independent repo grep), never only the first
agent's preferred surface; and ask the forcing question WITHOUT naming the suspected class,
the authority target, or the word "predicate." (Driving the independent read through a TOOL channel —
`arcopolis-red-team-review` / `/code-review ultra` — is a LIMITATION, not yet a procedure:
those tools rate an EXISTING claim rather than classify from scratch, so feeding them even a
blind input would not seal anything — the limitation is the tools' rate-not-classify
behavior, not a missing input shape (`arcopolis-external-seal-prompt` produces that input for
the sanctioned channels). A human "equivalent to WHAT?" read and a neutral grep/source
pointer are the sanctioned blind channels.) If the second reader
disagrees, names a different consumer/scope, or returns UNKNOWN: `AUDIT ONLY`.

To PRODUCE this blind input without hand-authoring it each time, invoke
`arcopolis-external-seal-prompt`; it enforces exactly the requirements above (strip the
card / class / target, raw impulse only, neutral both-surface pointers, forcing question
without the word "predicate") and emits a portable prompt. This section remains the SPEC the
generator implements — the External-seal requirement and the blind-input shape are DEFINED here; the
generator only assembles them, and it does not itself clear the block.

### AUDIT ONLY output (non-actionable stop)

```
AUDIT ONLY — [reason]
Class:          [derived class, or UNKNOWN]
Artifact named: [named artifact, or UNKNOWN]
Flags:          [all logged flags]
Required source inspection before next interrogation:
  - Read [artifact] in [file if known, otherwise: search for artifact symbol]
  - Identify [the engine call that consumes this predicate / the active input loop /
    the registered handler] at runtime; for a possession/objective goal, read the
    predicate body and state its scope (on-person container-deep vs crafting/map reach)
  - Name the specific function (e.g. uilist::query, input_context::handle_input,
    condition.cpp::set_has_items, mission.cpp MGOAL_FIND_ITEM)
Return with that function name (and its proven scope) to restart from Pass [2 or 3].
```

The inspection block must be specific to the named artifact and derived class. A generic
"go read the code" is not a valid AUDIT ONLY output.

`AUDIT ONLY` fires on:

- Pass 2: no classifiable consumer (no consumer nameable after the gate + one intent question)
- Pass 3: B- or C-class with unknown / proxy-substituted / wrong-scope mechanism

Pass 4 self-contradictory scope is a SEPARATE terminal stop, not an `AUDIT ONLY`: it emits
its own `SELF-CONTRADICTORY SCOPE` line and is resolved by redefining the goal/non-goal,
not by reading code — it does not use the inspection template above.

`AUDIT ONLY` is a valid, successful outcome. A well-run interrogation that concludes
the impulse is not yet actionable is better than a fabricated task statement.

## Integration with `arcopolis-claim-plan`

`arcopolis-claim-plan`'s preamble carries the downstream enforcement for the flags this
skill emits — see its **`## Incoming Task Statement Card`** block. That block makes a
`CLASS UNVERIFIED` flag a mandatory resolution point at the "Consumer + native mechanism"
step (item 4); runs item 4's consumer re-derivation + predicate body-read + the
goal-required vs authority vs surface scope comparison for every observation/predicate
card; requires a `FALSIFICATION UNKNOWN` flag to be resolved before any witness (item 5);
and treats `External-seal required: YES` as a hard block on a Stage-blocking witness until
an independent (human / cross-model) read is recorded (a stronger floor, not a seal).

The authoritative wording lives in `arcopolis-claim-plan` — do not duplicate it here, to
avoid drift. These flags have downstream enforcement only while that block is present; if
it is removed, they become inert.

## Hard rules

- The AGENT derives class, consumer, authority target, and scope from grounded inspection.
  Do NOT quiz the user on classification or call paths; ask only intent questions.
- The possession-surface keyword scan is a cheap over-trigger, NOT the mechanical
  guarantee. The floor is consumer-naming + the discriminating body-read; an independent
  external (human / cross-model) read is a STRONGER FLOOR (independence evidence), not the
  seal; the only true seal is a mechanical Class-C witness. Never call an in-loop pass, or an
  independent read, the seal.
- A possession / mission / objective / state-check card is `External-seal required: YES`
  and is not plan-ready on this skill alone.
- Do not generate implementation options, evaluate feasibility, or assign equivalence
  levels. Those belong in `arcopolis-claim-plan`.
- Do not select what to work on next. Broad roadmap/options selection belongs in
  `arcopolis-design-explore`; already-narrowed implementation/audit planning belongs in
  `arcopolis-claim-plan`. `ARCOPOLIS_STATE.md` is a state reference, not a
  prioritization queue.
- Do not write a confident-but-unverified or wrong-scope mechanism to the card; an honest
  AUDIT ONLY beats a plausible wrong symbol.
- One follow-up question to the user per pass (Pass 4's non-goal ratification is the lone
  bounded exception). Flag and advance on failure.

## Shared vocabulary

- **Native-authority class:** as defined in `AGENTS.md` → "Native-authority class" (A/B/C/D/S,
  may grow). Do not enumerate from memory.
- **Orthogonal reframe:** changing the decision _axis_ before accepting the user's or
  author's framing — not a larger or smaller version of the same task. A valid reframe must
  state what it changes: route, downstream consumer, native-authority class guess, active
  mechanism, witness, stop condition, or scope. In this skill the reframe is internal: the
  three **reframe-before-classifying probes** (SHOW vs EVALUATE, ACTION vs PROMPT/MENU,
  AUTHORITATIVE vs DERIVED/DISPLAY) flip the impulse's frame so the class follows the
  consumer, not the wording. Broad option/axis reframing at the product level belongs to
  `arcopolis-design-explore`.
- **Floor vs independence vs seal:** in-loop gates (consumer-naming, body-read,
  scope-binding, the keyword over-trigger) RAISE THE FLOOR; an independent external check
  (human GUI-equivalence question or cross-model adversarial review) is a STRONGER FLOOR /
  independence evidence, NOT a proven seal; the only true SEAL is a mechanical Class-C witness
  (and for the framing judgment itself, none exists — floors all the way up). The skill forces
  the independent check; it does not internally close Spike-25.
- **Downstream consumer:** the named engine consumer of the surface/action (display /
  snapshot / action / menu-loop / predicate). Naming it is Pass 2's primary gate.
- **Goal-required scope / Authority scope:** the reach the goal needs (on-person /
  container-deep / crafting reach / map / GUI / raw) vs the reach proven by the cited body.
  A mismatch is `SCOPE MISMATCH` → AUDIT ONLY.
- **`Predicate-read owed`:** a possession/objective surface owes the discriminating
  body-read before a class is final.
- **`External-seal required`:** a possession/objective/Stage-blocking card needs an
  independent (human / cross-model) read — a stronger floor, not a seal — before it is
  plan-ready.
- **Proxy substitution:** a D/S surface offered as the B/C mechanism. `AUDIT ONLY`.
- **`MECHANISM UNKNOWN`:** no citable authority mechanism (predicate body / input loop /
  handler) for the goal — the genus; `PROXY SUBSTITUTION` and `SCOPE MISMATCH` are named
  sub-causes. Class-dependent disposition: A-class logs and continues to Pass 4; B/C-class is
  terminal `AUDIT ONLY`.
- **Classifier / Prober / Bounder:** the functions of Passes 2, 3, 4 — sequential, not
  multi-agent roles.
- **`ARTIFACT UNVERIFIED`:** proposed symbol not found in `ARCOPOLIS_STATE.md` / `AGENTS.md`.
  Open unknown, not a stop.
- **`CLASS UNVERIFIED`:** consumer named but not anchored to a cited caller/surface. Risk flag.
- **`AUTHORITY UNVERIFIED`:** a D/S field is a derived / cached / display copy (or cannot be
  confirmed authoritative for the stated consumer), not the authoritative value — the Pass-2
  AUTHORITATIVE-vs-DERIVED probe. Logged to `Open unknowns` for `arcopolis-claim-plan` to
  resolve at its consumer re-derivation (item 4).
- **`SPLIT DECLINED`:** user declined a class-based split.
- **`SCOPE MISMATCH`:** cited predicate's scope ≠ goal-required scope. `AUDIT ONLY`. Requires
  a KNOWN goal-required scope; an `UNKNOWN` required scope routes to the citation threshold,
  not a mismatch.
- **`NON-GOAL-UNBOUNDED`:** no user-owned non-goal boundary established in Pass 4 — the user
  named none and confirmed no proposed candidate. Yellow flag. (Renamed from `SCOPE UNBOUNDED`
  so it stops colliding with the agent-derived authority/goal scope.)
- **`FALSIFICATION UNKNOWN`:** no behavioral divergence stated in Pass 5. `arcopolis-claim-plan`
  must resolve before any witness.
- **`SELF-CONTRADICTORY SCOPE`:** goal and non-goal name the same artifact. A separate
  terminal stop after Pass 4 (not an `AUDIT ONLY`); resolved by redefining the scope. The
  name-identity check fires whenever Pass 1 produced a goal-artifact name (including
  `ARTIFACT UNVERIFIED`) and is skipped only for `TARGET UNKNOWN` (no name to compare).
- **`TARGET UNKNOWN`:** user cannot name any artifact or frontier area. Proceed using the
  frontier as a loose anchor; logged on card.
