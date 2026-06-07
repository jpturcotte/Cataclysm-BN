# Spike 7A — nearby NPC export v0

> **Status: ✅ implemented (2026-06-06).** The next **dynamic-entity** slice after Spike 6A's monsters: a
> read-only `entities.npcs[]` block beside `entities.monsters[]` in each snapshot, listing the NPCs in the
> **same radius-12 single-z window as `tiles[]` and `entities.monsters[]`**. Additive and read-only —
> snapshot `schema_version` stays **1**, no gameplay/command/protocol change, and the failed Spike-3
> `command → do_turn` path is **not** revived. Builds on
> [14_SPIKE6_MONSTER_EXPORT.md](14_SPIKE6_MONSTER_EXPORT.md) and the move-into-NPC root cause
> [15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md](15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md).

## Why this is "Spike 7A"

The export backlog's linchpin is **dynamic entities** ([ARCOPOLIS_STATE.md](ARCOPOLIS_STATE.md) backlog #2).
Spike 6A took the first slice (monsters). NPCs are the next, and they are the slice with the sharpest
motivation: **an NPC can block movement and trigger GUI/menu semantics while being completely invisible in
the previous snapshots.** PR #19 root-caused the `ArcopolisTest` `move_n` no-op as the stock evac-shelter
NPC **Edwardo Stovall** standing one tile north of the avatar — but Spike 6A exported monsters only, so
nothing in the snapshot _showed_ him. The diagnosis had to be read out of the save. This spike closes that
gap: after it, the `move_n` no-op is **explainable from the snapshot itself**. NPCs are labelled **7A**
because items/fields/vehicles remain explicit follow-ups.

## Scope

**IN:** NPCs only · current z-level only · the same square radius/window as `tiles[]` · read-only fields
`index`, `name`, `pos_local`, `pos_abs`, `is_enemy`, `is_following`, `is_player_ally`, `is_stationary`,
`hallucination` · viewer renders + lists NPCs · a fixture-driven regression on `ArcopolisTest` · this doc +
the state page.

**OUT:** any NPC **interaction** command (talk / attack / swap / push) · dialogue automation · any movement
change · items · fields · vehicles · deep faction / dialogue / inventory / mission / opinion fields · stable
persistent entity IDs · targeting/combat · protocol/socket/stdin mode · `schema_version` bump.

## The contract — `entities.npcs[]`

`entities` now has two members, `monsters[]` (Spike 6A) and `npcs[]` (this spike); the object shape is
`"entities": { "monsters": [ … ], "npcs": [ … ] }`. `entities.monsters[]` is unchanged. Each `npcs[]`
element:

| field            | type      | source (`src/npc.{h,cpp}` / `src/creature.h` / `src/character.h`) | notes                                                |
| ---------------- | --------- | ----------------------------------------------------------------- | ---------------------------------------------------- |
| `index`          | int       | export-local counter                                              | 0-based, assigned **after** the window filter        |
| `name`           | string    | `np.get_name()` (character.h:1622)                                | display name                                         |
| `pos_local`      | `[x,y,z]` | `np.bub_pos()` (creature.h:492, `tripoint_bub_ms`)                | reality-bubble coords — matches `tiles[].x/y/z`      |
| `pos_abs`        | `[x,y,z]` | `np.abs_pos()` (creature.h:493, `tripoint_abs_ms`)                | absolute coords — matches `avatar.pos_abs` frame     |
| `is_enemy`       | bool      | `np.is_enemy()` (npc.cpp:2246)                                    | attitude ∈ {KILL, FLEE, FLEE_TEMP}                   |
| `is_following`   | bool      | `np.is_following()` (npc.cpp:2236)                                | attitude ∈ {FOLLOW, WAIT}                            |
| `is_player_ally` | bool      | `np.is_player_ally()` (npc.cpp:2205)                              | `is_ally( g->u )`                                    |
| `is_stationary`  | bool      | `np.is_stationary()` (npc.cpp:2251)                               | guarding, or a shelter / shopkeep / infected mission |
| `hallucination`  | bool      | `np.is_hallucination()` (npc.h:858)                               | true if the NPC isn't real (key mirrors monsters)    |

All accessors are **public const** methods (pure reads of `attitude` / `mission` / `my_fac` / effects — the
engine calls them every turn, so they are safe headless). v0 deliberately stops here: no faction object, no
dialogue/opinion, no inventory/mission detail, no persistent ID (none has an obviously-safe public accessor
yet — deferred).

### Window-equivalence invariant

`write_entities` filters NPCs with the **identical** predicate it uses for monsters, now factored into one
helper `in_export_window( p, center, ctx )`: same z as the centre, `center ± ctx.radius` in x and y
(mirroring `points_in_radius`), then `map::inbounds`. The centre is `ctx.u.bub_pos()` — the same coordinate
`write_tiles` centres on and `write_avatar` serialises as `pos_local`. Sharing the helper makes the monster
window, the NPC window, and `tiles[]` equal **by construction**, so **every exported NPC's `pos_local`
equals some exported tile's `(x,y,z)`**. The offline viewer asserts this (`verify_npcs_in_window` →
`npcs_off_window`) and fails the report if any NPC lands off-window.

### Authoritative/debug export, not a player-visibility or interaction surface

`entities.npcs[]` is the engine's **raw, authoritative** NPC list within the window. The source is
`game::all_npcs()` — the **active non-dead NPC range** (`npc_range`, game.h:515, a `non_dead_range<npc>`,
game.h:488). It is **not** pre-filtered to loaded/simulated NPCs: `game::do_turn` separately skips
`!guy.is_simulated()` (game.cpp:6351), so — exactly as with monsters — out-of-bubble NPCs are excluded only
by the `inbounds` window check, not by the range. The avatar (`g->u`) is not in the list. As with monsters,
hallucinations are **included** and flagged (`hallucination`) rather than hidden; a frontend layers its own
visibility/rendering policy on top.

This is a **read-only export**, **not** an interaction surface. It exposes _that_ an NPC blocks a tile and
_what its disposition is_, but adds **no** way to act on it. Choosing an NPC interaction
(talk/attack/swap/push, or pathing around) is a separate command-vocabulary expansion with its own fidelity
surface (the GUI menu, dialogue, hostility) and is **explicitly deferred** to a future "richer commands /
NPC interaction" spike (see [15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md](15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md), "Scope
question surfaced", and the [ARCOPOLIS_STATE.md](ARCOPOLIS_STATE.md) backlog).

## Relationship to doc 15 — the `move_n` no-op is now self-explaining

[15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md](15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md) established that `move_n` in
`ArcopolisTest` is a **GUI-faithful** no-op: the avatar bumps into neutral NPC Edwardo Stovall (local
`(85,84,0)`), the engine opens `npc_menu`, which auto-cancels in `test_mode` (≡ pressing ESC) — no move, 0
AP, world not ticked. That conclusion was read out of the save because the snapshot didn't export NPCs. With
Spike 7A the **before** snapshot now carries an NPC at `pos_local [85,84,0]` (`is_enemy=false`,
`is_player_ally=false` — a neutral non-ally), so a consumer can see the blocker directly and explain the
no-op without opening the save. Movement behaviour itself is **unchanged**; this spike only makes the cause
visible.

## Implementation

### Snapshot — `src/arcopolis_export.cpp`

Added `#include "npc.h"` (the complete `npc` type the range-for + accessors need; the file previously had
only the `game.h` forward declaration — mirrors Spike 6A adding `monster.h`). Factored the shared window
test into an anonymous-namespace helper `in_export_window` and call it from **both** the monster loop
(refactor; the three inline `continue` checks collapse to one call, and the counter is renamed
`monster_index`) and the new NPC loop. The NPC loop iterates `g->all_npcs()` as `const npc &`, filters with
`in_export_window`, and writes one object per surviving NPC with the fields above (`pos_local`/`pos_abs` as
`[x,y,z]` arrays exactly like `write_avatar`/the monster block). `write_entities` is still called in
`write_snapshot` between `write_tiles` and `write_messages`, so field order stays `… tiles, entities,
messages, diagnostics`. No public header, CMake, or `schema_version` change.

### Offline viewer — `tools/arcopolis_viewer/make_report.py`

Backward compatible: pre-Spike-7A snapshots lack `entities.npcs`, so `dig(data, "entities.npcs")` returns
`None` and every NPC path no-ops (the viewer still exits 0).

- **`render_map_html`** overlays NPCs on the same single-z grid with precedence **avatar > npc > monster >
  terrain**. NPC cells render the glyph `"N"` in an amber `.cell.npc` class, with name + all relationship
  flags in the cell tooltip. `npc_cells.setdefault((x,y), npc)` makes a shared cell deterministically show
  the first NPC by export `index`; the per-snapshot card lists all. An "npc" legend entry and an "N npc
  cell(s)" caption bit appear when NPCs are present.
- **`verify_npcs_in_window`** builds the 3D tile set and returns any NPC whose `pos_local` isn't on an
  exported tile; malformed NPC objects are **counted as off-window** (never crash). Missing/empty `tiles[]`
  ⇒ a note, never a false failure. `build_model` tallies `npcs_off_window` and ANDs it into `overall_pass`,
  so **viewer exit 0 asserts the window-equivalence invariant** for NPCs too.
- **`render_export_card`** adds an `npcs (N): <name> @ <pos_local> enemy=… ally=… stationary=…` line and a
  warn-callout if any NPC is off-window. The validation table/stdout gain an "npcs off the tile window"
  count (`npcs_off_window=`).

### Regression — `docs/arcopolis/npc_export_regression.ps1`

A sibling of [`monster_export_regression.ps1`](monster_export_regression.ps1) with the same shape (param
block, `$ErrorActionPreference = "Stop"`, the `Stop-WithCode` exit-code helper, delete-then-copy fixture
refresh, the `Start-Process -Wait -PassThru` pattern a GUI-subsystem exe needs, `ConvertFrom-Json` reads, a
single `$fail` accumulator, `exit 1`/`exit 0`). It runs `export(before) → move_n → export(after_move_n)`
over **`ArcopolisTest`** (no save edit needed — Edwardo is already in-window) and asserts: (1) `entities.npcs`
present on each snapshot; (2) off-window == 0; (3) `before` count > 0; (4) a north blocker at
`[avatar_x, avatar_y-1, avatar_z]`, printing a PASS line with that NPC's name/position/flags; (5) the
`move_n` faithful no-op (`after.avatar.pos_abs == before.avatar.pos_abs` and `backend.turn` unchanged;
`moves` reported, not the primary signal); (6) viewer exit 0 and `npcs_off_window=0`. It also soft-reports
every NPC's flags. The negative check (a fixture without the shelter NPC fails gate 4) is documented in the
header, not enforced.

## Files changed

| File                                          | Change                                                                                   |
| --------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `src/arcopolis_export.cpp`                    | `+#include npc.h`; factor `in_export_window`; add the `npcs[]` array in `write_entities` |
| `tools/arcopolis_viewer/make_report.py`       | NPC overlay + `verify_npcs_in_window` + card line + `npcs_off_window` count + CSS        |
| `docs/arcopolis/npc_export_regression.ps1`    | **new** — the NPC-export witness gate on `ArcopolisTest`                                 |
| `docs/arcopolis/18_…md`, `ARCOPOLIS_STATE.md` | this doc + the current-truth checkpoint page                                             |

No engine system files (turn loop, `messages`, `map`, `game`) are touched. CMake needs no edit (`src/` is
globbed). The `[arcopolis]` unit suite is pure formatters/parsers and is unchanged; the snapshot writers
(incl. the NPC block) read live game globals and are e2e-proven against the `ArcopolisTest` fixture, exactly
as `write_entities`/monsters were in Spike 6A.

## Validation

Build the game **and** tests in the single `win-rel-deb` dir (shared `cataclysm-bn-tiles-common` OBJECT
library — see [00_WINDOWS_LOCAL_ENVIRONMENT.md](00_WINDOWS_LOCAL_ENVIRONMENT.md)). Copy the external
`ArcopolisTest` fixture, then drive `export(before) → move_n → export(after_move_n)` and assert the contract.

```powershell
$exe = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe"
Copy-Item C:\dev\arcopolis-fixtures\arcopolis_user .\arcopolis_user -Recurse -Force

@'
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "before" },
  { "op": "command", "command": "move", "direction": "move_n" },
  { "op": "export",  "name": "after_move_n" }
] }
'@ | Set-Content -Encoding ascii .\out\arco_s7.json

& $exe --world ArcopolisTest --arcopolis-run-script .\out\arco_s7.json --arcopolis-export-dir .\out\arco_s7 --userdir .\arcopolis_user
# entities.npcs present; before has an NPC at local [avatar_x, avatar_y-1, avatar_z] (Edwardo Stovall);
# after_move_n: avatar.pos_abs and backend.turn unchanged (faithful no-op).

python tools\arcopolis_viewer\make_report.py --session-dir .\out\arco_s7 --output .\out\arco_s7_report.html
"viewer exit = $LASTEXITCODE"   # expect 0, stdout contains npcs_off_window=0

# Or, all of the above as one gate:
.\docs\arcopolis\npc_export_regression.ps1                       # expect exit 0
& ".\out\build\win-rel-deb\tests\cata_test-tiles.exe" "[arcopolis]"   # additive — unchanged
```

The **viewer logic** was additionally proven build-free with synthetic snapshots: `verify_npcs_in_window`
returns `off_window == []` for an in-window NPC and flags an off-window / malformed one; `render_map_html`
renders `@` for the avatar and `N` for the NPC with the flags tooltip and honours avatar > npc > monster
precedence; and the end-to-end CLI exits **0** (`npcs_off_window=0`) for an in-window NPC and **2**
(`npcs_off_window=1`) for an off-window one. Pre-Spike-7A snapshots (no `entities.npcs`) still exit 0.

## Citation audit

| Claim                                                          | Implementing line(s) / evidence                                                         | Verdict                           |
| -------------------------------------------------------------- | --------------------------------------------------------------------------------------- | --------------------------------- |
| NPCs come from the active non-dead NPC range                   | `g->all_npcs()` → `npc_range` (game.h:515) = `non_dead_range<npc>` (game.h:488)         | ✅                                |
| Range is not pre-filtered to loaded/simulated                  | `do_turn` separately skips `!guy.is_simulated()` (game.cpp:6351); window uses inbounds  | ✅ (out-of-bubble excluded by it) |
| Same window predicate as `tiles[]`/monsters (every NPC a tile) | shared `in_export_window`; viewer `npcs_off_window == 0`                                | ✅ (synthetic + e2e)              |
| All 9 fields exported from public const APIs                   | get_name (character.h:1622); bub_pos/abs_pos (creature.h:492-493); npc.cpp:2205-2258    | ✅                                |
| `is_enemy/following/player_ally/stationary` semantics          | npc.cpp:2246 / 2236 / 2205 / 2251 (attitude/mission reads)                              | ✅                                |
| move_n no-op now visible: neutral NPC at the north tile        | doc 15 (Edwardo at local (85,84,0), NPCATT_NULL); before snapshot `npcs[]`              | ✅                                |
| Viewer renders + lists NPCs, asserts the invariant             | `render_map_html` overlay + `verify_npcs_in_window` → `npcs_off_window` gates exit      | ✅ (synthetic + e2e exit 0/2)     |
| Viewer backward-compatible with pre-Spike-7A snapshots         | `dig(data,"entities.npcs")` → `None` ⇒ no-op (synthetic test, exit 0)                   | ✅                                |
| Additive: no `schema_version` bump, no engine-system edits     | snapshot `schema_version` unchanged; only `arcopolis_export.cpp` + viewer + docs/script | ✅                                |
| No NPC interaction command / no movement change added          | only `write_entities` + viewer touched; no command/seam/`avatar_action` edit            | ✅                                |
