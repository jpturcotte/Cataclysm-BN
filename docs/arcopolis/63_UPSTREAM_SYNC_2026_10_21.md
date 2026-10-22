# Arcopolis upstream sync + clean-merge behavior-change audit (2026-10-21)

**Status: upstream sync, NOT a feature spike. NO new Arcopolis behavior.** This records rebasing the
`arcopolis` patch set onto `upstream/main` `a463bd2220`, plus an audit of upstream behavior changes
that merged clean INSIDE engine functions the backend relies on. One compile fixup; no protocol, wire,
export-field, exit-code or seam change.

> **Equivalence level changed by this sync: NONE.** No Arcopolis code path changed. But the ENGINE
> changed under five fixture witnesses: they now fail because headless BN behaves more like the tiles
> GUI (§4). Those failures are faithful engine behavior. They are recorded here, not papered over, and
> the witness adaptations are a follow-up (§6).

> **Citations** are `file:line` on the synced tree (`9ddea0f56f`). Line numbers drift; confirm by
> symbol.

## 1. Sync refs

|                         | ref                                                                       | date       |
| ----------------------- | ------------------------------------------------------------------------- | ---------- |
| previous merge-base     | `5171f8fe80` (an unrecorded 2026-06-30 sync; doc 41 is the last recorded) | 2026-06-30 |
| `arcopolis` before sync | `0f74bea263` (99 patches)                                                 | 2026-10-21 |
| new base                | `upstream/main` `a463bd2220` (682 commits absorbed; includes 0.13.0)      | 2026-10-21 |
| result branch           | `claude/sync-upstream-2026-10-21-0657ac` = 99 patches rebased + 1 fixup   | 2026-10-21 |

`main` and `arcopolis` were NOT moved or pushed by this work. Patch-set invariant: per-file
`git diff --numstat` of `5171f8fe80..0f74bea263` equals `upstream/main..<rebased tip>` exactly, and the
added/removed lines of every engine-hook file (`main.cpp`, `game.cpp`, `handle_action.cpp`, `input.cpp`,
`popup.cpp`, `output.cpp`, `ui.cpp`, `pickup.cpp`, `iexamine.cpp`, `character.cpp`) are byte-identical.

## 2. Conflicts and compile drift

| item                                         | resolution                                                                                                                                                                                                       |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/game.cpp` `#include` block (Spike 3.1A) | the **only** textual conflict. Upstream re-sorted the block and moved headers into `map/`, `overmap/`, `vehicle/`, `weather/`, `mapgen/`, `reload/`. Took upstream's block, re-added `arcopolis_backend_input.h` |
| `src/arcopolis_export.cpp`                   | **silent compile break**: `#include "map.h"` → `"map/map.h"` (commit `9ddea0f56f`). Every other include in the Arcopolis diff still resolves                                                                     |
| `src/main.cpp` `<arg_handler, 22>`           | upstream did not touch `main.cpp`; 22 entries = 17 upstream + 5 `--arcopolis-*`, recounted                                                                                                                       |

rerere recorded the new `game.cpp` resolution. AStyle reports the touched file unchanged.

## 3. Seam audit (skill points 1–7): all intact

- **CLI** — 22 entries, 5 flags present (`src/main.cpp:284`).
- **Input branch** — `next_backend_action()` still leads the dispatch chain (`src/handle_action.cpp:1946`).
- **Nested-input hook** — still leads `input_context::handle_input( const int timeout )` (`src/input.cpp:931-949`).
  Upstream did not touch `input.cpp` or `popup.cpp`.
- **do_turn** — clean-park intact (`src/game.cpp:2311`), `new_game` head unchanged (`src/game.cpp:2132`).
- **Prompt gates** — `ui.cpp` gained uilist **categories** (#9907/#9963), used only by the spell menus
  (`src/magic/magic.cpp:1958,2351`), never by a served menu. The `pickup.cpp` changes are include-only.
  `iexamine::deployed_furniture` only renamed `take_down_deployed_furniture` → `map_funcs::…`. The
  `output.cpp` hunks are draw helpers, not `query_yn`.
- **27B damage tap** — the `Character::apply_damage` body is byte-unchanged; the tap sits at
  `src/character.cpp:10074-10089`.
- **Include drift** — §2.

## 4. Behavior changes that merged clean (skill point 8)

| PR                                | where (synced tree)                                                                                                                                                                                                       | effect on the headless backend                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | class                                                                                                      |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| #10104 / #10127 / #10265          | `game::do_turn` → `refresh_player_visibility_cache_if_needed( true, true )` `src/game.cpp:2225-2229` (body `5060-5087`, `#if CATA_SDL`), gated: skipped during an activity or sleep when `ACTIVITY_SKIP_VISIBILITY` is on | the tiles visibility cache is now rebuilt once per turn **headless**, at turn start. `player_visibility_cache_current()` (`5599-5606`) turns true, so `mon_info_update` (`5612`) runs and sets `SAFE_MODE_STOP` (`5860`). **Within-turn parity is open:** the GUI also refreshes in `game::draw` between actions; headless does not (`draw` is a test_mode no-op), and the in-loop `mon_info_update` (`2256`) returns early once a mid-turn action dirties the cache. Multi-action turns (speed > 100, zero-cost actions) can differ from the GUI. Source-read, not run                                                                                                                          | **faithful at turn start**; within-turn parity unproven                                                    |
| (same)                            | `check_safe_mode_allowed` `src/game.cpp:12568-12622`; refused at `avatar_action::move` `src/avatar_action.cpp:368` and `ACTION_PAUSE` `src/handle_action.cpp:2192`                                                        | **WITNESSED:** with the pack's `SAFEMODE=true`, every `wait`/`move` with a hostile in view is refused ("Spotted zombie--safe mode is on! … x 8"), zero moves are used, and the turn never advances. The doc-62 §5 prediction now holds on tiles                                                                                                                                                                                                                                                                                                                                                                                                                                                  | **faithful**                                                                                               |
| (same)                            | `map::pl_sees` `src/map/lightmap.cpp:2041-2066` now needs only `variables_set`                                                                                                                                            | **WITNESSED:** exported `tiles[].seen` is now `true` (25 of 625 tiles in an attacker snapshot). The "headless seen is always false" claim is retired for tiles                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | **faithful**                                                                                               |
| #10163 (and possibly NPC-AI PRs)  | `build_map_cache( get_levz(), false )` `src/game.cpp:2397`: the lightmap is now rebuilt every turn; sight scales with `ambient_light_at` (`src/creature.cpp:491-492`)                                                     | **WITNESSED in the run snapshots** (gitignored `out/arco_fight_regress/*-contrast/*.json`; not in the `.out` logs): the shelter NPC Edwardo steps from `[6301,6420]` to `[6300,6421]`, beside the zombie, and attacks it ("Edwardo Stovall cuts the zombie"; contrast zombie hp 80→7, seed alpha). Before the sync he stayed put. In the attacker/liveness probe runs the "killed" reading is from snapshot messages ("The zombie dies!" after Edwardo's hits). **Cause not isolated** to one PR; #10163 is the leading candidate (before it, headless had only the load-time lightmap). The lightmap compute path the headless runs used (CPU vs GPU) was not recorded; NPC sight depends on it | engine NPC AI inside the unmodified `do_turn`; **likely faithful, cause unproven** (not an Arcopolis seam) |
| #10666                            | `game::suggest_auto_walk_to_stairs` `src/game.cpp:973-1016`; callers on the `vertical_move` failure paths `14485-14615`                                                                                                   | dropped the `u.sees( stair )` guard. Any reachable stair within 80 tiles now counts — real terrain (`terrain_leads_to_zlevel`) or remembered — and `SUGGEST_AUTOWALK_STAIRCASE` defaults to true (the pack does not override it). So a failed `vertical_move` near stairs now reaches `query_yn`. Unarmed, that fails loud as `unexpected_prompt` (`src/popup.cpp:277-285`) instead of the old add_msg no-op. No witness drives a failing vertical move                                                                                                                                                                                                                                          | **faithful**; fail-loud holds                                                                              |
| #10125                            | `u.process_items()` moved out of `process_turn` to `src/game.cpp:2459`                                                                                                                                                    | same per-turn work, slightly later in the tick                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | faithful                                                                                                   |
| #9756                             | `character_funcs::search_surroundings( u )` on every move `src/handle_action.cpp:2230` (`src/character_turn.cpp:1295`)                                                                                                    | consumes RNG only for seen, non-null traps within 5 tiles; now reachable headless because `sees()` works. It can shift seeded RNG near traps                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | faithful                                                                                                   |
| #10347                            | stair stamina check moved under climbing `src/game.cpp:14788`                                                                                                                                                             | stairs no longer cost or require stamina                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | faithful                                                                                                   |
| #10374                            | `submap::last_actualized` (`src/map/mapbuffer.cpp:3555,3563`; load `src/savegame_json.cpp:4635`)                                                                                                                          | the fixtures predate `turn_last_actualized`, so the first actualization replays plant/fruit/sap/rad catch-up for the whole game age, on every load (headless never saves). No witness asserts affected terrain                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | faithful save migration                                                                                    |
| #10403                            | option definitions moved to `data/json/options/*.json`; `options_manager::deserialize` `src/options.cpp:4289-4302`                                                                                                        | `config/options.json` format is unchanged (array of `{name,value}`). **WITNESSED:** flipping only `SAFEMODE` in a scratch pack removes the STOP (§5), so the option still loads                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | no change                                                                                                  |
| #10128 / #10219 / #10391 / #10449 | activity / sleep turn skipping: `try_activity_fixed_window_skip` (`src/game.cpp:2103`), `run_activity_skip_batch_turns`, the `ACTIVITY_SKIP_*` options                                                                    | batches turns during long activities and sleep. **Considered, not exercised:** no witness drives an activity or sleep                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | not audited further                                                                                        |

No row is a regression in the AGENTS.md sense: in every case the backend drives the same engine code
the GUI does. Safe mode and `seen` now behave as in the tiles GUI at turn granularity; within-turn parity and the NPC cause stay open (§6). The visibility refresh is `#if CATA_SDL` only: the curses build is unchanged by it.

## 5. Validation

- **Build** — `ccache -C`, wiped `out/build/win-rel-deb` (kept `vcpkg_installed`), fresh configure
  (`-S` this worktree). `cataclysm-bn-tiles` built clean: **500 compiles, 0 ccache hits**, exit 0,
  exe 2026-10-21 16:25. All Arcopolis TUs compiled fresh.
- **Catch2 `[arcopolis]` — PASS: `All tests passed (1044 assertions in 159 test cases)`**, exit 0
  (`CATA_TEST_COMPUTE_ACCELERATION=cpu`, child cwd = this worktree so the synced `data/` is used). The
  first two `cata_test-tiles` links failed on machine resources, not code: `LNK1201` (disk full writing
  the PDB), then `LNK1102` (out of memory: the pagefile had grown to ~32 GB and filled `C:`). Once memory
  and disk were freed, a plain relink succeeded (exe 2026-10-21 20:51).
- **Fixture regressions (21, pwsh, committed pack): 16 PASS / 5 FAIL.**
  - PASS: client_harness, examine, frontend_prototype, item_export, live_protocol, monster_export,
    movement, npc_export, prompt_menu, query_popup, script_prompt, slice,
    spike26a_dialogue_predicate, stage_a_return_condition, stairs_fixture, vertical_movement.
  - FAIL, safe mode (§4 row 2): attacker_damage (0 hits, 3/3 seeds), attacker_instance_ambiguity (0 hits),
    oneshot_damage (0/12), world_tick_liveness (clock never advances).
  - FAIL, NPC engagement (§4 row 4): fight_mechanic. It already pins `SAFEMODE=false`; its contrast
    arm (`contrast_hp_unchanged`) and `npc_noninterference` caught the new third-party damage source,
    which is the attribution gate working as designed.
- **Diagnostic probe (uncommitted; scratch copy of the pack with ONLY `SAFEMODE` → `false`):**
  attacker_instance_ambiguity PASS (3/3), oneshot_damage PASS (8/12 hits), attacker_damage 2/3 seeds
  (third seed: the zombie died to Edwardo's hits, per that run's snapshot messages). world_tick_liveness
  still FAIL, now on `mover_survived` / `npc_non_interference` (snapshot messages again show Edwardo's hits
  before "The zombie dies!"). This isolates the two causes. The snapshot evidence lives in the gitignored
  `out/` run dirs, not in the `.out` logs.

## 6. Follow-ups (not done here)

1. **Witness adaptation for safe mode** — the hostile-in-view witnesses need the doc-62 `SAFEMODE=false`
   sandbox pin (GUI-equivalent: the player turned safe mode off), or a pack-level default. This overlaps
   the planned faithful-by-default monster-fixture change, so it is left to that change.
2. **NPC non-interference by fixture design** — fight, liveness and attacker fixtures put the shelter
   NPC within reach of the zombie. Relocate or wall off the NPC in those generated fixtures. Pin the
   exact upstream cause first if the fix depends on it.
3. **`SAFEMODE=true` as a first-class witness** — safe mode now fires headless, so the long-deferred
   `safe_mode_blocked` fail-loud (declared, never emitted) can be witnessed. Today a blocked wait
   reports `status:"queued"` and the session ends `ok` with no turn advance. That is GUI-faithful (the
   GUI also only prints a message), but the backend says nothing explicit about the refusal.
4. **Stale "headless `seen` is always false" text** — `client_harness_regression.ps1` (PASS label,
   line ~258), docs 20/43/47/60, TEST_FIXTURES (~l.161-162), ARCOPOLIS_STATE (~l.398 and ~l.735), and
   the doc-43 terrain-attribution rationale. The harness's seen-gated `blocked_by=terrain` branch is now
   reachable.
5. **Within-turn safe-mode parity** — prove or bound the §4 gap (headless re-evaluates once per turn;
   the GUI also re-evaluates in `game::draw` between actions) with a multi-action-turn witness.
6. **Record the lightmap compute path** (CPU vs GPU) of headless runs. NPC sight depends on ambient light,
   and doc 00 shows the two paths differ by 1-2 light cells.
