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
[34_SPIKE14_SECONDARY_PICKUP_UILIST.md](34_SPIKE14_SECONDARY_PICKUP_UILIST.md).

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

## Spike 16 — non-live run-script reuse of the prompt fixtures

**Spike 16 reuses all four prompt fixtures (`ArcopolisTest`, `ArcopolisVehicleCargoTest`,
`ArcopolisCapacityTest`, `ArcopolisDeployedFurnitureTest`) in NON-LIVE `--arcopolis-run-script` mode** via
a command step's declared `prompt_answers` (the script prompt sources feed the same `backend_resolve_*`
machinery as live), gated by [`docs/arcopolis/script_prompt_regression.ps1`](script_prompt_regression.ps1)
(a pure run-script regression — no live driver/python). A run-script `pickup` with NO `prompt_answers`, and
every one-shot `--arcopolis-command` pickup, still fail loud (exit 6); a missing/wrong/unused scripted
answer fails loud (`script_prompt_failed`, exit 13). See
[36_SPIKE16_SCRIPT_PROMPT_ANSWERS.md](36_SPIKE16_SCRIPT_PROMPT_ANSWERS.md).
