# Spike 3.1B — Clean-Park Hardening

> **Status: ✅ implemented (2026-06-02).** A scoped stabilization pass over the clean-park return that
> Spike 3.1A made load-bearing. **Not** a new feature spike (not "Spike 4", not "Spike 3.2"). It adds
> regression coverage and a small terminal-snapshot hook, and **explicitly defers** the full automated
> world-tick regression harness. Builds on
> [09_SPIKE3_1_INPUT_SEAM_EXPLORATION.md](09_SPIKE3_1_INPUT_SEAM_EXPLORATION.md).

## Why this is "Spike 3.1B"

Spike 3.1A delivered the backend **input-seam architecture**: the engine's `game::do_turn` runs verbatim,
each backend command's `action_id` is consumed at the real `handle_action()` input seam, and a gated
**clean-park** `return false` ends a script faithfully (see 09). 3.1A is the _feature_. This pass does not
add behavior to the backend boundary — it **hardens** one piece 3.1A introduced. Hence a point-release
suffix (`B`) on the same spike, not a new number.

## What "clean-park" is

`game::do_turn` has two halves:

- **top half** (`src/game.cpp` ~1879+): bootstrap handling + `calendar::turn += 1_turns` on non-bootstrap
  turns, weather, missions, body update, then the **input loop** (`while( u.moves > 0 ... )`) that calls
  `handle_action()`.
- **bottom half** (`src/game.cpp` ~2038+): the world tick — `vehmove`/`monmove`/`npcmove`,
  `u.process_turn`, `cleanup_dead`, `world_tick`, scent, fields, etc.

In backend mode the input loop's action comes from `arcopolis::next_backend_action()` (the seam at
`src/handle_action.cpp`). When the script is exhausted while the avatar may still have moves, the provider
sets `backend_input_done()` and returns `ACTION_NULL`, and `do_turn` takes the **clean-park** branch:

```cpp
// src/game.cpp (after the input loop's is_game_over() check)
if( arcopolis::backend_session_active() && arcopolis::backend_input_done() ) {
    return false;   // leave do_turn BEFORE the bottom half -- the world is NOT ticked
}
```

This is "the player stopped giving input mid-turn": the turn does not complete, the world does not tick,
and the avatar keeps its remaining moves. It is gated on `backend_session_active()` so normal play never
reaches it.

## Why clean-park is load-bearing

It is a **new, backend-only engine state** that the pre-backend turn loop never needed to express. Two
distinct ways it can regress:

1. **Fires during normal play** — if `backend_session_active()`/`backend_input_done()` ever read true
   outside a backend session, normal turns would mysteriously stop ticking. Mitigation: the gate must be
   _inert by default_.
2. **Stops working** — if the branch were turned into a `break` (falling through to the bottom half) or
   removed, the backend would tick the world on a turn the player "walked away" from — unfaithful.

So the gate's inertness and the park's existence both need explicit guarding.

## Why the full world-tick regression harness is deferred

The obvious automated test — "drive a turn, assert the world did/didn't tick" — runs into an
**observability wall** unique to this design:

- Snapshots are written **at the input-seam** (`next_backend_action`, inside the input loop), which is
  **before** the turn's bottom half.
- The clean-park **terminates the run**: once `backend_input_done()` is true, the script runner's
  `while( !backend_input_done() )` loop exits — there is no subsequent turn, and therefore no later
  `export` step.

Consequently a parked turn's _skipped_ bottom half is invisible to any `export` **step**: whether the
bottom half runs or not, its only observable effect (a monster stepping, a field aging) lands **after** the
last in-loop snapshot, and there is no next turn to capture it. Directly witnessing non-tick needs **all
three** of:

1. a deterministic world with **dynamic** state (a generated fixture + a placed monster),
2. the snapshot export extended to include that dynamic state (monster/field positions), and
3. a runner that diffs the parked turn's in-loop snapshot against a snapshot taken **after** `do_turn`
   returns.

Those are a much larger build (a new `--arcopolis-new-world` generator, monster/field export, a Python
harness, CTest/CI wiring). They are **deferred**; this pass builds only the small foundation (item 3's
hook) plus the cheap, world-independent guards.

## What this spike implemented instead

### 1. Provider / gate tests (`tests/arcopolis_backend_input_test.cpp`)

New world-independent `[arcopolis]` case **"arcopolis backend gate is inert without an active session"**:

- with no session begun, `backend_session_active()` **and** `backend_input_done()` are both `false`
  (so the `game.cpp` clean-park guard is dead code during normal play);
- a `begin → end` cycle arms then fully disarms the gate: after `end_backend_session()`,
  `backend_session_active()` is `false`, `backend_input_done()` is `false`, `backend_cursor() == 0`, and
  `backend_session_failure()` is empty (no leaked state, no queued action exposed).

This complements the existing lifecycle cases (begin→active, exhaust→done, "keeps moves > 0 across
commands"). It needs no loaded world.

### 2. Final-on-exit snapshot

On **clean** script completion the runner now writes one terminal snapshot **after** `do_turn` returns
from the clean-park path and **before** `end_backend_session()` clears state. Implementation:

- `arcopolis::snapshot_session_info` (`src/arcopolis_export.h`) gained `bool final` and its `step_index`
  became `std::optional<int>` (null for the terminal snapshot — it belongs to no `steps[]` entry).
  `write_session` (`src/arcopolis_export.cpp`) emits `"final"` and a value-or-`null` `step_index`.
- The inline-export body in `next_backend_action` was factored into a shared anon-namespace helper
  `write_session_snapshot(label, step_index, is_final)`; the new public
  `arcopolis::backend_write_final_snapshot()` (`src/arcopolis_backend_input.{h,cpp}`) reuses it with
  `label = "final"`, `step_index = nullopt`, `is_final = true`, reusing the session's running export index.
- `run_script` (`src/arcopolis_script.cpp`) calls it once after the engine loop, **suppressed only by a
  recorded failure** (game-over and stall already `return` inside the loop).

`schema_version` stays `1` (additive fields; BN readers skip unknown members).

### 3. Documentation

This file, plus a forward pointer added to 09.

## What final-on-exit snapshots are for

A **terminal state capture**: the backend state right as the run ends cleanly. It is written on **every**
clean completion, **regardless of the script's last step type** (export or command) — opt-out **only** on
failure, never opt-in. A `[after_load, wait, after_wait]` script now yields:

```
000_after_load.json    session.final = false, step_index = 0
001_after_wait.json     session.final = false, step_index = 2
002_final.json          session.final = true,  step_index = null
```

It is the **hook** a future world-tick witness would diff against (item 3 above). On its own — with the
current avatar/terrain-only export and a hand-made world — it captures terminal state for the frontend and
for manual inspection.

## What this spike does NOT prove

- It does **not** photograph "world does not tick" on the parked turn (see the observability wall above).
- It adds **no** generated world, monster/field export, harness, or CI.
- The final snapshot is terminal-state capture, **not** a tick witness.

## Future work (full automated world-tick regression coverage)

When desired, build the three deferred pieces: a deterministic `--arcopolis-new-world` generator (world +
default avatar + a placed monster, saved headlessly with `std::_Exit` per the existing flows), a read-only
extension of the snapshot export to include nearby monster/field state, and a cross-platform runner
(CTest-registered) that asserts the parked-turn in-loop snapshot equals the final-on-exit snapshot (no
tick) while a completed `wait` turn advances the monster (the world is live). See the superseded broad plan
for the full design.

## Validation

Build the game **and** tests in the single `win-rel-deb` dir (shared `cataclysm-bn-tiles-common` OBJECT
library; a second dir exhausts the disk — see
[00_WINDOWS_LOCAL_ENVIRONMENT.md](00_WINDOWS_LOCAL_ENVIRONMENT.md)). Copy the external `ArcopolisTest`
fixture first.

```powershell
$exe = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe"
Copy-Item C:\dev\arcopolis-fixtures\arcopolis_user .\arcopolis_user -Recurse -Force
New-Item -ItemType Directory -Force .\out | Out-Null

@'
{ "schema_version": 1, "steps": [
  { "op": "export", "name": "after_load" },
  { "op": "command", "command": "wait" },
  { "op": "export", "name": "after_wait" }
] }
'@ | Set-Content -Encoding ascii .\out\script_clean_park.json

$p = Start-Process -FilePath $exe -ArgumentList @(
    '--world','ArcopolisTest','--seed','arco-clean-park',
    '--arcopolis-run-script','.\out\script_clean_park.json',
    '--arcopolis-export-dir','.\out\arcopolis_clean_park',
    '--userdir','.\arcopolis_user'
) -NoNewWindow -Wait -PassThru -RedirectStandardError C:\tmp\err.txt -RedirectStandardOutput C:\tmp\out.txt

"exit=$($p.ExitCode)"; Get-Content C:\tmp\err.txt
$snapshots = Get-ChildItem .\out\arcopolis_clean_park\*.json | Sort-Object Name
foreach ($s in $snapshots) {
    $j = Get-Content $s.FullName -Raw | ConvertFrom-Json
    "$($s.Name): turn=$($j.backend.turn), final=$($j.session.final), export_index=$($j.session.export_index), step_index=$($j.session.step_index), name=$($j.session.export_name)"
}
```

**Expected:** exit `0`; three files `000_after_load` / `001_after_wait` / `002_final`; `002_final` has
`final=true` and a null `step_index`; the final snapshot is written before the session is cleared; stderr
empty. Unit run: `& ".\out\build\win-rel-deb\tests\cata_test-tiles.exe" "[arcopolis]"` — the new gate case
plus the existing cases pass.

### Results (this run, 2026-06-02, MSVC/Ninja/ccache `win-rel-deb`)

Built `cataclysm-bn-tiles` + `cata_test-tiles` (same dir) — both exit 0, no warnings on the changed files.

- **Unit:** `cata_test-tiles "[arcopolis]"` → **All tests passed (120 assertions in 29 test cases)** — the
  new gate-inertness case plus the prior 28 (was 113 assertions / 28 cases).
- **Manual** (`--arcopolis-run-script` of `[after_load, wait, after_wait]` vs `--world ArcopolisTest --seed
  arco-clean-park`) → exit `0`, empty stderr, three snapshots:

  | file                  | turn          | session.final | step_index | export_index | avatar.moves |
  | --------------------- | ------------- | ------------- | ---------- | ------------ | ------------ |
  | `000_after_load.json` | 1324801 (T)   | false         | 0          | 0            | 99           |
  | `001_after_wait.json` | 1324802 (T+1) | false         | 2          | 1            | 100          |
  | `002_final.json`      | 1324802 (T+1) | **true**      | **null**   | 2            | 100          |

  The `wait` ticked the world (T→T+1); the final-on-exit snapshot was written after the parked turn, reuses
  the running export index, and shows `moves = 100 > 0` (parked mid-turn). Raw final session block:
  `"session": { "export_index": 2, "step_index": null, "export_name": "final", "final": true }`. Existing
  export steps are unchanged apart from the additive `"final": false`.

## Files changed

| File                                     | Change                                                                               |
| ---------------------------------------- | ------------------------------------------------------------------------------------ |
| `src/arcopolis_export.h`                 | `snapshot_session_info`: `step_index` → `std::optional<int>`, add `bool final`.      |
| `src/arcopolis_export.cpp`               | `write_session`: emit `step_index` value-or-`null` and `final`.                      |
| `src/arcopolis_backend_input.h`          | declare `backend_write_final_snapshot()`.                                            |
| `src/arcopolis_backend_input.cpp`        | factor shared `write_session_snapshot` helper; add `backend_write_final_snapshot()`. |
| `src/arcopolis_script.cpp`               | `run_script`: write the final-on-exit snapshot on clean completion.                  |
| `tests/arcopolis_backend_input_test.cpp` | new gate-inertness `[arcopolis]` case.                                               |
| `docs/arcopolis/10_…md`, `09_…md`        | this doc + forward pointer.                                                          |
