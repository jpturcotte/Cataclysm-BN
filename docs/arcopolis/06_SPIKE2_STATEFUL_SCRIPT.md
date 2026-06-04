# Spike 2 — Headless Stateful Step-Script Runner

> Scope: the **third implementation** in the Arcopolis investigation. Builds directly on
> [03_SPIKE0_CURRENT_VIEW_EXPORT.md](03_SPIKE0_CURRENT_VIEW_EXPORT.md) and
> [05_SPIKE1_WAIT_COMMAND.md](05_SPIKE1_WAIT_COMMAND.md). Proves a **persistent backend lifecycle**:
> load a prepared world **exactly once**, then run an ordered JSON **step script** against the _live_
> game, writing a read-only "current view" snapshot between steps.
>
> Spike 0 delivered headless **load** + read-only **export**. Spike 1 delivered the first **command**
> (`wait`) but exposed a _lifecycle_ limitation: the one-shot model reloads the save per command, so
> every command re-enters the engine's first-post-load **bootstrap turn** and the calendar never
> advances. Spike 2 fixes the **lifecycle**, not the behavior — and shows the clock advancing on the
> second wait **with zero faking**.
>
> Explicitly **out of scope** (non-goals): a real scripting language (no loops/conditionals/variables,
> no nested scripts), movement, inventory, targeting, sockets/stdin/stdout, deltas, new dependencies,
> any UI screen, GUI modernization. The script is a flat list of two step kinds. JSON remains a
> bootstrap/debug format only.
>
> Line numbers below were read from the source during implementation; they drift as the code evolves.

## Fidelity principle (read this first)

**The GUI behavior is the engine behavior is the behavior, period.** A headless action must reproduce
**exactly** what the engine does, and must **never override engine state/flags** to make output look
nicer or to make a counter move. Spike 1 learned this the hard way (an earlier build cleared
`game::new_game` to force a tick; that ran the turn one tick ahead of the GUI — wrong, reverted). The
corollary AGENTS.md draws: _if the lifecycle makes faithful behavior inconvenient, fix the lifecycle._
Spike 2 is that fix.

## Summary

Two CLI flags, used **together**:

```
--arcopolis-run-script <script_path>
--arcopolis-export-dir <output_dir>
```

Given `--world <name> --arcopolis-run-script <script.json> --arcopolis-export-dir <dir>`, the binary
loads the world headlessly **once** (exactly as Spike 0), validates the step script, then executes its
steps in order against the persistent loaded game, writing one snapshot per `export` step into
`<dir>`, and exits `0`.

### Script schema (`schema_version` 1)

`export` is a _script-runner directive_, not a game command, so the two are separated by an `op` field
(this ages better as the backend command set grows):

```json
{
  "schema_version": 1,
  "steps": [
    { "op": "export", "name": "after_load" },
    { "op": "command", "command": "wait" },
    { "op": "export", "name": "after_wait_1" },
    { "op": "command", "command": "wait" },
    { "op": "export", "name": "after_wait_2" }
  ]
}
```

| `op`      | meaning                       | fields                                      | unsupported →                                 |
| --------- | ----------------------------- | ------------------------------------------- | --------------------------------------------- |
| `export`  | write a current-view snapshot | `name` (optional; defaults to `"snapshot"`) | —                                             |
| `command` | apply a backend command       | `command` (required string; only `"wait"`)  | unknown `command` → `unsupported_command` (6) |

An **unknown `op`** fails fast at parse with `bad_schema` (5); an unknown backend `command` is caught
at apply by the reused `apply_command` with `unsupported_command` (6).

## Why this matters for Arcopolis

The target architecture keeps BN authoritative for simulation while a separate frontend sends
high-level commands and receives snapshots; the frontend never mutates state directly. The three
capabilities, in order: (1) deterministic load — Spike 0; (2) read-only export — Spike 0; (3) command
execution — Spike 1. Spike 2 proves the **lifecycle** all three live in for a real session: a
_persistent_ backend that loads once and processes a stream of commands, exactly as a long-running
server would. It is the prerequisite for movement and, eventually, a live protocol.

## The persistent-lifecycle proof (the point of this spike)

Answered from the engine code, decisively (per AGENTS.md — not by experiment):

- `g->load(world)` → `game::setup()` sets **`new_game = true`** ([src/game.cpp:625](../../src/game.cpp)).
- `game::do_turn()` "Actual stuff" block ([src/game.cpp:1879](../../src/game.cpp)):

  ```cpp
  if( new_game ) {
      new_game = false;            // 1st do_turn after load: bootstrap turn — clock stays at T
  } else {
      gamemode->per_turn();
      calendar::turn += 1_turns;   // 2nd do_turn onward: normal turn — clock advances
  }
  ```

Because Spike 2 loads **once**, the sample script walks the engine through exactly one bootstrap turn
and then normal turns:

| step idx | step                  | `do_turn` # | `new_game` before | `backend.turn` after                                              |
| -------- | --------------------- | ----------- | ----------------- | ----------------------------------------------------------------- |
| 0        | export `after_load`   | —           | true              | **T**                                                             |
| 1        | command `wait`        | 1st         | true → false      | **T** — bootstrap turn (world processed at T, clock not advanced) |
| 2        | export `after_wait_1` | —           | false             | **T**                                                             |
| 3        | command `wait`        | 2nd         | false             | **T+1** — first normal turn (`calendar::turn += 1`)               |
| 4        | export `after_wait_2` | —           | false             | **T+1**                                                           |

**The second wait advances the clock to `T+1`.** We never touch `new_game`; the engine itself cleared
it on the first `do_turn`. The _only_ difference from Spike 1's "the clock never advances" is the
lifecycle (load once vs reload-per-command) — precisely what AGENTS.md predicted. This is the
end-to-end evidence that a persistent backend is feasible and faithful.

## Files changed

| File                              | Change                                                                                                                    |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `src/arcopolis_script.h`          | **new** — `script_step`, `run_script_options`, `parse_script`/`read_script_file`/`run_script`                             |
| `src/arcopolis_script.cpp`        | **new** — step-script JSON parse + the load-once stateful loop (export → `write_current_view`; command → `apply_command`) |
| `src/arcopolis_export.h`          | **modified** — `snapshot_session_info` + reusable `write_current_view(path, session?)`                                    |
| `src/arcopolis_export.cpp`        | **modified** — extract `write_current_view`; emit an optional `"session"` block (one-shot output unchanged)               |
| `src/arcopolis_command.h`         | **modified** — additive `command_error_kind::export_failed`                                                               |
| `src/arcopolis_command.cpp`       | **modified** — `exit_code_for(export_failed) = 9`                                                                         |
| `src/main.cpp`                    | **modified** — two flags + locals; `first_pass_arguments` grown `17 → 19`; mode-exclusive dispatch (`run_script` branch)  |
| `tests/arcopolis_script_test.cpp` | **new** — Catch2 unit tests for `parse_script`/`read_script_file` (`[arcopolis]`)                                         |

No build-system edit for `src/`: `src/CMakeLists.txt` globs `src/*.cpp` with `CONFIGURE_DEPENDS`. **No
new third-party dependency** — parsing reuses the in-tree `JsonIn` (`src/json.h`); snapshots reuse the
Spike 0 `JsonOut` + `write_to_file`; paths/dirs use `src/filesystem.h`; the zero-padded filename uses
the in-tree `string_format` (`src/string_formatter.h`). `tests/CMakeLists.txt` globs **without**
`CONFIGURE_DEPENDS`, so the new test file needs a one-time CMake **re-configure** to compile.

### main.cpp wiring

- New locals `arcopolis_script_path` / `arcopolis_export_dir` beside the Spike 0/1 paths (~src/main.cpp:205).
- Two `arg_handler`s mirroring `--arcopolis-command`; `first_pass_arguments` grown to
  `std::array<arg_handler, 19>` (a miscount is a compile error via `sizeof`).
- The dispatch becomes **mode-exclusive** (the two headless modes cannot be mixed; only `main.cpp`
  sees both flag sets), in the `load_static_data()` try-block before `init_ui` (~src/main.cpp:801):

```cpp
const bool arco_oneshot = !arcopolis_export_path.empty() || !arcopolis_command_path.empty();
const bool arco_script  = !arcopolis_script_path.empty() || !arcopolis_export_dir.empty();
if( arco_oneshot && arco_script ) { /* clear stderr; exit( 1 ) */ }
if( arco_script )  { std::_Exit( arcopolis::run_script( { .world = world, .script_path = …, .export_dir = … } ) ); }
if( arco_oneshot ) { std::_Exit( arcopolis::export_current_view( { … } ) ); }
```

`std::_Exit` is retained for the Spike 0 reason — after a full `game::load(world)` (and now repeated
`do_turn()`s), running BN's global/static destructors corrupts the heap; the snapshots are already
flushed, so terminate.

### Call path

```
main() [src/main.cpp ~801, arco_script std::_Exit branch]
  └─ arcopolis::run_script({ world, script_path, export_dir })   [src/arcopolis_script.cpp]
       ├─ read_script_file(script_path) → parse_script(JsonIn)   (validate schema/steps; no sim state)
       ├─ assure_dir_exist(export_dir)                           [src/filesystem.h]
       ├─ g->load( world )                                       (Spike 0; EXACTLY ONCE)
       └─ for each step, in order:
            ├─ op "export":  write_current_view(<dir>/NNN_<name>.json, session)   [src/arcopolis_export.cpp]
            └─ op "command": apply_command({ command })          [src/arcopolis_command.cpp]
                 └─ "wait": check_safe_mode_allowed() → do_pause(get_avatar()) + g->do_turn()  (no new_game clear)
```

## Output: filenames and the `session` block

Snapshots are written to `<export_dir>\<NNN>_<name>.json`, where **`NNN`** is the zero-padded
**export-sequence** index (0-based, counting only `export` steps), and `<name>` is the export's `name`
(sanitized via `ensure_valid_file_name`, defaulting to `snapshot`). For the sample script:

```
000_after_load.json
001_after_wait_1.json
002_after_wait_2.json
```

Each script-runner snapshot additionally carries a read-only `"session"` object (added right after
`schema_version`), so the JSON keeps **script-array traceability** even though the filename uses the
contiguous export index. `schema_version` stays **1** (the field is additive):

```jsonc
"session": {
  "export_index": 1,          // 0-based sequence among export steps
  "step_index": 2,            // 0-based index of this export within the script's steps[]
  "export_name": "after_wait_1"
}
```

The one-shot Spike 0/1 export passes `std::nullopt` and emits **no** `"session"` block — its output is
byte-identical to before. The `backend.turn` field (Spike 1) is what carries the clock proof above.

## How a `command` step is applied (reused from Spike 1, faithfully)

`run_script` does **not** re-implement `wait`. It calls `arcopolis::apply_command({ .command =
step.command })`, the Spike 1 path, which:

1. Mirrors the GUI `ACTION_PAUSE` safe-mode gate — `if( !g->check_safe_mode_allowed() )` declines
   (`safe_mode_blocked`, exit 8), exactly as pressing `'.'` would warn and not advance.
2. `character_funcs::do_pause( get_avatar() )` — the `'.'` mechanism (zero moves, pause/trap/wait
   effects).
3. `g->do_turn()` — advances through the engine's own path. With `moves == 0`, `do_turn`'s blocking
   input loop is skipped; everything else runs as a real turn. **`new_game` is never cleared** — the
   bootstrap turn on the first wait, normal turns thereafter (the proof above).

This keeps a single source of truth for "what `wait` does" and inherits Spike 1's headless-safety
analysis verbatim.

## Error handling & exit codes

`read_script_file`/`parse_script` return `std::expected<…, command_error>`; `run_script` maps every
failure through Spike 1's `exit_code_for`, printing `arcopolis: …` to stderr. Codes are shared with
Spike 1 so a frontend reads them uniformly; Spike 2 adds one (`export_failed = 9`):

| condition                                                                                                      | `command_error_kind`  | exit  |
| -------------------------------------------------------------------------------------------------------------- | --------------------- | ----- |
| missing `--world` / `--arcopolis-run-script` / `--arcopolis-export-dir`; world-load failure; **mode conflict** | — (pre-flight)        | 1     |
| script file does not exist                                                                                     | `missing_file`        | 2     |
| script file unreadable                                                                                         | `unreadable_file`     | 3     |
| malformed script JSON                                                                                          | `invalid_json`        | 4     |
| bad `schema_version`; `steps` not an array; step missing `op`; unknown `op`; `command` op without `command`    | `bad_schema`          | 5     |
| a backend `command` other than `wait`                                                                          | `unsupported_command` | 6     |
| recognised wait could not be applied (none yet)                                                                | `apply_failed`        | 7     |
| safe mode declined a wait                                                                                      | `safe_mode_blocked`   | 8     |
| snapshot write / export-dir creation failed                                                                    | `export_failed`       | **9** |

## Building

Use the proven ccache Ninja route from [00_WINDOWS_LOCAL_ENVIRONMENT.md](00_WINDOWS_LOCAL_ENVIRONMENT.md)
(VS 2022 DevShell + MSVC + Ninja + vcpkg short-roots; build dir `out/build/win-rel-deb`). After
DevShell activation:

```powershell
cmake --build .\out\build\win-rel-deb --target cataclysm-bn-tiles -- -j4
```

The build's post-step runs `docs:gen` / `deno fmt`, which dirties some generated tracked docs (e.g.
`docs/en/dev/reference/cli_options.md`) — revert that churn after building (`git checkout -- docs .claude`).

## Running & validation

The tiles exe is a **GUI-subsystem (WinMain)** binary, so use `Start-Process -Wait -PassThru
-RedirectStandard*` to capture the exit code reliably.

```powershell
$exe = ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe"
New-Item -ItemType Directory -Force .\out | Out-Null
@'
{ "schema_version": 1, "steps": [
  { "op": "export",  "name": "after_load" },
  { "op": "command", "command": "wait" },
  { "op": "export",  "name": "after_wait_1" },
  { "op": "command", "command": "wait" },
  { "op": "export",  "name": "after_wait_2" }
] }
'@ | Set-Content -Encoding ascii .\out\script_wait2.json

$p = Start-Process -FilePath $exe -ArgumentList @(
    '--world','ArcopolisTest',
    '--arcopolis-run-script','.\out\script_wait2.json',
    '--arcopolis-export-dir','.\out\arcopolis_session',
    '--userdir','.\arcopolis_user'
) -NoNewWindow -Wait -PassThru -RedirectStandardError C:\tmp\err.txt -RedirectStandardOutput C:\tmp\out.txt
"exit=$($p.ExitCode)"                         # expect 0
Get-ChildItem .\out\arcopolis_session         # expect 000_after_load / 001_after_wait_1 / 002_after_wait_2
$t0=(Get-Content .\out\arcopolis_session\000_after_load.json   -Raw|ConvertFrom-Json).backend.turn
$t1=(Get-Content .\out\arcopolis_session\001_after_wait_1.json -Raw|ConvertFrom-Json).backend.turn
$t2=(Get-Content .\out\arcopolis_session\002_after_wait_2.json -Raw|ConvertFrom-Json).backend.turn
"turns: $t0 -> $t1 -> $t2  (expect T, T, T+1)"   # PROOF: the second wait advances the clock
```

Expected: exit `0`; three snapshots; `t0 == t1` (bootstrap turn) and `t2 == t1 + 1` (the persistent
backend's first normal turn). Pass `--seed <string>` for bit-reproducible world processing (the RNG is
otherwise seeded from `time()`, like normal startup).

Error paths (distinct nonzero codes, one clean stderr line each):

```powershell
'{ not json'                                                  | Set-Content -Encoding ascii .\out\s_bad.json     # -> 4
'{ "schema_version": 2, "steps": [] }'                        | Set-Content -Encoding ascii .\out\s_ver.json     # -> 5
'{ "schema_version": 1, "steps": [ { "op": "wat" } ] }'       | Set-Content -Encoding ascii .\out\s_op.json      # -> 5
'{ "schema_version": 1, "steps": [ { "op": "command", "command": "fly" } ] }' | Set-Content -Encoding ascii .\out\s_cmd.json  # -> 6
# Mixing modes is rejected (exit 1):
#   --arcopolis-run-script … --arcopolis-command …  /  --arcopolis-export-current-view …
# Omitting --arcopolis-export-dir is rejected (exit 1).
```

`--help` lists both flags and exits before any load (no save needed):

```powershell
& ".\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe" --help | Select-String "arcopolis"
```

## Tests

`tests/arcopolis_script_test.cpp` unit-tests the parser/validation under `[arcopolis]` (valid script;
empty steps; omitted export name; bad `schema_version`; missing/non-array `steps`; step without `op`;
unknown `op`; `command` op without `command`; malformed JSON; missing file; `export_failed → 9`).
Because `tests/CMakeLists.txt` globs **without** `CONFIGURE_DEPENDS`, re-configure once, then build +
run:

```powershell
cmake .\out\build\win-rel-deb                      # re-glob to pick up the new test file
cmake --build .\out\build\win-rel-deb --target cata_test-tiles -- -j4
& ".\out\build\win-rel-deb\tests\cata_test-tiles.exe" "[arcopolis]"
```

The stateful **apply** path (load once + export/command loop) needs a fully loaded world and is **not**
unit-tested — the binary run above is its proof (same rationale as Spike 1).

## Acceptance criteria → coverage

| Criterion                                                                        | Status                                                       |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| `--arcopolis-run-script` / `--arcopolis-export-dir` recognized; sets `test_mode` | ✅ in `--help`; first-pass handlers                          |
| Require `--world` and `--arcopolis-export-dir`                                   | ✅ pre-flight guards, exit 1                                 |
| Load the world/save **exactly once**                                             | ✅ single `g->load(world)` in `run_script`                   |
| Execute steps in order; support only `export` + `command:wait`                   | ✅ load-once loop; `apply_command` for `wait`                |
| `export` → `<dir>\<NNN>_<name>.json`                                             | ✅ zero-padded export-sequence index                         |
| `wait` reuses `do_pause(get_avatar())` + `g->do_turn()`                          | ✅ via Spike 1 `apply_command` (with the GUI safe-mode gate) |
| Do **not** override `game::new_game`; do **not** fake calendar advance           | ✅ none overridden; advance emerges from load-once           |
| Exit 0 on success; clear nonzero on bad JSON/schema/op/command/export/wait       | ✅ `exit_code_for` 2–9 + stderr                              |
| No UI initialized; no main menu                                                  | ✅ `std::_Exit` before `init_ui`; modes mutually exclusive   |
| No movement/inventory/targeting/sockets/deltas/deps                              | ✅ none added                                                |

## Risks & what is still NOT proven

- **Long sessions / many turns headless.** The proof exercises two `do_turn`s. A long script (hundreds
  of turns) exercises more of `do_turn` headless than Spike 1 did; re-verify per the Spike 1 guardrail
  if a future step makes `do_turn` misbehave (UI/redraw, `sfx`, `autosave`, input/event) — document the
  failing call path; never suppress it or override engine state.
- **No teardown between commands.** This is the _point_ (persistence), but it means a step that leaves
  the game in a terminal state (avatar death during a wait → `do_turn` returns `true`) is not handled;
  the sheltered `ArcopolisTest` avatar will not trigger it.
- **Nondeterministic by default.** Like normal startup, the RNG is seeded from `time()` unless `--seed`
  is passed; pass `--seed` for reproducible snapshots.
- **Still a flat script, by design.** No control flow, variables, or live input — this is a lifecycle
  proof, not an automation language or a protocol.

## Next step (not in scope here)

> **Done:** movement landed in Spike 3.1A (input seam) and an offline viewer in Spike 4; see [ARCOPOLIS_STATE.md](ARCOPOLIS_STATE.md).

With `T → T → T+1` proven, the next meaningful proof is **movement** inside the persistent backend
(`export → move east → export → wait → export`) — spatial command execution with visible map changes,
still no frontend and no sockets. A tiny viewer becomes worthwhile only after that.

## PowerShell local checks

```powershell
# Flag + branch wiring in main.cpp
Select-String -Path .\src\main.cpp -Pattern 'arcopolis-run-script|arcopolis-export-dir|arco_script|arco_oneshot|std::array<arg_handler'

# The new files
Get-ChildItem .\src\arcopolis_script.h, .\src\arcopolis_script.cpp, .\tests\arcopolis_script_test.cpp

# Load-once + reused wait path; confirm NO new_game override (fidelity)
Select-String -Path .\src\arcopolis_script.cpp -Pattern 'g->load|apply_command|write_current_view|new_game'

# The engine bootstrap-turn branch the proof rests on
Select-String -Path .\src\game.cpp -Pattern 'if\( new_game|calendar::turn \+='
```
