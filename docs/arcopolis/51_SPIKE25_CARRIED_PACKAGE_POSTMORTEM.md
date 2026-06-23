# Spike 25 — failed spike postmortem (wrong primitive)

> **Status: FAILED (process) / CORRECTED.** The code Spike 25 built — the read-only
> `avatar.carried_items[]` top-level export — is correct, useful, and **will be merged**. But the spike
> asked the **wrong question**. It built a _display_ capability ("what can a frontend show about what the
> avatar is holding?") and labelled it as resolving the Stage A "carried-package" blocker, which is actually
> a _possession-validation_ question ("would Bright Nights itself consider this character to have the
> package?"). The export is **top-level by construction** and so cannot answer the possession question, which
> the engine evaluates with a **container-recursing** predicate. No gate caught the mismatch, because every
> gate verified **internal consistency** and none verified **goal-fit**. Disposition: merge the code,
> **relabel it display/observability-only**, correct the over-claiming doc lines, and answer Stage A
> possession with BN's own possession predicate (a follow-up, not this spike).

> **Scope:** a process/claim failure, not an architecture inversion. Unlike Spike 3 (a turn-structure defect
> in driven behavior, [`08_SPIKE3_MOVE_COMMAND.md`](08_SPIKE3_MOVE_COMMAND.md)), Spike 25 is **level-1
> observation only** — nothing new is driven, and the L1 claim it makes is _true_. What failed is upstream of
> the claim: the spike answered a well-formed question that was not the one the goal needed. Source line
> numbers drift — trust the symbol names quoted here.

## Fidelity / equivalence principle — NOT met by this spike

**For an observation claim, expose the engine's _native_ mechanism for the consumer that will actually read
it — never a convenient JSON proxy that merely looks consistent with the goal.** The Stage A goal ("find a
package, return it to the contact") is gated by BN's own possession check. The native mechanism for that
check is a container-recursing predicate over the character's carried items (`condition.cpp` `u_has_items` /
`u_has_item`; `mission.cpp` `MGOAL_FIND_ITEM` completion). `avatar.carried_items[]` is a flat, top-level
enumeration that is _consistent with_ possession in the witnessed case but is **not** that predicate and
cannot stand in for it. The spike met the L1-observation bar it set; it did not meet the goal-fit bar it
implied.

## Summary

Spike 25 added `write_carried_items()` to `src/arcopolis_export.cpp` (~50 lines, one source file): a
read-only `avatar.carried_items[]` array nested under the `avatar` snapshot object. It enumerates exactly
three flat, top-level sources in BN's own `visitable<Character>::visit_items` root order — `wielded_items()`,
`worn`, and the top-level stacks of `inv_const_slice()` — never descending into container contents. It is
purely additive (`schema_version` stays 1), preserves fail-loud behavior, and was validated: MSVC build
clean, clang-cl 0 errors, `[arcopolis]` 981 assertions green, all regressions green including a new
**count-delta** pickup gate (`glass_shard` ground `−1`, carried(inventory) `0 → 1`). As an L1 display export,
it is sound and reusable.

**However, the spike is marked FAILED**: it was scoped and documented as _resolving the carried-package gap
for Stage A_ ([`50_SPIKE25_CARRIED_PACKAGE_EXPORT.md`](50_SPIKE25_CARRIED_PACKAGE_EXPORT.md) §"Status and
claim"; [`ARCOPOLIS_STATE.md`](ARCOPOLIS_STATE.md) "carried-package visibility"). The Stage A blocker is
possession **validation**, not frontend display, and the engine answers it with a recursing predicate that a
top-level export structurally cannot mirror. The capability is real but is the **wrong primitive** for the
goal it cites.

## Why this matters for Arcopolis

The whole point of the backend is that **the engine's answer is the answer**. A frontend asking "did the
player return the package?" must get BN's verdict, not a verdict re-composed by a consumer from a partial
JSON view. If the consumer composes "has the package" by scanning a flat `carried_items[]`, it will
**disagree with the engine** the moment the package is nested inside a container by _any_ means — the export
will not list it, but BN's predicate still finds it (it recurses). Shipping the display proxy _as if_ it were
the possession primitive would bake a silent divergence into the Stage A slice. Catching this at the doc
stage, before any consumer relied on it, is the cheap version of the lesson.

## Prior state

- **Spike 8A** — read-only ground-item export (`entities.items[]`); the field-shape precedent
  `carried_items[]` mirrors.
- **Spikes 12A/16** — the existing level-4 `pickup` machinery the Spike 25 witness rides to _create_ a
  carried item, then observe it (no new driven path).
- **Audit 47** ([`47_ARCOPOLIS_VERTICAL_SLICE_ENGINE_AUDIT.md`](47_ARCOPOLIS_VERTICAL_SLICE_ENGINE_AUDIT.md))
  §5/§9 — named a "carried-package gap" for the Stage A slice. Spike 25 **inherited this as a _display_
  gap** and never re-asked which engine consumer answers "has the package." This is where the wrong question
  entered.
- **Spike 25 (this)** — `avatar.carried_items[]`, L1 observation, doc 50.

## Files changed

| File                                                  | Change                                                                                               |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `src/arcopolis_export.cpp`                            | `write_carried_items()` (`write_carried_items`); three flat top-level sources; nested under `avatar` |
| `docs/arcopolis/script_prompt_regression.ps1`         | new W1 carried gates (present / count-delta / worn-enumerated / clean-transcript)                    |
| `docs/arcopolis/50_SPIKE25_CARRIED_PACKAGE_EXPORT.md` | spike doc — over-claim lines corrected (see "Proposed correction")                                   |
| `docs/arcopolis/ARCOPOLIS_STATE.md`                   | `carried_items[]` paragraph + capability row — relabelled display-only                               |

The code rows stand. The doc rows over-claimed and are corrected.

## What the correct path is (from the code)

### What was claimed / done

`carried_items[]` enumerates the avatar's carried items as **three flat top-level sources** and **never
descends into container contents** (`write_carried_items`: `wielded_items()`, `worn`, `inv_const_slice()`
top-level stacks; comment "never descending into contents"). Doc 50 §"Why a top-level export proves the
carried package (the linchpin)" argues a picked-up loose item lands in flat top-level `Character::inv` via
`i_add` → `inv.add_item`, so a top-level-only export is _sufficient_ to show the carried package. That
argument is correct **for the loose-pickup path only**.

### What is actually true

The Stage A possession question is answered by an engine predicate that **recurses into containers**, so the
top-level export is _not_ sufficient in general:

- **The on-person predicate the user chose** is dialogue `u_has_items` / `u_has_item` (`condition.cpp`,
  `set_has_items`): `actor->has_charges( item_id, count ) || actor->has_amount( item_id, count )` (and the
  single form `charges_of(id) > 0 || has_amount(id, 1)`). It is charges-OR-amount over the character.
- **`has_amount` recurses.** `visitable<T>::has_amount` is `amount_of(...) == qty` (capped at `qty`, so "at
  least N"); `amount_of` tallies through `visit_items` (`amount_of_internal`), and that traversal **descends
  into container contents** — `visit_internal` recurses via `node->contents.visit_contents(...)` on
  `VisitResponse::NEXT`; only guns/magazines do **not** descend. The `Character` override special-cases only
  bionic pseudo-tools / voltmeter / apparatus under `pseudo`, then falls to the same recursing
  `amount_of_internal` — it adds **no** off-person source, so scope is on-person but container-deep.
- **Mission completion is broader still.** `MGOAL_FIND_ITEM` checks `has_amount` over
  `u.crafting_inventory()` (with a `has_charges` fallback for charge items), i.e. nearby ground/vehicle
  reach — a wider scope than on-person, also recursing.
- **The export is top-level by construction.** `write_carried_items` enumerates only the three flat roots
  and stops; nested contents are omitted **by design**.

The lined-up mismatch:

```
question            scope / shape                       what answers it
"has the package"   on-person, container-DEEP           condition.cpp  has_charges || has_amount
  (Stage A goal)                                          -> visitable.cpp visit_internal  (RECURSES into contents)
                    ^^^^^^^^^^^^^^^^^^^^^^^^^
carried_items[]     on-person, top-level FLAT            arcopolis_export.cpp write_carried_items  (NEVER descends)
  (Spike 25 built)                                        ^^^^^^^^^^^^^^^^^^^^^^^^^
                    scope matches; SHAPE does not — a flat export cannot mirror a recursing predicate
```

**The load-bearing point is mechanism-independent.** Because `has_amount` recurses, the predicate finds the
item **wherever it sits** — top-level _or_ nested one-or-more pockets deep inside any container. A flat
export is correct only while the item stays top-level; it diverges from the predicate the instant the item is
nested by **any** means (an item already inside a worn container you then don; a container that already holds
it; an engine path that pockets it). The divergence is a property of the two _shapes_, not of one particular
action.

The one **pickup-time** route that demonstrably nests-and-hides is narrow and worth stating precisely so it
is not over-claimed: reloading/merging **ammo** into a pre-existing worn ammo container.
`Character::i_add_to_container` **early-returns unless the item `is_ammo()`** and only merges into a worn
`is_ammo_container` already holding that ammo type — so picked-up ammo can vanish into a bandolier/mag-pouch
pocket, bypassing flat `inv` entirely (invisible to `carried_items[]`, still counted by `has_amount`). A
**non-ammo** package picked up via the menu does **not** take this path: it falls to `u.i_add` → flat
`Character::inv` and therefore **does** appear in `carried_items[]`. So "the package was picked up into a
backpack pocket" is _not_ a real pickup route for a non-ammo package — the honest divergence for a package is
the shape mismatch above (any pre-existing nesting), not a pickup-time pocketing.

> **Hedge (kept):** the container divergence is a **verified code property** — `has_amount` recurses
> (`visit_internal`) while the export is flat by construction (`write_carried_items`) — **not** a
> runtime-witnessed result on a nested Stage A package. The witnessed pickup used a loose item (`glass_shard`)
> on the flat path. The divergence does not need a runtime witness to invalidate the proxy: the predicate is
> the right primitive **because it is authoritative regardless of where the item sits**, which is exactly the
> property a flat export lacks.

## Proposed correction

1. **Relabel `carried_items[]` as display/observability ONLY** in doc 50 and `ARCOPOLIS_STATE.md`: it is a
   read-only view of top-level carried items for a frontend to _show_, **explicitly not** the authoritative
   return-package predicate, and it omits nested-container contents **by design**. — ✅ applied (this commit).
2. **Correct the over-claiming lines** (the diff that accompanies this doc):
   - `ARCOPOLIS_STATE.md` — drop "_…which is what makes "returned with package" **composable by a consumer**
     from avatar position + carried-package visibility_." Replace with plain display-state framing pointing
     possession at BN's own predicate (`has_amount`/`has_charges`).
   - `50_…md` §"Status and claim" — "_**Resolves** the carried-package gap…_" → "_provides **display
     visibility** of top-level carried items; it does **not** resolve the Stage A possession check, which is
     answered by BN's own container-recursing predicate (`has_amount`/`has_charges`)._"
   - `50_…md` "_'Returned with package' stays **composed by the consumer**…_" → removed; possession is BN's
     verdict, not a consumer composition.
3. **Answer Stage A possession with BN's own possession predicate** (see "The corrected primitive" below),
   not with this export.

## Retrospective — why this is logged as a failure

- **What stands (reusable):** the `write_carried_items()` export itself, the three-flat-source enumeration in
  `visit_items` root order, the `location` tag, the field shape mirroring `entities.items[]`, the additive
  `schema_version`-1 discipline, and the **count-delta** witness (genuinely stronger than presence/absence).
  All correct as a **display** capability. Only the _label and the cited goal_ were wrong.
- **What failed:** the spike asked "what can a frontend show?" and answered it well, when the goal needed
  "would BN consider the character to have the package?". The fixture detail (loose `glass_shard` vs a
  nested package) was a **symptom**; the root cause is a missing **consumer/mechanism** check.
- **Process failures during the task, recorded so they are not repeated:**
  - **Inherited the goal's framing without classifying the consumer.** The plan classified the _claim_ (L1
    observation) but never classified the _consumer_ — display-state vs simulation-state vs
    engine-computed-predicate. The Stage A consumer is an **engine-computed predicate** (`condition.cpp`
    `set_has_items` / `mission.cpp` `MGOAL_FIND_ITEM`); the spike exposed a JSON proxy instead.
  - **Sharpened a well-formed answer to the wrong question.** The three red-team plan revisions improved
    witness rigor (count-vs-presence, source-only wording, transcript-honesty gates) — tightening the answer
    while never challenging the question.
  - **Filed the disconfirming evidence as a footnote.** Red-team _found_ the `i_add` vs `i_add_to_container`
    container boundary and recorded it as a **witness-scope note** (doc 50 §"Witness scope"), instead of
    recognizing it as the proof that the top-level primitive cannot answer possession.
  - **Let "faithful to spec" launder "wrong spec."** The ad-hoc two-axis review reported 0 Standards
    violations and 0 missing / 0 wrong vs the approved plan — but the plan itself encoded the wrong
    primitive, so spec-faithfulness structurally could not surface it.
  - **Caught only when asked "equivalent to WHAT."** The mismatch first surfaced when the user asked whether
    the addition is GUI-equivalent; naming a concrete consumer (the inventory GUI) immediately exposed the
    flat-vs-nested gap. An external review independently flagged the doc over-claim.
  - **Even this postmortem's first draft over-claimed the divergence** — it asserted a non-ammo package is
    "picked up into a backpack pocket" via `i_add_to_container`. That path is **ammo-only**
    (`Character::i_add_to_container` early-returns unless `is_ammo()`); an adversarial critic caught it and
    the claim was narrowed to the verified ammo-into-worn-ammo-container case plus the mechanism-independent
    shape argument. The same overreach appeared in mid-investigation prose. Recorded because it is the exact
    kind of plausible-but-wrong mechanism claim the consumer/mechanism discipline and adversarial verification
    exist to catch.

## How it passed every gate undetected

The gates split into two tiers. The **standardized Arcopolis gates** are purpose-built to catch
equivalence/fidelity failures — they are the damning misses. The two checks that ran outside the standardized
workflow are listed for completeness; one of them is what finally surfaced it.

| Gate                                             | Tier                   | What it checked (internal consistency)                                 | Why it missed the wrong primitive                                                                                                                                   |
| ------------------------------------------------ | ---------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Plan** (`arcopolis-claim-plan`)                | standardized Arcopolis | L1 classification, narrowest mechanism, smallest witness, source scope | Classified the claim, not the **consumer**; 3 revisions tightened a well-formed answer to the wrong question                                                        |
| **Build** (`arcopolis-build-from-approved-plan`) | standardized Arcopolis | smallest diff, fail-loud preserved, 981 assertions, clang-cl clean     | Verifies fidelity-to-plan, not plan validity — **by design** it cannot catch a wrong primitive                                                                      |
| **Red-team** (`arcopolis-red-team-review`)       | standardized Arcopolis | false-green, overclaim, seam bypass, witness scope                     | Tested whether the L1 claim was **true**, never whether L1 was the **right** claim; filed the container boundary as a witness-scope note                            |
| **Two-axis Standards+Spec** (`/review`)          | ad-hoc, NOT Arcopolis  | 0 standards violations; 0 missing / 0 wrong vs plan                    | A generic, user-installed skill (`~/.claude/skills/review`), invoked ad hoc; its Spec axis is "faithful to the given spec" — structurally blind to a **wrong spec** |
| **GUI-equivalence** (ad-hoc workflow)            | ad-hoc, NOT Arcopolis  | does it drive an input path / mirror the inventory GUI?                | **This one surfaced it** — asking "equivalent to WHAT" named a concrete consumer and exposed flat-vs-nested                                                         |

**The standardized Arcopolis gates had a 0% catch rate.** The mismatch was surfaced only from _outside_ the
governed loop — by an ad-hoc consumer-naming question (the GUI-equivalence check) and an external review. The
generic `/review` is not part of the Arcopolis workflow and could not have caught this regardless, so its
miss is unsurprising; the point of this postmortem is that the gates designed to catch fidelity failures did
not.

**The ONE missing check (consumer/mechanism).** Every gate verified internal consistency; none verified
goal-fit. The single question that catches this at the plan stage: **"Name the engine predicate the goal will
actually call, and show this export feeds it."** That forces `condition.cpp` `set_has_items` into view, whose
`has_amount` recurses where `carried_items[]` is flat — making the mismatch obvious before any code is
written.

## The corrected primitive (what should come next)

Stage A possession is BN's verdict, not a JSON proxy a consumer re-composes — so the corrected primitive is
to expose **the engine's own possession predicate** and return its answer. The design and scope are a
separate task, deliberately **not** settled here; only the sourced facts that constrain that follow-up:

- **The predicate exists and recurses.** The on-person possession check is
  `has_charges( id, count ) || has_amount( id, count )` (`condition.cpp` `set_has_items`), and `has_amount`
  is authoritative **regardless of where the item sits** because it recurses into container contents
  (`visitable.cpp` `visit_internal`) — the property a flat export structurally lacks.
- **Scope is a real fork.** On-person (the dialogue predicate over the `Character`, which adds no off-person
  source) differs from mission-completion scope (`MGOAL_FIND_ITEM` over `crafting_inventory()`, nearby
  ground/vehicle reach). A follow-up must choose and state which it answers.
- **A parameterized query needs a request/response surface.** "Does the avatar have item X?" takes a
  parameter and returns a computed scalar, so it does not fit the parameter-less snapshot export; the live
  request/response protocol is the natural home (script mode has no scalar-response channel). The exact
  surface, op shape, scope choice, and fail-loud behavior are for that follow-up to decide and witness — not
  asserted here.

The one generalizable, non-deferred assertion: **return the engine's answer, computed by the engine's own
predicate — never a consumer-side reconstruction from a partial view.**

## Recommended governance fix — the consumer/mechanism rule

_Recommended for a separate skills-update task; not applied here._ The generalizable lesson: **for any
observation claim, classify the real consumer — display-state vs simulation-state vs
engine-computed-predicate — and expose the native mechanism for that category, never a convenient JSON proxy.
If the consumer is an engine-computed predicate, name the consuming engine call and its scope, and expose
that predicate, not a proxy.** It would attach to `arcopolis-claim-plan` as a pre-witness step, with a
backstop in `arcopolis-red-team-review`: _"is the capability **sufficient for** — not merely **consistent
with** — the cited goal?"_ Both gates today verify internal consistency; this is the one check that would
verify goal-fit.

## Claims this doc does NOT make

- **Not** that `carried_items[]` is broken or should be reverted — it is correct as a **display/
  observability** export and is merged.
- **Not** that the container divergence was runtime-witnessed on a Stage A package specifically — it is a
  **verified code property** (`has_amount` recurses; the export is flat), reasoned from source, not from a
  nested-package transcript. It does not need to be witnessed to invalidate the proxy.
- **Not** that a non-ammo package is pocketed into a worn container at pickup — that path is **ammo-only**
  (`i_add_to_container` early-returns unless `is_ammo()`); a non-ammo package lands in flat `inv` and _does_
  appear in `carried_items[]`. The divergence is the shape mismatch under _any_ pre-existing nesting, not a
  pickup-time pocketing.
- **Not** that a possession query — or anything proposed here — fixes Stage A. Exposing the engine's
  possession predicate would itself be **observation of a predicate result** (does BN consider the avatar to
  hold item X?), **not** a level-4 "NPC accepts the package / mission completes" claim, which needs driving
  the dialogue/turn loop. The follow-up must not be over-claimed the way this export was.
- **Not** that any gate was negligent — each did its job within its remit. The defect is the **missing
  remit** (goal-fit), now added as the consumer/mechanism rule.

## Citation audit

Line numbers drift — trust the symbols.

| Claim                                                                | Type       | Implementing symbol                                                                             | Verdict               |
| -------------------------------------------------------------------- | ---------- | ----------------------------------------------------------------------------------------------- | --------------------- |
| On-person possession predicate is charges-OR-amount (multi-form)     | behavioral | `condition.cpp` `set_has_items`: `has_charges(id,count) \|\| has_amount(id,count)`              | CONFIRMED             |
| …single-item form                                                    | behavioral | `condition.cpp` `set_has_item`: `charges_of(id) > 0 \|\| has_amount(id,1)`                      | CONFIRMED             |
| Mission completion uses broader `crafting_inventory()` scope         | behavioral | `mission.cpp` `MGOAL_FIND_ITEM`: `crafting_inventory()` then `has_amount(...)`                  | CONFIRMED             |
| `has_amount` recurses into container contents                        | behavioral | `visitable.cpp` `visit_internal`: `contents.visit_contents(...)` on NEXT; guns/mags stop        | CONFIRMED             |
| `amount_of` routes through the recursing `visit_items`               | behavioral | `visitable.cpp` `amount_of_internal`: `self.visit_items(...)`                                   | CONFIRMED             |
| `has_amount(...) == qty`, capped → "at least N"                      | behavioral | `visitable.cpp` `visitable<T>::has_amount`                                                      | CONFIRMED             |
| Character override adds no off-person source (on-person scope)       | absence    | `visitable.cpp` `visitable<Character>::amount_of` (bionic/voltmeter/apparatus only)             | CONFIRMED             |
| Export enumerates three flat top-level sources, never descends       | behavioral | `arcopolis_export.cpp` `write_carried_items` (wielded / worn / inv top-level)                   | CONFIRMED             |
| Export array nests under the `avatar` object                         | behavioral | `arcopolis_export.cpp` `write_avatar` (call before `json.end_object()`)                         | CONFIRMED             |
| Loose pickup → flat `inv`                                            | behavioral | `pickup.cpp` `i_add`; `character.cpp` `i_add` → `inv.add_item`                                  | CONFIRMED             |
| `i_add_to_container` is AMMO-ONLY (non-ammo package → flat `inv`)    | behavioral | `character.cpp` `i_add_to_container`: early-return unless `is_ammo()`; worn `is_ammo_container` | CONFIRMED             |
| Script mode has no scalar-response channel for a parameterized query | absence    | `arcopolis_script.cpp` script-step preflight (`op == "command"` only)                           | CONFIRMED             |
| LIVE op allowlist + per-request success response                     | behavioral | `arcopolis_live.cpp` op allowlist; command/export success lines                                 | CONFIRMED             |
| Doc over-claim: "composable / returned with package"                 | absence    | `ARCOPOLIS_STATE.md` carried_items paragraph; `50_…md` §"Status and claim"                      | CONFIRMED (corrected) |
