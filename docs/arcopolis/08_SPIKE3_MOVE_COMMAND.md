# Arcopolis Spike 3 — Faithful cardinal `move` command

> **Scope:** implementation. Spike 3 was *explored* in
> [`07_SPIKE3_MOVEMENT_EXPLORATION.md`](07_SPIKE3_MOVEMENT_EXPLORATION.md) ("Recommendation A"); this
> doc records the implemented result. Source line numbers drift — trust symbol names over the numbers
> quoted here.

## Fidelity principle (non-negotiable)

**The GUI behavior is the engine behavior is the behavior, period.** A `move` command reproduces
exactly what Bright Nights does when a movement key is pressed: it resolves the direction with the
engine's own vocabulary, calls the engine's own `avatar_action::move`, and advances the turn **only when
the avatar's moves are spent** — the same condition as the GUI input loop (`while( u.moves > 0 )` in
`game::do_turn`). No engine state is faked; no `do_turn` is forced. See AGENTS.md "Arcopolis backend
fidelity".

## Summary

A new backend command `{ "command": "move", "direction": "move_e" }` moves the avatar one tile in a
cardinal direction through the persistent step-script runner (Spike 2). Four cardinals are supported
(`move_n` / `move_s` / `move_e` / `move_w`); diagonals, vertical moves, pathfinding, and interaction are
out of scope and rejected. One additive read-only snapshot field, `avatar.moves`, was added so the turn
behavior is explainable. JSON `schema_version` is unchanged (1) — `direction` and `avatar.moves` are
additive.

## Why this matters for Arcopolis

Movement is the first *state-changing, position-changing* command (wait only advanced time). It proves
the backend can apply a real spatial action through the faithful GUI path and report the new position,
the turn, and the remaining action points — the loop a mouse-first frontend needs for traversal.

## Prior backend state

- **Spike 0** — headless load + read-only current-view export.
- **Spike 1** — one `wait` through the real `ACTION_PAUSE` path; exposed the bootstrap-turn rule.
- **Spike 2** — persistent step-script runner (load once, export between steps); proved `T → T → T+1`.
- **Spike 3 (this)** — adds `move` to that runner.

## Files changed

| File | Change |
| --- | --- |
| `src/arcopolis_command.h` | `backend_command.direction`; declare `is_supported_move_direction`; doc updates |
| `src/arcopolis_command.cpp` | includes; `is_supported_move_direction`; `direction` in `parse_command`; `move` branch in `apply_command` |
| `src/arcopolis_script.h` | `script_step.direction` |
| `src/arcopolis_script.cpp` | parse + validate `direction` for `move`; pass `direction` into `apply_command` |
| `src/arcopolis_export.cpp` | additive `avatar.moves` snapshot field |
| `tests/arcopolis_command_test.cpp`, `tests/arcopolis_script_test.cpp` | `[arcopolis]` parser tests for `move` |

## Normal move call path (what the GUI does)

A movement key in the GUI reaches `handle_action()`'s `ACTION_MOVE_*` cases (`src/handle_action.cpp`),
which compute a delta with `get_delta_from_movement_action( act, iso_rotate::yes )` and call
`avatar_action::move( u, m, delta )` (`src/avatar_action.cpp`). That call lives inside
`game::do_turn`'s `while( u.moves > 0 )` input loop; when moves run out the loop exits and the rest of
`do_turn` (monsters, NPCs, environment, calendar) runs.

The backend mirrors this in `apply_command` (`src/arcopolis_command.cpp`): resolve → safe-mode gate →
`avatar_action::move` → advance the turn only if `get_avatar().moves <= 0`.

## Direction and action representation

`look_up_action( ident )` (`src/action.h`) maps an ident string to an `action_id`, e.g. `"move_e"` →
`ACTION_MOVE_RIGHT`; it returns `ACTION_NULL` for an unknown name **but still resolves diagonals
(`move_ne`/...) and vertical moves (`move_up`/`move_down`)**. So `look_up_action` alone cannot enforce
"cardinals only" — a cardinal-set membership check does. `get_delta_from_movement_action( action,
iso_rotate::no )` (`src/action.h`) turns the `action_id` into a `point_rel_ms` delta:

| ident | action_id | delta (x, y) |
| --- | --- | --- |
| `move_e` | `ACTION_MOVE_RIGHT` | (+1, 0) |
| `move_w` | `ACTION_MOVE_LEFT` | (−1, 0) |
| `move_n` | `ACTION_MOVE_FORTH` | (0, −1) |
| `move_s` | `ACTION_MOVE_BACK` | (0, +1) |

`iso_rotate::no` is used because headless `test_mode` loads no tileset — iso rotation only triggers
under `use_tiles && tile_iso`.

## Move entry point — faithful vs unfaithful

| Option | Verdict |
| --- | --- |
| **`avatar_action::move( get_avatar(), get_map(), delta )`** | ✅ chosen — the exact function the GUI keys call; runs the safe-mode gate, attacks/traps/terrain handling, and move-cost accounting |
| `game::walk_move` | ❌ a sub-step of the above; skips the GUI-level gate |
| `game::place_player` / direct `setpos` | ❌ teleports; pays no move cost; not what a keypress does |

`avatar_action.h` provides a `point_rel_ms` overload, so the 2-D delta is passed directly (z = 0). Its
`bool` result means "auto-move not cancelled", **not** "did move" — so it is not used as a movement
signal. Whether the avatar actually moved is read from the exported `avatar.pos_abs` across the
surrounding `export` snapshots.

## Turn-advance semantics (`do_turn` guard)

`do_turn()` is called **only when `get_avatar().moves <= 0`** after the move — the engine's own input-loop
exit condition. If moves remain ( > 0 ), the backend stays in the same partial turn and does **not** call
`do_turn` (doing so would enter `do_turn`'s blocking `handle_action()` input loop headlessly). Because the
world is loaded once, the first `do_turn` is the engine's bootstrap turn (processes at the loaded turn
`T`, clears `game::new_game`, does not advance the calendar); every later `do_turn` advances by one.
`avatar.moves` in the snapshot makes the resulting turn sequence explainable.

## Safety, blocking, and prompts

- **Safe-mode gate** reused from `wait`: `if( !g->check_safe_mode_allowed() )` → `safe_mode_blocked`
  (exit 8). `avatar_action::move` re-checks it internally too. `check_safe_mode_allowed()` is
  headless-safe (no popups/queries).
- **Scope kept to clean ground** — the first move scope targets passable, same-z terrain, avoiding any
  path that would reach a `query_yn`/`uilist` prompt.

## Command schema (additive; `schema_version` still 1)

```json
{ "op": "command", "command": "move", "direction": "move_e" }
```

| field | rule |
| --- | --- |
| `command` | `"move"` (new) or `"wait"` (existing) |
| `direction` | **required when `command == "move"`**; one of `move_n` / `move_s` / `move_e` / `move_w`. Missing, non-string, diagonal, vertical, or unknown → `bad_schema` (exit 5), rejected at parse time by `is_supported_move_direction`. |

A non-`move`/`wait` verb (e.g. `"fly"`) parses, then `apply_command` returns `unsupported_command`
(exit 6).

## Snapshot fields

Additive only: `avatar.moves` (the avatar's remaining action points). Everything else in the Spike 0–2
snapshot is unchanged; `schema_version` stays 1.

## Building (game + tests in one dir)

`cataclysm-bn-tiles-common` is a CMake **OBJECT** library shared by `cataclysm-bn-tiles` and
`cata_test-tiles`, so build both in the **same** `out/build/win-rel-deb` dir — the test target reuses the
game's compiled objects and only the ~169 test sources recompile + link. Do **not** create a separate
`out/build/win-tests` dir: it duplicates the whole ~10 GB object tree and has exhausted the disk here
(`fatal error C1085: ... No space left on device`). After the game build, re-configure the same dir with
`-DTESTS=True` and build the test target (see AGENTS.md "Arcopolis Windows build route" and
`docs/arcopolis/00_WINDOWS_LOCAL_ENVIRONMENT.md`):

```powershell
cmake -S . -B .\out\build\win-rel-deb -G Ninja -DTESTS=True (…same flags as the game configure…)
cmake --build .\out\build\win-rel-deb --target cata_test-tiles -- -j4
& ".\out\build\win-rel-deb\tests\cata_test-tiles.exe" "[arcopolis]"
```

## Validation

Run from the worktree root after building `cataclysm-bn-tiles` and copying the world fixture
(`Copy-Item C:\dev\arcopolis-fixtures\arcopolis_user .\arcopolis_user -Recurse -Force`; see AGENTS.md
"Arcopolis test world fixture").

```powershell
$exe = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe"
New-Item -ItemType Directory -Force .\out | Out-Null
@'
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "before_move" },
  { "op": "command", "command": "move", "direction": "move_e" },
  { "op": "export",  "name": "after_move" },
  { "op": "command", "command": "wait" },
  { "op": "export",  "name": "after_wait" }
] }
'@ | Set-Content -Encoding ascii .\out\script_move.json
$p = Start-Process -FilePath $exe -ArgumentList @(
    '--world','ArcopolisTest','--seed','arco-move',
    '--arcopolis-run-script','.\out\script_move.json',
    '--arcopolis-export-dir','.\out\arcopolis_move',
    '--userdir','.\arcopolis_user'
) -NoNewWindow -Wait -PassThru -RedirectStandardError C:\tmp\err.txt -RedirectStandardOutput C:\tmp\out.txt
"exit=$($p.ExitCode)"; Get-Content C:\tmp\err.txt
```

**Pass criteria:** exit 0; three snapshots; `after_move.avatar.pos_abs.x == before_move.avatar.pos_abs.x + 1`;
y and z unchanged; stderr empty; the `backend.turn` sequence explainable by `avatar.moves`.

### Result (this run — game build, `--seed arco-move`, world `ArcopolisTest`)

```
exit=0   stderr=[]   snapshots=3 (000_before_move, 001_after_move, 002_after_wait)
before pos_abs: 6301,6421,0
after  pos_abs: 6302,6421,0     # dx=+1, dy=0, dz=0
afterwait pos:  6302,6421,0     # wait does not move
turns:  1324801 -> 1324801 -> 1324802     # T -> T -> T+1
moves:  99 -> 98 -> 100
```

- **`move_e` moved the avatar +1 on x**, y and z unchanged — the hard criterion. ✅
- **`T → T → T+1`**, the faithful lifecycle: the move drove `moves` to ≤ 0, which fired the guarded
  `do_turn()`. As the first post-load `do_turn` it is the **bootstrap turn** — it processes the world at
  the loaded turn `T` and does **not** advance the calendar (then the bootstrap turn's upkeep replenished
  moves 99 → 98). The later `wait` is the second `do_turn` (normal), advancing `T → T+1`. No state faked.
- **`avatar.moves` explains it**: 99 (loaded) → 98 (move cost paid, then a turn's worth replenished by the
  bootstrap `do_turn`) → 100 (`wait`'s `do_pause` zeroed moves, the normal turn replenished a full turn).

Invalid inputs (each rejected before any UI; clear stderr):

| input | exit | stderr |
| --- | --- | --- |
| `move` without `direction` | 5 | `steps[0]: command 'move' requires a string 'direction'` |
| `direction:"east"` | 5 | `steps[0]: unsupported move direction 'east' (expected move_n/move_s/move_e/move_w)` |
| `direction:"move_ne"` (diagonal) | 5 | `steps[0]: unsupported move direction 'move_ne' ...` |
| `direction:"move_up"` (vertical) | 5 | `steps[0]: unsupported move direction 'move_up' ...` |
| `command:"fly"` | 6 | `step 0 (command 'fly'): unsupported command: 'fly'` |

Parser unit tests (`cata_test-tiles "[arcopolis]"`) cover the same schema rules in-process.

## Citation audit

| Claim | Implementing symbol |
| --- | --- |
| ident → action_id; resolves diagonals/vertical too | `look_up_action` (`src/action.cpp`) |
| action_id → `point_rel_ms` delta; iso gated by `use_tiles && tile_iso` | `get_delta_from_movement_action` (`src/action.cpp`) |
| faithful movement entry point (GUI keys call it) | `avatar_action::move` (`src/avatar_action.cpp`); `ACTION_MOVE_*` in `src/handle_action.cpp` |
| turn advances only when moves spent | `while( u.moves > 0 )` input loop in `game::do_turn` (`src/game.cpp`) |
| bootstrap turn skips `calendar::turn += 1` | `if( new_game )` branch in `game::do_turn` (`src/game.cpp`) |
| remaining action points | `Creature::moves` / `Creature::get_moves()` (`src/creature.h`) |
