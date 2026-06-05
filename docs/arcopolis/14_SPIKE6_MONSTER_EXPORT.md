# Spike 6A — nearby monster export v0

> **Status: ✅ implemented (2026-06-05).** The first **dynamic-entity** slice of doc 12's future-export
> backlog: a read-only `entities.monsters[]` block in each snapshot, listing the monsters in the **same
> current-view window as `tiles[]`**. Additive and read-only — snapshot `schema_version` stays **1**, no
> gameplay/command/protocol change, and the failed Spike-3 `command → do_turn` path is **not** revived.
> Builds on [13_SPIKE5_EXPORT_CHEAP_WINS.md](13_SPIKE5_EXPORT_CHEAP_WINS.md).

## Why this is "Spike 6A"

Spike 5 was the "cheap wins" slice of the export backlog (per-tile `is_avatar`, `--seed`). The backlog's
linchpin is **dynamic entities** ([ARCOPOLIS_STATE.md](ARCOPOLIS_STATE.md) backlog #2) — they're what a
frontend needs to show a living world, and they later unblock the world-tick regression harness (a tick
is hard to witness without dynamic state). That work is large (monsters, NPCs, items, fields, vehicles),
so this spike takes the **first** slice — **monsters only** — and labels it **6A**; NPCs/items/fields/
vehicles are explicit follow-ups (6B+).

## Scope

**IN:** monsters only · current z-level only · the same square radius/window as `tiles[]` · read-only
fields `index`, `type_id`, `name`, `symbol`, `pos_local`, `pos_abs`, `hp`, `hp_max`, `moves`,
`hallucination` · viewer renders + lists monsters · this doc + the state page.

**OUT:** NPCs · items · fields · vehicles · monster inventory · factions/AI internals · stable persistent
entity IDs · targeting/combat commands · protocol/socket/stdin mode · `schema_version` bump.

## The contract — `entities.monsters[]`

A new top-level `entities` object sits between `tiles[]` and `messages[]` in the snapshot; today it has
exactly one member, `monsters[]` (so `entities.npcs[]`/`entities.items[]` can slot in later without a
breaking change). Each array element:

| field           | type      | source (`src/monster.h` / `src/creature.h`) | notes                                            |
| --------------- | --------- | ------------------------------------------- | ------------------------------------------------ |
| `index`         | int       | export-local counter                        | 0-based, assigned **after** the window filter    |
| `type_id`       | string    | `mon.type->id.str()`                        | e.g. `"mon_zombie"`                              |
| `name`          | string    | `mon.get_name()`                            | display name                                     |
| `symbol`        | string    | `mon.symbol()`                              | full display string (may be multi-byte)          |
| `pos_local`     | `[x,y,z]` | `mon.bub_pos()` (`tripoint_bub_ms`)         | reality-bubble coords — matches `tiles[].x/y/z`  |
| `pos_abs`       | `[x,y,z]` | `mon.abs_pos()` (`tripoint_abs_ms`)         | absolute coords — matches `avatar.pos_abs` frame |
| `hp`            | int       | `mon.get_hp()`                              | current hit points                               |
| `hp_max`        | int       | `mon.get_hp_max()`                          | maximum hit points                               |
| `moves`         | int       | `mon.get_moves()`                           | action points this turn (a mid-turn snapshot)    |
| `hallucination` | bool      | `mon.is_hallucination()`                    | true if the monster isn't real                   |

### Window-equivalence invariant

`write_entities` uses the **identical** window predicate to `write_tiles`: same z-level, `center ±
radius` in x and y (mirroring `points_in_radius`), then `map::inbounds`. The centre is
`ctx.u.bub_pos()` — the same coordinate `write_tiles` centres on and `write_avatar` serialises as
`pos_local`. Therefore **every exported monster's `pos_local` equals some exported tile's `(x,y,z)`**.
The offline viewer asserts this (see Validation) and fails the report if any monster lands off-window.

### Authoritative/debug export, not a player-visibility list

`entities.monsters[]` is the engine's **raw, authoritative** monster list within the export window. It
deliberately uses `game::all_monsters()`, which **includes hallucinations and friendly/ridden
monsters, and monsters the avatar cannot currently see**. The GUI hides hallucinations and out-of-LOS
monsters _at draw time_, but the backend's job is to export authoritative simulation state and let the
frontend apply any visibility/rendering policy — so the raw list is correct here, and the
`hallucination` flag is exported so a consumer can choose to hide or mark those.

This also drove the **source choice**: `map::get_creatures_in_radius` walks the same window but returns
`Creature*` (avatar + NPCs) and **excludes hallucinations** (`critter_at` defaults
`allow_hallucination = false`), which would make the `hallucination` field always-false and pull in
non-monsters. `all_monsters()` + a spatial filter is the faithful source.

> **Consumer note:** `entities.monsters[]` is authoritative _local simulation state within the window_,
> **not** a filtered "what the player can see" presentation list. A future frontend may layer its own
> visibility policy on top (e.g. cross-referencing each monster's tile `seen` flag).

## Implementation

### Snapshot — `src/arcopolis_export.cpp`

A new anonymous-namespace `write_entities( JsonOut &, const snapshot_ctx & )` mirrors `write_tiles`:
it centres on `ctx.u.bub_pos()`, iterates `g->all_monsters()`, skips any monster off the current z,
outside `center ± ctx.radius`, or `!ctx.m.inbounds(...)`, and writes one object per surviving monster
(fields above; `pos_local`/`pos_abs` as `[x,y,z]` arrays exactly like `write_avatar`). It is called in
`write_snapshot` **between** `write_tiles` and `write_messages`, so the field order is `… tiles,
entities, messages, diagnostics`. It pushes no `diagnostics.warnings`. Two includes were added
(`monster.h` for the complete type the range-for + accessors need — the file previously had only the
`game.h` forward declaration — and `mtype.h` for `mon.type->id`). No public header, CMake, or
`schema_version` change.

### Offline viewer — `tools/arcopolis_viewer/make_report.py`

Backward compatible: pre-Spike-6 snapshots lack `entities`, so `dig(data, "entities.monsters")`
returns `None` and every monster path no-ops.

- **`render_map_html`** overlays monsters on the same single-z grid, precedence **avatar > monster >
  terrain**. Monster cells use the monster's `symbol` (guarded: `raw[0] if isinstance(raw, str) and
  raw else "M"`, since a symbol may be empty/non-str/multi-byte) in a red `.cell.monster` class, with
  the type/name/hp in the cell tooltip. `monster_cells.setdefault((x,y), mon)` makes a shared cell
  deterministically show the first monster by export `index`; the per-snapshot list shows all. A
  "monster" legend entry and a "N monster cell(s)" caption bit appear when monsters are present.
- **`verify_monsters_in_window`** builds the 3D tile set and returns any monster whose `pos_local`
  isn't on an exported tile. Missing/empty `tiles[]` ⇒ nothing to verify against ⇒ zero flagged (a
  note, never a false failure). `build_model` tallies `monsters_off_window` and ANDs it into
  `overall_pass`, so **viewer exit 0 asserts the window-equivalence invariant** end-to-end.
- **`render_export_card`** adds a `monsters (N): …` line (mirroring the messages line) and a
  warn-callout if any monster is off-window. The validation summary table/stdout gain a "monsters off
  the tile window" count.

## Files changed

| File                                          | Change                                                                           |
| --------------------------------------------- | -------------------------------------------------------------------------------- |
| `src/arcopolis_export.cpp`                    | new `write_entities`; call it in `write_snapshot`; `+#include monster.h/mtype.h` |
| `tools/arcopolis_viewer/make_report.py`       | monster overlay + `verify_monsters_in_window` + card list + count + CSS          |
| `docs/arcopolis/14_…md`, `ARCOPOLIS_STATE.md` | this doc + the current-truth checkpoint page                                     |

No engine system files (turn loop, `messages`, `map`, `game`) are touched. CMake needs no edit
(`src/`/`tests/` are globbed). The `[arcopolis]` unit suite is pure formatters/parsers and is
unchanged; the snapshot writers (incl. `write_entities`) read live game globals and are **e2e-proven**
against the `ArcopolisTest` fixture, exactly as `write_tiles`/`is_avatar` were in Spike 5.

## Validation

Build the game **and** tests in the single `win-rel-deb` dir (shared `cataclysm-bn-tiles-common` OBJECT
library — see [00_WINDOWS_LOCAL_ENVIRONMENT.md](00_WINDOWS_LOCAL_ENVIRONMENT.md)). Copy the external
`ArcopolisTest` fixture, then run a stateful `export → move_s → export` script and assert the contract.
(The literal `C:\dev\arcopolis-fixtures\` below is the project's **approved fixture-root** — an explicit
local-path exception, like `C:\dev\ccache`, per AGENTS.md's fixture section; kept verbatim so the commands
stay copy-pasteable, and it carries no username or secret.)

```powershell
$exe = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe"
Copy-Item C:\dev\arcopolis-fixtures\arcopolis_user .\arcopolis_user -Recurse -Force
New-Item -ItemType Directory -Force .\out | Out-Null

@'
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "start" },
  { "op": "command", "command": "move", "direction": "move_s" },
  { "op": "export",  "name": "after_move" }
] }
'@ | Set-Content -Encoding ascii .\out\arco_s6.json

& $exe --world ArcopolisTest --arcopolis-run-script .\out\arco_s6.json --arcopolis-export-dir .\out\arco_s6 --userdir .\arcopolis_user
"run exit = $LASTEXITCODE"   # expect 0

# entities.monsters present, same z as tiles, each on an exported tile (off-window == 0 always).
foreach ($f in "000_start.json","001_after_move.json") {
  $snap = Get-Content ".\out\arco_s6\$f" -Raw | ConvertFrom-Json
  $mons = @($snap.entities.monsters)
  $tz   = $snap.tiles[0].z
  $set  = @{}; foreach ($t in $snap.tiles) { $set["$($t.x),$($t.y),$($t.z)"] = $true }
  $bad  = 0
  foreach ($m in $mons) {
    $k = "$($m.pos_local[0]),$($m.pos_local[1]),$($m.pos_local[2])"
    if ($m.pos_local[2] -ne $tz -or -not $set.ContainsKey($k)) { $bad++ }
  }
  "$f : monsters=$($mons.Count)  off-window/off-z=$bad"   # present array; bad==0 always
}

# Viewer (exit 0 also asserts the window-equivalence invariant).
python tools\arcopolis_viewer\make_report.py --session-dir .\out\arco_s6 --output .\out\arco_s6_report.html
"viewer exit = $LASTEXITCODE"   # expect 0

# Unit regression (additive — unchanged from Spike 5).
& ".\out\build\win-rel-deb\tests\cata_test-tiles.exe" "[arcopolis]"
```

### Fixture finding: empty at radius 12, proven non-empty at a wider radius

`ArcopolisTest` spawns the avatar inside an evac shelter at local `(85,85)`; `game::all_monsters()`
returns **14** monsters, all on z 0, but the **nearest is Chebyshev 31 tiles away** (confirmed with a
temporary in-tree diagnostic). At the scoped **radius 12** none are in the window, so the shipped
`entities.monsters[]` is correctly **present-but-empty** for this fixture — by design (the window is the
same as `tiles[]`), not a defect.

To prove the **emission path** end-to-end with real engine monsters, the view radius was **temporarily**
raised to 60 (a throwaway probe; the shipped value is 12) and the same script re-run:

```powershell
# (temporary) set arcopolis_view_radius = 60 in src/arcopolis_export.cpp, rebuild cataclysm-bn-tiles, then:
& $exe --world ArcopolisTest --arcopolis-run-script .\out\arco_s6.json --arcopolis-export-dir .\out\arco_s6_r60 --userdir .\arcopolis_user
$snap = Get-Content .\out\arco_s6_r60\000_start.json -Raw | ConvertFrom-Json
@($snap.entities.monsters).Count                                  # 7 in range at r=60
$snap.entities.monsters[0] | ConvertTo-Json -Compress             # full per-monster object
# then revert the radius to 12 and rebuild.
```

### Results (2026-06-05, MSVC/Ninja/ccache `win-rel-deb`)

- **Build:** `cataclysm-bn-tiles` + `cata_test-tiles` in the single `win-rel-deb` dir → both exit `0`.
- **Unit:** `cata_test-tiles "[arcopolis]"` → **All tests passed (204 assertions in 41 test cases)** —
  unchanged from Spike 5 (the suite is pure formatters/parsers; the writer is e2e-proven).
- **Shipped radius 12, `export → move_s → export`** → run exit `0`. All three snapshots
  (`000_start`, `001_after_move`, `002_final`) carry `entities.monsters` **present**, `count == 0`,
  `off-window/off-z == 0`. Avatar tracks the move (`is_avatar`/`pos_abs` advance `(85,85)→(85,86)`).
- **Viewer** → exit `0`: `exports=3 pass=3 fail=0 … monsters_off_window=0`.
- **Radius-60 proof probe** (throwaway, reverted) → **7** monsters in window, **off-window == 0**, types
  `mon_groundhog` / `mon_dog` / `mon_fish_lbass`. Example object:
  `{"index":0,"type_id":"mon_groundhog","name":"groundhog","symbol":"r","pos_local":[66,30,0],`
  `"pos_abs":[6282,6366,0],"hp":12,"hp_max":12,"moves":-60,"hallucination":false}`. The viewer renders
  all 7 as red `cell … monster` glyphs with `monster=…` tooltips and exits `0`.

### Movement test

`export → move_s → export` is a clean radius-12 movement test: the avatar moves `(85,85)→(85,86)`, the
`entities.monsters[]` array stays present + empty (the 14 monsters remain ≥31 tiles away), and the
window-equivalence invariant holds (`off-window == 0`) before and after the move.

Driving the avatar the full ~31 tiles to force `count > 0` at radius 12 was **not** achieved: the avatar
is boxed in the shelter (walls, a **boarded** door `t_door_b` beside the openable `t_door_c`, windows,
furniture) and sustained movement toward the monsters stalls at the movement-command layer (`move_n` was
a no-op from the spawn even with `SAFEMODE` disabled). That is a Spike-3.1A movement / engine concern,
**orthogonal to this read-only export**, and reaching a monster needs interactions this spike does not
add (door-opening, safe-mode toggle, pathing).

So the dynamic behaviour was instead confirmed with the same **temporary radius-60 probe** (the shipped
radius stays **12**): a 10-step `move_s`/`move_e`/`wait` session exported after every step. As the world
ticked (`backend.turn` 1324801 → 1324811) and the avatar walked `pos_abs [6301,6421] → [6302,6425]`, the
monsters **update** turn-to-turn — the dogs wander (`6267,6481 → 6265,6484`), the groundhogs shuffle, and
the `mon_fish_lbass` stays fixed at `6332,6397` (it is in water — faithful). The in-window set changes as
they roam in and out (`count` 7 → 8 → … → 6), and `pos_local`/`pos_abs` track every step. The viewer
consumes all 12 frames at exit `0` (`exports=12 pass=12 … monsters_off_window=0`, 93 monster cells
rendered) — the window-equivalence invariant holds on every frame. This is the definitive proof that the
export reflects live monster movement; the shipped radius-12 snapshot shows the same behaviour whenever a
monster is within the engine's normal view window.

## Citation audit

| Claim                                                      | Implementing line(s) / evidence                                                             | Verdict                              |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------ |
| Monsters come from the authoritative raw list              | `write_entities` iterates `g->all_monsters()` (src/arcopolis_export.cpp)                    | ✅ (incl. hallucinations by design)  |
| Same window predicate as `tiles[]` (every mon on a tile)   | `mp.z()==center.z()`, `center ± ctx.radius`, `ctx.m.inbounds(mp)` — mirrors `write_tiles`   | ✅ e2e `off-window == 0` (r12 & r60) |
| All 10 fields exported, values authentic                   | r60 probe object: index/type_id/name/symbol/pos_local/pos_abs/hp/hp_max/moves/hallucination | ✅ e2e (7 monsters, sane values)     |
| Empty at r12 is fixture placement, not a defect            | diagnostic `total=14 nearest_cheby=31`; 7 emit at r60                                       | ✅ proven                            |
| Export reflects live monster movement                      | r60 move/wait session: `turn 1324801→1324811`, monsters wander, `count` 7→…→6, invariant ok | ✅ e2e (12 frames, viewer exit 0)    |
| Viewer renders + lists monsters, asserts the invariant     | `render_map_html` overlay + `verify_monsters_in_window` → `monsters_off_window` gates exit  | ✅ (r60 report: 7 red cells, exit 0) |
| Viewer backward-compatible with pre-Spike-6 snapshots      | `dig(data,"entities.monsters")` → `None` ⇒ no-op (smoke-tested)                             | ✅                                   |
| Additive: no `schema_version` bump, no engine-system edits | snapshot `schema_version` unchanged; only `arcopolis_export.cpp` + viewer + docs            | ✅                                   |
