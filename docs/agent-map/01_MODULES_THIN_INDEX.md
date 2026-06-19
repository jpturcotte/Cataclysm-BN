# Thin module index — where to start per subsystem

> **This thin index is intentionally incomplete; before editing a subsystem, inspect the current
> code and tests.** It lists, per area, a one-line purpose, a few anchor files, and the single seam
> to read first — not a full type/dependency map. Ordered by near-term Arcopolis usefulness.

## 1. Entry / turn loop / action dispatch

- **Purpose:** process startup, the per-turn pipeline, and input→action dispatch.
- **Anchor files:** `src/main.cpp`, `src/game.cpp`, `src/game.h`, `src/handle_action.cpp`,
  `src/action.cpp`, `src/action.h`.
- **Start here:** `src/main.cpp:1062` (`while( !g->do_turn() )`) → `src/game.cpp:1884`
  (`game::do_turn`) → `src/handle_action.cpp:1763` (`game::handle_action`).

## 2. Arcopolis backend seam (fork-specific)

- **Purpose:** drive the engine headlessly from external commands and export read-only snapshots.
- **Anchor files:** `src/arcopolis_backend_input.cpp/.h`, `src/arcopolis_command.cpp`,
  `src/arcopolis_export.cpp`, `src/arcopolis_live.cpp`, `src/arcopolis_script.cpp`,
  `src/arcopolis_session_log.cpp`.
- **Start here:** the input hook `src/handle_action.cpp:1779` (`arcopolis::next_backend_action()`),
  gated by `arcopolis::backend_session_active()` (`src/arcopolis_backend_input.cpp:528`).
- **Risk:** must uphold the backend-UI invariant — see [`04_RISK_ZONES.md`](04_RISK_ZONES.md).

## 3. UI / input / prompt machinery

- **Purpose:** keybinding/action mapping, list menus, and yes/no & message popups (curses + tiles).
- **Anchor files:** `src/input.cpp/.h`, `src/ui.cpp/.h`, `src/popup.cpp/.h`, `src/output.cpp`,
  `src/ui_manager.cpp/.h`.
- **Start here:** `input_context::handle_input` in `src/input.cpp`; menus go through `uilist` in
  `src/ui.cpp`; confirmations through `query_popup` in `src/popup.cpp`.
- **Risk:** under backend `test_mode` these short-circuit (e.g. `uilist` → `UILIST_ERROR`,
  `src/ui.cpp:935`) — see risk zones.

## 4. Map / terrain / reality bubble

- **Purpose:** the loaded in-play map (the "reality bubble") over the global world.
- **Anchor files:** `src/map.cpp/.h`, `src/submap.cpp/.h`, `src/mapdata.cpp/.h`,
  `src/coordinates.h`, `src/game_constants.h`.
- **Start here:** the `map` class in `src/map.h`; bubble size `MAPSIZE` at `src/game_constants.h:34`;
  the overmap→OMT→submap hierarchy is described in `doxygen_doc/pages.h:1-25`.

## 5. Examine / interaction

- **Purpose:** contextual "examine"/interact actions on terrain, furniture, and creatures.
- **Anchor files:** `src/iexamine.cpp/.h`, `src/monexamine.cpp`, `src/examine_item_menu.cpp`.
- **Start here:** the examine-action registry in `src/iexamine.cpp` (terrain/furniture handlers like
  `deployed_furniture`).

## 6. Activities / activity actors

- **Purpose:** multi-turn player/NPC actions (crafting, pickup, harvesting, movement-to).
- **Anchor files:** `src/activity_actor.cpp/.h`, `src/activity_actor_definitions.h`,
  `src/activity_handlers.cpp`, `src/player_activity.cpp`.
- **Start here:** concrete actors in `src/activity_actor_definitions.h` (e.g. `pickup_activity_actor`
  at `src/activity_actor_definitions.h:561`).

## 7. Items / inventory / pickup

- **Purpose:** item instances vs definitions, containers, inventory, and the pickup flow.
- **Anchor files:** `src/item.cpp/.h`, `src/itype.h`, `src/item_factory.cpp/.h`,
  `src/inventory.cpp/.h`, `src/pickup.cpp`.
- **Start here:** `item` (instance) in `src/item.h` vs `itype` (definition) in `src/itype.h`; the
  pickup menu lives in `src/pickup.cpp` and the pickup actor in `src/activity_actor_definitions.h:561`.

## 8. Creatures / avatar / NPC / monster

- **Purpose:** the living-entity hierarchy and the live-creature tracker.
- **Anchor files:** `src/creature.cpp/.h`, `src/character.cpp/.h`, `src/avatar.cpp/.h`,
  `src/npc.cpp/.h`, `src/monster.cpp/.h`, `src/creature_tracker.cpp`.
- **Start here:** the abstract base `Creature` in `src/creature.h`; `Character` → `avatar`/`npc`,
  and `monster` extends `Creature` directly.

## 9. Vehicles

- **Purpose:** multi-tile vehicles, their parts, and on-map placement.
- **Anchor files:** `src/vehicle.cpp/.h`, `src/vehicle_part.cpp/.h`, `src/vpart_position.h`,
  `src/veh_type.cpp`, `src/veh_interact.cpp`.
- **Start here:** the `vehicle` class in `src/vehicle.h`; map access via `veh_at` returning
  `optional_vpart_position` (`src/vpart_position.h`).

## 10. Pathfinding / movement

- **Purpose:** route-finding for monsters/NPCs and monster turn movement.
- **Anchor files:** `src/pathfinding.cpp/.h`, `src/simple_pathfinding.cpp`,
  `src/legacy_pathfinding.cpp`, `src/monmove.cpp`.
- **Start here:** `src/pathfinding.h` for the route API; monster movement in `src/monmove.cpp`.

## 11. Save / load / serialization

- **Purpose:** reading/writing world and character state, with versioned migration.
- **Anchor files:** `src/savegame.cpp`, `src/savegame_json.cpp`, `src/savegame_legacy.cpp`,
  `src/mapbuffer.cpp` (submap persistence).
- **Start here:** `src/savegame.cpp` (serialize/unserialize); the wire version is
  `const int savegame_version` at `src/savegame.cpp:66`. **Bumping it is high-risk** — see risk zones.

## 12. JSON loading / generic factories

- **Purpose:** loading content from JSON into typed factories and stable IDs.
- **Anchor files:** `src/init.cpp/.h`, `src/json.h`, `src/generic_factory.h`, `src/string_id.h`,
  `src/int_id.h`, `src/type_id.h`.
- **Start here:** `DynamicDataLoader` in `src/init.cpp` registers all type loaders; per-type storage
  uses the `generic_factory` template (`src/generic_factory.h`) with `string_id`→`int_id` mapping.

## 13. Options / settings

- **Purpose:** game configuration, keybindings, and hot-path cached flags.
- **Anchor files:** `src/options.cpp/.h`, `src/cached_options.cpp/.h`, `src/preload_config.cpp`.
- **Start here:** `src/options.cpp` for the option registry; `src/cached_options.*` for the
  fast-read flags consulted in tight loops.

## 14. Testing / fixtures

- **Purpose:** the Catch2 suite and the Arcopolis regression harnesses.
- **Anchor files:** `tests/CMakeLists.txt`, `tests/*_test.cpp`, `docs/arcopolis/*regression.ps1`.
- **Start here:** `tests/CMakeLists.txt:16-54` (targets); Arcopolis fixtures/worlds and how they are
  built/run are documented in `AGENTS.md:169` (the "Arcopolis test world fixture" section) and the
  `docs/arcopolis/*regression.ps1` scripts. See [`02_BUILD_AND_TOOLCHAIN.md`](02_BUILD_AND_TOOLCHAIN.md).

## 15. Build / tooling

- **Purpose:** how the project configures, builds, and formats.
- **Anchor files:** `CMakeLists.txt`, `src/CMakeLists.txt`, `CMakePresets.json`,
  `CMakeSettings.json`, `build-scripts/`.
- **Start here:** [`02_BUILD_AND_TOOLCHAIN.md`](02_BUILD_AND_TOOLCHAIN.md).

## Deferred modules (known, not mapped here)

These are real and substantial but out of scope for this v0 index — read the code directly:
crafting / construction; combat (ranged/melee/ballistics); weather / fields / scent / lighting;
factions / missions / dialogue; magic / mutation / bionics / effects; Lua scripting (`catalua_*`);
sound; GPU compute (`src/compute/`); debug menu / dev tools.
