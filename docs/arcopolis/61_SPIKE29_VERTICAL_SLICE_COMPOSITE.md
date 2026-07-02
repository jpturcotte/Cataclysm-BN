# Spike 29 (folded) — N-floor slice fixtures + the vertical-slice composite witnesses

**Status: BUILT + witnessed (2026-07-01).** Zero `src/` change. Two new committed fixture worlds, one
parameterized generator, one live driver, one four-gate regression, docs.

## 1. The fold decision (recorded here; doc 60 is deliberately unedited)

Doc 60 proposed **Spike 28** (2-floor composite slice, "the keystone") before **Spike 29** (N-floor
generator + 5–6-floor traversal), citing doc 48 §20. On **2026-07-01 the maintainer folded 28 into 29
as ONE spike** after a red-team of the sequencing rationale: §20's lesson ("isolate the test
environment before proving the command seam") binds _which environment the first composite runs on_,
not generator build order. The fold preserves it via an internal **gate ladder** — each gate fails
independently, in order:

1. **G1** — generator assertions, no session (fixture machinery isolated);
2. **G2** — N-floor traversal round trip, run-script, no package (new fixture machinery isolated from
   composition);
3. **G3** — composite at 2 floors — former Spike 28 **verbatim**, on the already-proven z=−1
   environment (deliverable even if lower-z synthesis had stalled);
4. **G4** — composite at 6 floors, package on the deepest floor (Stage A's traversal core, doc 60 §3).

Doc 60 §7's "28 before 29" and FE-4's "waits on 28" are therefore stale as sequencing (FE-4 now waits
on this spike's G3). Doc 60 itself is not edited, per the maintainer's instruction; this section is the
current-truth record of the decision.

## 2. The four claims (no composite headline — never "the vertical slice works")

| #  | Claim                                                                                                                                                                                                          | Level / class                                                                                                                                                                                                            | Witness                                                                                          |
| -- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| C1 | Per-floor-pair fixture determinism: the generator asserts doc 47 §4's three conditions per pair (travel-direction flag on the pair's top tile; aligned counterpart directly below; no creature on either tile) | fixture tooling mirroring an engine predicate's conditions — no equivalence level                                                                                                                                        | G1 (`--check-only` per world + dest read-back + the loaded z=0 read-back)                        |
| C2 | A **6-floor (z=0…−5) descent→ascent round trip** completes through the proven route, per-floor snapshot each leg                                                                                               | **L1 observation** of a traversal executed via the **level 2/3** `vertical_move` (doc 49 — the `action_id` is injected at the `handle_action` seam, never enters `input_context::handle_input`; unchanged by this spike) | G2 (18 legs, per-leg `pos_abs` trajectory + avatar-tile stair terrain + strictly advancing turn) |
| C3 | The **2-floor composite** — descend, walk, level-4 `pickup`, walk back, ascend, consumer-side conjunction green, with the full false-green guard set                                                           | **Arcopolis-layer L1 composite** (docs 53/55); constituents at their recorded levels: `pickup` **B/L4** at its Spike-12A witnessed site, `has_item` **class C**, position **class S**, vertical/planar movement **2/3**  | G3 (`slice_live_driver.py --floors 2` on `ArcopolisSliceTest`, 14 gates)                         |
| C4 | The **6-floor composite**, package on z=−5                                                                                                                                                                     | same as C3                                                                                                                                                                                                               | G4 (`--floors 6` on `ArcopolisTowerTest`, 15 gates)                                              |

**No new equivalence claim** (doc 60 §3 verbatim). The conjunction
`carried_at_contact = pos_abs == contact && query.has && query.scope == "on_person_dialogue_predicate"`
is computed **consumer-side in the driver**, never by the backend — no `return_condition` API (the
docs 53/55 contract placement, a ratified non-goal).

**External seal:** the possession/on-person framing rides the **doc 53** decision (two independent
blind cross-agent/human reads of the same query + same conjunction); the maintainer ratified
inheritance for this spike on 2026-07-01 (no new possession framing exists here — `pos_abs` already
carries z; the new guards are class-S facts). Per the floor/seal doctrine that inheritance is
independence evidence, not a seal; the mechanical checks are G3/G4's guards.

## 3. What was probe-proven before code was written (2026-07-01, scratch only)

- **Lower-z submap creation is feasible by row synthesis.** The save has map rows only at
  z ∈ {−1, 0, +1}; `map::loadn`'s miss-fallback is mapgen (`src/map.cpp:8759-8778` — rock under the
  shelter, no stairs → `find_stairs` fabrication prompts → fail-loud). A hand-INSERTed z=−2 quad row
  (cloned from the basement quad, coordinates rewritten, terrain rewritten, dynamic keys emptied) was
  accepted by the loader end-to-end: `vertical_move down ×2` landed the avatar on the synthesized
  `t_stairs_up` at z=−2, exit 0, `session_end ok`.
- **The `files` schema + the UPDATE no-op gotcha.** `map.sqlite3` is
  `files(path TEXT PK, parent TEXT NOT NULL, compression TEXT NULL, data BLOB NOT NULL)`; map rows are
  `maps/<seg>/<omt.x>.<omt.y>.<z>.map` — the exact path `world::read_map_omt` constructs
  (`src/world.cpp:671-708`, no z special-casing). The Spike-23 generator's `UPDATE … WHERE path=?` is a
  **silent no-op for a missing row** — new-floor rows must INSERT all four columns. The generator's
  `write_submap_file` now fails loud on `rowcount != 1`.
- **`box_small` does NOT fit the stock `ArcopolisTest` avatar.** `can_pick_volume`
  (`src/character.cpp:3239-3241`: `inv.volume() + it.volume() <= Σ worn storage`) returns false for
  the 1 L box on the no-worn-storage avatar → the Spike-14 secondary WIELD `uilist`
  (`src/pickup.cpp:428-432` → `handle_problematic_pickup`) → run-script exit 13. The SAME script on
  **`ArcopolisBackpackTest`** (+2 L backpack) completes as a single-prompt L4 pickup, the box landing
  in `carried_items[]` `location:"inventory"`. Hence both slice worlds source from
  `ArcopolisBackpackTest` — keeping the composite's pickup constituent identical to its Spike-12A/16
  witnessed shape rather than silently swapping in the Spike-14 secondary.
- **A single-item tile still opens the menu.** The "just grab" shortcut needs
  `here.size() <= min && min != -1` (`src/pickup.cpp:728-733`) and the command path passes `min=0`
  (`:1523`) — so the package tile's one-item pickup runs the real `"PICKUP"` menu with exactly one
  entry (G3/G4 assert exactly that shape).
- **Well geometry is SOUTH, bounded.** One tile cannot carry both stair directions, so an N-floor
  column needs offset wells (the stock dual-flag `t_ladder_up_down` exists — its `DIFFICULT_Z` is
  consumed only on the mounted branch, `src/handle_action.cpp:2192/:2247` — but stairs were ratified
  for product-faithfulness and Spike-23/24 continuity). Eastward is blocked on the one non-hermetic
  floor (`(6302,6421,-1)` carries furniture); the south column is clean for dy=0..4 — enough for six
  floors, and NOT arbitrarily extensible (dy=5 has furniture, dy=6 is `t_concrete_wall`): a taller
  tower needs a different offset scheme.

## 4. What was built

- **[`make_stairs_fixture.py`](make_stairs_fixture.py) parameterized in place** (ratified Q3a):
  `--floors N` (default 2 = the Spike 23 behavior, **content-identical** — gated), south-offset pair
  layout, footprint-wide lower-floor synthesis (49 quad rows per floor: stairwell quad
  `t_linoleum_white`, elsewhere `t_rock`; the full reality-bubble footprint +1 submap margin, so mapgen
  never runs on a synthesized floor), `--package-typeid`/`--package-offset` ground-item injection with
  clean-tile + walk-tile asserts, extended `--check-only`/read-back over every pair + the package.
- **`ArcopolisSliceTest`** (2 floors + package at `(6301,6423,-1)`) and **`ArcopolisTowerTest`**
  (6 floors, wells at `(6301,6421+k)`, package at `(6301,6427,-5)`) — committed worlds; catalog
  entries in [TEST_FIXTURES.md](TEST_FIXTURES.md).
- **[`slice_live_driver.py`](slice_live_driver.py)** — one persistent `--arcopolis-live` backend per
  run (the `stage_a_return_condition_driver.py` gate/summary shape + the `prompt_menu_live_driver.py`
  prompt wire and deadline-recv `LiveSession`), generic over `--floors`.
- **[`slice_regression.ps1`](slice_regression.ps1)** — the G1–G4 ladder (pwsh 7).

## 5. The witness gates, and what each does NOT prove

**G1** (fixture machinery): `--check-only` source-preconditions + dest read-back per slice world;
**default-invocation content-identity** (regenerate `ArcopolisStairsCheck` from `ArcopolisTest`,
compare file-set + bytes + row-wise decompressed `map.sqlite3` payloads against the committed
`ArcopolisStairsTest` — the ratified non-goal, mechanically gated); loaded z=0 read-back per world
(avatar on `t_stairs_down` — the loaded-state transposed-RLE-index catcher; deeper floors are
validated loaded by G2/G4's per-leg asserts, since the single-z window cannot see them at load).

**G2** (traversal): the 18-leg round trip with per-leg `pos_abs`/terrain/turn asserts, zero
monsters/NPCs in every synthesized-floor window, `damage_taken[]` empty in every snapshot, exit 0 +
`session_end ok`. _Does not prove:_ L4 vertical, ramps/elevators/ladders/ropes/climb/falls, multi-z
snapshots, any floor count other than the witnessed 6.

**G3/G4** (composites): the 14/15 driver gates — `possession_false_at_start`,
`descent_trajectory`, `floor_provenance_before` (package on the deepest floor's GROUND —
`entities.items[]` at the package tile, `carried_items[]` empty of it, query false),
`walk_to_package`, `pickup_l4_transaction` (the real menu prompt, exactly one enabled entry, answered
through the ack → terminal-response wire), `floor_provenance_after` (ground −1 == carried +1,
`location:"inventory"`, query true), `return_to_landing` (+ `ascent_trajectory` at 6 floors),
**`z_changed_off_contact_pinned`**, `final_ascent`, `composite_green_at_contact`,
`off_contact_displacement` (proven `[0,1,0]` delta, conjunction false while possession true),
`no_damage_interference`, `hermetic_lower_floors`, `scope_label_guard` (the literal
`on_person_dialogue_predicate` on every successful query, count-pinned). _Does not prove:_ mission
completion, `MGOAL_FIND_ITEM`/`crafting_inventory()` scope, NPC turn-in, stealth/perception, a
validated frontend.

**The pinned z-guard (the red-team's Lens-A fix) is exercised, not asserted.** It is evaluated at the
pre-ascent tile `(contact.x, contact.y, −1)` — x/y EQUAL to the contact tile, only z differing — the
one state where a z-blind conjunction (comparing `pos_abs[0:2]`) diverges from the real one. Evidence
from the witnessed run: `pos [6301,6421,-1]` vs `contact [6301,6421,0]`, `xy_equal: true`,
`z_differs: true`, `query_has: true`, `composite: false`.

**First live-transport `vertical_move`.** Doc 49 added no live probe (doc 60 FE-1 named the gap);
G3/G4 are the first live-mode `vertical_move` witnesses. FE-1's caveat (a) is thereby discharged for
the backend half: the verb works over the live transport on these fixtures.

**A build-time catch worth keeping (why per-leg position asserts, not command success):** the first
tower driver run had a leg-plan bug — one `move_n` too many, stepping off the pair-0 stair onto plain
floor. The subsequent flagless `vertical_move up` was a **prompt-free engine no-op returning
`ok:true`** ("You can't go down/up here!" message path, `src/game.cpp:14223-14227`) with **no position
change and no turn advance**. Trusting command success would have mislocated the failure; the per-leg
`pos_abs` assert caught it at the exact leg. (The engine's flagless failure path also calls the
option-gated `suggest_auto_walk_to_stairs`, `src/game.cpp:891` — unaudited; a deliberate negative
witness for flagless `vertical_move` stays out of scope until that path is audited.)

## 6. Anti-flat honesty (why there is no anti-flat gate here)

Doc 53's `flat_carried_items_not_authority` divergence gate needs a NESTED carried package (the flat
export structurally missing it) — that state exists on `ArcopolisCarriedNestedTest`, not here: the
picked `box_small` lands top-level (`location:"inventory"`), so flat export and predicate agree on
this fixture by construction. The composite therefore keeps the class discipline **structurally**
instead: the conjunction's possession half reads ONLY the class-C query result; `carried_items[]` is
read ONLY for the floor-provenance count-deltas (display observability, its postmortem-approved use,
doc 51). The anti-flat divergence witness remains doc 53's.

## 7. Validation record (2026-07-01, all against the committed fixtures)

- `slice_regression.ps1` — **G1a, G1b, G1c, G1d×2, G2 (18/18 legs), G3 (14/14 gates), G4 (15/15
  gates): all green**, exit 0.
- No-regression: `stairs_fixture_regression.ps1` (5/5) and `vertical_movement_regression.ps1` (all
  gates) green with the extended generator and untouched `ArcopolisStairsTest`.
- The generator's default invocation regenerates `ArcopolisStairsTest` **content-identically**
  (file-set + bytes; `map.sqlite3` row-wise on decompressed payloads — sqlite page layout is not
  byte-stable, so the promise is content, not file bytes; the `.sav` is byte-identical).

## 8. Deferred / out of scope (unchanged by this spike)

Level-4 vertical (doc 60 §6 Q1 stays an open maintainer decision); ramps/elevators/ladders/ropes/
climb/falls; multi-z snapshot contract (doc 60 §6 Q2); mission-scope possession (Spike 26B, Stage B);
NPC turn-in (26C, Stage B); the fight/sneak route witnesses (doc 60 Spikes 30–32); FE-1..FE-4 (the
browser still lacks `vertical_move` + the prompt wire; FE-4 can now target G3's composite); towers
taller than 6 floors (the south-offset column is terrain-bounded at the source's z=−1 — see §3).
