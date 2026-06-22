# Startup and CLI Exploration

> Scope: read-only investigation of Cataclysm: Bright Nights (BN) startup and command-line
> infrastructure, to assess whether BN can later host an "Arcopolis" backend/export mode that runs
> **without** the normal BN player UI. No source or build files were changed to produce this document.
>
> Confidence legend: **high** = read directly from the file during this investigation;
> **medium** = located but exact line not personally re-opened (verify with the PowerShell checks below);
> **low** = inferred, needs inspection.
>
> **Validation status:** the `file:line` references below were last confirmed 2026-05-29 and have
> **SINCE DRIFTED** as upstream evolved (notably `src/main.cpp` grew ~90 lines near the top — the
> first-pass arg array is now `arg_handler, 22` at `src/main.cpp:284`, not `, 15` at `:241`). **Treat
> every line number here as approximate; cite/verify by SYMBOL NAME, and re-run the PowerShell checks in
> the final section against the current commit before relying on a number.** (2026-06-22 audit: the
> per-flag tables and load-sequence cites in this doc are stale; the conceptual flow remains accurate.)

## Summary

Yes — BN already has substantial command-line and noninteractive infrastructure that Arcopolis can
build on, and it does **not** require touching the player-facing UI screens.

Key facts (all **high** confidence, read directly):

- There is a single program entry point in [src/main.cpp](../../src/main.cpp) with a hand-rolled
  command-line parser (a `struct arg_handler` table, not getopt).
- A global flag `test_mode` ([src/cached_options.cpp:5](../../src/cached_options.cpp)) gates the
  creation of the actual terminal/SDL window: `catacurses::init_interface()` is only called
  `if( !test_mode )` ([src/main.cpp:724](../../src/main.cpp)). Several existing flags set `test_mode`
  and then do real work and exit — i.e. they run **headless**.
- Existing headless modes: `--jsonverify`, `--check-mods`, `--dump-stats`, `--lua-doc`, `--lua-types`.
  These validate JSON, validate mods, export item/recipe/vehicle stats (TSV/HTML), and generate Lua
  docs/types — all without entering the main menu or game loop.
- A world can be loaded **directly from the command line** with `--world <name>`, bypassing the main
  menu ([src/main.cpp:820](../../src/main.cpp)–832, [src/game.cpp:3214](../../src/game.cpp)).
- The Catch2 **test binary** ([tests/test_main.cpp](../../tests/test_main.cpp)) demonstrates a complete
  headless bring-up of game + world + map + avatar with **no UI window** — this is the cleanest model
  for an Arcopolis fixture loader.

Conclusion: Arcopolis-style flags (e.g. `--arcopolis-run-fixture`, `--arcopolis-export-current-view`)
can be added later as new `arg_handler` entries that set `test_mode` and branch into a headless work
path, mirroring the existing `--check-mods`/`--dump-stats` pattern exactly. No GUI automation is needed.

## Why this matters for Arcopolis

The Arcopolis architecture under investigation keeps BN authoritative for simulation, rules, save/load,
world state, and content loading, while a separate graphical, mouse-first frontend sends high-level
commands and receives snapshots/deltas/events. The frontend must never mutate simulation state directly.

For that to work without bridging BN's existing UI screens one-by-one, we need a way to:

1. **Boot BN without its terminal/SDL UI** (headless), so the simulation can run under a different
   front end or be driven programmatically.
2. **Load a known world/fixture deterministically** (no menus, no human input), so the frontend or a
   test rig can put the simulation into a precise state.
3. **Export/serialize state on demand** ("current view"), so the frontend can render it.
4. Do all of the above with **deterministic exit codes** and **isolated data paths**, so runs don't
   pollute a user's real save directory.

This document maps which of those capabilities already exist and where the cleanest extension points
are. The good news: (1), (2), and (4) already have working precedents in the codebase; (3) is the only
genuinely new piece.

## Files inspected

- [src/main.cpp](../../src/main.cpp) — entry point, CLI parser, every flag, headless branches, main
  loop. **Read in full (lines 1–899).**
- [tests/test_main.cpp](../../tests/test_main.cpp) — test-binary entry and headless world bootstrap
  `init_global_game_state`. **Read lines ~80–210.**
- [src/path_info.h](../../src/path_info.h) — `PATH_INFO` namespace: path init, accessors, setters.
  **Read in full.**
- [src/game.cpp](../../src/game.cpp) — `game::load(world)`, `game::load(save_t)`, `load_static_data`.
  **Read lines 3214–3258 + grep-confirmed signatures.**
- [src/cached_options.cpp](../../src/cached_options.cpp) / [src/cached_options.h](../../src/cached_options.h)
  — definition/extern of the `test_mode` global. **Grep-confirmed.**
- [src/cursesdef.h](../../src/cursesdef.h) — `catacurses::init_interface()` declaration. **Grep-confirmed.**
- [src/ncurses_def.cpp](../../src/ncurses_def.cpp), [src/sdltiles.cpp](../../src/sdltiles.cpp),
  [src/wincurse.cpp](../../src/wincurse.cpp) — platform `init_interface()` implementations. **Grep-confirmed.**
- [src/game_ui.h](../../src/game_ui.h) — `game_ui::init_ui()` declaration. **Grep-confirmed.**
- [src/init.h](../../src/init.h) / [src/init.cpp](../../src/init.cpp) — `DynamicDataLoader`,
  `init::check_mods_for_errors`. **All line numbers PowerShell-verified.**
- [src/dump.cpp](../../src/dump.cpp) — `game::dump_stats`. **PowerShell-verified.**
- [src/options.cpp](../../src/options.cpp) — `options_manager::load()`. **PowerShell-verified.**
- [src/filesystem.cpp](../../src/filesystem.cpp) — `get_files_from_path()` JSON discovery.
  **PowerShell-verified.**

## Entry point

| Entry                                         | Location                                             | Notes                                                                        | Confidence |
| --------------------------------------------- | ---------------------------------------------------- | ---------------------------------------------------------------------------- | ---------- |
| `int main( int argc, char *argv[] )`          | [src/main.cpp:193](../../src/main.cpp)               | Default (Linux/macOS, and Windows non-`USE_WINMAIN`).                        | high       |
| `int APIENTRY WinMain(...)`                   | [src/main.cpp:185](../../src/main.cpp)               | Windows GUI subsystem build (`USE_WINMAIN`); reads `__argc`/`__argv`.        | high       |
| `extern "C" int SDL_main(...)`                | [src/main.cpp:191](../../src/main.cpp)               | Android (`__ANDROID__`).                                                     | high       |
| Shared body begins                            | [src/main.cpp:195](../../src/main.cpp)               | All three converge on one body; first call is `init_crash_handlers()` (196). | high       |
| Test binary `int main( int, const char* [] )` | [tests/test_main.cpp:268](../../tests/test_main.cpp) | Catch2 runner; separate program with its own arg handling.                   | high       |

On Windows, whether `WinMain` or `main` is used depends on the `USE_WINMAIN` build flag (tiles/console
subsystem). Both reach the same body.

## Command-line parsing

BN uses a **custom, table-driven parser** — no `getopt`/`getopt_long`, no third-party arg library.

- `struct arg_handler` ([src/main.cpp:166](../../src/main.cpp)): fields `flag`, `param_documentation`,
  `documentation`, `help_group`, and a `handler` lambda
  `std::function<int( int, const char** )>`. The handler returns how many parameters it consumed, or
  `-1` for a missing required argument. **(high)**
- **Two passes**, because some flags depend on earlier ones:
  - `first_pass_arguments` — `std::array<arg_handler, 22>` at [src/main.cpp:284](../../src/main.cpp) (was `, 15` at `:241` when written; upstream + the Arcopolis flags grew it — see AGENTS.md on the `<arg_handler, N>` sync gotcha). **(high)**
  - `second_pass_arguments` — `std::array<arg_handler, 8>` at [src/main.cpp:454](../../src/main.cpp). **(high)**
- **First-pass dispatch loop**: [src/main.cpp:566](../../src/main.cpp). `--help` (567), `--version`
  (571), and `--paths` (574) are matched inline before the table loop; unknown args are skipped (597). **(high)**
- **Second-pass dispatch loop**: [src/main.cpp:603](../../src/main.cpp); unknown args ignored (622). **(high)**
- `--paths` output is emitted after both passes (`resolved_game_paths()`) then the program exits —
  [src/main.cpp:627](../../src/main.cpp). **(high)**
- `printHelpMessage()` ([src/main.cpp:845](../../src/main.cpp)) groups handlers by `help_group` and
  prints them. **(high)**

Path-affecting flags are split deliberately: `--basepath`/`--userdir` are first-pass (they re-run path
setup), while `--datadir`/`--savedir`/`--configdir`/etc. are second-pass (they depend on base/user dirs).

## Existing flags

All line numbers below are **high** confidence (read directly from [src/main.cpp](../../src/main.cpp)).

**First pass** (declared [src/main.cpp:241](../../src/main.cpp)–449):

| Flag              | Param                       | Effect                                                            | Line | Headless?        |
| ----------------- | --------------------------- | ----------------------------------------------------------------- | ---- | ---------------- |
| `--seed`          | `<string>`                  | Hashes string to RNG seed (`djb2_hash`).                          | 243  | no               |
| `--jsonverify`    | —                           | Sets `test_mode` + `verifyexit`; verifies JSON then exits.        | 257  | **yes**          |
| `--check-mods`    | `[mods…]`                   | Sets `test_mode` + `check_mods`; validates mod JSON then exits.   | 267  | **yes**          |
| `--dump-stats`    | `<what> [mode=TSV] [opts…]` | Sets `test_mode`; dumps stats (TSV/HTML) then exits.              | 281  | **yes**          |
| `--world`         | `<name>`                    | Stores world name; first save in that world is loaded on startup. | 311  | no (enters game) |
| `--basepath`      | `<path>`                    | `init_base_path()` + `set_standard_filenames()`.                  | 324  | no               |
| `--shared`        | —                           | Enables map-sharing mode.                                         | 338  | no               |
| `--username`      | `<name>`                    | Map-sharing username.                                             | 349  | no               |
| `--addadmin`      | `<username>`                | Map-sharing admin (cheat access).                                 | 362  | no               |
| `--adddebugger`   | `<username>`                | Map-sharing: running under a debugger.                            | 376  | no               |
| `--competitive`   | —                           | Map-sharing: disable in-game cheats.                              | 389  | no               |
| `--userdir`       | `<path>`                    | `init_user_dir()` + `set_standard_filenames()`.                   | 398  | no               |
| `--dont-debugmsg` | —                           | Suppress debug messages (`dont_debugmsg`).                        | 413  | no               |
| `--lua-doc`       | `<output path>`             | Sets `test_mode`; generates Lua docs then `return 0`.             | 422  | **yes**          |
| `--lua-types`     | `<output path>`             | Sets `test_mode`; generates Lua types then `return 0`.            | 436  | **yes**          |

Inline (handled in the dispatch loop, not in the table): `--help` (567), `--version` (571),
`--paths` (574).

**Second pass** (declared [src/main.cpp:454](../../src/main.cpp)–555):

| Flag               | Param        | Effect                             | Line |
| ------------------ | ------------ | ---------------------------------- | ---- |
| `--worldmenu`      | —            | Enables world menu in map-sharing. | 456  |
| `--datadir`        | `<dir>`      | `PATH_INFO::set_datadir()`.        | 465  |
| `--savedir`        | `<dir>`      | `PATH_INFO::set_savedir()`.        | 478  |
| `--configdir`      | `<dir>`      | `PATH_INFO::set_config_dir()`.     | 491  |
| `--memorialdir`    | `<dir>`      | `PATH_INFO::set_memorialdir()`.    | 504  |
| `--optionfile`     | `<filename>` | `PATH_INFO::set_options()`.        | 517  |
| `--autopickupfile` | `<filename>` | `PATH_INFO::set_autopickup()`.     | 530  |
| `--motdfile`       | `<filename>` | `PATH_INFO::set_motd()`.           | 543  |

**Coverage of the requested flag categories:** world name ✅ `--world`; user dir ✅ `--userdir`;
save dir ✅ `--savedir`; base path ✅ `--basepath`; config path ✅ `--configdir`; data path ✅
`--datadir`; JSON verification ✅ `--jsonverify`; mod checking ✅ `--check-mods`; dumping stats ✅
`--dump-stats`; Lua/doc generation ✅ `--lua-doc` / `--lua-types`; test mode ✅ (the `test_mode`
global, set by the headless flags above). There is **no** dedicated `--test` flag and **no** generic
"load save file directly" flag beyond `--world`.

## Noninteractive or test-like modes

The pivotal mechanism is the `test_mode` global ([src/cached_options.cpp:5](../../src/cached_options.cpp),
extern in [src/cached_options.h:12](../../src/cached_options.h), default `false`) — **high**. When set,
the terminal/SDL window is never created:

```
// src/main.cpp:723-736
// in test mode don't initialize curses to avoid escape sequences ...
if( !test_mode ) {
    ...
    catacurses::init_interface();   // line 729
    ...
}
```

Existing flows that do useful work without the normal UI (all **high** confidence — the calls are read
directly in [src/main.cpp](../../src/main.cpp)):

| Mode                        | Where it runs                                         | What it does                                                                   | Implementation                                                                       |
| --------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------ |
| `--jsonverify`              | [src/main.cpp:753](../../src/main.cpp) (`verifyexit`) | Loads static data, then `exit_handler(0)`.                                     | `game::load_static_data` [src/game.cpp:440](../../src/game.cpp)                      |
| `--dump-stats`              | [src/main.cpp:756](../../src/main.cpp)                | `init_colors()` + `g->dump_stats(...)`, then `exit()`.                         | `game::dump_stats` [src/dump.cpp:36](../../src/dump.cpp)                             |
| `--check-mods`              | [src/main.cpp:760](../../src/main.cpp)                | `loading_ui ui(false)` + `init::check_mods_for_errors(...)`, then `exit(0/1)`. | decl [src/init.h:219](../../src/init.h), def [src/init.cpp:1009](../../src/init.cpp) |
| `--lua-doc` / `--lua-types` | [src/main.cpp:792](../../src/main.cpp)–815            | `cata::generate_lua_docs(...)`, then `return 0`.                               | `cata::generate_lua_docs` (catalua.*)                                                |

Important sequencing detail (**high**): `--jsonverify`, `--dump-stats`, and `--check-mods` are handled
**before** `game_ui::init_ui()` ([src/main.cpp:777](../../src/main.cpp)), inside the
`load_static_data()` try-block (752–773). The `--lua-doc`/`--lua-types` block runs **after**
`game_ui::init_ui()` (792–815) — but because `test_mode` was set, the _window_ (line 729) was already
skipped, so it is still effectively headless. For a clean headless Arcopolis mode, the
pre-`init_ui()` region (≈752–773) is the better neighbourhood.

The headless work modes use `loading_ui ui( false )` — a non-interactive loading indicator — rather
than interactive curses popups. **(high)**

## Path, userdir, savedir, and config handling

All paths route through `namespace PATH_INFO` (decl [src/path_info.h:7](../../src/path_info.h);
impl `src/path_info.cpp`). **(high)**

Startup order inside `main()` (**high**, read directly):

1. `PATH_INFO::init_base_path(...)` — [src/main.cpp:215/219/221](../../src/main.cpp) (Android / `PREFIX` / default).
2. `PATH_INFO::init_user_dir(...)` — [src/main.cpp:226/229/231](../../src/main.cpp)
   (Android / `USE_HOME_DIR`|`USE_XDG_DIR` / `"."`).
3. `PATH_INFO::set_standard_filenames()` — [src/main.cpp:234](../../src/main.cpp). Derives datadir,
   savedir, config dir, memorial dir, options file, etc.
4. **Then** CLI parsing runs; `--basepath` (332) and `--userdir` (407) re-invoke the above; second-pass
   flags call the targeted setters.

Setters (declared [src/path_info.h:64](../../src/path_info.h)–70): `set_datadir`, `set_config_dir`,
`set_savedir`, `set_memorialdir`, `set_options`, `set_autopickup`, `set_motd`. **(high)**

Accessors (declared [src/path_info.h:13](../../src/path_info.h)–62) include `base_path()`, `datadir()`,
`config_dir()`, `savedir()`, `memorialdir()`, `moddir()`, `user_moddir()`, `templatedir()`,
`worldoptions()`, `options()`, `user_dir()`. **(high)**

Directory validation: the `check_dir_good` lambda ([src/main.cpp:648](../../src/main.cpp)) asserts a
directory exists and is writable; it is applied to user dir, config dir, and save dir at
[src/main.cpp:693](../../src/main.cpp)–695. Missing datadir is a fatal error (635–646). **(high)**

**Why this matters for Arcopolis:** an Arcopolis fixture/export run should set
`--userdir`/`--savedir`/`--configdir` (or `--basepath`) to a throwaway sandbox directory so a fixture
load or export never touches the player's real saves/config. The test binary does exactly this —
it points `init_user_dir` at a temp dir and wipes it first
([tests/test_main.cpp:103](../../tests/test_main.cpp)–112). **(high)**

## Static data loading

- `game::load_static_data()` — [src/game.cpp:440](../../src/game.cpp); called at
  [src/main.cpp:752](../../src/main.cpp). Loads everything independent of the active mods/world. **(high)**
- `class DynamicDataLoader` — declared [src/init.h:56](../../src/init.h). Key methods (PowerShell-verified):
  `load_data_from_path` [src/init.cpp:484](../../src/init.cpp),
  `finalize_loaded_data` [src/init.cpp:665](../../src/init.cpp),
  `check_consistency` [src/init.cpp:752](../../src/init.cpp),
  `unload_data` [src/init.cpp:555](../../src/init.cpp). **(high)** (`load_all_from_json` ~526 not re-checked
  individually — **medium**.)
- Mod loading: `init::load_core_bn_modfiles` [src/init.cpp:979](../../src/init.cpp) for vanilla and
  `init::load_world_modfiles` [src/init.cpp:990](../../src/init.cpp) for a world's active mod order, both
  via the static helper `load_and_finalize_packs` [src/init.cpp:858](../../src/init.cpp). **(high)**
- World/JSON file discovery: `get_files_from_path( ".json", ... )` at
  [src/filesystem.cpp:392](../../src/filesystem.cpp) walks a mod's data directory. **(high)**
- Consistency checking for `--check-mods`: `init::check_mods_for_errors` —
  decl [src/init.h:219](../../src/init.h), def [src/init.cpp:1009](../../src/init.cpp). **(high)**
- Options/config: `options_manager::load()` [src/options.cpp:4347](../../src/options.cpp), called at
  [src/main.cpp:718](../../src/main.cpp) (non-TILES) or 741 (TILES, test_mode). **(high)**

## UI initialization boundary

The boundary between "no window yet" and "window created" is a single call:

- `catacurses::init_interface()` — called [src/main.cpp:729](../../src/main.cpp), guarded by
  `if( !test_mode )` (724). Declared [src/cursesdef.h:40](../../src/cursesdef.h). **(high)**
- Platform implementations (**high**, grep-confirmed):
  - ncurses (console, non-TILES): [src/ncurses_def.cpp:294](../../src/ncurses_def.cpp).
  - SDL (TILES): [src/sdltiles.cpp:3765](../../src/sdltiles.cpp).
  - **Windows console curses: [src/wincurse.cpp:594](../../src/wincurse.cpp)** — the relevant one for a
    Windows console build.
- `game_ui::init_ui()` — [src/main.cpp:777](../../src/main.cpp) (decl [src/game_ui.h:5](../../src/game_ui.h)).
  This runs **even in test_mode**; it sets up UI layout state but not the window. The actual window
  creation skipped under `test_mode` is the `init_interface()` call at 729. **(high)**

So: anything inserted _before_ line 729, or inside a `test_mode` branch, runs with **no window**.

## Main menu versus direct world loading

The post-init main loop ([src/main.cpp:820](../../src/main.cpp)–837) decides between menu and direct
load (**high**, read directly):

```
while( true ) {
    if( !world.empty() ) {
        if( !g->load( world ) ) { break; }   // line 822 — direct load, NO menu
        world.clear();                        // line 825
    } else {
        main_menu menu;                       // line 828
        if( !menu.opening_screen() ) { break; } // line 829 — normal menu
    }
    shared_ptr_fast<ui_adaptor> ui = g->create_or_get_main_ui_adaptor(); // 834
    options_manager::cache_balance_options();  // 835
    while( !g->do_turn() );                     // 836 — gameplay loop
}
```

- **Yes, the menu can be bypassed**: passing `--world <name>` populates the `world` local and the loop
  takes the direct-load branch. **(high)**
- `game::load( const std::string &world )` — [src/game.cpp:3214](../../src/game.cpp): `world_generator->init()`
  → `get_world(name)` → returns `false` if the world is missing or has no saves → `set_active_world` →
  `g->setup()` → `g->load( first_save )`. **(high)**
- `game::load( const save_t & )` — [src/game.cpp:3240](../../src/game.cpp): **already gates its
  "Please wait… Loading the save…" popup on `if( !test_mode )`** ([src/game.cpp:3244](../../src/game.cpp)).
  So the save-load path is **already headless-safe**. **(high)**

Caveat: the `--world` direct-load branch runs **after** `game_ui::init_ui()` (777) and after the
window-init gate (729). With just `--world` (no `test_mode`), a window _is_ created. To load a world
headless, an Arcopolis flag should set `test_mode` itself and load earlier (see next section).

## Existing hooks useful for Arcopolis

1. **`test_mode` window-skip gate** ([src/main.cpp:724](../../src/main.cpp)) — the on/off switch for
   headless operation. **(high)**
2. **`arg_handler` table** ([src/main.cpp:166](../../src/main.cpp), arrays at 241/454) — drop-in
   extension point for new flags. **(high)**
3. **Existing headless branches** ([src/main.cpp:753](../../src/main.cpp)–769) — `verifyexit`/`dump`/
   `check_mods` are a working template for "load data, do work, exit with a code." **(high)**
4. **`game::load(world)`** ([src/game.cpp:3214](../../src/game.cpp)) — deterministic world load by name,
   no menu. **(high)**
5. **Test bootstrap `init_global_game_state`** ([tests/test_main.cpp:99](../../tests/test_main.cpp)) —
   the most complete headless bring-up reference: sandbox dirs → options → `load_static_data` →
   `world_generator` + `make_new_world(mods)` → `load_world_modfiles` → avatar → `map` → weather, with
   **no `init_interface()` call**. This is essentially a ready-made fixture loader. **(high)**
6. **`PATH_INFO` setters** ([src/path_info.h:64](../../src/path_info.h)) — isolate fixture/export runs in
   sandbox directories. **(high)**
7. **`loading_ui ui( false )`** (used at [src/main.cpp:762](../../src/main.cpp)) — non-interactive
   progress object for headless loads. **(high)**

## Candidate insertion points for Arcopolis flags

> **Superseded — now implemented.** This was the original feasibility sketch; the Arcopolis CLI flags it
> proposed have since shipped (Spikes 0–24) as `--arcopolis-export-current-view`,
> `--arcopolis-run-script`, `--arcopolis-export-dir`, `--arcopolis-command`, and `--arcopolis-live` (added
> as new `arg_handler` entries, exactly as predicted). The section is kept as the design rationale; see
> `docs/arcopolis/ARCOPOLIS_STATE.md` for the shipped flag set.

Both proposed flags follow the existing three-step pattern:

1. **Declare a local** near [src/main.cpp:198](../../src/main.cpp)–205 (alongside `world`, `dump`,
   `lua_doc_output_path`), e.g. `std::filesystem::path arcopolis_fixture_path;` and
   `std::filesystem::path arcopolis_export_path;`.
2. **Register an `arg_handler`** in `first_pass_arguments` ([src/main.cpp:241](../../src/main.cpp)) whose
   lambda sets `test_mode = true` and stores the path (mirror `--lua-doc` at 422).
3. **Add a headless work branch** inside the `load_static_data()` try-block, alongside the existing
   `dump`/`check_mods` branches at [src/main.cpp:756](../../src/main.cpp)–769 (i.e. **before**
   `game_ui::init_ui()` at 777).

### `--arcopolis-run-fixture <fixture_path>`

- **Model:** `init_global_game_state` ([tests/test_main.cpp:99](../../tests/test_main.cpp)).
- **Insertion point:** new branch at ≈[src/main.cpp:769](../../src/main.cpp) (after `load_static_data`,
  next to `check_mods`). With `test_mode` set, the window (729) is skipped → headless.
- **Body:** if the fixture is an existing saved world, reuse `g->load( world )`
  ([src/game.cpp:3214](../../src/game.cpp)); if it's a custom fixture, replicate the test-harness
  sequence (`world_generator->init()` + `make_new_world(mods)` + `init::load_world_modfiles` + avatar +
  `map::load`). Then either run fixture-supplied commands or `exit()` with a status code.

### `--arcopolis-export-current-view <output_path>`

> **Implemented as Spike 0** — see [03_SPIKE0_CURRENT_VIEW_EXPORT.md](03_SPIKE0_CURRENT_VIEW_EXPORT.md); the headless design below is the one that was adopted.

- **Dependency:** "current view" requires a loaded state (`g->m` map, `g->u` avatar, overmap). A bare
  export with nothing loaded has nothing to serialize.
- **Recommended:** pair it with the fixture branch above — load headless, then **serialize read-only**
  state to `output_path`, then `exit()`. Reading only (never writing sim state) preserves the
  "frontend never mutates simulation" invariant.
- **Alternative (not headless):** hook just after `g->load( world )` in the main loop
  ([src/main.cpp:822](../../src/main.cpp)) and `break` before the `do_turn` loop (836). Simpler to wire
  to the existing `--world` flow, but it runs after `init_interface()` (729), so a window is created —
  acceptable only if a headless export is not required.

**Recommended single design:** both flags set `test_mode` and do their work in one new branch after
`load_static_data()` (≈[src/main.cpp:769](../../src/main.cpp)), exactly mirroring `--check-mods` /
`--dump-stats`: noninteractive, no menu, no window, deterministic exit code, sandboxed via
`--userdir`/`--savedir`.

## Risks and unknowns

- **Line numbers were validated 2026-05-29 but have since DRIFTED** (see the header banner): the
  `src/main.cpp` cites in particular are stale (the first-pass arg array is now `arg_handler, 22` at
  `:284`). The `src/init.cpp`, `src/options.cpp`, and `src/filesystem.cpp` numbers were confirmed at that
  time. Treat all line numbers as approximate and verify by symbol; re-run the PowerShell checks below
  against the current commit before relying on a number.
- **`--world` is not headless on its own**: it loads after UI init, so it cannot serve as a headless
  template without also setting `test_mode`.
- **Export scope is undefined**: what "current view" means (a screen of tiles? the reality bubble? the
  overmap? creatures/NPCs in view?) and the serialization format (JSON? binary? protocol message?) are
  out of scope here and need their own investigation. BN already serializes world/map/creature state to
  saves, which may be reusable, but that is unverified for an on-demand snapshot.
- **`game_ui::init_ui()` runs in test_mode**: confirm it is safe to call (or skippable) on the exact
  Windows build configuration Arcopolis will use; the existing headless flags exit _before_ it, so a new
  branch should too.
- **TILES vs console option-load ordering** differs ([src/main.cpp:716](../../src/main.cpp)–744): a new
  flag must not assume options are loaded at a particular point; load them explicitly if needed (the
  test harness calls `get_options().init()/load()` itself).
- **Threading/global state**: BN relies heavily on the global `g` (`game`) singleton and other globals.
  A long-lived backend process (vs one-shot export) would need investigation into re-entrancy,
  `unload_data`, and clean teardown — not covered here.

## Recommended next exploration task

**`docs/arcopolis/02_HEADLESS_WORLD_AND_STATE.md` — "Headless world bring-up and serializable state."**

Goal: trace exactly how `init_global_game_state` ([tests/test_main.cpp:99](../../tests/test_main.cpp))
and `game::load(world)` ([src/game.cpp:3214](../../src/game.cpp)) bring the world up, and inventory what
state is readable/serializable for an export:

- the `game` singleton `g` and its members `g->m` (`map`), `g->u` (`avatar`), and the active world;
- the `worldfactory`/`world_generator` API (`init`, `make_new_world`, `get_world`, `set_active_world`);
- existing save serialization (`game::save`, map/overmap serialization) as a candidate snapshot format;
- the "reality bubble" / loaded-map extent that would define a "current view."

That document should determine whether an Arcopolis snapshot can reuse existing save serialization or
needs a purpose-built read-only exporter.

## PowerShell local checks

Run from the repository root (`C:\dev\Cataclysm-BN`) in PowerShell to verify the findings above:

```powershell
# Entry point and the start of CLI setup (read the first ~240 lines of main)
Get-Content .\src\main.cpp -TotalCount 240

# Every command-line flag string declared in main.cpp
Select-String -Path .\src\main.cpp -Pattern '"--'

# The test_mode global: definition, extern, and all uses in src/
Select-String -Path .\src\*.cpp, .\src\*.h -Pattern 'test_mode'

# Key startup landmarks: window init, static data, menu, game loop
Select-String -Path .\src\main.cpp -Pattern 'init_interface|load_static_data|opening_screen|do_turn|init_ui'

# The UI-init boundary call and its platform implementations
Select-String -Path .\src\main.cpp, .\src\cursesdef.h, .\src\ncurses_def.cpp, .\src\sdltiles.cpp, .\src\wincurse.cpp -Pattern 'init_interface'

# PATH_INFO setters/accessors used for sandboxing fixtures
Select-String -Path .\src\path_info.h -Pattern 'set_|init_|datadir|savedir|config_dir|user_dir'

# The headless test bootstrap (model for a fixture loader)
Select-String -Path .\tests\test_main.cpp -Pattern 'init_global_game_state|load_world_modfiles|make_new_world|load_static_data'

# Direct world load entry points
Select-String -Path .\src\game.cpp -Pattern 'game::load|load_static_data'

# Headless-mode work functions
Select-String -Path .\src\dump.cpp -Pattern 'game::dump_stats'
Select-String -Path .\src\init.cpp -Pattern 'check_mods_for_errors|load_world_modfiles|load_core_bn_modfiles|finalize_loaded_data'

# Confirm the docs file this investigation produced
Get-ChildItem .\docs\arcopolis\
```
