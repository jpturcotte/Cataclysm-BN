# Spike 0 — Headless Current-View Export

> Scope: the **first implementation** in the Arcopolis investigation (everything prior was
> documentation-only). Adds a headless command-line mode to Cataclysm: Bright Nights (BN) that loads a
> prepared world/save and writes a small, **read-only** "current view" JSON snapshot, then exits — no
> main menu, no gameplay loop, no player-facing UI. Builds on
> [00_WINDOWS_LOCAL_ENVIRONMENT.md](00_WINDOWS_LOCAL_ENVIRONMENT.md),
> [01_STARTUP_AND_CLI.md](01_STARTUP_AND_CLI.md), and
> [02_HEADLESS_WORLD_AND_STATE.md](02_HEADLESS_WORLD_AND_STATE.md); it implements the read-only view
> export that doc 02 recommended as **"Spike 0 = Option A"** (load an existing prepared save via the
> already-headless-safe `game::load(world)` and serialise the read-only accessors).
>
> **Status: implemented and verified end-to-end** on Windows (MSVC + Ninja + ccache) against a prepared
> `ArcopolisTest` save — it builds, loads headlessly, writes a valid 625-tile snapshot, and exits `0`.
> Verified at commit `b10bd5939a` plus the uncommitted Spike 0 changes. (The binary reports
> `8fa4dfe077-dirty` because `game_version` comes from a build-time `version.h`, which can lag HEAD.)
>
> Line numbers below were read directly from the current source; they drift as the code evolves —
> re-run the PowerShell checks in the final section against a newer commit.

## Summary

Spike 0 proves the Arcopolis backend boundary in the smallest possible way: BN can be driven as a
headless authoritative simulation that loads a known state and emits a render-ready, read-only view for
an external frontend, without touching any BN UI screen.

It adds one CLI flag:

```
--arcopolis-export-current-view <output_path>
```

which, paired with `--world <name>`, loads that world's first save through BN's existing no-menu
loader, walks a set of read-only accessors, and writes a JSON snapshot (avatar state, a square tile
window around the avatar, map bounds, recent messages, diagnostics) to `<output_path>`, then exits.

This is explicitly **not** a frontend, **not** a live protocol, **not** world generation, and **not** UI
modernization. JSON is only the first debug/bootstrap snapshot format, not the final runtime protocol.

## Why this matters for Arcopolis

The target architecture keeps BN authoritative for simulation, save/load, rules, and content, while a
separate graphical, mouse-first frontend sends high-level commands and receives snapshots/deltas/events
and **never mutates simulation state directly**. Three capabilities are needed, in order:

1. **Deterministic state loading** — put the sim into a known state with no menus/human input.
2. **Read-only state export** — serialise a "current view" the frontend can render.
3. **Command execution** — later: accept commands, validate, apply, return deltas.

Spike 0 delivers (1) and (2) at minimal scope by reusing the most battle-tested BN path. The "frontend
never mutates state" invariant is preserved structurally: the exporter only ever **reads** accessors.

## The flag

| Property                  | Behavior                                                                                         |
| ------------------------- | ------------------------------------------------------------------------------------------------ |
| Flag                      | `--arcopolis-export-current-view <output_path>` (first-pass `arg_handler`)                       |
| Side effects              | Sets the global `test_mode = true` (skips window/SDL init) and stores `<output_path>`            |
| Requires                  | `--world <name>` (the prepared world to load); for Spike 0 a save must already exist             |
| On success                | Writes the JSON snapshot to `<output_path>`, exits `0`                                           |
| Missing `--world`         | Prints `arcopolis: --arcopolis-export-current-view requires --world <name>` to stderr, exits `1` |
| World not found / no save | Prints `arcopolis: failed to load world '<name>'` to stderr, exits `1`                           |
| Write failure             | Prints `arcopolis: failed to write snapshot to '<path>'` to stderr, exits `1`                    |
| Never                     | Enters the main menu or `do_turn` loop; initializes the player-facing UI                         |

Example (Windows, from the repo root so `data/`+`gfx/` resolve; `--userdir` sandboxes it):

```powershell
.\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe --world ArcopolisTest --arcopolis-export-current-view .\out\arcopolis_state.json --userdir .\arcopolis_user
```

## Files changed

| File                       | Change                                                                                            |
| -------------------------- | ------------------------------------------------------------------------------------------------- |
| `src/arcopolis_export.h`   | **new** — `arcopolis::export_current_view_options` struct + the `export_current_view` entry point |
| `src/arcopolis_export.cpp` | **new** (~180 lines) — headless world load + read-only `JsonOut` snapshot writer                  |
| `src/main.cpp`             | **modified** (+27/−1) — include, output-path local, `arg_handler`, headless branch                |
| `.gitignore`               | **modified** — ignore the `--userdir` sandbox `arcopolis_user/`                                   |

No build-system edit: `src/CMakeLists.txt` globs `src/*.cpp` with `CONFIGURE_DEPENDS`, so the new `.cpp`
is picked up automatically. **No new third-party dependency** — the snapshot uses the in-tree `JsonOut`
(`src/json.h`) via `write_to_file` (`src/fstream_utils.h`).

### main.cpp wiring (current line numbers)

- `#include "arcopolis_export.h"` — [src/main.cpp:25](../../src/main.cpp)
- `std::filesystem::path arcopolis_export_path;` local — [src/main.cpp:203](../../src/main.cpp)
- `first_pass_arguments` grown to `std::array<arg_handler, 16>` — [src/main.cpp:243](../../src/main.cpp)
  (the count is derived via `sizeof`, so a miscount is a compile error)
- The flag's `arg_handler` (mirrors `--lua-doc`: sets `test_mode`, stores the path) —
  [src/main.cpp:452](../../src/main.cpp)–464
- The headless branch, inside the `load_static_data()` try-block at
  [src/main.cpp:768](../../src/main.cpp), placed **after** the `check_mods` branch and **before**
  `game_ui::init_ui()` ([src/main.cpp:803](../../src/main.cpp)) — [src/main.cpp:786](../../src/main.cpp):

```cpp
if( !arcopolis_export_path.empty() ) {
    // ... terminate with std::_Exit (see "exit teardown" below) ...
    std::_Exit( arcopolis::export_current_view( {
        .world = world,
        .output_path = arcopolis_export_path.string()
    } ) );
}
```

`main.cpp` only parses the flag and delegates; all orchestration (validate world → `g->load(world)` →
export → return an exit code) lives in `arcopolis::export_current_view`.

### Call path

```
main() [src/main.cpp:786]
  └─ arcopolis::export_current_view(opts)         [src/arcopolis_export.cpp]
       ├─ g->load( opts.world )                   [src/game.cpp:3214 -> save_t overload 3240]
       │    └─ setup() -> load_world_modfiles -> finalize -> unserialize ->
       │       update_map(u) -> build_map_cache + update_visibility_cache  (avatar-centred, caches built)
       └─ write_to_file( opts.output_path, [&]( std::ostream & ){ write_snapshot(...) } )  [src/fstream_utils.h:117]
```

## Snapshot schema (schema_version 1)

```jsonc
{
  "schema_version": 1,
  "backend":  { "game_version": "<getVersionString()>", "save_version": <savegame_version> },
  "avatar": {
    "name": "...",
    "pos_local": [x, y, z],   // tripoint_bub_ms  (reality-bubble milestone coords)
    "pos_abs":   [x, y, z],   // tripoint_abs_ms  (absolute milestone coords)
    "z": 0,                    // game::get_levz()
    "hp": 0, "hp_max": 0,      // summed across body parts
    "stamina": 0, "pain": 0, "thirst": 0, "fatigue": 0,
    "stored_kcal": 0, "kcal_percent": 0.0
  },
  "map_bounds": {
    "origin_abs_sm": [x, y, z],   // tripoint_abs_sm  (absolute submap coords); map::get_abs_sub()
    "size_x": 0, "size_y": 0,     // loaded bubble width in ms tiles = map::getmapsize() * SEEX
    "z": 0
  },
  "tiles": [
    // one entry per tile in a clamped square window of radius 12 around the avatar (single z-level).
    // x/y/z are tripoint_bub_ms.
    { "x": 0, "y": 0, "z": 0, "ter": "t_floor", "furn": "f_null", "seen": true }
  ],
  "messages": [ { "text": "...", "type": "" } ],   // see "message type" limitation below
  "diagnostics": { "warnings": [] }
}
```

### Coordinate systems (explicit)

| Field                               | Source accessor                         | Coordinate type                              |
| ----------------------------------- | --------------------------------------- | -------------------------------------------- |
| `avatar.pos_local`, `tiles[].x/y/z` | `avatar::bub_pos()`, `points_in_radius` | `tripoint_bub_ms` — reality-bubble milestone |
| `avatar.pos_abs`                    | `avatar::abs_pos()`                     | `tripoint_abs_ms` — absolute milestone       |
| `map_bounds.origin_abs_sm`          | `map::get_abs_sub()`                    | `tripoint_abs_sm` — absolute submap          |

The three systems are labelled at each use site in `src/arcopolis_export.cpp`; they are never mixed
silently. `.x()/.y()/.z()` return `int`.

### Read-only accessors used (all verified)

| Datum                        | Accessor                                                       | File:line                                                                                  |
| ---------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Build version                | `getVersionString()`                                           | [src/get_version.h:2](../../src/get_version.h)                                             |
| Save-format version          | `extern const int savegame_version`                            | [src/game.h:64](../../src/game.h)                                                          |
| Avatar / map handles         | `get_avatar()`, `get_map()`                                    | [src/avatar.h:341](../../src/avatar.h), [src/map.h:2442](../../src/map.h)                  |
| Avatar name                  | `Character::get_name()`                                        | [src/character.h](../../src/character.h)                                                   |
| Position (bubble / absolute) | `bub_pos()`, `abs_pos()`                                       | [src/character.h:453](../../src/character.h)–454                                           |
| Z-level                      | `game::get_levz()`                                             | [src/game.h:753](../../src/game.h)                                                         |
| HP                           | `get_hp()`, `get_hp_max()`                                     | [src/creature.h:619](../../src/creature.h)–622                                             |
| Status getters               | `get_stamina/pain/thirst/fatigue/stored_kcal/get_kcal_percent` | [src/character.h](../../src/character.h)                                                   |
| Terrain / furniture          | `map::ter()`, `map::furn()` (→ `.id().str()`)                  | [src/map.h:977](../../src/map.h)/952                                                       |
| Visibility                   | `map::pl_sees( p, range )` (Chebyshev `square_dist`)           | [src/map.h:1856](../../src/map.h) → [src/lightmap.cpp:1112](../../src/lightmap.cpp)        |
| Bounds checking              | `map::inbounds( tripoint_bub_ms )`                             | [src/map.h:1890](../../src/map.h)                                                          |
| Bubble size                  | `map::getmapsize() * SEEX`                                     | [src/map.h:1905](../../src/map.h), [src/game_constants.h:39](../../src/game_constants.h)   |
| Submap origin                | `map::get_abs_sub()`                                           | [src/map.h:1866](../../src/map.h)                                                          |
| Tile window                  | `points_in_radius( center, radius )` (a C++20 view)            | [src/map_iterator.h:126](../../src/map_iterator.h)                                         |
| Recent messages              | `Messages::recent_messages( n )` → `(time_of_day, text)`       | [src/messages.h:25](../../src/messages.h) → [src/messages.cpp:250](../../src/messages.cpp) |
| JSON / IO                    | `JsonOut`, `write_to_file`                                     | [src/json.h:644](../../src/json.h), [src/fstream_utils.h:117](../../src/fstream_utils.h)   |

## Key design decisions & gotchas (verified during implementation)

1. **Headless placement — before `game_ui::init_ui()`.** Under TILES, `game_ui::init_ui()`
   ([src/game.cpp:468](../../src/game.cpp)) calls `get_terminal_width()/height()`, which query the SDL
   window that `test_mode` never creates — so calling it headless is unsafe. The existing headless flags
   (`--jsonverify`/`--dump-stats`/`--check-mods`) all exit before it for this reason; the Arcopolis
   branch goes in the same `load_static_data()` try-block, after `check_mods` and before `init_ui()`.

2. **Reuse `game::load(world)`.** It loads the world's first save through the `save_t` overload, which is
   the only path that produces a coherent, render-ready view (avatar-centred bubble + built
   light/visibility caches) and is already headless-safe (its "Loading the save…" popup is gated on
   `if( !test_mode )`, [src/game.cpp:3244](../../src/game.cpp)). `game::setup()`'s `loading_ui ui( true )`
   is inert under `test_mode` (the `loading_ui` ctor only builds its menu `if( display && !test_mode )`,
   [src/loading_ui.cpp:465](../../src/loading_ui.cpp)).

3. **Exit teardown → `std::_Exit`.** A normal `exit()` after a _full_ `game::load(world)` corrupts the
   heap (Windows `0xC0000374` STATUS_HEAP_CORRUPTION) while running BN's global/static destructors — the
   engine never tears a fully-loaded game down via raw `exit()` (the Catch2 test binary uses
   `g.reset()` + `DynamicDataLoader::unload_data()` instead). The existing headless flags `exit()` _before_
   loading a world, so they never hit it; Spike 0 is the first to `exit()` after a full save load. Fix:
   after the snapshot is flushed to disk, terminate with **`std::_Exit(code)`**, skipping the fragile
   teardown. **Any future headless one-shot that loads a world must do the same.**

4. **Tile window — radius-12 square, clamped.** `points_in_radius` yields a Chebyshev square at the
   avatar's z; tiles failing `map::inbounds()` are skipped (clamps the window to the loaded bubble). The
   `seen` flag uses `map::pl_sees( p, radius )`; because `pl_sees` range-checks with `square_dist`
   (Chebyshev), passing `radius` rejects nothing by range, so real light/LOS decides visibility (the
   caches are built by `game::load`). `map_bounds` describes the _full_ loaded bubble; `tiles` is the
   exported subset — intentional.

5. **`messages[].type` is intentionally blank.** `Messages::recent_messages` exposes only
   `(time_of_day, text)`, not severity ([src/messages.cpp:250](../../src/messages.cpp)). The exporter sets
   `text` from the pair and leaves `type` empty, recording a `diagnostics.warnings` note rather than
   mislabeling the timestamp. Exposing real severity would need a small gameplay-source accessor (out of
   Spike 0 scope).

## Building

Use the proven ccache Ninja route from
[00_WINDOWS_LOCAL_ENVIRONMENT.md](00_WINDOWS_LOCAL_ENVIRONMENT.md) (VS 2022 DevShell + MSVC + Ninja +
vcpkg short-roots under `C:\tmp`; build dir `out/build/win-rel-deb`; exe
`out/build/win-rel-deb/src/cataclysm-bn-tiles.exe`). After DevShell activation:

```powershell
cmake --build .\out\build\win-rel-deb --target cataclysm-bn-tiles -- -j4
```

The build's post-step runs `docs:gen` / `deno fmt`, which dirties some tracked docs (e.g.
`cli_options.md`) — revert that churn after building (`git checkout -- docs .claude`).

## Creating a prepared save (one-time)

There is no headless "create save" in the game binary yet (that is a later spike), so a save is made
once through the **graphical** client, then read headlessly by the export. Launch from the repo root so
`data/`+`gfx/` resolve, point `--userdir` at a sandbox, create a character via **New Game → Play Now!**,
take one step, then **Save & Quit**. Saves land in `<userdir>/save/<WorldName>/`; the `--world` argument
must match that folder name.

> **Renderer gotcha (graphical client only).** BN's default `RENDERER=direct3d11` crashes on the loading
> screen during finalize (`loading_ui::show` → SDL3 `SetRenderTarget` access violation — a known SDL3
> D3D11 bug, libsdl-org/SDL [#9861](https://github.com/libsdl-org/SDL/issues/9861) /
> [#14733](https://github.com/libsdl-org/SDL/issues/14733)). Set `RENDERER` to `opengl` (or `software`) in
> `<userdir>/config/options.json` before creating the save. **The headless export is immune** —
> `test_mode` means `loading_ui` has no menu and `show()` never renders.

## Running & validation

The tiles exe is a **GUI-subsystem (WinMain)** binary, so PowerShell's `&` neither waits on it nor
captures stdout/stderr/exit code reliably. Use `Start-Process -Wait -PassThru -RedirectStandard*`:

```powershell
$exe = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe"
New-Item -ItemType Directory -Force .\out | Out-Null
$p = Start-Process -FilePath $exe -ArgumentList @(
    '--world','ArcopolisTest',
    '--arcopolis-export-current-view','.\out\arcopolis_state.json',
    '--userdir','.\arcopolis_user'
) -NoNewWindow -Wait -PassThru -RedirectStandardError C:\tmp\err.txt -RedirectStandardOutput C:\tmp\out.txt
"exit=$($p.ExitCode)"                                  # 0 on success
(Get-Content .\out\arcopolis_state.json -Raw | ConvertFrom-Json).tiles.Count   # 625
```

`--help` lists the flag and exits before any load (no save needed):

```powershell
& ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe" --help | Select-String "arcopolis"
```

### Verified result (prepared `ArcopolisTest` save, exit 0)

```jsonc
"backend":  { "game_version": "8fa4dfe077-dirty (2026-05-29)", "save_version": 29 },
"avatar":   { "name": "Nubia 'Single' Rosales", "pos_local": [85,85,0], "pos_abs": [6301,6421,0],
              "z": 0, "hp": 1080, "hp_max": 1080, "stamina": 10000, "pain": 0, "thirst": 1,
              "fatigue": 1, "stored_kcal": 17391, "kcal_percent": 0.993771 },
"map_bounds": { "origin_abs_sm": [518,528,0], "size_x": 180, "size_y": 180, "z": 0 },
// tiles: 625 (25x25 radius-12 window), 101 currently visible (seen=true); avatar's own
//        tile (85,85) = t_floor / seen:true. Terrain reads a coherent evac-shelter scene:
//        t_floor/t_wall_w/t_window_frame/t_door_locked_interior/t_stairs_down/t_console_broken
//        ringed by t_grass/t_pavement/t_sidewalk.
// messages: 3 real spawn messages (text populated, type "").
// diagnostics.warnings: 1 note (message type not exposed by recent_messages).
```

(Here `size_x/y = 180` because this world's loaded bubble is `getmapsize()*SEEX = 15*12`.)

## Formatting

`src/*.cpp` top-level files are formatted with **AStyle** per `.astylerc` (1tbs, 4-space,
`align-pointer=name`, `max-code-length=100`). BN does not pin a version — CI
(`.github/workflows/autofix.yml`) installs the distro `apt` package (astyle **3.1–3.4.x**) and runs
`cmake --build build --target format`. **AStyle 3.6.x mis-parses this codebase's designated initializers
and trailing-return lambdas and corrupts indentation — do not use it.** Running AStyle **3.1** over the
Spike 0 files reports them all _Unchanged_ (the code already conforms).

## Acceptance criteria → coverage

| Criterion                                           | Status                                                    |
| --------------------------------------------------- | --------------------------------------------------------- |
| Flag recognized by the binary                       | ✅ appears in `--help`; handled in `first_pass_arguments` |
| Sets `test_mode`                                    | ✅ in the handler                                         |
| Requires `--world` for this spike                   | ✅ guarded; clear error + exit 1 otherwise                |
| Loads the prepared world/save headlessly            | ✅ via `game::load(world)` (no window)                    |
| Writes a JSON file                                  | ✅ `JsonOut` + `write_to_file`; valid 625-tile snapshot   |
| Exits instead of menu/gameplay                      | ✅ `std::_Exit` before `init_ui` / `do_turn`              |
| No GUI modernization, no live protocol, no new deps | ✅                                                        |

## Risks & limitations

- **Save must pre-exist.** Spike 0 loads a prepared save only; it does not generate worlds.
- **`game_version` can lag HEAD** — it comes from a build-time `version.h`; rebuild to refresh.
- **`messages[].type` is blank** (public API limit) — see decision 5.
- **One-shot only.** A long-lived backend (repeated load/unload, clean teardown of the global `g`,
  re-entrancy) is unexamined; Spike 0 always loads once and `std::_Exit`s.
- **`tiles` is emitted on one line** (valid JSON; `start_array` without wrap). Switching to a wrapped
  array is a one-line change if per-tile readability is wanted.

## Next steps

- **Spike 1** — a no-save fixture world: adopt the Catch2 bootstrap (`init_global_game_state`,
  [tests/test_main.cpp:99](../../tests/test_main.cpp)) as a blueprint in the game binary, adding the
  missing `update_map` + cache-build steps to reach a coherent view without a save.
- **Spike 2** — deterministic fixtures from a JSON spec + fixed RNG seed.
- **Later** — capability (3): high-level command validation/application and `do_turn` advancement
  (`05_ACTIONS_COMMANDS_AND_TURN_ADVANCE.md`), and growing the snapshot (actors, items, larger-than-bubble
  map views) toward a real runtime protocol with deltas.

## PowerShell local checks

Run from the repo root to re-verify the wiring cited above:

```powershell
# Flag wiring in main.cpp
Select-String -Path .\src\main.cpp -Pattern 'arcopolis|std::_Exit|std::array<arg_handler'

# The new files
Get-ChildItem .\src\arcopolis_export.h, .\src\arcopolis_export.cpp

# Headless landmarks (branch must sit before init_ui)
Select-String -Path .\src\main.cpp -Pattern 'load_static_data|arcopolis_export_path|game_ui::init_ui'

# Build + smoke-test the flag (after DevShell activation; see doc 00)
cmake --build .\out\build\win-rel-deb --target cataclysm-bn-tiles -- -j4
& ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe" --help | Select-String "arcopolis"
```
