# Spike 3.1C — Session Transcript for Stateful Script Runs

> **Status: ✅ implemented (2026-06-03).** An **observability** pass: a stateful script run now writes a
> machine-readable JSON Lines transcript (`<export_dir>\session.jsonl`) beside its snapshots. **Not** a new
> feature spike (not "Spike 4"): no new gameplay, no command, no protocol, no socket, no snapshot-schema
> change. Builds on [10_SPIKE3_1B_CLEAN_PARK_HARDENING.md](10_SPIKE3_1B_CLEAN_PARK_HARDENING.md).

## Why this is "Spike 3.1C"

Spike 3.1A delivered the accepted backend **input-seam architecture** (the engine's `do_turn` runs
verbatim; each command's `action_id` is consumed at `handle_action()`; a gated clean-park ends a script
faithfully — see 09). Spike 3.1B hardened that clean-park and added the final-on-exit snapshot (see 10).
3.1C adds **no behavior to the backend boundary** — it records the run that the seam already drives. Hence
another point-release suffix (`C`) on the same spike, not a new number.

## Why the transcript exists

A stateful run already emits numbered snapshot files (`NNN_<name>.json`). But nothing records the run **as
a sequence**: what was queued, in what order, which snapshot resulted, and how the session ended. A future
viewer/frontend would have to _infer_ the run by globbing and sorting snapshot files. The transcript makes
the sequence explicit and machine-readable, so **transcript + snapshots are sufficient to reconstruct the
whole script run** without guessing.

JSON Lines (one JSON object per `\n`-terminated line) is the natural fit for an append-only, log-like,
streamable record: each event is written and **flushed immediately**, so the file is readable while or
right after the run, and a reader can consume it line-by-line without loading the whole file.

## Prior backend state

- **Spike 0** — headless load + one-shot current-view snapshot.
- **Spike 1** — one `wait` command (bootstrap turn).
- **Spike 2** — persistent `--arcopolis-run-script` + `--arcopolis-export-dir`: load once, run a step
  script, snapshot per `export`.
- **Spike 3** — movement; FAILED (`command → do_turn` inverted the turn structure).
- **Spike 3.1A** — fixed: backend is a pure input source at the `handle_action` seam.
- **Spike 3.1B** — clean-park hardening + final-on-exit snapshot.
- **Spike 3.1C** — this pass: the session transcript.

## The transcript

One file, `<export_dir>\session.jsonl`, opened (truncating) when the run starts and closed when it ends.
UTF-8, binary mode so newlines stay LF-only. Written by a small, engine-free module
(`src/arcopolis_session_log.{h,cpp}`) using the existing `JsonOut` (compact, one object per line) and the
existing UTF-8-safe `cata_ofstream` — **no new dependency**, `schema_version = 1`.

### Event schema (`schema_version = 1`)

Every record carries `schema_version` and `event`. Fields marked _(opt)_ are omitted when absent; an
_(opt-null)_ field is written as JSON `null`.

| event           | fields                                                                                                                                |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `session_start` | `world`, `seed` _(opt)_, `export_dir`, `game_version`                                                                                 |
| `command`       | `step_index`, `command`, `direction` _(opt)_, `action_id` _(opt)_, `status` (always `"queued"`)                                       |
| `export`        | `step_index` _(opt-null)_, `export_index`, `name`, `path` (relative `NNN_<name>.json`), `final`, `turn`, `pos_abs` `[x,y,z]`, `moves` |
| `error`         | `step_index` _(opt)_, `kind`, `detail`, `exit_code`                                                                                   |
| `session_end`   | `status` (`"ok"`/`"error"`), `snapshots`, `commands`, `final_turn` _(opt)_, `final_pos_abs` _(opt)_                                   |

Semantics worth stating:

- A **`command` record describes what was _queued_** into the engine (`status: "queued"`), with the
  resolved engine action ident (`action_ident()`, e.g. `"pause"`, `"move_back"`). The **observable result**
  of a command is the **following `export`/snapshot**, not the command record. This spike deliberately
  invents **no** deep command-result semantics.
- An **`export` record's `turn`/`pos_abs`/`moves` mirror the snapshot it names.** They are read with the
  _same accessors the snapshot uses_ (`current_snapshot_summary()`) at the _same instant_ the snapshot was
  written (no turn runs between), so they equal that snapshot's `backend.turn` / `avatar.pos_abs` /
  `avatar.moves`. This is a build-time invariant, confirmed by the validation below — not a forever-proof.
- `export.path` is a **relative** filename, never a machine-local absolute path, so the transcript is
  portable beside its snapshot directory.
- `seed` is **omitted** this spike: the CLI `--seed` is a `main.cpp` local and is not threaded into the
  backend session, and the task marks it "if available". Threading it through `run_script_options` is a
  cheap future enhancement if deterministic-seed reproduction is wanted.

### Example `session.jsonl`

For the script `export → move_s → export → move_s → export → wait → export`:

```json
{"schema_version":1,"event":"session_start","world":"ArcopolisTest","export_dir":".\\out\\arco_3v1c","game_version":"<version>"}
{"schema_version":1,"event":"export","step_index":0,"export_index":0,"name":"start","path":"000_start.json","final":false,"turn":1324801,"pos_abs":[6301,6421,0],"moves":99}
{"schema_version":1,"event":"command","step_index":1,"command":"move","direction":"move_s","action_id":"DOWN","status":"queued"}
{"schema_version":1,"event":"export","step_index":2,"export_index":1,"name":"after_move1","path":"001_after_move1.json","final":false,"turn":1324802,"pos_abs":[6301,6422,0],"moves":98}
{"schema_version":1,"event":"command","step_index":3,"command":"move","direction":"move_s","action_id":"DOWN","status":"queued"}
{"schema_version":1,"event":"export","step_index":4,"export_index":2,"name":"after_move2","path":"002_after_move2.json","final":false,"turn":1324803,"pos_abs":[6301,6423,0],"moves":72}
{"schema_version":1,"event":"command","step_index":5,"command":"wait","action_id":"pause","status":"queued"}
{"schema_version":1,"event":"export","step_index":6,"export_index":3,"name":"after_wait","path":"003_after_wait.json","final":false,"turn":1324804,"pos_abs":[6301,6423,0],"moves":100}
{"schema_version":1,"event":"export","step_index":null,"export_index":4,"name":"final","path":"004_final.json","final":true,"turn":1324804,"pos_abs":[6301,6423,0],"moves":100}
{"schema_version":1,"event":"session_end","status":"ok","snapshots":5,"commands":3,"final_turn":1324804,"final_pos_abs":[6301,6423,0]}
```

(These are the **actual** values from the validation run below; `action_id` is the engine ident
`action_ident()` returns — `DOWN` for `move_s`, `pause` for `wait`.)

## Logger semantics (best-effort, but never obscuring the backend)

- **`session_end` is written on every `run_script` return path _after_ the log opened** — clean
  completion, game-over, stall, and export-write failure all close the transcript out. (Pre-flight
  failures — bad script JSON, an unsupported command/direction, a missing world — return _before_ the log
  opens, so no transcript is produced and none is owed.)
- **The transcript is a default deliverable, so it fails fast on open.** If `session.jsonl` cannot be
  opened, `run_script` surfaces a clear typed `export_failed` error (exit 9) **before** driving the engine
  — at that point no backend result exists to mask, and a bad export dir is caught here rather than on the
  first snapshot.
- **Once open, the writer is best-effort and never overrides the real backend result.** An `error` record
  is written at the single point of detection (e.g. a snapshot write failure inside
  `write_session_snapshot`), and the _backend's_ typed error still owns the process exit code. The writer
  invents no recovery behavior.
- **Flush discipline.** Every event flushes immediately; `end_session_log` flushes + closes before
  `run_script` returns — which is before the `std::_Exit(arcopolis::run_script(...))` at `main.cpp` that
  bypasses normal teardown. `main.cpp` is unchanged.

## How it supports a future viewer

A read-only viewer can tail `session.jsonl` and render the run as a timeline: each `command` is an input
event; the `export` that follows is the resulting frame (open `export.path` for the full snapshot, or use
the inline `turn`/`pos_abs`/`moves` for a cheap summary); `error`/`session_end` close the story. Because the
file is flushed per line, a viewer can follow a run live. No parsing of file names, no sorting, no
inference — the order and the wiring are explicit.

## What it does NOT solve

- **No new gameplay** — no new command, direction, examine, targeting, inventory, interaction, pathfinding,
  diagonal/vertical movement.
- **No snapshot-schema change** — the per-snapshot JSON is byte-for-byte unchanged (only the new sibling
  transcript file is added).
- **No deltas** — each `export` references a full snapshot; the transcript carries only a scalar summary,
  not a diff.
- **No protocol / sockets / stdin-stdout mode / JSONL _command input_** — the transcript _describes_ a run;
  it is not a command channel. Input is still the existing `--arcopolis-run-script` JSON step file.
- **No deep command-result semantics** — a `command` record says only that the action was queued.

## Why it is not yet a live protocol

A transcript is a one-way, file-based _record_ of a completed (or failed) run. A live protocol would need
the inverse direction (commands _in_), a transport (socket/stdin), framing, request/response correlation,
back-pressure, and error/ack semantics — none of which exist here and all of which are explicitly out of
scope. Keeping 3.1C to an append-only file avoids prematurely committing to a wire format: the same events,
if a protocol is later wanted, can be emitted over a transport, but the file form is sufficient (and
simpler) for the current frontend-readiness goal.

## Files changed

| File                                   | Change                                                                                              |
| -------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `src/arcopolis_session_log.h`          | **new** — event structs, pure `write_*_line` formatters, stateful session API.                      |
| `src/arcopolis_session_log.cpp`        | **new** — `JsonOut` formatters + `cata_ofstream` singleton, flush per line.                         |
| `src/arcopolis_export.h` / `.cpp`      | add `snapshot_summary` + `current_snapshot_summary()` (same accessors as the snapshot).             |
| `src/arcopolis_backend_input.cpp`      | emit `command` (in `next_backend_action`) + `export`/`error` (in `write_session_snapshot`).         |
| `src/arcopolis_script.cpp`             | `run_script`: open the transcript (fail-fast), and `error`/`session_end` on every post-open path.   |
| `tests/arcopolis_session_log_test.cpp` | **new** — `[arcopolis]` formatter unit tests (valid JSON Lines, per-event fields, omit/null rules). |
| `docs/arcopolis/11_…md`                | this doc.                                                                                           |

CMake needs no edit: `src/`/`tests/` are globbed.

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
  { "op": "export",  "name": "start" },
  { "op": "command", "command": "move", "direction": "move_s" },
  { "op": "export",  "name": "after_move1" },
  { "op": "command", "command": "move", "direction": "move_s" },
  { "op": "export",  "name": "after_move2" },
  { "op": "command", "command": "wait" },
  { "op": "export",  "name": "after_wait" }
] }
'@ | Set-Content -Encoding ascii .\out\arco_3v1c.json

$p = Start-Process -FilePath $exe -ArgumentList @(
    '--world','ArcopolisTest','--seed','arco-3v1c',
    '--arcopolis-run-script','.\out\arco_3v1c.json',
    '--arcopolis-export-dir','.\out\arco_3v1c',
    '--userdir','.\arcopolis_user'
) -NoNewWindow -Wait -PassThru -RedirectStandardError C:\tmp\arco_3v1c_err.txt -RedirectStandardOutput C:\tmp\arco_3v1c_out.txt
"exit=$($p.ExitCode)"; "stderr:"; Get-Content C:\tmp\arco_3v1c_err.txt

# Transcript checks
$dir   = ".\out\arco_3v1c"
$objs  = Get-Content "$dir\session.jsonl" | ForEach-Object { $_ | ConvertFrom-Json }   # every line parses
"$($objs[0].event) ... $($objs[-1].event)"                                              # session_start ... session_end
$objs | Where-Object { $_.event -eq 'export' } | ForEach-Object {
    $snap = Get-Content (Join-Path $dir $_.path) -Raw | ConvertFrom-Json
    "{0,-22} final={1,-5} turn {2}=={3} moves {4}=={5} pos=[{6}]==[{7}]" -f `
        $_.path, $_.final, $_.turn, $snap.backend.turn, $_.moves, $snap.avatar.moves, `
        ($_.pos_abs -join ','), ($snap.avatar.pos_abs -join ',')
}
```

**Expected:** exit `0`; `C:\tmp\arco_3v1c_err.txt` empty; first event `session_start`, last `session_end`;
3 `command` events in step order; every `export.path` exists; each export's `turn`/`pos_abs`/`moves` equal
the referenced snapshot's; one `export` with `final:true` (the final-on-exit snapshot);
`session_end.snapshots == 5`, `commands == 3`. Unit run:
`& ".\out\build\win-rel-deb\tests\cata_test-tiles.exe" "[arcopolis]"`.

Negative path (reviewer-requested) — an unsupported direction is rejected at pre-flight, _before_ the
transcript opens, so no `session.jsonl` is produced and the typed error owns the exit code:

```powershell
@'
{ "schema_version": 1, "steps": [ { "op": "command", "command": "move", "direction": "move_ne" } ] }
'@ | Set-Content -Encoding ascii .\out\arco_3v1c_bad.json
$pb = Start-Process -FilePath $exe -ArgumentList @(
    '--world','ArcopolisTest','--arcopolis-run-script','.\out\arco_3v1c_bad.json',
    '--arcopolis-export-dir','.\out\arco_3v1c_bad','--userdir','.\arcopolis_user'
) -NoNewWindow -Wait -PassThru -RedirectStandardError C:\tmp\arco_3v1c_bad_err.txt
"exit=$($pb.ExitCode)"; Test-Path .\out\arco_3v1c_bad\session.jsonl
```

**Expected (negative):** exit `5` (`bad_schema`); `session.jsonl` absent (failure precedes log-open).

### Results (this run, 2026-06-03, MSVC/Ninja/ccache `win-rel-deb`)

Built `cataclysm-bn-tiles` + `cata_test-tiles` (same dir) — both exit 0, no warnings on the changed files.

- **Unit:** `cata_test-tiles "[arcopolis]"` → **All tests passed (204 assertions in 41 test cases)** — the
  12 new session-log formatter cases plus the prior 29.
- **Positive** (`--arcopolis-run-script` of `export → move_s → export → move_s → export → wait → export`,
  `--world ArcopolisTest --seed arco-3v1c`) → exit `0`, empty stderr, 5 snapshots + `session.jsonl` (10
  lines, every line parsed as JSON). First event `session_start`, last `session_end`; 3 `command` events in
  step order (`step_index` 1/3/5); each `export` referenced an existing snapshot and matched it exactly:

  | export `path` | `final` | `turn` == snapshot | `moves` == snapshot | `pos_abs` == snapshot |
  | --- | --- | --- | --- | --- |
  | `000_start.json` | false | 1324801 ✅ | 99 ✅ | `[6301,6421,0]` ✅ |
  | `001_after_move1.json` | false | 1324802 ✅ | 98 ✅ | `[6301,6422,0]` ✅ |
  | `002_after_move2.json` | false | 1324803 ✅ | 72 ✅ | `[6301,6423,0]` ✅ |
  | `003_after_wait.json` | false | 1324804 ✅ | 100 ✅ | `[6301,6423,0]` ✅ |
  | `004_final.json` | **true** | 1324804 ✅ | 100 ✅ | `[6301,6423,0]` ✅ |

  `session_end`: `status=ok, snapshots=5, commands=3, final_turn=1324804, final_pos_abs=[6301,6423,0]`. The
  `move_s`/`wait` turn-and-moves progression is the engine's faithful behavior unchanged from Spike 3.1B;
  3.1C only records it, and every transcript scalar equals its snapshot.
- **Negative** (`move_ne`) → exit `5` (`bad_schema`), stderr `arcopolis: steps[0]: unsupported move
  direction 'move_ne' …`, and **no** export dir / **no** `session.jsonl` — the pre-flight rejection precedes
  log-open, so the typed error owns the exit code and no spurious transcript is produced.

## Citation audit

| Claim                                                                     | Implementing line(s)                                                                                                                                                                                                                               | Verdict                  |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| Transcript path is `<export_dir>\session.jsonl`, opened UTF-8/binary (LF) | `src/arcopolis_session_log.cpp` `begin_session_log`                                                                                                                                                                                                | ✅                       |
| One JSON object per line, flushed after each event                        | `write_*_line` (`out << '\n'`) + per-event `flush()` in `session_log_*`                                                                                                                                                                            | ✅                       |
| Flushed/closed before `std::_Exit` bypasses teardown                      | `end_session_log` (flush+close) called on every `run_script` return; `main.cpp` `std::_Exit(run_script(...))`                                                                                                                                      | ✅                       |
| `export` turn/pos/moves equal the named snapshot                          | `current_snapshot_summary()` (`arcopolis_export.cpp`) reads the same `calendar::turn`/`avatar::abs_pos`/`get_moves` as `write_backend`/`write_avatar`; emitted in `write_session_snapshot` immediately after `write_current_view`, no turn between | ✅ build-invariant + e2e |
| `export.path` is the relative `NNN_<name>.json`                           | `write_session_snapshot` passes `filename` (not `path`)                                                                                                                                                                                            | ✅                       |
| `command` records the queued action ident                                 | `next_backend_action` → `action_ident(*resolved)`                                                                                                                                                                                                  | ✅                       |
| `session_end` on every post-open return path                              | `run_script` game-over / stall / tail branches                                                                                                                                                                                                     | ✅                       |
| Fail-fast if the transcript cannot open                                   | `run_script` `if( !begin_session_log(...) ) return exit_code_for(export_failed)`                                                                                                                                                                   | ✅                       |
| No snapshot-schema change                                                 | snapshot writers in `arcopolis_export.cpp` untouched (only the new sibling file is added)                                                                                                                                                          | ✅                       |
| `main.cpp` unchanged                                                      | no edit to `src/main.cpp`                                                                                                                                                                                                                          | ✅                       |
