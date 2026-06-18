# Arcopolis Spike 3 — cardinal `move` command — **FAILED (turn-structure inversion)**

> **Status: FAILED.** The `move` command was implemented and it does move the avatar one cardinal tile
> through `avatar_action::move`, but the spike did **not** meet its own fidelity bar. The backend applies
> the action **before** the turn's `do_turn` (`action → do_turn`), whereas the GUI applies it **inside**
> `do_turn`, after that turn's top half (`top-half → action → bottom-half`). That is a real
> **action/top-half inversion**: the backend evaluates every action one top-half "early" relative to the
> engine. The single `move_e` validation passed only because the first post-load turn is the bootstrap
> turn (no calendar advance), which masks the divergence; it shows from the second action on. This
> contradicts the spike's premise — that a _persistent stream_ is faithful by construction — so it is
> recorded as a failure and the fix is proposed below.
>
> Spike 2's persistent lifecycle (load once, pay the bootstrap once, clock advances `T → T → T+1`) is
> **not** what failed and still holds. What failed is the assumption that "load once + `command → do_turn`"
> also removes the action-ordering inversion. It does not. The inversion is **architectural and
> pre-existing** (Spikes 1–2 share it); movement is just the first command where it can be observably
> wrong, because a move reads/writes map state that the top half also touches.

> **Scope:** implementation. Spike 3 was _explored_ in
> [`07_SPIKE3_MOVEMENT_EXPLORATION.md`](07_SPIKE3_MOVEMENT_EXPLORATION.md) ("Recommendation A"); this
> doc records the implemented result. Source line numbers are from commit `792a2d2345`/`<this branch>`
> and drift — trust symbol names over the numbers quoted here.

## Fidelity principle (non-negotiable) — NOT met by this implementation

**The GUI behavior is the engine behavior is the behavior, period.** A faithful `move` would reproduce
exactly what Bright Nights does when a movement key is pressed. This implementation reproduces the
movement _call_ (`avatar_action::move`) and the _direction resolution_ (`look_up_action` →
`get_delta_from_movement_action`) faithfully, but **not the turn structure**: it runs the action outside
and before `do_turn` rather than at the `handle_action()` slot inside `do_turn`'s input loop. See
"Turn-structure inversion (why this spike FAILED)" below, and AGENTS.md "Arcopolis backend fidelity".

## Summary

A new backend command `{ "command": "move", "direction": "move_e" }` moves the avatar one cardinal tile
through the persistent step-script runner (Spike 2). Four cardinals are supported
(`move_n` / `move_s` / `move_e` / `move_w`); diagonals, vertical moves, pathfinding, and interaction are
out of scope and rejected. One additive read-only snapshot field, `avatar.moves`, was added. JSON
`schema_version` is unchanged (1).

**However, the implementation is marked FAILED**: the `command → do_turn` shape inverts the
action/top-half ordering relative to the engine's `do_turn`-driven input loop (details below). It must be
restructured to inject the command at the engine's input point before it can be called faithful.

## Why this matters for Arcopolis

Movement is the first _state-changing, position-changing_ command (wait only advanced time) and it is the
loop a mouse-first frontend needs for traversal. Precisely because movement reads/writes map state that
`do_turn`'s top half also touches, it is the first command where the action-placement inversion becomes
observable rather than benign — which is what surfaced the failure documented here. Getting the turn
structure right (Spike 3.1) is a prerequisite for every later spatial command.

## Prior backend state

- **Spike 0** — headless load + read-only current-view export.
- **Spike 1** — one `wait` through the real `ACTION_PAUSE` path; exposed the bootstrap-turn rule.
- **Spike 2** — persistent step-script runner (load once, export between steps); proved `T → T → T+1`.
- **Spike 3 (this)** — adds `move` to that runner.

## Files changed

| File                                                                  | Change                                                                                                    |
| --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `src/arcopolis_command.h`                                             | `backend_command.direction`; declare `is_supported_move_direction`; doc updates                           |
| `src/arcopolis_command.cpp`                                           | includes; `is_supported_move_direction`; `direction` in `parse_command`; `move` branch in `apply_command` |
| `src/arcopolis_script.h`                                              | `script_step.direction`                                                                                   |
| `src/arcopolis_script.cpp`                                            | parse + validate `direction` for `move`; pass `direction` into `apply_command`                            |
| `src/arcopolis_export.cpp`                                            | additive `avatar.moves` snapshot field                                                                    |
| `tests/arcopolis_command_test.cpp`, `tests/arcopolis_script_test.cpp` | `[arcopolis]` parser tests for `move`                                                                     |

## Normal move call path (what the GUI does)

A movement key in the GUI reaches `handle_action()`'s `ACTION_MOVE_*` cases (`src/handle_action.cpp`),
which compute a delta with `get_delta_from_movement_action( act, iso_rotate::yes )` and call
`avatar_action::move( u, m, delta )` (`src/avatar_action.cpp`). That call lives inside
`game::do_turn`'s `while( u.moves > 0 )` input loop; when moves run out the loop exits and the rest of
`do_turn` (monsters, NPCs, environment, calendar) runs.

The backend does **not** mirror this faithfully. `apply_command` (`src/arcopolis_command.cpp`) does:
resolve → safe-mode gate → `avatar_action::move` → `if(moves<=0) do_turn()`. That places the action
_before_ `do_turn`'s top half, not at the `handle_action()` slot _inside_ it — the inversion documented
in "Turn-structure inversion (why this spike FAILED)" below.

## Direction and action representation

`look_up_action( ident )` (`src/action.h`) maps an ident string to an `action_id`, e.g. `"move_e"` →
`ACTION_MOVE_RIGHT`; it returns `ACTION_NULL` for an unknown name **but still resolves diagonals
(`move_ne`/...) and vertical moves (`move_up`/`move_down`)**. So `look_up_action` alone cannot enforce
"cardinals only" — a cardinal-set membership check does. `get_delta_from_movement_action( action,
iso_rotate::no )` (`src/action.h`) turns the `action_id` into a `point_rel_ms` delta:

| ident    | action_id           | delta (x, y) |
| -------- | ------------------- | ------------ |
| `move_e` | `ACTION_MOVE_RIGHT` | (+1, 0)      |
| `move_w` | `ACTION_MOVE_LEFT`  | (−1, 0)      |
| `move_n` | `ACTION_MOVE_FORTH` | (0, −1)      |
| `move_s` | `ACTION_MOVE_BACK`  | (0, +1)      |

`iso_rotate::no` is used because headless `test_mode` loads no tileset — iso rotation only triggers
under `use_tiles && tile_iso`.

## Move entry point — faithful vs unfaithful

| Option                                                      | Verdict                                                                                                                             |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| **`avatar_action::move( get_avatar(), get_map(), delta )`** | ✅ chosen — the exact function the GUI keys call; runs the safe-mode gate, attacks/traps/terrain handling, and move-cost accounting |
| `game::walk_move`                                           | ❌ a sub-step of the above; skips the GUI-level gate                                                                                |
| `game::place_player` / direct `setpos`                      | ❌ teleports; pays no move cost; not what a keypress does                                                                           |

`avatar_action.h` provides a `point_rel_ms` overload, so the 2-D delta is passed directly (z = 0). Its
`bool` result means "auto-move not cancelled", **not** "did move" — so it is not used as a movement
signal. Whether the avatar actually moved is read from the exported `avatar.pos_abs` across the
surrounding `export` snapshots.

## Turn-structure inversion (why this spike FAILED)

This is the core finding. Read line by line against the current code (commit `792a2d2345`).

### What the GUI does — action is _inside_ `do_turn`

`main.cpp:930` drives the whole game as one repeated turn:

```cpp
while( !g->do_turn() );          // src/main.cpp:930
```

Inside a single `game::do_turn()` (`src/game.cpp:1846`), the order is **top half → action → bottom half**:

```
game::do_turn()                                             src/game.cpp:1846
  ├─ calendar gate:  if(new_game) new_game=false;           src/game.cpp:1879-1884
  │                  else calendar::turn += 1_turns;
  ├─ TOP HALF:       update_body(), weather, timed_events,  src/game.cpp:1907-1974
  │                  mission::process_all(), hordes, autosave …
  ├─ INPUT LOOP:     while( u.moves > 0 ) {                 src/game.cpp:1980
  │                      handle_action();   ← THE ACTION    src/game.cpp:2004
  │                  }
  └─ BOTTOM HALF:    scent.update(), monsters, vehicles …   src/game.cpp:2025+
```

The player's keypress is consumed at `handle_action()` (`src/game.cpp:2004`), which **runs after that
turn's top half** and inside the `while( u.moves > 0 )` loop.

### What the backend does — action is _before_ `do_turn`

`apply_command`'s move branch (`src/arcopolis_command.cpp:168-174`):

```cpp
avatar_action::move( get_avatar(), get_map(), delta );   // src/arcopolis_command.cpp:168  ← THE ACTION
if( get_avatar().moves <= 0 ) {                          // src/arcopolis_command.cpp:172
    g->do_turn();                                        // src/arcopolis_command.cpp:173  ← top half + bottom half
}
```

So the backend does **action → do_turn(top half → [input loop skipped, moves≤0] → bottom half)**.

### The inversion, lined up

```
turn boundary │←        turn N        →│←        turn N+1        →│
GUI           │ topN   ACTN   botN      │ topN+1  ACTN+1  botN+1   │
backend       │ ACTN   topN   botN      │ ACTN+1  topN+1  botN+1   │
                ^^^^^^^^^^^                ^^^^^^^^^^^^^
                action & top half swapped within every turn
```

- The action and that turn's top half are **transposed**. The backend evaluates `avatar_action::move`
  against state from _before_ `update_body()` / `weather` / `timed_events` / `mission::process_all()`
  have run for that turn; the GUI evaluates it _after_.
- For the **first** action this is partly hidden: the first `do_turn` is the bootstrap turn
  (`new_game == true`, set in `game::setup()` at `src/game.cpp:625`), so its calendar gate at
  `src/game.cpp:1879-1884` does **not** advance the clock — both GUI and backend sit at the loaded turn
  `T`. The divergence is purely the reordered top-half _processing_.
- From the **second** action on it is unambiguous: the GUI runs `topN+1` (which advances the calendar to
  `T+1`) **before** `ACTN+1`; the backend runs `ACTN+1` while the calendar still reads `T`, then `do_turn`
  advances to `T+1`. The action is evaluated one top-half behind the engine.

This is exactly the inversion the persistent stream was supposed to eliminate. It is **not** fixed by
loading once — loading once fixes the _bootstrap/clock_ problem (Spike 2), not the _action placement_
problem. The `command → do_turn` shape is structurally not the engine's `do_turn`-with-action-inside.

### Corrected `moves` / `avatar.moves` narrative

An earlier draft of this doc (and several mid-task explanations) got the `moves` story wrong in both
directions. The accurate mechanism, from the code:

- `avatar_action::move` → `g->walk_move` (`src/avatar_action.cpp:462`) charges the step's move cost, which
  for a normal-speed avatar (~100 moves/turn, ~100 terrain cost) drives `moves` to **≤ 0**.
- The guard (`src/arcopolis_command.cpp:172`) therefore fires `g->do_turn()`. As the first post-load
  `do_turn` this is the bootstrap turn (calendar held at `T`), and its bottom-half upkeep **replenishes
  moves** to ~98.
- The exported `avatar.moves` is the **post-`do_turn`** value (~98), so it does _not_ show the ≤ 0 dip at
  the decision point. Reading `moves == 98 > 0` from the snapshot and concluding "the move did not advance
  the turn" is wrong — the move _did_ advance it; the snapshot is taken after the refill.
- This is why the single-move validation reads `T → T → T+1`: `move_e` consumed the bootstrap turn at `T`,
  and the following `wait` is the first _normal_ turn → `T+1`.

### The case that proves the inversion is observable, not cosmetic

For an avatar whose per-turn moves exceed a single step's cost (haste/high speed, > 100 moves), one step
leaves `moves > 0`. The GUI's `while( u.moves > 0 )` loop (`src/game.cpp:1980`) then lets that avatar take
a **second action in the same turn**, before any top half. The backend's guard correctly skips `do_turn`
(matching the loop condition) and the next command applies in the same turn — but it still applies
_before_ the top half, so the divergence persists, and the bootstrap is consumed by whichever later
command first drives `moves ≤ 0`. The ordering is wrong regardless of speed; speed only changes how many
actions share a turn.

### Blocked move (wall bump) — this part _is_ faithful

When the destination is impassable on the same z and the avatar is sighted and unstunned, `walk_move`
returns false and `avatar_action::move` falls to the "Invalid move" branch
(`src/avatar_action.cpp:466-497`): because `waste_moves` is false (`src/avatar_action.cpp:467-469`), it
**spends no moves, prints nothing, returns false** — a silent no-op. The guard then leaves the turn open.
This matches the GUI (walking into a wall on flat ground costs nothing and does not end the turn) and is
the one turn-related behavior the spike got right. Observed: a 5×`move_e` script moved the avatar one tile
onto `t_floor`, then bumped `t_wall_w` four times with `moves`/`turn`/`pos` all frozen and empty stderr.

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

| field       | rule                                                                                                                                                                                                                           |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `command`   | `"move"` (new) or `"wait"` (existing)                                                                                                                                                                                          |
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
`out/build/win-tests` dir: it re-duplicates the whole object tree (~7–8 GB) and has exhausted the disk here
(`fatal error C1085: ... No space left on device`). The shared dir holding both targets is ~7.6 GB cold
(measured 2026-06-18); a routine incremental rebuild adds only ~a couple hundred MB. After the game build, re-configure the same dir with
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

- **`move_e` moved the avatar +1 on x**, y and z unchanged — the movement mechanic works. ✅
- **`T → T → T+1`** is observed, but this does **not** demonstrate fidelity — it is exactly the case that
  _masks_ the inversion. `move_e` drove `moves ≤ 0` and consumed the **bootstrap** turn at `T` (calendar
  held by `new_game`, `src/game.cpp:1879-1884`); the `wait` is the first normal turn → `T+1`. Because the
  bootstrap turn does no calendar advance, the action/top-half transposition has no visible calendar
  effect on this single step. A second moving action would expose it. ⚠️ See "Turn-structure inversion".
- **`avatar.moves` is post-`do_turn`**: 99 (loaded) → 98 (step cost drove it ≤ 0, then the bootstrap
  `do_turn`'s upkeep refilled to 98) → 100 (`wait`'s `do_pause` zeroed moves, normal turn refilled). The
  snapshot never shows the ≤ 0 dip; do not read `98 > 0` as "the turn didn't advance".

Invalid inputs (each rejected before any UI; clear stderr):

| input                            | exit | stderr                                                                               |
| -------------------------------- | ---- | ------------------------------------------------------------------------------------ |
| `move` without `direction`       | 5    | `steps[0]: command 'move' requires a string 'direction'`                             |
| `direction:"east"`               | 5    | `steps[0]: unsupported move direction 'east' (expected move_n/move_s/move_e/move_w)` |
| `direction:"move_ne"` (diagonal) | 5    | `steps[0]: unsupported move direction 'move_ne' ...`                                 |
| `direction:"move_up"` (vertical) | 5    | `steps[0]: unsupported move direction 'move_up' ...`                                 |
| `command:"fly"`                  | 6    | `step 0 (command 'fly'): unsupported command: 'fly'`                                 |

Parser unit tests (`cata_test-tiles "[arcopolis]"`) cover the same schema rules in-process.

## Proposed next step — fix the inversion (Spike 3.1) — ✅ done in Spike 3.1A

> Implemented and validated as Spike 3.1A (the input-seam turn driver); see [09_SPIKE3_1_INPUT_SEAM_EXPLORATION.md](09_SPIKE3_1_INPUT_SEAM_EXPLORATION.md) and [ARCOPOLIS_STATE.md](ARCOPOLIS_STATE.md).

The fix is to stop driving the engine with `command → do_turn` and instead **run the engine's own
`do_turn` loop and inject the command at the engine's input point** — i.e. where `handle_action()` is
called (`src/game.cpp:2004`), inside the `while( u.moves > 0 )` loop, after the top half. That makes the
command land in the exact slot a keypress does, eliminating the action/top-half transposition by
construction (the "permanent stream" the spike was meant to be).

Recommended approach, smallest faithful change first:

1. **Introduce a backend input source the engine pulls from.** Add a seam at the single
   `handle_action()` call site (`src/game.cpp:2004`) so that, in Arcopolis backend mode, the turn's
   action is taken from a queued backend command instead of the interactive input context. Concretely:
   a function the runner fills (`arcopolis::next_queued_action()` → an optional `action_id` + payload such
   as the movement delta) and a minimal branch at the call site that, when in backend mode and a command
   is queued, performs that action exactly as the matching `ACTION_*` case would (for movement: the same
   `get_delta_from_movement_action` + `avatar_action::move` the GUI case at
   `src/handle_action.cpp:1917-1961` runs). This is a gameplay-source touch at _one_ call site, which is
   why it was deferred — but it is the only way to be truly faithful, and it is now justified by this
   failure.
2. **Restructure `run_script` as a turn pump.** Instead of `for step: apply_command(...)`, the runner
   drives `while( !g->do_turn() )` and feeds queued commands at the input seam; `export` steps fire
   between turns (or at a defined sub-turn point). The bootstrap turn is consumed by the first real
   action exactly as in the GUI, with no special-casing.
3. **Re-validate against the GUI decisively from the code** (per AGENTS.md: answer from `do_turn`, do not
   "deduce then experiment"): with the seam in place, the action executes at `src/game.cpp:2004` after the
   top half, so `top → action → bottom` matches the GUI for every turn, not just the bootstrap.
4. **Keep the safe scope**: still cardinals-only, still the `avatar_action::move` path, still the
   safe-mode gate. Only the _turn placement_ changes.

Alternative considered and rejected: splitting `do_turn` into `do_turn_top()` / `do_turn_bottom()` so the
runner can sandwich the action (`top → action → bottom`) without touching the input loop. This also fixes
the ordering but forks a large, central engine function and risks drift from the real `do_turn`; the
input-seam approach reuses the engine's own structure and is lower-risk.

Out of scope for the fix, still: diagonals, vertical, pathfinding, interaction, multi-tile, protocol
surface.

## Retrospective — why this is logged as a failure

- **The spike's premise was that a persistent stream is faithful by construction.** It is not, as built:
  `command → do_turn` is not the engine's `do_turn`-with-action-inside, so the action/top-half ordering is
  inverted for every turn after the bootstrap. Loading once (Spike 2) fixed the clock, not the action
  placement; that distinction was missed until a reviewer (`chatgpt-codex-connector`, PR #10, P1) pushed
  on the `moves > 0` case.
- **Process failures during the task, recorded so they are not repeated:**
  - Claimed "byte-identical" / "faithful" from `docs/arcopolis/07` without re-verifying — an unproven,
    load-bearing claim. The `07` wording ("A/B-verified byte-identical for `wait`") should likewise be
    softened to what was actually checked.
  - Violated the AGENTS.md fidelity rule "answer from the code, don't spin up experiments to defer the
    question" by running snapshot probes to _deduce_ behavior, then mis-reading the post-`do_turn`
    `avatar.moves` value and flip-flopping on whether the move advanced the turn.
  - Briefly rationalized the inversion as an "accepted" property instead of a defect to fix. It is a
    defect; this doc reclassifies it.
- **What stands:** the direction vocabulary, the `avatar_action::move` entry point, the safe-mode gate, the
  blocked-bump no-op, the additive `avatar.moves` field, and the schema/parser validation are all correct
  and reusable by Spike 3.1. Only the turn driver must change.

## Citation audit

| Claim                                                                  | Implementing line (commit `792a2d2345`)                                                                                          |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| GUI drives the game as one repeated turn                               | `while( !g->do_turn() );` — `src/main.cpp:930`                                                                                   |
| GUI consumes the action _inside_ `do_turn`, after the top half         | `handle_action()` at `src/game.cpp:2004`, inside `while( u.moves > 0 )` at `src/game.cpp:1980`                                   |
| `do_turn` top half (update_body, weather, timed_events, missions…)     | `src/game.cpp:1907-1974`; `u.update_body()` at `src/game.cpp:1941`                                                               |
| `do_turn` bottom half (scent, monsters, vehicles…)                     | `src/game.cpp:2025+`                                                                                                             |
| bootstrap turn skips `calendar::turn += 1`                             | `if( new_game )` gate — `src/game.cpp:1879-1884`; `new_game = true` set in `setup()` `src/game.cpp:625`                          |
| **backend applies the action BEFORE `do_turn` (the inversion)**        | `avatar_action::move(...)` `src/arcopolis_command.cpp:168`, then `if(moves<=0) g->do_turn()` `src/arcopolis_command.cpp:172-173` |
| ident → action_id; resolves diagonals/vertical too                     | `look_up_action` `src/action.cpp` (≈460-491)                                                                                     |
| action_id → `point_rel_ms` delta; iso gated by `use_tiles && tile_iso` | `get_delta_from_movement_action` `src/action.cpp` (≈549-572)                                                                     |
| movement entry point (GUI keys call it)                                | `avatar_action::move` `src/avatar_action.cpp:99`; `ACTION_MOVE_*` `src/handle_action.cpp:1917-1961`                              |
| blocked same-z move spends no moves / silent                           | "Invalid move" branch `src/avatar_action.cpp:466-497`; `waste_moves` `src/avatar_action.cpp:467-469`                             |
| remaining action points                                                | `Creature::moves` / `Creature::get_moves()` `src/creature.h:576,737`                                                             |
