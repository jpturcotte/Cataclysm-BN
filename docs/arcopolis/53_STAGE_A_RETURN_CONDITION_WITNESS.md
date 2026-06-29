# Stage A return-condition witness — L1 carried-at-contact composite

> **Goal claim (verbatim — load-bearing boundary):**
>
> An L1 **observation-only** witness that an external frontend/consumer can compute the chosen Stage A
> return signal
>
> ```
> carried_at_contact = avatar.pos_abs == contact_pos_abs
>                     && query.has == true
>                     && query.scope == "on_person_dialogue_predicate"
> ```
>
> PURELY from existing native observations. The backend gains **no** "return condition" API, mutates no
> state, and touches no mission / NPC / dialogue / crafting system. It does **NOT** prove `MGOAL_FIND_ITEM`,
> `crafting_inventory()`, NPC item checks, dialogue selection, mission completion, "package returned" in any
> BN engine-native objective sense, or L4 input equivalence.

## Status and scope

- **Built — regression evidence (seal CLEARED — not provisional; see "Seal status" below).** A stdlib live driver
  ([`stage_a_return_condition_driver.py`](stage_a_return_condition_driver.py)) + a pwsh wrapper
  ([`stage_a_return_condition_regression.ps1`](stage_a_return_condition_regression.ps1)) compose three
  EXISTING live surfaces over the existing `ArcopolisCarriedNestedTest` fixture. **No `src/` change, no
  fixture change.**
- **Equivalence level 1 — observation only.** No engine action runs for the position/possession halves; no
  `input_context` is consulted; no per-transaction backend-input gate is armed; no transcript engine event
  is emitted. The conjunction is computed **consumer-side, in the driver** — never by the backend.
- **The `move` step is not the claim.** It is existing level-2/3 movement machinery (the `action_id` is
  injected at the `handle_action` seam, never `input_context::handle_input` — like planar `move`), used
  ONLY to manufacture the off-contact false-green row. The regression does not trust command success: it
  exports after the move and asserts `pos_abs != contact_pos_abs` (exact south delta `[0,1,0]`), failing
  loud if the move was blocked / prompted / a no-op.

## The two native surfaces (and their authority classes)

| Half       | Native-authority class     | Consumer value       | Native source                                                                                                                                                                                              |
| ---------- | -------------------------- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Position   | **S** — simulation-state   | `avatar.pos_abs`     | `ctx.u.abs_pos()` (`src/arcopolis_export.cpp`, `write_avatar`), via live `op:"export"`                                                                                                                     |
| Possession | **C** — predicate-fidelity | on-person possession | `get_avatar().has_charges(id,count) \|\| get_avatar().has_amount(id,count)` (Spike 26A, `src/arcopolis_live.cpp`), via live `op:"query", kind:"has_item"`, labelled `scope:"on_person_dialogue_predicate"` |

The possession half is the **predicate**, not the flat `avatar.carried_items[]` display export (Spike 25,
class **D**). Substituting the flat export for the predicate is the Spike-25 trap; this witness instead uses
the flat export as a **negative** witness (see `flat_carried_items_not_authority` below) to prove the two
diverge. The possession scope is deliberately the **on-person dialogue** predicate; the broader
`MGOAL_FIND_ITEM` / `crafting_inventory()` scope is **rejected adjacent scope** (`src/mission.cpp` →
`src/crafting.cpp`) — see Spike 26B, not this witness.

## False-green matrix (what the witness exercises)

| Row                                | Position vs contact | `query.has` | scope verbatim | composite | what it pins                                                                                                                |
| ---------------------------------- | ------------------- | ----------- | -------------- | --------- | --------------------------------------------------------------------------------------------------------------------------- |
| `carried_at_contact_glass_shard`   | match (at contact)  | true        | yes            | **TRUE**  | nested carried package AT the contact tile                                                                                  |
| `dropped_at_contact_feather`       | match (at contact)  | **false**   | yes            | **FALSE** | dropped-on-own-tile / anti-`crafting_inventory()` false green                                                               |
| `wrong_position_glass_shard`       | **differ** (moved)  | true        | yes            | **FALSE** | possession-only false green (proven off-contact `move_s`, delta `[0,1,0]`)                                                  |
| `absent_hairpin`                   | differ (moved)      | **false**   | yes            | **FALSE** | a valid-but-absent id                                                                                                       |
| `flat_carried_items_not_authority` | —                   | true        | —              | —         | the flat `carried_items[]` export LACKS the nested package the predicate finds                                              |
| `unknown_id_fail_loud`             | —                   | —           | —              | —         | garbage `itype_id` → `ok:false`/`bad_request` (health/recovery; Spike 26A already proves it — **not** new Stage A evidence) |

`scope_label_guard` additionally asserts every successful query response carries
`scope:"on_person_dialogue_predicate"` verbatim — the labelling guard shared with Spike 26A.

## What it proves / does not prove

**Proves:** the Stage A frontend/consumer can compute the chosen return signal from existing native
observations; dropped-near-contact does not pass; possession away from contact does not pass; the flat
`avatar.carried_items[]` cannot be substituted for the predicate; the query stays explicitly labelled
on-person dialogue-predicate scope.

**Does not prove:** no mission system; no NPC turn-in; no dialogue; no `crafting_inventory()`; no Stage B
social/objective completion; no broader prompt/menu class support.

## Seal status — CLEARED (not provisional)

This witness has cleared every guardrail this repo defines for a possession/objective-adjacent,
Stage-blocking claim. It is **not** provisional, and "lock it later, pending a seal" no longer applies.

- **Classification — mechanically sealed by construction.** The possession answer _is_ the engine
  predicate's own returned value: the live op forwards `get_avatar().has_charges(id,n) || has_amount(id,n)`
  verbatim (`src/arcopolis_live.cpp:232-233`). A surface that _is_ the predicate's result cannot diverge
  from it — this is the mechanical Class-**C** seal, not merely corroborated evidence. So "possession =
  class C (the engine predicate's recursing result), not the flat `carried_items[]` display (class D)" is
  sealed.
- **Wording / witness boundary — cleared at the independence floor (the terminal guardrail for a framing
  claim).** Two independent blind cross-model / human reads each independently named the on-person /
  container-deep / ground-excluding scope and the "on-person, **not** mission completion" boundary. **No
  mechanical gate exists — or can — for a wording / framing choice** (true of every framing decision in
  this repo, not just this one), so the independent blind read is the strongest attainable check, and it is
  cleared. This is settled, not "awaiting a seal that cannot be built."

Out of scope (unchanged): the conjunction stays consumer-side; no backend "return condition" endpoint; do
**not** relabel the result as `MGOAL_FIND_ITEM` / mission completion / NPC turn-in / dialogue completion.

> **Cleared (2026-06-28):** two independent blind cross-model / human reads cleared the wording / witness
> boundary (on-person, **not** mission completion); the classification was already mechanically sealed by
> construction (above). The real-product-item PICKUP-then-query end-to-end (briefcase / `box_small`, vs.
> the save-edited `ArcopolisCarriedNestedTest` fixture) remains future Stage B **coverage** — a coverage
> bound, **not** an open question about the decision. See
> [55_SPIKE26B_26C_NOT_REQUIRED.md](55_SPIKE26B_26C_NOT_REQUIRED.md).

See [52_SPIKE26A_DIALOGUE_PREDICATE_QUERY.md](52_SPIKE26A_DIALOGUE_PREDICATE_QUERY.md) (the possession
half), [51_SPIKE25_CARRIED_PACKAGE_POSTMORTEM.md](51_SPIKE25_CARRIED_PACKAGE_POSTMORTEM.md) (why the flat
export is not the authority), and [ARCOPOLIS_STATE.md](ARCOPOLIS_STATE.md) for the live frontier.
