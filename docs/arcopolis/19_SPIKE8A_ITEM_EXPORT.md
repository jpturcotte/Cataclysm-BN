# Spike 8A — nearby ground-item export v0

> **Status: ✅ implemented (2026-06-06).** The next **read-only observability** slice after Spike 7A's NPCs:
> a `entities.items[]` block beside `entities.monsters[]` and `entities.npcs[]` in each snapshot, listing the
> top-level **ground items** on the tiles in the **same radius-12 single-z window as `tiles[]`,
> `entities.monsters[]`, and `entities.npcs[]`**. Additive and read-only — snapshot `schema_version` stays
> **1**, no gameplay/command/protocol change, and the failed Spike-3 `command → do_turn` path is **not**
> revived. Builds on [14_SPIKE6_MONSTER_EXPORT.md](14_SPIKE6_MONSTER_EXPORT.md) and
> [18_SPIKE7A_NPC_EXPORT.md](18_SPIKE7A_NPC_EXPORT.md).

## Why this is "Spike 8A"

A mouse-first frontend needs to see not just terrain and creatures but **what loot is on the tiles**. The
export backlog's dynamic-entity linchpin ([ARCOPOLIS_STATE.md](ARCOPOLIS_STATE.md) backlog #2) had monsters
(6A) and NPCs (7A); ground items are the remaining everyday tile content. This is the minimum slice that lets
a frontend render tile contents — "there is a backpack and a rock here" — even though it cannot yet **act**
on them. Items are labelled **8A** because pickup/drop/use, inventory, vehicle cargo, and nested containers
remain explicit follow-ups.

## Scope

**IN:** top-level ground items only · current z-level only · the same square radius/window as `tiles[]` ·
read-only fields `index`, `type_id`, `name`, `symbol`, `pos_local`, `pos_abs`, `charges`,
`count_by_charges` · viewer renders + lists items · a fixture-driven regression on `ArcopolisTest` · this
doc + the state page.

**OUT:** any item **interaction** command (pickup / drop / use / wield / examine-menu / drag / loot /
auto-pickup / selection) · item mutation of any kind · avatar inventory · NPC inventory · **vehicle cargo**
(a separate stack — `vehicle::get_items`, not `map::i_at`) · items **nested inside containers** (not
surfaced by `map::i_at`) · weight / volume / price / damage / flags / rot / per-item state detail ·
per-tile symbol/colour (#1) · protocol/socket/stdin mode · `schema_version` bump.

## The contract — `entities.items[]`

`entities` now has three members, `monsters[]` (6A), `npcs[]` (7A), and `items[]` (this spike); the object
shape is `"entities": { "monsters": [ … ], "npcs": [ … ], "items": [ … ] }`. `entities.monsters[]` and
`entities.npcs[]` are **unchanged** (not removed, not renamed). Each `items[]` element:

| field              | type      | source (`src/item.h` / `src/map.h` / `src/creature.cpp`) | notes                                                            |
| ------------------ | --------- | -------------------------------------------------------- | ---------------------------------------------------------------- |
| `index`            | int       | export-local counter                                     | 0-based, assigned **after** the window filter, flat over tiles   |
| `type_id`          | string    | `it->typeId().str()` (item.h:1451)                       | stable item-type id (e.g. `"evac_pamphlet"`)                     |
| `name`             | string    | `it->display_name()` (item.h:495)                        | the look/pickup display name (pickup.cpp:181-188)                |
| `symbol`           | string    | `it->symbol()` (item.h:606)                              | the item's map glyph (`type->sym`); analog of `mon.symbol()`     |
| `pos_local`        | `[x,y,z]` | the tile `p` (`tripoint_bub_ms`)                         | reality-bubble coords — matches `tiles[].x/y/z`                  |
| `pos_abs`          | `[x,y,z]` | `ctx.m.bub_to_abs( p )` (map.h:2134)                     | absolute coords — **same frame** as avatar/monster/NPC `pos_abs` |
| `charges`          | int       | `it->charges` (item.h:2554-2555, public member)          | meaningful **only** when `count_by_charges`; else treat as 1     |
| `count_by_charges` | bool      | `it->count_by_charges()` (item.h:895)                    | true for ammo / liquids / stackables                             |

All accessors are **public** (`typeId`/`display_name`/`symbol`/`count_by_charges` are public const methods;
`charges` is a public data member), already used by the engine's look/pickup/examine paths, so they are safe
headless. v0 deliberately stops here: no weight/volume/price/damage/flags, no rot/decay, no per-item state.

### Why `pos_abs` is frame-correct

`pos_abs` is computed as `ctx.m.bub_to_abs( p )` — the **identical** conversion `Creature::abs_pos()` uses
(`get_map().bub_to_abs( bub_pos() )`, creature.cpp:2556), so an item on a tile reports the same absolute
coordinate a creature standing on that tile would (`monster::abs_pos()` returns the engine-cached `pos_abs`,
which the engine keeps equal to `bub_to_abs(bub_pos())`). `map::bub_to_abs` is a **const** method (map.h:2134),
so it is called on the read-only `ctx.m`.

### Window-equivalence invariant

Unlike the monster/NPC blocks (which filter a global engine list), the item block **iterates the exported
tile window itself**: `points_in_radius( center, ctx.radius )` (the very loop `write_tiles` uses), guarded by
the shared `in_export_window( p, center, ctx )` helper (Spike 7A). For each surviving tile it reads the
ground-item stack and emits one object per item. Because the iteration **is** the `tiles[]` iteration and the
guard **is** the shared predicate, **every exported item's `pos_local` equals some exported tile's `(x,y,z)`
by construction** — the same invariant monsters/NPCs satisfy. The offline viewer asserts it
(`verify_items_in_window` → `items_off_window`) and fails the report if any item lands off-window.

### Read-only authoritative export, not an interaction surface

`entities.items[]` is the engine's **raw ground-item state** on the windowed tiles, read through the same
public accessor look/pickup/examine use. It exposes **what is on a tile**, but adds **no** way to act on it.
Pickup/drop/use, inventory, and item selection are a separate command-vocabulary expansion with their own
fidelity surface (the GUI pickup/AIM menus, weight/volume limits, container nesting) and are **explicitly
deferred**. The export is also deliberately narrow about _which_ items it returns:

- **Vehicle cargo is excluded.** `map::i_at` reads only the submap's own item stack; vehicle contents live in
  the vehicle and are reached via `vehicle::get_items` (pickup.cpp:1293-1300). They are **deferred**, not
  silently merged.
- **Nested container contents are excluded.** `map::i_at` yields only the top-level items on the tile
  (submap.h:84); items inside a container need `item::visit_items`. They are **deferred**.

## Implementation

### Snapshot — `src/arcopolis_export.cpp`

Added `#include "item.h"` (the complete `item` type the accessors and `map_stack` deref need; mirrors 6A/7A
adding `monster.h`/`npc.h`). In `write_entities`, **after** the `npcs[]` array and still inside the
`entities` object, added an `items[]` array. It iterates `points_in_radius( center, ctx.radius )`, applies
`in_export_window`, computes the tile's `pos_abs` once via `ctx.m.bub_to_abs( p )`, and iterates the tile's
ground stack with `for( const item *const it : get_map().i_at( p ) )`, writing the eight fields per item.

**`map::i_at` is non-const** (map.h:1692, comment "for safe modification" — there is no const overload), so
the stack is reached through the non-const global `get_map()` (map.h:2736; the same map object `ctx.m` was
set from). **Every other read stays on the const `ctx.m`, and every item value is only read — no item is
mutated, moved, or removed.** The `const item *const` range-`for` matches the established pickup/look idiom
(pickup.cpp:1279). `write_snapshot`'s call order is unchanged (`… tiles, entities, messages, diagnostics`),
so the only schema change is the additive array. No public header, CMake, or `schema_version` change.

### Offline viewer — `tools/arcopolis_viewer/make_report.py`

Backward compatible: pre-8A snapshots lack `entities.items`, so `dig(data, "entities.items")` returns `None`
and every item path no-ops (the viewer still exits 0).

- **`render_map_html`** overlays items on the same single-z grid with precedence **avatar > npc > monster >
  item > terrain**. An item-only cell renders `"*"` in a teal `.cell.item` class; a tile that also holds an
  avatar/NPC/monster keeps the higher-priority glyph but the cell tooltip still appends `items=N (first: …)`.
  `item_cells` maps `(x,y) → [item, …]` (the full per-tile list, since a tile can hold many items). An
  `item (ground)` legend entry and an `N item cell(s)` caption bit appear when items are present. Overlay
  cells (item, monster, and NPC) are **dimmed when their tile is unseen** (`tiles[].seen == false`), so the
  report distinguishes what the player can currently see from what merely exists in the bubble; the avatar is
  never dimmed. The export itself stays authoritative — out-of-LOS entities are still listed (the frontend
  owns visibility policy, and can also join an item to its tile's `seen`).
- **`verify_items_in_window`** builds the 3D tile set and returns any item whose `pos_local` isn't on an
  exported tile; malformed item objects are **counted as off-window** (never crash). Missing/empty
  `entities.items` ⇒ `checked == 0`; an empty `items[]` is not a failure; missing/empty `tiles[]` ⇒ a note,
  never a false failure. `build_model` tallies `items_off_window` and ANDs it into `overall_pass`, so
  **viewer exit 0 asserts the window-equivalence invariant for items too**.
- **`render_export_card`** adds an `items (N): <type_id> @ <pos_local>` line (capped with a `+K more`
  overflow note, since a tile can hold many) and a warn-callout if any item is off-window. The validation
  table/stdout gain an `items off the tile window` / `items_off_window=` count. `TOOL_VERSION` → `1.2.0`.

### Regression — `docs/arcopolis/item_export_regression.ps1`

A sibling of [`npc_export_regression.ps1`](npc_export_regression.ps1) with the same shape (param block,
`$ErrorActionPreference = "Stop"`, the `Stop-WithCode` exit-code helper, delete-then-copy fixture refresh,
the `Start-Process -Wait -PassThru` pattern a GUI-subsystem exe needs, `ConvertFrom-Json` reads, a single
`$fail` accumulator, `exit 1`/`exit 0`). It runs `export(items_before) → wait → export(items_after_wait)`
over **`ArcopolisTest`** (no save edit — the saved evac shelter already holds in-window loot) and asserts:
(1) `entities.items` present on each snapshot; (2) off-window == 0 on each snapshot; (3) `items_before`
count > 0; (4) `items_after_wait` still exports `entities.items` (the export survives a world tick); (5)
viewer exit 0 and `items_off_window=0`. It soft-reports the per-snapshot item count and the nearest item to
the avatar. Per the spike it does **not** gate on exact count across the wait nor on specific item
names/tiles (prefer tile/window invariants over fragile metadata).

## Fixture choice — `ArcopolisTest` (no new fixture)

`ArcopolisTest` is a _saved_ world, so its evac-shelter mapgen rolls are **frozen** into concrete save data.
A read-only scan of its `map.sqlite3` (avatar at abs `[6301,6421,0]` from the `.sav` `player.abs_pos`) found
**27 deterministic ground items inside the radius-12 window**, the closest being `evac_pamphlet` at abs
`[6301,6423,0]` — `(0,+2)` from the avatar (Chebyshev 2). So `ArcopolisTest` is the **item-export witness**,
exactly as it is the NPC-export witness; no save-edit / `ArcopolisItemTest` fixture is required. (Had the
saved window been empty, the plan was a `make_monster_fixture.py`-style `map.sqlite3` item injection; it
proved unnecessary.)

## Files changed

| File                                          | Change                                                                                  |
| --------------------------------------------- | --------------------------------------------------------------------------------------- |
| `src/arcopolis_export.cpp`                    | `+#include item.h`; add the `items[]` array in `write_entities` (read-only `i_at` loop) |
| `tools/arcopolis_viewer/make_report.py`       | item overlay + `verify_items_in_window` + card line + `items_off_window` count + CSS    |
| `docs/arcopolis/item_export_regression.ps1`   | **new** — the item-export witness gate on `ArcopolisTest`                               |
| `docs/arcopolis/19_…md`, `ARCOPOLIS_STATE.md` | this doc + the current-truth checkpoint page                                            |
| `AGENTS.md`                                   | one-line pointer: `ArcopolisTest` is also the item-export witness                       |

No engine system files (turn loop, `messages`, `map`, `game`) are touched. CMake needs no edit (`src/` is
globbed). The `[arcopolis]` unit suite is pure formatters/parsers and is unchanged; the snapshot writers read
live game globals and are e2e-proven against the `ArcopolisTest` fixture, exactly as the monster/NPC blocks
were in 6A/7A.

## Validation

Build the game **and** tests in the single `win-rel-deb` dir (shared `cataclysm-bn-tiles-common` OBJECT
library — see [00_WINDOWS_LOCAL_ENVIRONMENT.md](00_WINDOWS_LOCAL_ENVIRONMENT.md)). Copy the external
`ArcopolisTest` fixture, then drive `export(items_before) → wait → export(items_after_wait)`.

```powershell
$exe = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe"
Copy-Item C:\dev\arcopolis-fixtures\arcopolis_user .\arcopolis_user -Recurse -Force

@'
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "items_before" },
  { "op": "command", "command": "wait" },
  { "op": "export",  "name": "items_after_wait" }
] }
'@ | Set-Content -Encoding ascii .\out\arco_s8.json

& $exe --world ArcopolisTest --arcopolis-run-script .\out\arco_s8.json --arcopolis-export-dir .\out\arco_s8 --userdir .\arcopolis_user
# entities.items present and non-empty; every item pos_local equals some tiles[] (x,y,z).

python tools\arcopolis_viewer\make_report.py --session-dir .\out\arco_s8 --output .\out\arco_s8_report.html
"viewer exit = $LASTEXITCODE"   # expect 0, stdout contains items_off_window=0

# Or, all of the above as one gate:
.\docs\arcopolis\item_export_regression.ps1                          # expect exit 0
& ".\out\build\win-rel-deb\tests\cata_test-tiles.exe" "[arcopolis]"  # additive — unchanged
```

The **viewer logic** was additionally proven build-free with synthetic snapshots: `verify_items_in_window`
returns `off_window == []` for an in-window item and flags an off-window / malformed one; `render_map_html`
renders `*` for an item-only cell with the count tooltip and honours avatar > npc > monster > item
precedence; and the end-to-end CLI exits **0** (`items_off_window=0`) for an in-window item and **2**
(`items_off_window=1`) for an off-window one. Pre-8A snapshots (no `entities.items`) still exit 0.

## Citation audit

| Claim                                                      | Implementing line(s) / evidence                                                                                       | Verdict                       |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- | ----------------------------- |
| Ground items read via the look/pickup map accessor         | `map::i_at` (map.h:1692); callers pickup.cpp:1279, game.cpp:8770                                                      | ✅                            |
| `i_at` is non-const → reached via `get_map()`, read-only   | map.h:1692 (no const overload); `get_map()` map.h:2736; loop only reads                                               | ✅                            |
| Vehicle cargo excluded (separate stack)                    | `vehicle::get_items` vs `i_at` (pickup.cpp:1293-1300; map.cpp:5537)                                                   | ✅ (deferred, not merged)     |
| Nested container contents excluded (top-level only)        | submap `itm` stack (submap.h:84); nesting needs `visit_items`                                                         | ✅ (deferred)                 |
| Same window predicate as `tiles[]` (every item a tile)     | iterates `points_in_radius` + shared `in_export_window`; viewer `items_off_window==0`                                 | ✅ (synthetic + e2e)          |
| `pos_abs` matches creature frame                           | `ctx.m.bub_to_abs(p)` (map.h:2134) == `Creature::abs_pos()` (creature.cpp:2556)                                       | ✅                            |
| All 8 fields exported from public item APIs                | typeId item.h:1451; display_name item.h:495; symbol item.h:606; charges item.h:2554-2555; count_by_charges item.h:895 | ✅                            |
| `charges` only meaningful when `count_by_charges`          | `item::count()` = `count_by_charges() ? charges : 1` (item.cpp)                                                       | ✅ (documented for consumers) |
| Fixture witness is deterministic (saved rolls frozen)      | map.sqlite3 scan: 27 in-window items, evac_pamphlet abs [6301,6423,0] off (0,+2)                                      | ✅                            |
| Viewer renders + lists items, asserts the invariant        | `render_map_html` overlay + `verify_items_in_window` → `items_off_window` gates exit                                  | ✅ (synthetic + e2e exit 0/2) |
| Viewer backward-compatible with pre-8A snapshots           | `dig(data,"entities.items")` → `None` ⇒ no-op (synthetic test, exit 0)                                                | ✅                            |
| Additive: no `schema_version` bump, no engine-system edits | snapshot `schema_version` unchanged; only `arcopolis_export.cpp` + viewer + docs/script                               | ✅                            |
| No item interaction command / no item mutation added       | only `write_entities` + viewer touched; no command/seam/inventory edit                                                | ✅                            |
