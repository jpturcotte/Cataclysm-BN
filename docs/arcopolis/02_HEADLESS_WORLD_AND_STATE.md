# Headless World and State Exploration

> Scope: read-only investigation of how Cataclysm: Bright Nights (BN) brings up a **world + map +
> avatar without the player UI**, how that compares to the two `game::load` overloads, and what
> read-only state an "Arcopolis" current-view snapshot could export. **No source or build files were
> changed to produce this document.** This is the follow-up to
> [docs/arcopolis/01_STARTUP_AND_CLI.md](01_STARTUP_AND_CLI.md), which it assumes nothing from beyond
> the few facts restated below.
>
> Confidence legend: **high** = the exact line(s) were read directly during this investigation;
> **medium** = located via search/exploration but the exact line was not personally re-opened (verify
> with the PowerShell checks at the end); **low** = inferred, needs inspection.
>
> **Validation status (2026-05-29):** every `file:line` in the *backbone* sections (test bootstrap,
> `game.cpp` load/setup paths, worldfactory, and the export accessors) was read directly this session
> and is **high**. A handful of secondary references (map buffer / overmap internals, a couple of
> descriptor fields, the `clear_avatar` test helper) are **medium** and called out inline. Line numbers
> drift as the source evolves — re-run the PowerShell checks against a newer commit.

## Summary

**Yes — BN already contains a complete headless world/map/avatar bring-up**, and it does not touch any
player-facing UI screen. The cleanest reference is the Catch2 test binary's
`init_global_game_state(...)` ([tests/test_main.cpp:99](../../tests/test_main.cpp)–170), which, with the
`test_mode` global set, performs the entire sequence — sandbox paths → options → `load_static_data` →
`world_generator->make_new_world(mods)` → `init::load_world_modfiles` → create avatar → load map →
init weather — **without ever creating a window**.

Key facts (all **high** confidence, read directly this session):

- The test bootstrap brings up the global `game` singleton `g`, a fresh world (`world_generator`), the
  avatar `g->u`, and the local map `g->m`, then initialises weather — entirely headless
  ([tests/test_main.cpp:99](../../tests/test_main.cpp)–170).
- There are **three distinct bring-up paths**, and they are *not* equivalent:
  - `game::load( const std::string &world )` ([src/game.cpp:3214](../../src/game.cpp)) — no-menu load of
    an existing world by name; delegates to…
  - `game::load( const save_t & )` ([src/game.cpp:3240](../../src/game.cpp)) — full save
    deserialisation. **This is the only path that produces a coherent, render-ready view**: it centres
    the reality bubble on the avatar (`update_map(u)`, [src/game.cpp:3383](../../src/game.cpp)) and
    rebuilds the floor/map/visibility caches ([src/game.cpp:3385](../../src/game.cpp),
    3418–3421). Its "Loading the save…" popup is already gated on `if( !test_mode )`
    ([src/game.cpp:3244](../../src/game.cpp)).
  - the **test bootstrap** ([tests/test_main.cpp:99](../../tests/test_main.cpp)) — brings up a *fresh*
    world but does **not** call `game::setup()`, does **not** centre the bubble on the avatar, and does
    **not** build the visibility caches. It is the right blueprint for "make a world from nothing," but
    its output is a *degenerate* view until extra steps are added.
- A rich set of **read-only accessors** already exists for everything an Arcopolis "current view" needs
  (avatar position/z-level/status, terrain/furniture ids, creatures, items, messages, time, weather) —
  see [State available for export](#state-available-for-export). Even numeric *hunger/satiety* is
  available via the calorie getters (`get_stored_kcal`/`max_stored_kcal`/`get_kcal_percent`); the only
  minor gaps are `recent_messages` metadata (turn/count) and the exact stomach-calorie value behind
  `get_hunger_description()`.

**Bottom line:** BN has more than enough headless infrastructure to support an Arcopolis fixture runner.
The smallest first spike (Spike 0) should **load an existing prepared save via the already-headless-safe
`game::load(world)`** and serialise the read-only accessors — this reuses the most battle-tested code
and yields the most complete state for the least new code. See
[Recommended Arcopolis fixture strategy](#recommended-arcopolis-fixture-strategy).

## Why this matters for Arcopolis

The Arcopolis architecture under investigation keeps BN authoritative for simulation, rules, save/load,
world state, and content loading, while a separate graphical, mouse-first frontend sends high-level
commands and receives snapshots/deltas/events — and **never mutates simulation state directly**.

Arcopolis explicitly wants to avoid GUI automation. To get there without bridging BN's UI screens one by
one, it eventually needs three capabilities, in order:

1. **Deterministic fixture loading** — put the simulation into a known state with no menus or human
   input.
2. **Read-only state export** — serialise a "current view" (the reality bubble around the avatar) so the
   frontend can render it, without ever writing simulation state.
3. **Command execution** — later, accept high-level commands, validate, apply, and return deltas.

This document covers the foundations of (1) and (2): exactly how a world/map/avatar comes up headlessly,
and which already-existing accessors a read-only exporter would read. Capability (3) is out of scope
here (see [Recommended next exploration task](#recommended-next-exploration-task)).

## Files inspected

All paths are repo-relative. "Read" = opened and read the exact lines this session; "Searched" =
located precise lines via content search.

- [tests/test_main.cpp](../../tests/test_main.cpp) — **Read in full (1–385).** Test entry `main`, the
  headless `init_global_game_state`, mod selection, sandbox setup, teardown.
- [src/worldfactory.h](../../src/worldfactory.h) — **Read in full.** `worldfactory` class, the
  unit-test `make_new_world` overload, `world_generator` global.
- [src/game.cpp](../../src/game.cpp) — **Read** the constructor tail (425–435), `load_static_data`
  (440–460), `setup` (603–665), both `load` overloads (3214–3425), the reality-bubble globals
  (232–237), and the `update_map` definitions (14301/14308).
- [src/game.h](../../src/game.h) — **Searched.** `setup` default arg (197), `get_levz` (753),
  `all_monsters`/`all_npcs` (506/508), `savegame_version` extern (64), `get_avatar` friend (172).
- [src/init.cpp](../../src/init.cpp) — **Searched.** `load_world_modfiles` (990), `load_and_finalize_packs`
  (858), `finalize_loaded_data` (665), `check_consistency` (752).
- [src/map.h](../../src/map.h) — **Searched.** `load` (679), `ter`/`furn` (977/952), `i_at` (1426),
  `pl_sees` (1856), `visibility_cache` (410), `update_visibility_cache` (2388), `get_abs_sub` (1866).
- [src/mapdata.h](../../src/mapdata.h) — **Searched.** `ter_t` (547), `furn_t` (634), `name()` (455).
- [src/creature.h](../../src/creature.h) — **Searched.** `bub_pos`/`abs_pos` (492/493), `get_pain`
  (572), `get_hp`/`get_hp_max` (619–622).
- [src/character.h](../../src/character.h) — **Searched.** `get_thirst` (400), `get_hunger_description`
  (402), `get_fatigue` (404), `get_name` (1622), `get_stamina` (1904), `get_painkiller` (1959).
- [src/weather.h](../../src/weather.h) — **Searched.** `weather_manager` (183), `temperature` (194),
  `weather_id` (198), `get_weather` (237), `print_temperature` (118).
- [src/calendar.h](../../src/calendar.h) — **Searched.** `turn` extern (151), `season_of_year` (620),
  `to_string(time_point)` (622), `to_string_time_of_day` (624).
- [src/game_constants.h](../../src/game_constants.h) — **Searched.** `REALITY_BUBBLE_SIZE_MAX` (30),
  `MAPSIZE` (34), `SEEX`/`SEEY` (39/40), `MAPSIZE_X`/`MAPSIZE_Y` (42/43).
- [src/item.h](../../src/item.h) — **Searched.** `tname` (487).
- [src/messages.h](../../src/messages.h) — **Searched.** `recent_messages` (25).
- [src/avatar.h](../../src/avatar.h) / [src/avatar.cpp](../../src/avatar.cpp) — **Searched.** `create`
  (avatar.h:84), `get_avatar` (avatar.h:341, avatar.cpp:111).
- [src/pldata.h](../../src/pldata.h) — **Searched.** `character_type` enum (11), `NOW` (15).
- [src/get_version.h](../../src/get_version.h) — **Searched.** `getVersionString()` (2).
- Located via exploration but **not personally re-opened (medium):**
  [tests/player_helpers.cpp](../../tests/player_helpers.cpp) `clear_avatar` (~134),
  [src/mapbuffer.h](../../src/mapbuffer.h) / [src/mapbuffer_registry.h](../../src/mapbuffer_registry.h)
  (`MAPBUFFER` macro), [src/overmapbuffer.h](../../src/overmapbuffer.h).

## Test harness bootstrap

`init_global_game_state( const std::vector<mod_id> &mods, option_overrides_t &option_overrides, const
std::string &user_dir )` — [tests/test_main.cpp:99](../../tests/test_main.cpp)–170 — is the single
function that turns an empty process into a fully loaded headless game. The exact, in-order sequence
(**all high**):

| # | Line | Call | Purpose |
|---|------|------|---------|
| 1 | 103–108 | `remove_tree(user_dir)` + `assure_dir_exist(user_dir)` | Wipe & recreate the sandbox dir. |
| 2 | 110–112 | `PATH_INFO::init_base_path("")`, `init_user_dir(user_dir)`, `set_standard_filenames()` | Point all game paths at the sandbox. |
| 3 | 114–124 | `assure_dir_exist(config_dir()/savedir()/templatedir())` | Create the derived sub-dirs. |
| 4 | 126 | `init_language_system()` | i18n. |
| 5 | 130–141 | `get_options().init()` / `.load()` + apply `--option_overrides` | Load options without a config UI. |
| 6 | 142 | `init_colors()` | Color table (no window). |
| 7 | 144 | `g = std::make_unique<game>()` | Construct the global `game` singleton (this also creates `world_generator`, see [src/game.cpp:432](../../src/game.cpp)). |
| 8 | 145 | `g->new_game = true` | Mark as a fresh game. |
| 9 | 146 | `g->load_static_data()` | Mod-independent data (see [Static data loading](#static-data-loading)). |
| 10 | 148–152 | `world_generator->set_active_world(nullptr)` → `init()` → `make_new_world(mods)` → `set_active_world(test_world)` | Create & activate a fresh world (see [World creation path](#world-creation-path)). |
| 11 | 155–156 | `calendar::set_eternal_season(...)`, `set_season_length(...)` | Seed calendar config from options. |
| 12 | 158–159 | `loading_ui ui( false )` + `init::load_world_modfiles( ui, g->get_active_world(), SAVE_ARTIFACTS )` | Load + finalize all mod JSON (non-interactive UI). |
| 13 | 161–162 | `g->u = avatar()` + `g->u.create( character_type::NOW )` | Construct & generate the avatar. |
| 14 | 164–165 | `g->m = map()` + `disable_mapgen = true` | Construct the local map; force test mapgen. |
| 15 | 167 | `g->m.load( g->m.get_abs_sub(), false )` | Fill the reality bubble around the map's current submap. |
| 16 | 169 | `get_weather().update_weather()` | Compute initial weather. |

The bootstrap is invoked from the Catch2 `main` ([tests/test_main.cpp:268](../../tests/test_main.cpp)),
which sets the pivotal `test_mode = true` ([tests/test_main.cpp:313](../../tests/test_main.cpp)) **before**
calling it ([tests/test_main.cpp:334](../../tests/test_main.cpp)). `test_mode` is the same global that
[doc 01](01_STARTUP_AND_CLI.md) found gates window creation in `src/main.cpp`. Teardown is via an
`on_out_of_scope` guard that calls `g.reset()` and `DynamicDataLoader::get_instance().unload_data()`
([tests/test_main.cpp:328](../../tests/test_main.cpp)–331), plus `clear_all_state()` (352) and
`world_generator->delete_world(...)` (356).

**Crucial nuance (high):** the bootstrap creates the avatar (162) *before* the map (164) and loads the
bubble around `g->m.get_abs_sub()` (167) — it never re-centres the bubble on the avatar and never builds
the lighting/visibility caches. This is fine for unit tests (each test does its own placement via helpers
such as `clear_avatar`), but it means **the bootstrap alone does not produce a coherent player view** —
see [World loading path](#world-loading-path) for the contrast with `game::load(save_t)`.

## Temporary paths and sandboxing

The harness fully isolates itself from a real install (**all high**):

- The user dir defaults to `./test_user_dir/` (`extract_user_dir`,
  [tests/test_main.cpp:229](../../tests/test_main.cpp)–239) and can be overridden with `--user-dir=`.
- It is **wiped and recreated every run** (`remove_tree` then `assure_dir_exist`,
  [tests/test_main.cpp:103](../../tests/test_main.cpp)–108) — the help text warns "all contents will be
  erased!" ([tests/test_main.cpp:302](../../tests/test_main.cpp)).
- `PATH_INFO::init_base_path("")` + `init_user_dir(user_dir)` + `set_standard_filenames()`
  ([tests/test_main.cpp:110](../../tests/test_main.cpp)–112) derive `savedir()`, `config_dir()`,
  `templatedir()` underneath the sandbox; those three are then created (114–124).
- On exit, the world is deleted unless tests failed (and `--drop-world`/`-D` forces deletion regardless)
  ([tests/test_main.cpp:354](../../tests/test_main.cpp)–359).

This is exactly the isolation an Arcopolis fixture/export run wants. As [doc 01](01_STARTUP_AND_CLI.md)
noted, the game binary exposes the same controls as CLI flags (`--userdir`, `--savedir`, `--configdir`,
`--basepath`) routed through the same `PATH_INFO` setters, so a headless Arcopolis flag can sandbox
itself the same way the test binary does.

## Static data loading

`game::load_static_data()` — [src/game.cpp:440](../../src/game.cpp)–460 (decl in
[src/game.h](../../src/game.h)) — loads only **mod-independent** data and must run before any world/mod
load (**high**). It does:

- `inp_mngr.init()` — input config JSON;
- `DynamicDataLoader::get_instance()` — constructs the JSON type-dispatch mapper (does **not** load mod
  JSON yet);
- `panel_manager::get_manager().init()`;
- `get_auto_pickup().load_global()`, `get_safemode().load_global()`,
  `get_distraction_manager().load()` — hardcoded global settings.

The actual mod content (items, terrain, monsters, mapgen, …) is loaded later by
`init::load_world_modfiles` (see next sections). The comment at
[src/game.cpp:451](../../src/game.cpp)–455 confirms the split: anything that loads from JSON belongs in
mod loading, not here.

## World creation path

A *new* world is created by the `worldfactory` (global `world_generator`, declared
[src/worldfactory.h:122](../../src/worldfactory.h), constructed in the game ctor at
[src/game.cpp:432](../../src/game.cpp)). Relevant API (**all high**, read from
[src/worldfactory.h](../../src/worldfactory.h)):

| Method | Line | Notes |
|--------|------|-------|
| `WORLDINFO *make_new_world( bool show_prompt = true, const std::string &world_to_copy = "" )` | 38 | Interactive (UI worldgen tabs) — **not** for headless. |
| `WORLDINFO *make_new_world( special_game_type )` | 39 | Tutorial/defense worlds. |
| `WORLDINFO *make_new_world( const std::vector<mod_id> &mods )` | 41 | **Unit-test overload** — comment says "does NOT verify if the mods can be loaded." Sets `WORLDINFO::active_mod_order = mods` and persists via the private `add_world` (106). |
| `WORLDINFO *get_world( const std::string &name )` | 43 | Returns an *existing* world. |
| `void set_active_world( WORLDINFO *world )` | 48 | Sets the active world & world options. |
| `void init()` | 50 | Scans the save dir and loads existing world metadata. |
| `std::unique_ptr<world> active_world` | 54 | The active world (`world` wraps `WORLDINFO` with file I/O). |

The test bootstrap uses the `make_new_world(mods)` overload
([tests/test_main.cpp:150](../../tests/test_main.cpp)) precisely because it skips dependency
verification and is non-interactive — the headless-friendly entry point for "make a world from a mod
list." Note `init()` (149) is called *before* `make_new_world` so the factory's internal state is set up,
and `set_active_world(nullptr)` (148) clears any prior active world first.

## World loading path

`game::load` has two overloads; **neither is what the test bootstrap does** — the bootstrap builds a
*new* world, while these *load an existing* one.

**`bool game::load( const std::string &world )`** — [src/game.cpp:3214](../../src/game.cpp)–3238
(**high**). No-menu load of a named world:

```
world_generator->init();                       // 3216
WORLDINFO *wptr = world_generator->get_world(world);  // 3217  (false if missing)
if( wptr->world_saves.empty() ) return false;  // 3221  (false if no saves)
world_generator->set_active_world(wptr);       // 3227
g->setup();                                     // 3228  (reloads world modfiles, see below)
g->load( wptr->world_saves.front() );           // 3229  -> the save_t overload
```

**`bool game::load( const save_t &name )`** — [src/game.cpp:3240](../../src/game.cpp)–3425 (**high**) —
full save deserialisation and **the only path that yields a coherent, render-ready state**:

- popup gated on `if( !test_mode )` ([src/game.cpp:3244](../../src/game.cpp)) → already headless-safe;
- `load_master()` (3261); `u = avatar()` (3262); `init_bubble_config()` (3268);
- `unserialize(fin)` (3283) — restores game/avatar/map state from JSON;
- `load_dimension_data()` (3292); `u.load_map_memory()` (3331);
- `get_weather().nextweather = calendar::turn` (3334); `reload_npcs()` + validators (3364–3367);
- **`update_map( u )`** ([src/game.cpp:3383](../../src/game.cpp)) — shifts/centres the reality bubble on
  the avatar (calls `point_rel_sm game::update_map( Character & )`,
  [src/game.cpp:14301](../../src/game.cpp));
- `m.build_floor_cache(get_levz())` (3385); `u.reset()` (3408);
- **`m.build_map_cache(get_levz())` + `m.update_visibility_cache(get_levz())`**
  ([src/game.cpp:3418](../../src/game.cpp)–3421) — populates lighting & visibility.

`game::setup( bool load_world_modfiles = true )` — [src/game.cpp:603](../../src/game.cpp)–665 (decl
[src/game.h:197](../../src/game.h)) — is called by `load(world)` (not by the test bootstrap). It uses
`loading_ui ui( true )` (note: `true`, vs the test's `false`), clears all overmapbuffers, optionally
re-runs `init::load_world_modfiles` (616–618), then `init_bubble_config()` + `m.resize(g_mapsize)`
(620–621) and resets ids/calendar/weather and clears monsters/NPCs/missions/messages (623–658).

### Three bring-up paths compared

| Aspect | `load(world)` (3214) | `load(save_t)` (3240) | test bootstrap (test_main.cpp:99) |
|--------|----------------------|------------------------|-----------------------------------|
| Source of state | existing save | existing save | **fresh** `make_new_world(mods)` |
| Calls `game::setup()` | **yes** (3228) | no (setup already ran via `load(world)`) | **no** (manual init instead) |
| Static data prereq | must already be loaded | must already be loaded | calls `load_static_data` itself (146) |
| Avatar source | from save (via `load(save_t)`) | `unserialize()` (3283) | `avatar::create(NOW)` (162) |
| Bubble centred on avatar | yes (via `load(save_t)`) | **yes** — `update_map(u)` (3383) | **no** — loads around `get_abs_sub()` (167) |
| Visibility/light caches built | yes | **yes** (3385, 3418–3421) | **no** |
| Headless-safe popup | n/a | yes — `!test_mode` gate (3244) | n/a (no popup) |
| Net result | coherent player view | **coherent player view** | world+data+avatar+map, **degenerate view** |

**Takeaway:** loading a save (directly or via `load(world)`) gives a fully coherent view for free; the
test bootstrap gives a loaded world but needs extra steps (place avatar → `update_map` → build caches)
to match.

## Active world and mods

- The active world is a `world` object owned by `world_generator->active_world`
  ([src/worldfactory.h:54](../../src/worldfactory.h)); `WORLDINFO` holds the world's
  `active_mod_order` (set by `make_new_world(mods)`).
- In the test binary, the mod list is assembled in `main`: `extract_mod_selection`
  ([tests/test_main.cpp:82](../../tests/test_main.cpp)–97) parses `--mods=a,b,c` and **always appends
  `"test_data"`** (94); `main` then **prepends the default core content pack** if absent
  ([tests/test_main.cpp:274](../../tests/test_main.cpp)–278). So the effective order is
  `[ <default core>, <user mods…>, test_data ]`.
- `init::load_world_modfiles( loading_ui &, const world *, const std::string &artifacts_file )` —
  [src/init.cpp:990](../../src/init.cpp) — drives the actual content load. At a high level (line numbers
  **high**; internal step ordering corroborated by [doc 01](01_STARTUP_AND_CLI.md)): it normalises the
  mod load order, then calls the static helper `load_and_finalize_packs`
  ([src/init.cpp:858](../../src/init.cpp)), which loads each pack's JSON, runs
  `DynamicDataLoader::finalize_loaded_data` ([src/init.cpp:665](../../src/init.cpp)), and
  `check_consistency` ([src/init.cpp:752](../../src/init.cpp)) to validate cross-references.

For Arcopolis, the important point is that **mod selection is just a `std::vector<mod_id>`** handed to
`make_new_world`, and the entire load is non-interactive (`loading_ui( false )`). A fixture can pin an
exact mod set deterministically.

## Avatar/player initialization

- The avatar is the global `g->u` (class `avatar` : `player` : `Character` : `Creature`). The free
  function `avatar &get_avatar()` returns it ([src/avatar.h:341](../../src/avatar.h), def
  [src/avatar.cpp:111](../../src/avatar.cpp); `friend` declared [src/game.h:172](../../src/game.h)).
- **In the test bootstrap:** `g->u = avatar()` then `g->u.create( character_type::NOW )`
  ([tests/test_main.cpp:161](../../tests/test_main.cpp)–162). `bool avatar::create( character_type type,
  const std::string &tempname = "" )` is at [src/avatar.h:84](../../src/avatar.h); `character_type::NOW`
  is one of `{CUSTOM, RANDOM, TEMPLATE, NOW, FULL_RANDOM}` ([src/pldata.h:11](../../src/pldata.h)–17).
  `NOW` generates a ready-to-play character immediately (no creation UI).
- **In the load path:** `load(save_t)` constructs a fresh `u = avatar()`
  ([src/game.cpp:3262](../../src/game.cpp)) and then restores all fields (including position) from JSON in
  `unserialize()` ([src/game.cpp:3283](../../src/game.cpp)).
- **Per-test placement (medium):** unit tests typically reset the avatar to a clean state via a
  `clear_avatar()` helper (located in [tests/player_helpers.cpp](../../tests/player_helpers.cpp) ~134 —
  not re-opened this session) and then set its position explicitly before exercising the map. The
  bootstrap itself does **not** place the avatar relative to the loaded bubble.

## Map and reality bubble initialization

- The local map is the global `g->m` (class `map`, [src/map.h](../../src/map.h)). Its current origin in
  absolute submap coordinates is `map::get_abs_sub()` → `tripoint_abs_sm`
  ([src/map.h:1866](../../src/map.h)).
- It is filled by `void map::load( const tripoint_abs_sm &w, bool update_vehicles, bool pump_events =
  false )` ([src/map.h:679](../../src/map.h)). The bootstrap calls `g->m.load( g->m.get_abs_sub(), false )`
  ([tests/test_main.cpp:167](../../tests/test_main.cpp)) with `disable_mapgen = true` set first (165), so
  it uses test mapgen rather than full procedural generation.
- **Reality-bubble extent.** Two distinct sizes matter:
  - *Compile-time maximum* (constants in [src/game_constants.h](../../src/game_constants.h)):
    `REALITY_BUBBLE_SIZE_MAX = 16` (30), `MAPSIZE = 2*16+3 = 35` (34), `SEEX = SEEY = 12` (39/40),
    `MAPSIZE_X = MAPSIZE_Y = SEEX*MAPSIZE = 420` (42/43).
  - *Actual loaded size at runtime* (mutable globals, [src/game.cpp:232](../../src/game.cpp)–237):
    `g_half_mapsize = 5`, `g_mapsize = 11`, `g_mapsize_x = g_mapsize_y = 132`. These are set by
    `init_bubble_config()` from the `REALITY_BUBBLE_SIZE` option. So a normal run loads a **132×132**
    tile bubble, not 420×420.
- **Visibility/lighting** is precomputed into `map::visibility_cache`
  (`std::vector<lit_level>`, [src/map.h:410](../../src/map.h)), refreshed by
  `map::update_visibility_cache( int zlev )` ([src/map.h:2388](../../src/map.h)). The "can the player see
  this tile?" query is `bool map::pl_sees( const tripoint_bub_ms &t, int max_range ) const`
  ([src/map.h:1856](../../src/map.h)).
- **Map buffer / overmap (medium — located via exploration, not re-opened this session):** submaps are
  cached in `MAPBUFFER` (a `mapbuffer`, [src/mapbuffer.h](../../src/mapbuffer.h), accessed via the
  `mapbuffer_registry` in [src/mapbuffer_registry.h](../../src/mapbuffer_registry.h)); overmaps are
  cached in `overmap_buffer` ([src/overmapbuffer.h](../../src/overmapbuffer.h)) and generated lazily on
  access. These are not needed for a first read-only snapshot of the local bubble but will matter for any
  larger "map view."

**Implication for export:** `game::load(save_t)` leaves `g->m` centred on the avatar with caches built,
so an exporter run *after* a save load can immediately read `ter`/`furn`/visibility. After the *test
bootstrap*, an exporter would first need `update_map(g->u)` + `m.build_map_cache` +
`m.update_visibility_cache` to get a meaningful view.

## State available for export

Every datum the Arcopolis "current view" needs already has a **read-only** accessor. Confidence is
**high** for items read directly this session, **medium** where the accessor was located by an
exploration agent but the exact line was not personally re-opened (verify via the PowerShell checks).

| View datum | Accessor (read-only) | File:line | Conf. |
|------------|----------------------|-----------|-------|
| Avatar position (bubble) | `Creature::bub_pos() → tripoint_bub_ms` | [src/creature.h:492](../../src/creature.h) | high |
| Avatar position (absolute) | `Creature::abs_pos() → tripoint_abs_ms` | [src/creature.h:493](../../src/creature.h) | high |
| Current z-level | `game::get_levz() const → int` | [src/game.h:753](../../src/game.h) | high |
| Loaded bubble size | `g_mapsize_x` / `g_mapsize_y` (=132) | [src/game.cpp:234](../../src/game.cpp) | high |
| Bubble max (compile-time) | `MAPSIZE_X` / `MAPSIZE_Y` (=420), `SEEX`/`SEEY` | [src/game_constants.h:42](../../src/game_constants.h) | high |
| "Player can see tile?" | `map::pl_sees( tripoint_bub_ms, int ) const → bool` | [src/map.h:1856](../../src/map.h) | high |
| Per-tile visibility | `map::visibility_cache` (`std::vector<lit_level>`) | [src/map.h:410](../../src/map.h) | high |
| Terrain id at tile | `map::ter( tripoint_bub_ms ) const → ter_id` | [src/map.h:977](../../src/map.h) | high |
| Terrain descriptor | `struct ter_t` (`.id` → `ter_str_id`, `.name()`) | [src/mapdata.h:547](../../src/mapdata.h) | high (`.id` field line medium) |
| Furniture id at tile | `map::furn( tripoint_bub_ms ) const → furn_id` | [src/map.h:952](../../src/map.h) | high |
| Furniture descriptor | `struct furn_t` (`.id` → `furn_str_id`, `.name()`) | [src/mapdata.h:634](../../src/mapdata.h) | high (`.id` field line medium) |
| Descriptor display name | `map_data_common_t::name() const → std::string` | [src/mapdata.h:455](../../src/mapdata.h) | high |
| Monsters | `game::all_monsters() → monster_range` | [src/game.h:506](../../src/game.h) | high |
| NPCs | `game::all_npcs() → npc_range` | [src/game.h:508](../../src/game.h) | high |
| Creature name | `Character::get_name() const` / `monster::get_name()` | [src/character.h:1622](../../src/character.h) | high |
| Items on ground | `map::i_at( tripoint_bub_ms ) → map_stack` | [src/map.h:1426](../../src/map.h) | high |
| Item display name | `item::tname( unsigned, bool, unsigned ) const` | [src/item.h:487](../../src/item.h) | high |
| Recent messages | `Messages::recent_messages( size_t ) → vector<pair<string,string>>` | [src/messages.h:25](../../src/messages.h) | high |
| Avatar HP | `Creature::get_hp() const` / `get_hp_max() const` | [src/creature.h:620](../../src/creature.h) | high |
| Avatar pain | `Creature::get_pain() const → int` | [src/creature.h:572](../../src/creature.h) | high |
| Avatar stamina | `Character::get_stamina() const → int` | [src/character.h:1904](../../src/character.h) | high |
| Avatar thirst | `Character::get_thirst() const → int` | [src/character.h:400](../../src/character.h) | high |
| Avatar fatigue | `Character::get_fatigue() const → int` | [src/character.h:404](../../src/character.h) | high |
| Avatar painkiller | `Character::get_painkiller() const → int` | [src/character.h:1959](../../src/character.h) | high |
| Avatar satiety (hunger) | `Character::get_stored_kcal()`, `max_stored_kcal()`, `get_kcal_percent()` | [src/character.h:395](../../src/character.h)–399 | high |
| Avatar hunger (display) | `Character::get_hunger_description() → (string,color)` | [src/character.h:402](../../src/character.h) | high |
| Current time | `calendar::turn` (`time_point`) | [src/calendar.h:151](../../src/calendar.h) | high |
| Time → string | `to_string( time_point )`, `to_string_time_of_day( time_point )`, `season_of_year( time_point )` | [src/calendar.h:622](../../src/calendar.h)/624/620 | high |
| Weather type | `weather_manager::weather_id` (`weather_type_id`) | [src/weather.h:198](../../src/weather.h) | high |
| Temperature | `weather_manager::temperature` (+ `print_temperature`) | [src/weather.h:194](../../src/weather.h) | high |
| Weather accessor | `weather_manager &get_weather()` | [src/weather.h:237](../../src/weather.h) | high |
| Build version | `getVersionString()` | [src/get_version.h:2](../../src/get_version.h) | high |
| Save-format version | `extern const int savegame_version` | [src/game.h:64](../../src/game.h) | high |

**Hunger note (resolved):** BN models hunger through a calorie system, so there is intentionally no plain
`int get_hunger()`. The numeric satiety signal is exposed read-only on `Character`:
`get_stored_kcal()`, `max_stored_kcal()`, and `get_kcal_percent()`
([src/character.h:395](../../src/character.h)–399, under the comment "Getter for need values exclusive to
characters"). Export `get_kcal_percent()` (or the raw `get_stored_kcal()`/`max_stored_kcal()` pair) as the
hunger/satiety field. **Caveat (only if an exact match is required):** the player-facing
`get_hunger_description()` ([src/character.cpp:5179](../../src/character.cpp)) computes
`stored_calories + stomach.get_calories()` divided by `bmr()` — i.e. it also counts undigested food in the
stomach. To reproduce that string's underlying value exactly, add `stomach.get_calories()` to
`get_stored_kcal()`; for a simple satiety percentage, `get_kcal_percent()` alone suffices.

## Recommended Arcopolis fixture strategy

The user's three candidate strategies, evaluated against "smallest first spike that proves headless
bring-up + read-only export":

**A) Load an existing prepared save** (via `game::load(world)` → `game::load(save_t)`).
- *Pros:* reuses the most battle-tested code; `load(save_t)` already produces a **coherent, render-ready
  view** (avatar-centred bubble, caches built) and is **already headless-safe** (popup gated on
  `test_mode`, [src/game.cpp:3244](../../src/game.cpp)). A fixed save **is** a deterministic fixture.
  Least *new* code: a flag + a read-only exporter.
- *Cons:* requires a save artifact to exist first (a one-time cost: play one turn and quit, or copy a
  known save into the sandbox).

**B) Generate a deterministic fixture world + avatar** (from a fixture spec).
- *Pros:* no save artifact; fully reproducible from JSON + a fixed RNG seed; the long-term ideal for
  Arcopolis fixtures.
- *Cons:* most new code — must replicate world creation **and** avatar placement **and** `update_map` +
  cache building to reach a coherent view; determinism of mapgen needs its own validation.

**C) Reuse the test-harness bootstrap logic** (`init_global_game_state` sequence) in the game binary.
- *Pros:* a ready-made, proven headless world+data+avatar+map bring-up; no save needed.
- *Cons:* its output is a **degenerate view** (no avatar-centred bubble, no caches — see
  [Map and reality bubble initialization](#map-and-reality-bubble-initialization)); it lives in the
  Catch2 test binary, not the game binary, so it would be a *blueprint to copy*, not code to call.

**Recommendation — Spike 0 = Option A.** Add a single headless flag to the game binary following the
`--check-mods`/`--dump-stats` template from [doc 01](01_STARTUP_AND_CLI.md) (a new `arg_handler` that
sets `test_mode` and does its work after `load_static_data()`), have it call the already-existing
`g->load( world )` to load a **prepared sandbox save**, then run a **read-only exporter** that walks the
accessors in [State available for export](#state-available-for-export) and writes the JSON snapshot
below, then `exit()`. This is the smallest spike because *no new bring-up code is required* — only the
flag and the exporter — and it yields the richest, most coherent state.

- **Then** (Spike 1): adopt Option C's bootstrap as the blueprint for a "no-save fixture world" mode,
  adding the missing `update_map` + cache-build steps.
- **Long term** (Spike 2): Option B — fully deterministic fixtures from a JSON spec.

*Caveats to verify during Spike 0:* `load_static_data()` must run before `load(world)`; confirm
`game::setup()`'s `loading_ui ui( true )` ([src/game.cpp:605](../../src/game.cpp)) is inert under
`test_mode` on the target Windows build (the existing headless flags use `loading_ui( false )`).

## Candidate snapshot schema

A minimal, **read-only** "current view" export. Coordinates are bubble-local
(`tripoint_bub_ms` from `bub_pos()`); `pos_abs` is included for stable cross-bubble identity.

```jsonc
{
  "schema_version": 1,
  "backend": {
    "game_version": "<getVersionString()>",        // src/get_version.h:2
    "save_version": 0                                // src/game.h:64  (extern const int savegame_version)
  },
  "turn": {
    "turn": 0,                                       // calendar::turn as a turn count
    "time_of_day": "08:00:00",                       // to_string_time_of_day(calendar::turn)
    "season": "spring",                              // season_of_year(calendar::turn)
    "day": 1,
    "year": 1
  },
  "avatar": {
    "name": "",                                      // Character::get_name()
    "pos_local": [60, 60, 0],                        // bub_pos()  (centre of a 132-wide bubble)
    "pos_abs":   [0, 0, 0],                          // abs_pos()
    "z": 0,                                          // game::get_levz()
    "hp": 0, "hp_max": 0,                            // get_hp()/get_hp_max()
    "stamina": 0, "pain": 0, "thirst": 0, "fatigue": 0,
    "stored_kcal": 0, "kcal_percent": 0.0    // get_stored_kcal() / get_kcal_percent(); satiety signal
  },
  "map_bounds": {
    "origin_abs_sm": [0, 0, 0],                      // map::get_abs_sub()
    "size_x": 132, "size_y": 132,                    // g_mapsize_x / g_mapsize_y
    "z": 0
  },
  "tiles": [
    // one entry per exported tile (full 132x132 bubble, or a radius-R window around the avatar)
    { "x": 60, "y": 60, "ter": "t_floor", "furn": "f_null", "seen": true }
    //   ter  = map::ter(p).id().str()   furn = map::furn(p).id().str()
    //   seen = map::pl_sees(p, range) or a visibility_cache lookup
  ],
  "actors": [
    { "kind": "monster", "name": "zombie", "pos_local": [62, 60, 0] },   // all_monsters()
    { "kind": "npc",     "name": "Smith",  "pos_local": [58, 61, 0] }    // all_npcs()
  ],
  "items": [
    { "pos_local": [60, 61, 0], "items": [ { "name": "rock" } ] }        // map::i_at(p) -> item::tname()
  ],
  "messages": [
    { "text": "You wake up.", "type": "good" }                          // Messages::recent_messages(N)
  ],
  "diagnostics": { "warnings": [] }
}
```

Notes:
- **Extent choice:** for Spike 0, dump either the full loaded bubble (`g_mapsize_x` × `g_mapsize_y` =
  132²) or a square window of radius *R* around `bub_pos()`, clamped to the bubble. Do **not** use the
  420² compile-time max — that is not the loaded extent.
- **`seen` semantics:** `pl_sees`/`visibility_cache` is *current* line-of-sight, distinct from
  remembered map memory (`u.load_map_memory()`, [src/game.cpp:3331](../../src/game.cpp)). Pick one and
  label it; do not conflate them.
- **`game_version`/`save_version`** are cheap (both symbols confirmed) — include them so the frontend can
  detect backend drift.
- Keep the schema additive: bump `schema_version` when fields change.

## Risks and unknowns

- **Line-number drift.** All references are valid at the current commit (2026-05-29); re-run the
  PowerShell checks below against newer commits.
- **`setup()`'s `loading_ui( true )`** ([src/game.cpp:605](../../src/game.cpp)) — unverified whether it
  is fully inert under `test_mode` on the target Windows build. `load(world)` reaches `setup()`, so a
  headless Spike-0 flag must confirm this (the existing headless flags sidestep it by using
  `loading_ui( false )` directly). **Medium risk.**
- **Bootstrap relies on default `g_mapsize` globals.** The test bootstrap never calls
  `init_bubble_config()`, so it uses the defaults (`g_mapsize = 11`); confirm the `map()` constructor and
  `map::load` honour those defaults if Option C is ever used directly. **Low/medium.**
- **Hunger exactness (minor).** Numeric satiety is available (`get_kcal_percent()` /
  `get_stored_kcal()`), but matching the exact value behind `get_hunger_description()` additionally
  requires the stomach's calories (`stomach.get_calories()`) — decide per snapshot whether stored kcal
  alone is sufficient. **Low.**
- **`recent_messages` is lossy** — it returns `(text, type)` string pairs only
  ([src/messages.h:25](../../src/messages.h)); turn number and repeat-count metadata are not exposed
  publicly. If the snapshot needs them, the `Messages` internals
  ([src/messages.cpp](../../src/messages.cpp)) must be inspected/extended. **Medium.**
- **Map buffer / overmap export** is out of scope here and only located at **medium** confidence; a
  larger-than-bubble view will need its own investigation.
- **Long-lived backend** (vs one-shot export): re-entrancy, repeated `unload_data`/reload, and clean
  teardown of the global `g` are unexamined. The test binary only ever loads **once** per process.
- **Coordinate systems.** BN distinguishes `tripoint_bub_ms` (bubble), `tripoint_abs_ms` (absolute ms),
  and `tripoint_abs_sm` (absolute submap). The exporter must be explicit about which it emits; mixing
  them silently is a likely bug source.

## Recommended next exploration task

**`docs/arcopolis/03_MAP_REALITY_BUBBLE_AND_VIEW_EXPORT.md` — "Reality bubble, visibility, and a concrete
read-only view export."** (Matches the artifact list in [AGENTS.md](../../AGENTS.md).)

Goals:
- Pin down the coordinate systems (`bub_ms` / `abs_ms` / `abs_sm`) and the exact conversion helpers.
- Trace `map::build_map_cache` / `update_visibility_cache` and the `lit_level`/`visibility_cache` model,
  so the exporter can correctly emit "currently visible" vs "remembered" tiles.
- Resolve the remaining gap from this doc: the message metadata in
  [src/messages.cpp](../../src/messages.cpp) (turn / repeat-count), and decide whether the snapshot needs
  stomach-calorie satiety (`stomach.get_calories()`) in addition to stored kcal.
- Produce a concrete, ordered read-only export walk (avatar → bounds → tiles → actors → items → messages
  → time/weather) ready to implement behind the Spike-0 flag.

A later doc (`05_ACTIONS_COMMANDS_AND_TURN_ADVANCE.md`) should cover capability (3): command
validation/application and `do_turn` advancement.

## PowerShell local checks

Run from the repository root (the folder containing `src/` and `tests/`) in PowerShell to re-verify every
`file:line` cited above. (Paths are repo-relative by design — substitute your own checkout location for
`<repo-root>` if needed.)

```powershell
# The headless bootstrap, top to bottom
Get-Content .\tests\test_main.cpp -TotalCount 170 | Select-Object -Skip 98

# Bootstrap landmarks (sandbox, world, modfiles, avatar, map, weather)
Select-String -Path .\tests\test_main.cpp -Pattern 'init_global_game_state|make_new_world|load_world_modfiles|disable_mapgen|update_weather|test_mode|create\( character_type'

# worldfactory API (unit-test make_new_world overload, set_active_world, init)
Select-String -Path .\src\worldfactory.h -Pattern 'make_new_world|set_active_world|void init\(|active_world|world_generator'

# game.cpp bring-up paths and globals
Select-String -Path .\src\game.cpp -Pattern 'game::load_static_data|game::setup|game::load\(|world_generator = std::make_unique|game::update_map'
Select-String -Path .\src\game.cpp -Pattern 'g_half_mapsize|g_mapsize'
Get-Content .\src\game.cpp -TotalCount 3425 | Select-Object -Skip 3239   # load( save_t )

# setup() default arg, get_levz, all_monsters/all_npcs, savegame_version, get_avatar friend
Select-String -Path .\src\game.h -Pattern 'void setup\(|get_levz|all_monsters|all_npcs|savegame_version|get_avatar'

# Mod load + finalize
Select-String -Path .\src\init.cpp -Pattern 'load_world_modfiles|load_and_finalize_packs|finalize_loaded_data|check_consistency'

# Map: load, ter/furn, i_at, pl_sees, visibility_cache, get_abs_sub
Select-String -Path .\src\map.h -Pattern 'void load\(|ter_id ter\(|furn_id furn\(|i_at\(|pl_sees|visibility_cache|get_abs_sub'

# Descriptors and reality-bubble constants
Select-String -Path .\src\mapdata.h -Pattern 'struct ter_t|struct furn_t|std::string name\('
Select-String -Path .\src\game_constants.h -Pattern 'REALITY_BUBBLE_SIZE_MAX|MAPSIZE|SEEX|SEEY'

# Avatar / creature / character read-only status getters
Select-String -Path .\src\avatar.h -Pattern 'bool create\(|get_avatar'
Select-String -Path .\src\pldata.h -Pattern 'enum class character_type'
Select-String -Path .\src\creature.h -Pattern 'bub_pos|abs_pos|get_hp|get_pain'
Select-String -Path .\src\character.h -Pattern 'get_thirst|get_fatigue|get_stamina|get_painkiller|get_name|get_hunger'

# Items, messages, time, weather, version
Select-String -Path .\src\item.h -Pattern 'std::string tname\('
Select-String -Path .\src\messages.h -Pattern 'recent_messages'
Select-String -Path .\src\calendar.h -Pattern 'extern time_point turn|to_string_time_of_day|season_of_year|std::string to_string'
Select-String -Path .\src\weather.h -Pattern 'class weather_manager|weather_id|temperature|get_weather'
Select-String -Path .\src\get_version.h -Pattern 'getVersionString'

# Confirm this doc exists alongside doc 01
Get-ChildItem .\docs\arcopolis\
```
