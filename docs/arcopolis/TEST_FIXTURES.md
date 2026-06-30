# Arcopolis test world fixtures

The headless `--arcopolis-*` modes load a prepared world. The canonical fixture worlds are now **committed
in the repo** under [`docs/arcopolis/fixtures/arcopolis_user/`](fixtures/arcopolis_user) (curated to
`save/<World>/` + `config/options.json`; see [`fixtures/README.md`](fixtures/README.md)). The regression
scripts copy that userdir into the gitignored `.\arcopolis_user` sandbox automatically — **no external
setup required.**

The fixture root resolves in this order (first match wins): an explicit `-FixtureSrc` (or a generator's
`--fixture-root`); then `$env:ARCO_FIXTURE_ROOT`; then the repo-local pack above; then an optional external
dev fallback at `C:\dev\arcopolis-fixtures\arcopolis_user`. The external root is now **optional developer
scratch space**, not a prerequisite; set `ARCO_FIXTURE_ROOT` to point the suite at one for a one-off. These worlds are
point-in-time snapshots; regenerate the generated ones with the `make_*_fixture.py` script that owns each
(see per-world sections below and `fixtures/README.md`).

**Run these regressions with `pwsh` (PowerShell 7), not `powershell` (5.1)** — 5.1 misreads BOM-less UTF-8
snapshots and writes an options.json BOM, causing spurious gate failures on unchanged code.

All worlds below live in the same userdir; `ArcopolisTest` is the base and the rest are clones of it, each
adding one deterministic element so it can act as a specific export/prompt/movement witness.

## `ArcopolisTest` — base world; movement / NPC / item / live-protocol witness

The canonical base world: avatar in an evac shelter, ~14 nearby monsters, calendar turn ~1,324,801. Its
`.sav` is content-identical to the pre-spike save and is unchanged by later spikes.

- **Movement / NPC fixture** and **NPC-export witness** — its stock shelter NPC sits one tile north of the
  avatar, inside the r12 export window. Gated by
  [`docs/arcopolis/npc_export_regression.ps1`](npc_export_regression.ps1) (Spike 7A; see
  [18_SPIKE7A_NPC_EXPORT.md](18_SPIKE7A_NPC_EXPORT.md)).
- **Ground-item-export witness** — its saved evac shelter already holds deterministic in-window loot (no
  save edit). Gated by [`docs/arcopolis/item_export_regression.ps1`](item_export_regression.ps1) (Spike 8A;
  see [19_SPIKE8A_ITEM_EXPORT.md](19_SPIKE8A_ITEM_EXPORT.md)).
- **Live-protocol fixture** — the Spike 9B `--arcopolis-live` stdin/stdout JSONL mode is gated end-to-end
  by [`docs/arcopolis/live_protocol_regression.ps1`](live_protocol_regression.ps1) (see
  [21_SPIKE9B_LIVE_PROTOCOL.md](21_SPIKE9B_LIVE_PROTOCOL.md)).
- **Driven single-entry WIELD secondary-capacity witness (Spike 14)** — the default `ArcopolisTest` avatar
  has room for ~one small item, so an over-capacity multi-select raises the in-activity capacity prompt.
  The blanket is wielded through the real `input_context("UILIST")` loop, south pile 7→5, response carries
  NO `forced_cancel`/`partial` markers (`prompt_menu_regression.ps1` Scenario E). The earlier marked-partial
  force-cancel survives only as the no-channel / disabled-entry / multi-tick-orphaned fallback, not as the
  default-avatar behavior.
- `ArcopolisTest`'s own monsters are all ≥31 tiles away, hence present-but-empty at r12 — which is why the
  monster-export witness needs a separate clone (below).

## `ArcopolisNearMonsterTest` — monster-export witness

A clone of `ArcopolisTest` with one `mon_fungal_wall` inside the radius-12 export window, so
`entities.monsters[]` is non-empty. Build the witness with
[`docs/arcopolis/make_monster_fixture.py`](make_monster_fixture.py) (save-edit, no GUI/build) and gate it
with [`docs/arcopolis/monster_export_regression.ps1`](monster_export_regression.ps1); see
[16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md](16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md) (Spike 6B).

## `ArcopolisBackpackTest` — multi-item-pickup carry-both witness (Spike 12A)

A clone of `ArcopolisTest` whose avatar additionally wears a `backpack`, giving real carrying capacity.
`ArcopolisBackpackTest` lets a multi-select deposit two items, witnessing carry-both at the state level
(`prompt_menu_regression.ps1` Scenario F). Gated by
[`docs/arcopolis/prompt_menu_regression.ps1`](prompt_menu_regression.ps1). See
[30_SPIKE12A_PROMPT_MENU_TRANSACTION.md](30_SPIKE12A_PROMPT_MENU_TRANSACTION.md) and
[34_SPIKE14_SECONDARY_PICKUP_UILIST.md](34_SPIKE14_SECONDARY_PICKUP_UILIST.md). **`ArcopolisBackpackTest`
is GUI-created** (no committed generator script) and is the source-of-truth clone-parent for
`ArcopolisCarriedNestedTest` below.

## `ArcopolisCarriedNestedTest` — L1 on-person dialogue-predicate witness (Spike 26A)

A clone of `ArcopolisBackpackTest` (NOT regenerated; inherits its committed save shape) with three
save-edited witness items pinning the on-person dialogue predicate's scope: one `glass_shard` nested
inside the existing worn backpack's pocket (the **load-bearing container-recursion witness** — proves
`visit_internal` recurses via `contents.visit_contents` into worn pockets, where `carried_items[]`
structurally cannot reach), one `rock` wielded as `player.weapon`, and one `feather` dropped on the
AVATAR'S OWN tile in the `.map` (the **load-bearing anti-`crafting_inventory()` scope-pin** — Spike
26B's broader predicate would flip this to `has:true`, while the on-person predicate excludes it).
The fixture also exercises an absent-but-valid id (`wooden_kitchen_spoon`, NOT placed) and a garbage
`itype_id` (queried directly, not placed). Built reproducibly by
[`docs/arcopolis/make_carried_nested_fixture.py`](make_carried_nested_fixture.py) (stdlib-only, no GUI,
no build). Gated by
[`docs/arcopolis/spike26a_dialogue_predicate_regression.ps1`](spike26a_dialogue_predicate_regression.ps1)
(seven hard gates including the scope-pinning ground negative and the labeling-guard string assertion).
See [52_SPIKE26A_DIALOGUE_PREDICATE_QUERY.md](52_SPIKE26A_DIALOGUE_PREDICATE_QUERY.md).

**Also the Stage A carried-at-contact L1 witness.** The same fixture (no change) backs the L1
observation-only composite `carried_at_contact = avatar.pos_abs == contact_pos_abs && query.has &&
query.scope == "on_person_dialogue_predicate"`: `glass_shard` is the carried package, `feather` (on the
avatar's own tile) the anti-`crafting_inventory()` false-green, and `hairpin` the valid-but-absent id. A
single live session exports position (`op:"export"`), queries possession (`op:"query"`), and uses one
`command move` `move_s` only to manufacture the off-contact false-green. **L1 only — NOT mission
completion.** Gated by
[`docs/arcopolis/stage_a_return_condition_regression.ps1`](stage_a_return_condition_regression.ps1); see
[53_STAGE_A_RETURN_CONDITION_WITNESS.md](53_STAGE_A_RETURN_CONDITION_WITNESS.md).

## `ArcopolisVehicleCargoTest` — vehicle-source `uilist` witness (Spike 13B `pickup`); vehicle `examine` "Select an action" fail-loud witness (Spike 21)

(Was the Spike 12A-follow-up fail-loud witness.) A clone of `ArcopolisTest` with an exact `folding_wagon`
replica (a single-tile `folding_frame`+`wheel_caster`+`basketlg_folding` CARGO cart) injected ONTO the
ground-item pile one south of the post-`move_s` avatar, so that tile has BOTH vehicle cargo and ground
items. A live `pickup` there hits the `"Get items from where?"` `uilist`; **Spike 13B DRIVES it at level
4** (un-aborts the uilist under a per-transaction `backend_uilist_transaction_active()` gate, runs
`setup()` headlessly, and serves registered `UILIST` actions through the real `input_context("UILIST")`
loop), then continues into the old `"PICKUP"` item menu. The earlier fail-loud is retained only as the
no-channel fallback (non-live / misconfigured). Built reproducibly by
[`docs/arcopolis/make_vehicle_fixture.py`](make_vehicle_fixture.py) (save-edit, no GUI/build), gated by
[`docs/arcopolis/prompt_menu_regression.ps1`](prompt_menu_regression.ps1) (gate H, four sub-scenarios). See
[33_SPIKE13B_BACKEND_DRIVEN_UILIST.md](33_SPIKE13B_BACKEND_DRIVEN_UILIST.md) (and the historical
[31_SPIKE12A_FOLLOWUP_FAIL_LOUD.md](31_SPIKE12A_FOLLOWUP_FAIL_LOUD.md)).

**Also the unarmed vehicle `examine` `uilist` fail-loud witness (Spike 21).** The same cart tile is examined
(not picked up) by [`docs/arcopolis/examine_regression.ps1`](examine_regression.ps1) scenario C: `examine
move_s` routes through `game::examine` → `vehicle::interact_with` (which returns before the pickup tail)
into its OWN unarmed `"Select an action"` `uilist selectmenu` (EXAMINE + TRACK are unconditional, so it
always has ≥2 entries and calls `query()`). `examine` arms only the query_popup transaction, so that uilist
is UNARMED and FAILS LOUD — non-live run-script **exit 14**, live recoverable **`ok=false`** — a distinct
path from the ARMED, level-4-DRIVEN `pickup` uilist above. See
[43_SPIKE21_UILIST_UNEXPECTED_PROMPT_FAIL_LOUD.md](43_SPIKE21_UILIST_UNEXPECTED_PROMPT_FAIL_LOUD.md) §2/§10.

## `ArcopolisCapacityTest` — backend-driven secondary capacity/wield/spill `uilist` multi-entry witness (Spike 14)

(Was the Spike 12A-follow-up marked-partial witness.) A clone of `ArcopolisTest` with ONE bulky
`jacket_leather` (ARMOR/OUTER, 4500 ml, not a bucket, no children) injected onto the same south ground
pile. Picking the jacket exceeds the unarmed avatar's volume capacity, so
`pickup_activity_actor::handle_problematic_pickup` raises a `uilist` with WEAR + WIELD = 2 enabled
entries; **Spike 14 DRIVES it at level 4 by REUSING the Spike 13B machinery unchanged** at a second site
(per-transaction `backend_uilist_transaction_active()` gate around the in-activity `uilist`, the same
`"UILIST"` serve branch and `live_uilist_prompt` channel — renamed from `live_vehicle_source_prompt`).
The marked-partial behavior is retained as the no-channel fallback (unit-tested). Built reproducibly by
[`docs/arcopolis/make_capacity_fixture.py`](make_capacity_fixture.py) (save-edit, no GUI/build), gated by
[`docs/arcopolis/prompt_menu_regression.ps1`](prompt_menu_regression.ps1) (gate E converted to driven WIELD
on `ArcopolisTest`'s blanket, plus gate J on `ArcopolisCapacityTest` with five sub-scenarios). See
[34_SPIKE14_SECONDARY_PICKUP_UILIST.md](34_SPIKE14_SECONDARY_PICKUP_UILIST.md).

## `ArcopolisDeployedFurnitureTest` — backend-driven `query_popup` (`query_yn`) witness (Spike 15)

A clone of `ArcopolisTest` with ONE `f_floor_mattress` (`examine_action: "deployed_furniture"`,
`deployed_item: "mattress"`) placed on the clean `t_floor` tile one tile EAST of the avatar. A live
`examine direction=move_e` reaches `iexamine::deployed_furniture`'s `query_yn("Take down the %s?")`
(`input_context("YESNO")`); **Spike 15 DRIVES it at level 4** — a `query_popup_witness_guard` at that one
call site arms a per-prompt query_popup transaction (the `session.query_popup.armed` flag, Spike 19's
`prompt_transaction` regroup), the new `backend_query_popup_transaction_active()` gate un-aborts
`query_popup::query_once`'s `test_mode` abort (`src/popup.cpp`) for ONLY that one query_yn, and the
client's YES/NO is served as registered `LEFT`/`CONFIRM` through the real `input_context("YESNO")` loop
(YES takes down the furniture via the engine's own `take_down_deployed_furniture`; NO is a no-op).
`query_yn` is **not cancelable** (no fabricated cancel; EOF serves the visible default, marked
`noncancelable_closed`). Built reproducibly by
[`docs/arcopolis/make_furniture_fixture.py`](make_furniture_fixture.py) (save-edit, no GUI/build), gated by
[`docs/arcopolis/query_popup_regression.ps1`](query_popup_regression.ps1) (six gates:
accept/reject/state-change/recovery/EOF). See
[35_SPIKE15_BACKEND_DRIVEN_QUERY_POPUP.md](35_SPIKE15_BACKEND_DRIVEN_QUERY_POPUP.md).

## `ArcopolisWallTest` — genuine terrain `blocked_no_op` witness (Spike 21)

A clone of `ArcopolisTest` with ONE impassable wall (`t_wall`, `move_cost 0`) written onto the clean
`t_floor` tile one tile EAST of the avatar. A `move direction=move_e` into it runs the real
`avatar_action::move` → `g->walk_move` leaf, which rejects the impassable destination with **no move, no
tick, and NO prompt** (auto-bash needs the explicit smash command; auto-mine needs a dig tool the avatar
lacks) — a genuine `blocked_no_op`. This is the **replacement** `blocked_no_op` witness after Spike 21 made
move-into-NPC fail loud (`unexpected_prompt`): the old move-into-Edwardo `blocked_no_op` was a tolerated
historical artifact (a hidden player-visible menu cancellation), not a true equivalence witness. (The gate
asserts the `blocked_no_op` outcome + the harness reading the real `t_wall` destination; it does NOT assert
`blocked_by=terrain`, because that harness branch needs `dest.seen=true` and a headless run never populates
LOS — every tile exports `seen=false` — so the attribution is honestly withheld rather than bend the
consumer's `seen` guard.) Built reproducibly by [`docs/arcopolis/make_wall_fixture.py`](make_wall_fixture.py)
(save-edit of the submap `terrain` RLE, no GUI/build), gated by the terrain `blocked_no_op` gate in
[`docs/arcopolis/client_harness_regression.ps1`](client_harness_regression.ps1). See
[43_SPIKE21_UILIST_UNEXPECTED_PROMPT_FAIL_LOUD.md](43_SPIKE21_UILIST_UNEXPECTED_PROMPT_FAIL_LOUD.md).

## `ArcopolisStairsTest` — aligned two-floor stair fixture (Spike 23) + vertical-movement witness (Spike 24)

A clone of `ArcopolisTest` with a **matched stair pair** written into the avatar's column WITHOUT moving
the avatar: the avatar's own z=0 tile becomes `t_stairs_down` (flag `GOES_DOWN`, was `t_floor`), and the
tile **directly below** at z=-1 (same x,y) becomes `t_stairs_up` (flag `GOES_UP`, was `t_linoleum_white` in
the already-saved basement). Both submaps already exist in `ArcopolisTest`'s saved bubble, so this is two
terrain edits — no submap synthesis, no avatar move, no bubble-origin shift (the loader recomputes the
bubble origin from `player.abs_pos`, so moving the avatar would risk edge mapgen — `src/savegame.cpp:350-352`).

**What it provides:** the deterministic setup for a vertical-movement witness. The avatar **stands on**
`t_stairs_down`, so a single **`vertical_move` down** hits `find_stairs`'s fast path
(`src/game.cpp:14840-14846`) — it returns the `GOES_UP` tile directly below, with no fabrication and no
`query_yn` (doc 47 §4: a matched aligned pair + no creature on either tile avoids both `find_or_make_stairs`
fabrication and the push-past prompt). After descending the avatar stands on `t_stairs_up`, so the
**`vertical_move` up** return leg hits the symmetric fast path (the `GOES_DOWN` tile directly above) — the
round trip is deterministic in both directions.

**Spike 24 now DRIVES it (PROVEN, level 2/3).** The `vertical_move` command (`down`/`up` →
`ACTION_MOVE_DOWN`/`ACTION_MOVE_UP` → native `game::vertical_move`) proves a **matched-stair down → up round
trip** on this fixture, gated by
[`docs/arcopolis/vertical_movement_regression.ps1`](vertical_movement_regression.ps1): `before` on
`t_stairs_down` (z 0) → `after_down` on `t_stairs_up` (z −1, x/y unchanged, turn advanced) → `after_up` back
on `t_stairs_down` (z 0, turn advanced again), exit 0, `session_end ok` (no unexpected prompt). The
after-down snapshot is also the **per-floor-observation** witness doc 47 §4 flagged as LIKELY-but-unwitnessed
(the snapshot re-windows on the new z). This is a **matched-stair round trip only** — it proves nothing about
ramps/elevators/ladders/ropes/climbing/falling/generic vertical, 5–6 floor traversal, or simultaneous
multi-z export. See [49_SPIKE24_VERTICAL_MOVEMENT_WITNESS.md](49_SPIKE24_VERTICAL_MOVEMENT_WITNESS.md).

Built reproducibly by [`docs/arcopolis/make_stairs_fixture.py`](make_stairs_fixture.py) (save-edit of two
submap `terrain` RLEs, no GUI/build; `--check-only` / `--force`), gated by
[`docs/arcopolis/stairs_fixture_regression.ps1`](stairs_fixture_regression.ps1) (five gates: clean load +
`session_end ok`; `avatar.z == 0`; `avatar.pos_abs == [6301,6421,0]` unmoved; the `is_avatar` tile is
`t_stairs_down`; and the generator `--check-only` re-asserts the z=-1 `t_stairs_up` the single-z snapshot
cannot observe). The fixture asserts no monster on either stair tile and `stair_monsters == []`; it does not
scan NPCs (they live in overmap files), which is sufficient here because the z=0 stair is the avatar's own
tile (never the shelter NPC Edwardo, one tile north) and the z=-1 stair is in a basement no NPC visits.

## `ArcopolisLivenessTest` — world-tick liveness witness (Spike 27A)

A clone of `ArcopolisTest` with one **hostile mobile** `mon_zombie` injected 2 tiles **south** of the
avatar (save fields `anger=100`, `morale=100`, `aggro_character=true` — an authored initial condition,
exactly as the GUI debug spawn authors one). Across `[export, (wait, export) × N]` the driven `wait`
falls through `do_turn`'s clean-park seam into the bottom-half tick (`game::monmove`), and the zombie
pathfinds toward the avatar **on its own engine turn** — witnessing that BN simulates between inputs
(equivalence **level 1 / class S**, observation only; `delta ⇒ act`, never `no-delta ⇒ no-liveness`).
Non-interference is structural: the stock NPC Edwardo is 1 tile **north** (opposite side, avatar
between) and exports `is_stationary=true`, so he can neither reach nor be reached by the zombie — gated
by asserting his `pos_abs` is held. Built by the **parameterized**
[`docs/arcopolis/make_monster_fixture.py`](make_monster_fixture.py) (the opt-in `--anger` /
`--morale` / `--aggro-character` flags; defaults still produce the immobile `ArcopolisNearMonsterTest`
witness byte-for-byte). Gated by
[`docs/arcopolis/world_tick_liveness_regression.ps1`](world_tick_liveness_regression.ps1), which runs
**3 distinct seeds** and asserts only **RNG-invariant** quantities (approach / clock-advance /
avatar-held / NPC-held / mover-survived) — the headless sim is not byte-deterministic even fully serial

- seeded, so the witness proves invariance by sampling RNG realizations rather than fixing the seed. The
  attacker-attributed **damage** fact (surfacing the engine's `source` at the damage funnel) is **27B**
  ([`attacker_damage_regression.ps1`](attacker_damage_regression.ps1), run-script, RNG-dependent, on this same
  fixture). The **one-shot** path's damage witness uses a **runtime-generated** adjacent-attacker variant
  (`make_monster_fixture.py --offset 0,1,0`, built into the sandbox, NOT a committed world) gated by
  [`oneshot_damage_regression.ps1`](oneshot_damage_regression.ps1); the one-shot session-serialization fix's
  deterministic seal is the RNG-free Catch2 tripwire. See
  [56_SPIKE27A_WORLD_TICK_LIVENESS.md](56_SPIKE27A_WORLD_TICK_LIVENESS.md),
  [57_SPIKE27B_ATTACKER_DAMAGE.md](57_SPIKE27B_ATTACKER_DAMAGE.md), and
  [58_ONESHOT_SESSION_SERIALIZATION.md](58_ONESHOT_SESSION_SERIALIZATION.md).

## Spike 16 — non-live run-script reuse of the prompt fixtures

**Spike 16 reuses all four prompt fixtures (`ArcopolisTest`, `ArcopolisVehicleCargoTest`,
`ArcopolisCapacityTest`, `ArcopolisDeployedFurnitureTest`) in NON-LIVE `--arcopolis-run-script` mode** via
a command step's declared `prompt_answers` (the script prompt sources feed the same `backend_resolve_*`
machinery as live), gated by [`docs/arcopolis/script_prompt_regression.ps1`](script_prompt_regression.ps1)
(a pure run-script regression — no live driver/python). A run-script `pickup` with NO `prompt_answers`, and
every one-shot `--arcopolis-command` pickup, still fail loud (exit 6); a missing/wrong/unused scripted
answer fails loud (`script_prompt_failed`, exit 13). See
[36_SPIKE16_SCRIPT_PROMPT_ANSWERS.md](36_SPIKE16_SCRIPT_PROMPT_ANSWERS.md).
