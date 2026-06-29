# 55 — Stage A return is an Arcopolis-layer rule over BN facts (so Spike 26B / 26C are not required)

> **Decision (2026-06-28).** Stage A "return completion" is an **Arcopolis-layer rule composed over
> BN-native facts** — NOT a BN mission / NPC / dialogue completion event. The backend contract is
> deliberately **narrow**: expose stable avatar **position** (native-authority class **S**) and stable
> **on-person possession** (class **C**, with an explicit scope label); the Arcopolis consumer /
> controller owns the conjunction. It follows that **Spike 26B** (a backend query exposing the broader
> `crafting_inventory()` mission scope) and **Spike 26C** (driving NPC dialogue at level 4 to fire
> `mission::is_complete`) are **mis-scoped and not required for Stage A**. Do not plan them as Stage A
> prerequisites, and **do not add a backend `return_condition` API** to make the witness feel more
> "implemented." No `src/` change follows from this doc.

## The contract-placement decision (the load-bearing why)

The intended architecture (`AGENTS.md` → "Target architecture under investigation"): **BN is
authoritative for simulation facts** — world state, position, possession — and returns read-only
snapshots + query responses; the **separate Arcopolis frontend / controller owns the quest / objective
rules** and never mutates simulation state. BN _has_ a mission system (`mission::is_complete`,
`MGOAL_FIND_ITEM`) and _could_ own "package returned," but Stage A deliberately **does not use it**:
the objective rule lives in the Arcopolis layer, composed over BN-native facts.

So the Stage A return signal is, by design:

```
carried_at_contact =  exported avatar position == contact position      // class S — raw state
                   && has_item(package).has == true                     // class C — on-person predicate's own result
                   && has_item(package).scope == "on_person_dialogue_predicate"
```

computed **consumer-side** (in the driver / frontend; see `stage_a_return_condition_driver.py`), never
by the backend.

## What "return condition" means here (dissolving the apparent contradiction)

A reader hits an apparent contradiction: the witness is called a "return-condition" witness, yet it
proves **no** BN mission, NPC turn-in, dialogue, or engine-native objective. That reads as contradictory
**only if** "return condition" means a _backend / BN objective_. It does not. Here **"return condition"
= the Arcopolis app-layer rule over backend facts.** Under that meaning the two statements are
consistent: the backend exposes the facts the rule needs; it deliberately does **not** own the objective.
The correct future-agent answer to _"this doesn't prove BN mission completion"_ is **"correct — Stage A
does not use BN mission completion."**

## The backend contract (narrow — what Stage A needs, and no more)

| Fact       | Class | Backend surface                                                                                                                                                                                                  |
| ---------- | ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Position   | **S** | `avatar.pos_abs` in the read-only snapshot (`src/arcopolis_export.cpp`, `write_avatar`).                                                                                                                         |
| Possession | **C** | the Spike-26A live op `op:"query", kind:"has_item"` → `get_avatar().has_charges(id,n) \|\| has_amount(id,n)` (`src/arcopolis_live.cpp:231-233`), labelled `scope:"on_person_dialogue_predicate"`. See doc 52/53. |

The possession surface returns **the engine predicate's own result** (it forwards verbatim to the same
disjunction BN's dialogue `set_has_items` uses, `src/condition.cpp`), traversing into carried-container
contents via `visitable<Character>::visit_items` → `visit_internal` (`src/visitable.cpp:442,517`). It is
**not** the flat `avatar.carried_items[]` display export (class **D**, top-level-only,
`src/arcopolis_export.cpp:97`) — that is used only as a _negative_ witness in doc 53. The conjunction
stays consumer-side; the backend gains **no** "return condition" endpoint.

## Why 26B and 26C are not required (and what they actually are)

- **26B** = a backend query for the broader `crafting_inventory()` scope (the `MGOAL_FIND_ITEM`
  authority, `src/mission.cpp:428`; reserved for a future `kind:"crafting_has_item"` /
  `scope:"crafting_inventory"` at `src/arcopolis_live.cpp:833`). `crafting_inventory()` is a strict
  **superset** of the on-person scope — its only extra reach is **off-person** sources (ground items
  at/near the tile, vehicle cargo, furniture within `PICKUP_RANGE`; `src/crafting.cpp:606-621`). For
  _"is the avatar carrying the package on their person,"_ that broader scope is **wrong**, not missing:
  it would **false-green** a package merely dropped near the contact tile (the `dropped_at_contact`
  case doc 53 deliberately pins to FALSE). So 26B is not just unnecessary for Stage A — its scope is the
  wrong authority for the Stage A question.
- **26C** = driving NPC dialogue at level 4 to fire `TALK_MISSION_SUCCESS` / `mission::is_complete`
  (`src/mission.cpp:384,706`). Stage A is **non-social** — doc 47 §10 (Stage B deferrals): _"must not
  route the package through NPC interaction"_ — so 26C is out of scope for Stage A.

## Scope discipline (load-bearing — confirmed by independent read)

The on-person query is the authority for the on-person _"carrying"_ question **only**. It must **not** be
reused as the authority for BN mission completion, which uses the broader `crafting_inventory()` scope. A
real predicate of the wrong reach is still the wrong authority (`AGENTS.md` class **C**: "match the
goal's required scope, not just predicate-ness"). This is exactly why the query carries a literal,
load-bearing `scope:"on_person_dialogue_predicate"` label.

## Evidence status (honest)

- **Possession classification — confirmed.** That the possession answer is the engine predicate's own
  recursing result (class **C**), **not** the flat `carried_items[]` display (class **D**), is (a)
  **mechanical by construction** — `src/arcopolis_live.cpp:232-233` returns `has_charges||has_amount`'s
  own value, so it cannot diverge from the predicate; and (b) **independently confirmed** by two blind
  cross-model / human reads (each independently named consumer = `condition.cpp` `set_has_items`, class
  **C**, scope on-person / container-deep / ground-excluding, and constructed the nested-in-backpack
  divergence the flat export misses). That is **independence evidence (a stronger floor)**, not a
  mechanical seal of the whole composite.
- **The composite witness** (doc 53) is **L1 observation** computed consumer-side. Its _wording and
  witness boundary_ — on-person, **not** mission completion — are now confirmed by the independent reads,
  discharging the "confirm the wording / witness boundary" condition doc 53 was provisional on. The
  remaining open items are **product decisions, not classification** — doc 47 §13 leaves "is Stage A
  success at 'picked up'?" and "which Step-2 design ships?" as maintainer choices, and the end-to-end
  PICKUP-then-query composition over the real product item (briefcase / `box_small`, vs. the save-edited
  fixture) is unwitnessed coverage, consistent with doc 53's provisional status.

## When 26B / 26C would become relevant

Only if the slice goal **changes** to require **engine-native** mission completion — BN itself reporting
the package returned via `mission::is_complete` (and, for a turn-in, NPC dialogue). That is **Stage B**,
deliberately deferred; it is a separate scoping decision, **not** a Stage A prerequisite.

## See also

- [47_ARCOPOLIS_VERTICAL_SLICE_ENGINE_AUDIT.md](47_ARCOPOLIS_VERTICAL_SLICE_ENGINE_AUDIT.md) — the slice
  (§1 return-as-placeholder, §10 Stage B / non-social deferrals, §13 open product decisions).
- [52_SPIKE26A_DIALOGUE_PREDICATE_QUERY.md](52_SPIKE26A_DIALOGUE_PREDICATE_QUERY.md) — the on-person
  possession query (class C).
- [53_STAGE_A_RETURN_CONDITION_WITNESS.md](53_STAGE_A_RETURN_CONDITION_WITNESS.md) — the L1 composite
  witness + false-green matrix.
