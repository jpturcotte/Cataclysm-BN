# Spike 1 — Headless Single "wait" Command

> Scope: the **second implementation** in the Arcopolis investigation. Builds directly on
> [03_SPIKE0_CURRENT_VIEW_EXPORT.md](03_SPIKE0_CURRENT_VIEW_EXPORT.md). Adds a headless way to apply
> **exactly one** high-level backend command to a loaded world and then export the resulting read-only
> "current view" snapshot — proving the frontend→backend **command path** end-to-end at minimal scope.
>
> Spike 0 delivered the first two Arcopolis backend capabilities (deterministic headless **load** and
> read-only state **export**). Spike 1 delivers the smallest slice of the third — **command execution**:
> validate a command, apply it through the engine's _real_ non-UI action mechanism, advance the simulation
> exactly as the game would (no more, no less), and re-export.
>
> Explicitly **out of scope**: movement, inventory, targeting, sockets/stdin/stdout, deltas, new dependencies,
> any UI screen, GUI modernization. JSON remains a bootstrap/debug format only.
>
> Line numbers below were read from the source during implementation; they drift as the code evolves.

## Fidelity principle (read this first)

**The GUI behavior is the engine behavior is the behavior, period.** There is no separate "headless mode" to
invent — BN's code _is_ the spec. A headless command must reproduce **exactly** what the engine does for the
same action, and must **never override engine state/flags** to make the output look nicer or to make a counter
move. If the lifecycle makes faithful behavior inconvenient, fix the **lifecycle**, not the behavior.

This principle was learned the hard way on this spike: an earlier build cleared `game::new_game` so the one
`do_turn()` would tick the calendar (turn `T → T+1`). That made the turn counter "advance" but ran the turn at
`T+1`, **one tick ahead of what the engine/GUI actually does** on the first turn after a load. It was wrong and
has been reverted. See AGENTS.md → "Arcopolis backend fidelity (NON-NEGOTIABLE)".

## Summary

Spike 1 adds one CLI flag, used **together with** the Spike 0 export flag:

```
--arcopolis-command <command_path>
```

Given `--world <name> --arcopolis-command <cmd.json> --arcopolis-export-current-view <out.json>`, the binary
loads the world headlessly (exactly as Spike 0), reads and validates the command JSON, applies the one
supported command, and writes the post-command snapshot, then exits `0`. The only command supported is:

```json
{ "schema_version": 1, "command": "wait" }
```

`wait` is applied through the engine's real pause action — `character_funcs::do_pause()` (the function the `'.'`
key invokes) — followed by one `game::do_turn()`. **We do not clear `game::new_game`.** A wait issued right
after a load is therefore the engine's **bootstrap turn**: it processes the world at the loaded turn `T`
(monsters move, fields/items tick, the avatar's `process_turn` runs) and — exactly like pressing `'.'` once in
the GUI after loading — does **not** advance the calendar. So a single one-shot wait reports the same
`backend.turn` it loaded with; the per-command clock advance you might expect is a property of a _persistent_
backend, not something to fake here (see "Lifecycle" under Risks).

## Why this matters for Arcopolis

The target architecture keeps BN authoritative for simulation while a separate frontend sends high-level
commands and receives snapshots; the frontend never mutates simulation state directly. The three needed
capabilities, in order:

1. **Deterministic state loading** — Spike 0.
2. **Read-only state export** — Spike 0.
3. **Command execution** — validate → apply → return new state. **Spike 1 is the first slice of (3).**

The "frontend never mutates state directly" invariant is preserved structurally: the frontend only ever hands
the backend a declarative command file; all mutation happens inside the backend via the engine's own action
path — faithfully, per the fidelity principle above.

## The flag

| Property                                                | Behavior                                                                                         |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Flag                                                    | `--arcopolis-command <command_path>` (first-pass `arg_handler`)                                  |
| Side effects                                            | Sets `test_mode = true` (skips window/SDL init) and stores `<command_path>`                      |
| Pairs with                                              | `--arcopolis-export-current-view <out>` (supplies the snapshot path) and `--world <name>`        |
| On success                                              | Applies the command (a wait = one engine turn at the loaded `T`), writes the snapshot, exits `0` |
| Missing output path                                     | `arcopolis: --arcopolis-command requires --arcopolis-export-current-view <path>` → exit `1`      |
| Command file missing                                    | clear stderr message → exit `2`                                                                  |
| File unreadable                                         | exit `3`                                                                                         |
| Invalid JSON                                            | exit `4`                                                                                         |
| Bad schema (wrong `schema_version` / missing `command`) | exit `5`                                                                                         |
| Unsupported command                                     | exit `6`                                                                                         |
| Apply failure                                           | exit `7`                                                                                         |
| Never                                                   | Enters the main menu / the interactive input loop; initializes the player-facing UI              |

Example (Windows, from the repo root so `data/`+`gfx/` resolve; `--userdir` sandboxes it):

```powershell
'{ "schema_version": 1, "command": "wait" }' | Set-Content -Encoding ascii .\out\cmd_wait.json
.\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe --world ArcopolisTest `
    --arcopolis-command .\out\cmd_wait.json `
    --arcopolis-export-current-view .\out\state_after.json --userdir .\arcopolis_user
```

## Files changed

| File                               | Change                                                                                                                                                      |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/arcopolis_command.h`          | **new** — `backend_command`, `command_error{kind,detail}`, `parse_command`/`read_command_file`/`apply_command`/`exit_code_for`                              |
| `src/arcopolis_command.cpp`        | **new** — JSON parse + schema validation (in-tree `JsonIn`) and the `wait` application (`do_pause` + `do_turn`, no `new_game` override)                     |
| `src/arcopolis_export.h`           | **modified** — `command_path` added to `export_current_view_options`; doc comment updated                                                                   |
| `src/arcopolis_export.cpp`         | **modified** — apply the command between load and export; add read-only `backend.turn` to the snapshot                                                      |
| `src/main.cpp`                     | **modified** — `--arcopolis-command` flag + local; `first_pass_arguments` grown `16 → 17`; headless branch fires on either path and forwards `command_path` |
| `tests/arcopolis_command_test.cpp` | **new** — Catch2 unit tests for the parser/validation (`[arcopolis]`)                                                                                       |

No build-system edit for `src/`: `src/CMakeLists.txt` globs `src/*.cpp` with `CONFIGURE_DEPENDS`. **No new
third-party dependency** — parsing reuses the in-tree `JsonIn` (`src/json.h`) over a `cata_ifstream`
(`src/fstream_utils.h`), mirroring `src/font_loader.cpp`. `tests/CMakeLists.txt` globs **without**
`CONFIGURE_DEPENDS`, so the new test file requires a one-time CMake **re-configure** before it compiles.

### main.cpp wiring

- New local `std::filesystem::path arcopolis_command_path;` beside `arcopolis_export_path` (~src/main.cpp:204).
- New `arg_handler` for `--arcopolis-command`, mirroring `--arcopolis-export-current-view`; `first_pass_arguments`
  grown to `std::array<arg_handler, 17>` (~src/main.cpp:243; a miscount is a compile error).
- The headless branch fires when **either** Arcopolis path is set and forwards the command path (~src/main.cpp:786):

```cpp
if( !arcopolis_export_path.empty() || !arcopolis_command_path.empty() ) {
    std::_Exit( arcopolis::export_current_view( {
        .world = world,
        .output_path = arcopolis_export_path.string(),
        .command_path = arcopolis_command_path.string()
    } ) );
}
```

`std::_Exit` is retained for the Spike 0 reason — after a full `game::load(world)` (and now a `do_turn()`),
running BN's global/static destructors corrupts the heap; the snapshot is already flushed, so terminate.

### Call path

```
main() [src/main.cpp ~786, std::_Exit branch]
  └─ arcopolis::export_current_view({ world, output_path, command_path })   [src/arcopolis_export.cpp]
       ├─ g->load( world )                                  (Spike 0, unchanged)
       ├─ if command_path set:                              (NEW)
       │    ├─ arcopolis::read_command_file(command_path)   [src/arcopolis_command.cpp]
       │    │     └─ file_exist → cata_ifstream → parse_command(JsonIn) → validate schema/command
       │    └─ arcopolis::apply_command(cmd)                [src/arcopolis_command.cpp]
       │         └─ "wait": if check_safe_mode_allowed() → do_pause(get_avatar()) + do_turn()  // GUI gate; no new_game clear
       └─ write_to_file( output_path, write_snapshot )      (Spike 0 writer + new backend.turn)
```

## How the `wait` command is applied (the core)

`wait` reuses the engine's existing **ACTION_PAUSE** mechanism — the `'.'` key — not the longer **ACTION_WAIT**
menu (`'|'`), whose entry point opens a `uilist` and has no clean non-UI path.

1. **Safe-mode gate** — `if( !g->check_safe_mode_allowed() ) → decline`. The GUI's `ACTION_PAUSE`
   (src/handle_action.cpp:1892) only pauses when `check_safe_mode_allowed()` is true; under a laser lock or a
   new visible threat (`SAFE_MODE_STOP`) it returns false and the GUI **neither pauses nor advances the turn** —
   it warns and leaves the avatar in control. We mirror that: if it returns false we decline the wait
   (`safe_mode_blocked`, exit 8) **without advancing the world**. The check is headless-safe (only
   `add_msg`/`press_x`, no popups). _Limitation:_ the per-turn threat scan (`mon_info_update`) runs inside
   `do_turn` and is private, so a threat first becoming visible _this_ turn isn't pre-assessed; the gate uses
   the loaded safe-mode / laser-lock state. (A persistent backend would close that gap.)
2. **`character_funcs::do_pause( get_avatar() )`** — src/character_turn.cpp:1080, declared
   src/character_turn.h:13. This is exactly what `ACTION_PAUSE` calls (src/handle_action.cpp:1893). It sets
   `who.moves = 0`, resets recoil, runs the martial-arts on-pause hooks, `search_surroundings`, and
   `wait_effects` — pure state mutation for a grounded, non-burning avatar.
3. **`g->do_turn()`** — public, src/game.h:216. Two things matter here, and both _honor the engine_:
   - **The bootstrap turn is left intact.** `game::setup()` (run by `g->load`) leaves `game::new_game == true`
     (src/game.cpp:625). The first `do_turn()` after a load takes the `if( new_game )` branch (src/game.cpp:1879)
     and **deliberately skips** `calendar::turn += 1_turns`. So this turn processes the world **at the loaded
     turn `T`** and does **not** advance the clock — precisely what pressing `'.'` once in the GUI does right
     after loading. We do **not** clear `new_game` to force a tick.
   - **No input is read.** The blocking keyboard read `handle_action()` (src/game.cpp:2004) lives inside
     `while( u.moves > 0 ... )` (src/game.cpp:1980), guarded by `if( u.moves > 0 ... )` (src/game.cpp:1979).
     Because `do_pause` left `moves == 0`, that input loop is skipped entirely. Everything else runs exactly as
     the engine's turn: monster/NPC movement (`monmove`/`npcmove`, src/game.cpp:2087–2090), `u.process_turn()`
     (src/game.cpp:2102), `world_tick()` (src/game.cpp:2192), light/visibility cache rebuild.

Net effect: one engine turn of world processing **at `T`**, with the calendar staying at `T` (the bootstrap
turn). The snapshot afterwards reports `backend.turn == T` — and you can see the world _did_ advance (e.g. the
visible-tile count changes as the light/visibility cache is rebuilt). Per-command clock advance is the job of a
_persistent_ backend, not this one-shot.

### Why `do_turn()` is safe to call headless here

This is the first headless one-shot to call the full `game::do_turn()` (Spike 0 only loaded + exported). The
sub-calls that run for a plain pause were checked against `test_mode`:

- `input_manager::pump_events()` (src/sdltiles.cpp:3928) early-returns `if( test_mode )` — no-op.
- The `ui_manager::redraw()` calls in `do_turn` are gated by `FORCE_REDRAW` (off by default) and by
  `wait_redraw`, which is **false** for a non-sleeping avatar with no activity/destination — i.e. a plain pause.
- `mon_info_update()` (src/game.cpp:4626) is pure monster-visibility data computation, not rendering.

Confirmed headless-clean by the end-to-end run (exit 0, no stray output). **Guardrail for future commands:** if
a later command makes `do_turn()` misbehave headless (a UI/redraw call, premature teardown, `sfx`, `autosave`,
input/event problem), **document the exact failing call path here** (file:line + the chain into `do_turn`)
rather than suppressing it — and never override engine state to hide it (fidelity principle).

## Error handling & exit codes

`read_command_file` / `apply_command` return `std::expected<…, command_error>` where `command_error{ kind,
detail }`. `exit_code_for(kind)` maps each kind to a distinct nonzero code so a frontend can tell failures
apart; `detail` is printed to stderr prefixed with `arcopolis:`.

| `command_error_kind`  | Exit | Cause                                                                                     |
| --------------------- | ---- | ----------------------------------------------------------------------------------------- |
| `missing_file`        | 2    | command file does not exist (`file_exist` false)                                          |
| `unreadable_file`     | 3    | file exists but `cata_ifstream` could not open it                                         |
| `invalid_json`        | 4    | `JsonError` thrown while parsing                                                          |
| `bad_schema`          | 5    | `schema_version` missing/≠1, or `command` missing/non-string                              |
| `unsupported_command` | 6    | a well-formed command other than `wait`                                                   |
| `apply_failed`        | 7    | recognised command could not be applied (none yet for `wait`)                             |
| `safe_mode_blocked`   | 8    | safe mode declined the wait (a threat is flagged) — mirrors the GUI's `ACTION_PAUSE` gate |

(Exit `0` = success; exit `1` = the pre-flight "command requires an output path" / missing `--world` guards.)

## Snapshot schema delta

`schema_version` stays **1** (the field is additive). One read-only field is added, inside `backend`:

```jsonc
"backend": { "game_version": "...", "save_version": 29, "turn": 1324801 }
//                                                       ^ NEW: to_turn<int>( calendar::turn )
```

`turn` exposes the engine's current calendar turn. **It honestly reflects the engine:** a single post-load
`wait` is the bootstrap turn, so `turn` is unchanged from the baseline export (the world still advanced; the
clock did not). Per-command advancement would appear once a _persistent_ backend lets the bootstrap turn happen
once at load and then issues normal turns. `to_turn` is src/calendar.h:187.

## Key design decisions

1. **`wait` = ACTION_PAUSE, not ACTION_WAIT.** ACTION_PAUSE (`'.'`, one turn) has a clean non-UI entry point
   (`do_pause`); ACTION_WAIT (`'|'`, a chosen duration) opens a `uilist` — no clean non-UI path, out of scope.
2. **Advance via `do_turn`, not a hand-rolled tick.** `process_activity`/`world_tick`/`monmove`/`npcmove` are
   private to `game`; the only external entry that advances a turn is `do_turn()`. Driving it with `moves == 0`
   reuses the real path instead of duplicating engine internals.
3. **Do NOT clear `new_game` (fidelity).** The first post-load turn is the engine's bootstrap turn; honoring it
   means the calendar stays at `T`. Forcing a tick was tried and reverted — see the principle at the top.
4. **Stream-based `parse_command` is public.** Parsing is split from file I/O so it can be unit-tested with a
   `std::istringstream` (no temp files), mirroring `tests/json_test.cpp`.
5. **`allow_omitted_members()` on the parsed object** (src/json.h:968). The parser may return early on a bad
   `schema_version`, so it tells BN's strict reader not to log an "unvisited member" json-error (which the
   Catch2 harness counts as a failure and which would also surface on stderr). Also lets a command file carry
   future/extra fields.
6. **`std::_Exit` retained** — same heap-corruption-on-teardown rationale as Spike 0.
7. **No normal-gameplay impact.** Every new path is gated behind the new CLI flags: on a launch without
   `--arcopolis-command`/`--arcopolis-export-current-view`, the `main.cpp` branch is skipped and the
   menu/`do_turn` loop is byte-for-byte unchanged. The `do_pause`/`do_turn` calls live only in `apply_command`,
   reachable solely from that gated, `std::_Exit`-ing path. No existing gameplay function was modified — they
   are only _called_, with no engine state overridden.

## Risks & what is still NOT proven

- **Lifecycle: one-shot ⇒ every command is the bootstrap turn.** Because the one-shot reloads for every command,
  every command re-enters the engine's first-post-load turn, which by design does not advance the calendar. So
  a one-shot `wait` never advances `backend.turn`. This is **correct** (it's what the engine does), but it means
  the clock won't move across one-shot commands. The fix is a **persistent** backend — load once, let the
  bootstrap turn happen once, then every subsequent command is a normal, clock-advancing turn exactly as in the
  GUI. That is the natural next spike; do **not** fake advancement by overriding `new_game`.
- **Full `game::do_turn()` headless — exercised here, but this spike is its first caller.** No Catch2 test drives
  the complete `game::do_turn()`. Confirmed headless-safe for a plain pause by the binary run; re-verify for any
  new command (see the guardrail above).
- **Why reverting the `new_game` clear is safe (evidence).** Before reverting, a controlled A/B build — same
  save, same command, RNG seed pinned via `--seed`, export _temporarily instrumented_ to also dump monster
  positions/hp, per-body-part body temperature, fields, and items — showed that clearing `new_game` changed
  **only** `backend.turn` (T+1 vs T); monsters, body temperature, fields, items, visibility, vitals, and
  position were byte-identical. (An unseeded first attempt showed a one-tile monster move that was pure
  `time()`-seed RNG noise.) An `once_every` probe confirmed the periodic gate flips at the boundary
  (`once_every(2_turns)` is `false` at `T`=1324801, `true` at `T+1`=1324802), but all three real `do_turn`
  periodic events (2.5 min / 5 min / 1 day) read `false` at **both** `T` and `T+1` here (last boundary was turn
  1324800), so no state-affecting boundary is crossed at this save. Conclusion: clearing `new_game` only moved
  the counter — it bought nothing real and deviated from the engine, so it was removed. The instrumentation was
  reverted after measuring. (Per-item _rot_ was not separately measured; assumes the base game mode.)
- **Other `do_turn` sub-calls run headless** — `sfx::*`, `autosave()` (sandboxed by `--userdir`; additionally
  inert on a headless wait because `quicksave()` early-returns on `moves_since_last_save == 0`, only incremented
  in the skipped input loop), overmap/horde ticks. Low risk, unverified.
- **Game-over during the wait** (avatar dies in a hazard → `do_turn` returns `true`) is not handled; the
  sheltered `ArcopolisTest` avatar will not trigger it.
- **`do_pause` open-air edge** — its only UI-ish branch (`g->vertical_move(0,true)`, src/character_turn.cpp:1099)
  requires standing on `t_open_air`; N/A for the sheltered fixture.
- **Nondeterministic by default.** Like normal startup, the command path seeds the RNG from `time()` unless
  `--seed <string>` is passed, so RNG-driven processing varies run-to-run. Pass `--seed` for reproducible output
  (verified bit-stable across repeats). Relevant to the deterministic-fixture spike.

## Verified result

Built with the proven ccache Ninja route (MSVC, `out/build/win-rel-deb` + `out/build/win-tests`) and run against
the prepared `ArcopolisTest` save (avatar "Nubia 'Single' Rosales", 14 wildlife monsters in the bubble):

- **Build:** `cataclysm-bn-tiles` and `cata_test-tiles` both link clean (MSVC, exit 0).
- **`--help`:** lists both `--arcopolis-export-current-view` and `--arcopolis-command`.
- **Wait happy-path (engine-faithful):** baseline export `backend.turn = 1324801`, `seen = 101`; after `wait`,
  `backend.turn = 1324801` (**unchanged — the bootstrap turn does not advance the clock**) but `seen = 115`
  (the world _was_ processed — `do_turn` rebuilt the light/visibility cache), avatar position unchanged
  (`85,85,0`), exit **0**, empty stderr.
- **Error paths (distinct exit codes, one clean stderr line each):** unsupported `command` → **6**;
  `schema_version: 2` → **5**; malformed JSON → **4**; missing file → **2**; command with no output path → **1**.
- **Unit tests:** `cata_test-tiles "[arcopolis]"` → **all 7 cases / 19 assertions pass**, exit 0.

## Building

Use the proven ccache Ninja route from [00_WINDOWS_LOCAL_ENVIRONMENT.md](00_WINDOWS_LOCAL_ENVIRONMENT.md)
(VS 2022 DevShell + MSVC + Ninja + vcpkg short-roots; build dir `out/build/win-rel-deb`). After DevShell
activation:

```powershell
cmake --build .\out\build\win-rel-deb --target cataclysm-bn-tiles -- -j4
```

The build's post-step runs `docs:gen` / `deno fmt`, which dirties some generated tracked docs (e.g.
`docs/en/dev/reference/cli_options.md`) — revert that churn after building (`git checkout -- <those files>`).

## Running & validation

The tiles exe is a **GUI-subsystem (WinMain)** binary, so use `Start-Process -Wait -PassThru -RedirectStandard*`
to capture the exit code reliably.

```powershell
$exe = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe"
New-Item -ItemType Directory -Force .\out | Out-Null
'{ "schema_version": 1, "command": "wait" }' | Set-Content -Encoding ascii .\out\cmd_wait.json

# Baseline (Spike 0 path) — record turn + visible-tile count
$p0 = Start-Process -FilePath $exe -ArgumentList @(
    '--world','ArcopolisTest','--arcopolis-export-current-view','.\out\state_before.json',
    '--userdir','.\arcopolis_user'
) -NoNewWindow -Wait -PassThru -RedirectStandardError C:\tmp\err0.txt -RedirectStandardOutput C:\tmp\out0.txt
$b = Get-Content .\out\state_before.json -Raw | ConvertFrom-Json

# Apply wait, then export
$p1 = Start-Process -FilePath $exe -ArgumentList @(
    '--world','ArcopolisTest','--arcopolis-command','.\out\cmd_wait.json',
    '--arcopolis-export-current-view','.\out\state_after.json','--userdir','.\arcopolis_user'
) -NoNewWindow -Wait -PassThru -RedirectStandardError C:\tmp\err1.txt -RedirectStandardOutput C:\tmp\out1.txt
$a = Get-Content .\out\state_after.json -Raw | ConvertFrom-Json
$seenB = ($b.tiles | Where-Object { $_.seen }).Count
$seenA = ($a.tiles | Where-Object { $_.seen }).Count
"exit=$($p1.ExitCode); turn $($b.backend.turn) -> $($a.backend.turn) (expect UNCHANGED: bootstrap turn)"
"seen $seenB -> $seenA (expect a change: do_turn processed the world)"

# Error paths return distinct nonzero codes
'{ "schema_version": 1, "command": "fly" }' | Set-Content -Encoding ascii .\out\cmd_bad.json
'{ not json'                                | Set-Content -Encoding ascii .\out\cmd_malformed.json
foreach ($c in @('.\out\cmd_bad.json','.\out\cmd_malformed.json','.\out\nope.json')) {
    $pe = Start-Process -FilePath $exe -ArgumentList @(
        '--world','ArcopolisTest','--arcopolis-command',$c,
        '--arcopolis-export-current-view','.\out\state_err.json','--userdir','.\arcopolis_user'
    ) -NoNewWindow -Wait -PassThru -RedirectStandardError C:\tmp\erre.txt -RedirectStandardOutput C:\tmp\oute.txt
    "$c -> exit=$($pe.ExitCode)"; Get-Content C:\tmp\erre.txt   # 6 (unsupported), 4 (invalid json), 2 (missing)
}
```

`--help` lists the flag and exits before any load (no save needed):

```powershell
& ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe" --help | Select-String "arcopolis"
```

## Tests

`tests/arcopolis_command_test.cpp` unit-tests the parser/validation under the `[arcopolis]` tag (valid wait,
wrong `schema_version`, missing `command`, malformed JSON, missing file, unsupported command, exit-code
mapping). Because `tests/CMakeLists.txt` globs **without** `CONFIGURE_DEPENDS`, re-configure once so the new
file is compiled, then build + run:

```powershell
cmake .\out\build\win-rel-deb                      # re-glob to pick up the new test file
cmake --build .\out\build\win-rel-deb --target cata_test-tiles -- -j4
& ".\out\build\win-rel-deb\tests\cata_test-tiles.exe" "[arcopolis]"
```

The `wait` **apply** path (do_pause + do_turn) needs a fully loaded world and is **not** unit-tested — the
binary run above is its proof.

## Acceptance criteria → coverage

| Criterion                                                          | Status                                                      |
| ------------------------------------------------------------------ | ----------------------------------------------------------- |
| `--arcopolis-command <command_path>` recognized                    | ✅ appears in `--help`; handled in `first_pass_arguments`   |
| Sets `test_mode` (headless)                                        | ✅ in the handler                                           |
| Loads world/save exactly as Spike 0                                | ✅ unchanged `g->load(world)`                               |
| Reads + validates `schema_version` and `command`                   | ✅ `parse_command` (`bad_schema` / `invalid_json`)          |
| Supports only `wait`                                               | ✅ `apply_command`; else `unsupported_command`              |
| Applies via existing non-UI mechanism                              | ✅ `character_funcs::do_pause(get_avatar())`                |
| Advances the sim exactly as the game would                         | ✅ one `game::do_turn()` = the engine bootstrap turn at `T` |
| Exports the snapshot after the command                             | ✅ Spike 0 writer + new `backend.turn`                      |
| Exit `0` on success                                                | ✅ `std::_Exit(0)`                                          |
| Clear nonzero errors (missing/invalid/unsupported/apply)           | ✅ `command_error_kind` → `exit_code_for` 2–7 + stderr      |
| No movement / inventory / targeting / sockets / deltas / deps / UI | ✅ none added; no engine state overridden                   |

## PowerShell local checks

```powershell
# Flag + branch wiring in main.cpp
Select-String -Path .\src\main.cpp -Pattern 'arcopolis-command|arcopolis_command_path|std::array<arg_handler'

# The new files
Get-ChildItem .\src\arcopolis_command.h, .\src\arcopolis_command.cpp, .\tests\arcopolis_command_test.cpp

# The wait application path — confirm NO new_game override (fidelity)
Select-String -Path .\src\arcopolis_command.cpp -Pattern 'do_pause|do_turn|new_game|unsupported|schema_version'

# do_turn input-loop guard + the new_game bootstrap-turn branch + pump_events test_mode early-return
Select-String -Path .\src\game.cpp -Pattern 'while\( u.moves > 0|handle_action\(\)|if\( new_game|calendar::turn \+='
Select-String -Path .\src\sdltiles.cpp -Pattern 'pump_events'

# Snapshot turn field
Select-String -Path .\src\arcopolis_export.cpp -Pattern 'backend.turn|to_turn|command_path'
```
