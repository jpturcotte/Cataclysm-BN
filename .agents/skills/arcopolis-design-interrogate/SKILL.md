---
name: arcopolis-design-interrogate
description: >
  Pre-classification skill for Arcopolis (Cataclysm-BN simulation-backend) work.
  Use BEFORE arcopolis-claim-plan whenever the user has a vague design impulse.
  Trigger when ANY of the following is true: (1) the impulse names no engine artifact
  (function, file, registered action, or seam); (2) the impulse names an artifact but
  does not classify the downstream consumer (A/B/C/D/S); (3) the impulse names an artifact
  and a class but the class is not anchored to a cited engine caller or observing surface.
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
live capability state are required inputs to Pass 2. Do not run from memory.

This skill does one thing: adversarial scope reduction. It turns a vague design impulse
into a scoped, falsifiable Task Statement Card. It does not generate implementation
options, evaluate feasibility, survey the backlog, or propose architecture.

Depth is not uniform across the passes. Passes 1, 4, and 5 plus the `AUDIT ONLY` exit are
the general, class-agnostic spine — they reduce scope for any impulse. Pass 2's domain
override and Pass 3's proxy-substitution check are a risk-targeted **C-class
(possession/predicate) sub-procedure**: they exist to catch the Spike-25 trap and are
largely inert for a plain A/B/D/S impulse, which is carried mostly by the spine. Do not
mistake that machinery for uniform interrogation depth.

**One follow-up question per pass, no exceptions.** If the user's answer after the
follow-up is still insufficient, log the appropriate flag and advance. Do not ask a
third time. Do not rephrase and retry. A logged flag is the correct output for an
unanswerable pass — it is information for `arcopolis-claim-plan`, not a failure of
this skill.

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
2's domain override and let it force Class C. Likewise, an impulse signaling stronger
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

## Pass 2 — Native-authority classification (Classifier)

_Failure mode addressed:_ Spike 25 — a display/raw-state export offered as proof of a
possession predicate; no gate caught the consumer misclassification before the plan was
written.

**Class-based split check.** Before asking the user to classify, evaluate whether the
impulse could receive two distinct native-authority assignments. If yes and the user
answered "no" to the Pass 1 natural-language split check: "On reflection, this may
involve both [X]-class and [Y]-class behavior. Should we split?" Apply the split if
confirmed. If declined: log `SPLIT DECLINED` and continue with the user's unified framing.

**Classification.** Read the class definitions from `AGENTS.md` now — do not enumerate
or paraphrase from memory (`AGENTS.md` → "Native-authority class"; the set is A/B/C/D/S
and may grow). Present the classes exactly as that doc defines them. Ask: "Which class
does the downstream consumer of this capability belong to? Name the consuming engine call
or the observing frontend surface."

**Anchor validation.** A valid anchor is a named function, a named call site, or a
cited line in `AGENTS.md` or `ARCOPOLIS_STATE.md`. Category names do not qualify:
"the condition evaluator," "the movement system," and "the frontend" are not anchors.
If the assignment is unanchored: log `CLASS UNVERIFIED`. This is a risk flag, not a
blocker.

**Domain override (unconditional — the Spike-25 gate).** The goal DOMAIN, not the surface
named, decides the class for a possession/predicate goal. If the impulse's goal is
possession / mission / objective / state-check adjacent, the class is **C** regardless of
any display (D) or raw-state (S) surface named, and Pass 3 runs the mechanism probe. This
fires:

- structurally, with no extra question, when the stated purpose names a possession /
  mission / objective check or a Stage gate ("would BN consider…", "confirm / validate /
  verify that the player has…"); OR
- after one disambiguating question when the impulse only HINTS at it through a predicate
  verb ("has," "holds," "returns true when") over a display-looking surface: ask "Is the
  downstream goal a display question (what can the frontend show?) or a possession /
  validation question (would the engine consider this condition met)?" — validation → C;
  display → keep the stated class. This counts as Pass 2's one follow-up. The keyword only
  TRIGGERS the question; it does not decide — the user's answer does, and a possession
  DOMAIN is C even when the wording is innocent.

The structural trigger keys on a yes/no condition the engine would evaluate — a
possession/objective CHECK or Stage GATE ("does the player have X?"). It FIRES (to Class
C) whenever the goal exposes a CONDITION RESULT — a checkmark, an "acquired" / "complete"
/ "met" / "delivered" indicator, or any quest/objective/mission STATUS whose truth comes
from a possession/objective predicate — even when phrased as "show" / "render" / "light
up" / "scan … for": the displayed value IS the predicate's result, so the authority is
the predicate, not the display surface. The carve-out is NARROW: only a goal that renders
a raw ITEM LIST (the inventory contents themselves, with NO condition evaluated) is
genuine D. When a goal touches a mission / quest / objective / Stage surface and is not
unambiguously a raw list, the disambiguating question is OWED (not optional) and the
default is C; a possession/objective DOMAIN is C even when phrased as an export or a
checkmark (the Spike-25 rule, not an escape from it).

Naming a D- or S-class surface does not exempt a possession goal from the predicate
body-read; that relabel is the Spike-25 dodge. (This mirrors `arcopolis-claim-plan`
item 4's unconditional domain trigger.)

If the user cannot assign any class after one follow-up: output `AUDIT ONLY —
impulse not actionable. No classifiable consumer identified.` Stop.

## Pass 3 — Mechanism probe (Prober)

_Failure mode addressed:_ The "convenient JSON proxy" pattern from doc 51 — a surface
consistent with the goal substituted for the native mechanism that answers it.

**D/S-class skip.** If the goal is D-class or S-class AND the Pass-2 domain override did
NOT fire, skip Pass 3. Log `PASS 3 SKIPPED — D-class` or `PASS 3 SKIPPED — S-class` on
the card and continue to Pass 4. (Observation of a display view or of raw world state has
no engine-computed mechanism to probe.) A possession/predicate goal can never reach this
skip — the domain override has already forced it to C.

**Mechanism question (A, B, C-class).** Ask: "What would the engine do, step by step,
if this capability did not exist? Walk the call path." If the user can walk it: name
the mechanism as file:function.

**Proxy-substitution check.** Verify class–mechanism consistency. A C-class goal
requires a predicate-returning engine call. A B-class goal requires an active input loop.
If the walked path names a D- or S-class surface (display export, JSON field, raw-state
dump, observation-only output) as the mechanism for a B- or C-class goal: log
`PROXY SUBSTITUTION` and treat as `MECHANISM UNKNOWN`. This is the Spike 25 failure
reproduced inside the interrogation — do not pass it through.

The proxy keyword filter (predicate verb over a display surface) is a cheap first pass
only; the Pass-2 domain override is the real backstop, because it fires on the goal
DOMAIN regardless of wording. Do not treat a clean keyword scan as proof of goal-fit.

**Resolution by class:**

```
MECHANISM UNKNOWN / PROXY SUBSTITUTION:
  A-class     → log MECHANISM UNKNOWN, continue to Pass 4
  B-class     → AUDIT ONLY with Required Source Inspection block, stop
  C-class     → AUDIT ONLY with Required Source Inspection block, stop
  D / S-class → cannot reach (skipped this pass, unless the domain override forced C)
```

## Pass 4 — Scope bounding (Bounder)

_Failure mode addressed:_ "One witnessed path generalized into prompt-class support" —
the non-goal violation documented across Spikes 12A, 13B, and in `arcopolis-claim-plan`'s
hard rules.

Ask: "Name one thing this change must NOT affect — a surface, a mechanism, or a
capability that must remain unchanged."

Accept only a specific artifact name: a file, a registered action, a seam, or a named
capability. Do not accept category-level answers: "existing behavior," "the save system,"
and "the UI layer" are not artifact names. If the user provides only a category: ask
once for a specific name. If still no specific name: log `SCOPE UNBOUNDED` and continue.

**Self-contradiction check.** After accepting a specific non-goal name: does it name
the exact same artifact as the goal artifact from Pass 1? If yes: output
`SELF-CONTRADICTORY SCOPE — the goal and the stated non-goal name the same artifact.
A Task Statement Card cannot be produced.` Stop. This check is name-identity only.

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

If the user cannot state a behavioral divergence after one follow-up: log
`FALSIFICATION UNKNOWN`. This does not block the card, but `arcopolis-claim-plan` must
address it before any witness is chosen.

## Output

### Task Statement Card (actionable impulse)

```
Task:              [one sentence, active verb, names the engine artifact]
Native-auth class: [A / B / C / D / S — with cited consumer, or UNVERIFIED]
Target mechanism:  [file:function — or UNKNOWN]
Must NOT touch:    [named surface, seam, or capability — or UNBOUNDED]
Falsification:     [observable behavioral divergence from engine state — or UNKNOWN]
Open unknowns:     [all logged flags — or NONE]
```

The Task Statement Card is the only artifact this skill produces for actionable impulses.
Three of its fields — **Native-auth class**, **Target mechanism**, and **Must NOT touch** —
are the user's CLAIMED values, not verified findings: `arcopolis-claim-plan` re-derives and
checks them at its Consumer/mechanism step (item 4, including the predicate body-read at
`file:line`), its registered-input step (item 3), and its impact map (item 6). The card
front-loads them as guesses to focus the plan, NOT as discharged work — a fully-filled card
is well-FORMED, not proven TRUE. The card's own load-bearing contributions are the
**Falsification** criterion (a behavioral divergence named before any witness exists) and
the **Open unknowns** flags `arcopolis-claim-plan` must resolve.

### AUDIT ONLY output (non-actionable stop)

```
AUDIT ONLY — [reason]
Class:          [stated class, or UNKNOWN]
Artifact named: [named artifact, or UNKNOWN]
Flags:          [all logged flags]
Required source inspection before next interrogation:
  - Read [artifact] in [file if known, otherwise: search for artifact symbol]
  - Identify [the engine call that consumes this predicate / the active input loop /
    the registered handler] at runtime
  - Name the specific function (e.g. uilist::query, input_context::handle_input,
    condition.cpp::set_has_items)
Return with that function name to restart from Pass [2 or 3].
```

The inspection block must be specific to the named artifact and stated class. A generic
"go read the code" is not a valid AUDIT ONLY output.

`AUDIT ONLY` fires on:

- Pass 2: unclassifiable consumer (no class after one follow-up)
- Pass 3: B- or C-class with unknown or proxy-substituted mechanism

Pass 4 self-contradictory scope is a SEPARATE terminal stop, not an `AUDIT ONLY`: it emits
its own `SELF-CONTRADICTORY SCOPE` line and is resolved by redefining the goal/non-goal,
not by reading code — it does not use the inspection template above.

`AUDIT ONLY` is a valid, successful outcome. A well-run interrogation that concludes
the impulse is not yet actionable is better than a fabricated task statement.

## Integration with `arcopolis-claim-plan`

`arcopolis-claim-plan`'s preamble carries the downstream enforcement for the flags this
skill emits — see its **`## Incoming Task Statement Card`** block (added when this skill
was deployed). That block makes a `CLASS UNVERIFIED` flag a mandatory resolution point at
the "Consumer + native mechanism" step (item 4), and requires a `FALSIFICATION UNKNOWN`
flag to be resolved before any witness is chosen (item 5).

The authoritative wording lives in `arcopolis-claim-plan` — do not duplicate it here, to
avoid drift. These flags have downstream enforcement only while that block is present; if
it is removed, they become inert.

## Hard rules

- Do not generate implementation options. That is `arcopolis-claim-plan`.
- Do not select what to work on next. This skill produces ONE card per impulse; it does
  not survey the backlog or prioritize (that is `arcopolis-claim-plan`'s Triage mode).
  `ARCOPOLIS_STATE.md` is a state reference, not a prioritization queue. The user drives
  which impulse to interrogate. (Using the frontier section headings to help the user
  anchor a `TARGET UNKNOWN` impulse is not selection — it is anchoring.)
- Do not evaluate feasibility or assign equivalence levels. Those belong in
  `arcopolis-claim-plan`.
- Do not run the adversarial multi-lens pass. That belongs in `arcopolis-red-team-review`.
- Do not accept category-level answers for artifact names, consumer anchors, or
  non-goal surfaces at any pass. Require symbol names, file references, or cited lines
  from `AGENTS.md` or `ARCOPOLIS_STATE.md`.
- One follow-up per pass. Flag and advance on failure.

## Shared vocabulary

- **Native-authority class:** as defined in `AGENTS.md` → "Native-authority class" — read
  that doc for the current authoritative list (A/B/C/D/S, and the set may grow). Do not
  enumerate classes from memory.
- **Goal-fit:** whether a capability answers the question the goal actually poses
  (predicate, state, action, or display), as distinct from being internally consistent
  with it or observationally plausible.
- **Task Statement Card:** the output artifact of this skill; the input artifact of
  `arcopolis-claim-plan`.
- **Proxy substitution:** naming a D- or S-class surface (display export, JSON field,
  raw-state dump) as the mechanism for a B- or C-class goal. Logs `PROXY SUBSTITUTION`;
  treated as `MECHANISM UNKNOWN`.
- **Classifier / Prober / Bounder:** the interrogation functions of Passes 2, 3, and 4.
  Not multi-agent roles — sequential functions this skill performs.
- **`ARTIFACT UNVERIFIED`:** proposed symbol not found in `ARCOPOLIS_STATE.md` or
  `AGENTS.md`. Does not stop the interrogation; appears on the card as an open unknown.
- **`CLASS UNVERIFIED`:** class stated but not anchored to a named caller or surface.
  Risk flag, not a stop.
- **`SPLIT DECLINED`:** user declined a class-based split. Logged on card.
- **`PROXY SUBSTITUTION`:** D- or S-class surface offered as B/C-class mechanism. Hard
  stop for B/C; see Pass 3 resolution table.
- **`SCOPE UNBOUNDED`:** no specific non-goal surface named in Pass 4. Yellow flag for
  `arcopolis-claim-plan`.
- **`FALSIFICATION UNKNOWN`:** no behavioral divergence stated in Pass 5. `arcopolis-claim-plan`
  must resolve before any witness is chosen.
- **`SELF-CONTRADICTORY SCOPE`:** goal and non-goal name the same artifact. A separate
  terminal stop after Pass 4 (not an `AUDIT ONLY`); resolved by redefining the scope.
- **`TARGET UNKNOWN`:** user cannot name any artifact or frontier area. Proceed using
  frontier as loose anchor; logged on card.
