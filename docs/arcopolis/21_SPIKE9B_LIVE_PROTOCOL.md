# Spike 9B — minimal persistent live backend protocol

> **Status: ✅ implemented (2026-06-10).** The first **liveness** spike: a persistent
> `--arcopolis-live` mode that loads the world **once**, then serves a JSON Lines protocol over
> **stdin/stdout** — one request at a time — executing each command through the **same
> `game::handle_action()` input seam** as `--arcopolis-run-script` and writing the same
> `NNN_<name>.json` snapshots + `session.jsonl` transcript. No sockets, no new gameplay commands, no
> snapshot `schema_version` bump (stays **1**), no save-format change, no world save. Builds on
> [20_SPIKE9A_CLIENT_HARNESS.md](20_SPIKE9A_CLIENT_HARNESS.md) and the input-seam architecture
> ([09](09_SPIKE3_1_INPUT_SEAM_EXPLORATION.md)).

## Why this is "Spike 9B"

Spike 9A proved an external harness can consume the contract — but only **one-shot**:
`--arcopolis-run-script` executes a fixed script and exits, so a frontend cannot _inspect → decide →
send → inspect again_ against one authoritative process. That liveness gap is the biggest remaining
backend/frontend risk, ahead of any further export widening. Spike 9B answers exactly one question:

> Can BN stay alive as an authoritative backend process and accept one request at a time from an
> external client?

The win condition (and regression gate): a separate client sends `move_n, move_s, wait` to **one
still-running** BN process and gets the **same** explanation sequence Spike 9A got from a one-shot
script — `blocked_no_op, moved, waited, no_command` — through the same harness/explain machinery,
never via special-cased protocol checks.

## Scope

**IN:** a `--arcopolis-live` flag · stdin JSONL requests / stdout JSONL responses, one in flight at
a time · the existing command vocabulary (`wait`, `move` + `move_n/move_s/move_e/move_w`) consumed
at the existing `handle_action()` seam · a snapshot per export/command request (normal
`NNN_<name>.json` files; responses point at filenames, never inline snapshots) · the normal
`session.jsonl` transcript · clean exit on `quit` **and** on stdin EOF · recoverable request errors
(the session survives bad requests) · a harness `live` probe + a fixture regression · this doc + the
state page.

**OUT (scope freeze):** socket/named-pipe transport · inline snapshots in responses · multiple
clients / concurrent requests / async queues · any new command verb or direction (diagonals and
vertical stay rejected — `move_up` is the regression's negative probe) · pickup/drop/use · NPC
interaction · fields/traps/vehicles export · GUI/mouse UI · save/resume of a live session ·
`schema_version` bumps. This is a **feasibility protocol**, not the final frontend transport.

## How to run

```powershell
.\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe `
  --world ArcopolisTest `
  --arcopolis-live `
  --arcopolis-export-dir .\out\arco_live `
  --userdir .\arcopolis_user
```

Requests are read from **stdin** (one JSON object per line); responses are written to **stdout**
(one JSON object per line, flushed per line). **stdout is protocol-only** while live mode is active;
all human diagnostics go to **stderr**. The mode is mutually exclusive with `--arcopolis-run-script`
and the one-shot flags. `--seed` is accepted and recorded in the transcript's `session_start`
(repro metadata, exactly like run-script).

## Protocol v0 (`protocol_version` 1)

### Startup

On successful startup (world loaded, transcript opened) the backend writes one `ready` event:

```json
{ "type": "ready", "protocol_version": 1, "ok": true, "world": "ArcopolisTest" }
```

### Requests

| op        | shape                                                                                   | effect                                                           |
| --------- | --------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| `export`  | `{ "id": 1, "op": "export", "name": "start" }`                                          | write a snapshot of the current state, respond with its filename |
| `command` | `{ "id": 2, "op": "command", "command": "move", "direction": "move_n", "name": "..." }` | feed ONE engine action at the seam, then snapshot + respond      |
| `command` | `{ "id": 3, "op": "command", "command": "wait", "name": "after_wait" }`                 | same, for the `wait` verb (no direction)                         |
| `quit`    | `{ "id": 4, "op": "quit" }`                                                             | acknowledge, then end the session cleanly (final snapshot + log) |

`id` is an optional client correlation integer, echoed verbatim in the response (JSON `null` when
absent/unreadable). `name` is the export label (optional; defaults to `"snapshot"`, the script
provider's default) and is **whitelisted** to `[A-Za-z0-9_.-]`, at most 64 chars — stricter than
`ensure_valid_file_name()` (which strips only `\/:?"<>|`), because an unchecked control character
would survive into the snapshot filename, fail the file open, and escalate a recoverable client typo
into the fatal `export_failed` path.

### Responses

Success (`export` and `command` share the shape; a command's response arrives only after the action
executed and its post-state snapshot was written):

```json
{
  "type": "response",
  "id": 2,
  "ok": true,
  "op": "command",
  "snapshot": "001_after_move_n.json",
  "export_index": 1,
  "turn": 1324801
}
```

Quit acknowledgement (the final-on-exit snapshot and the transcript's `session_end` are written
**after** this response, before the process exits 0):

```json
{ "type": "response", "id": 4, "ok": true, "op": "quit", "status": "session_end" }
```

Error (`ok: false`; `id` is JSON `null` when it could not be read, `op` omitted when unknown):

```json
{
  "type": "response",
  "id": 5,
  "ok": false,
  "op": "command",
  "error": {
    "code": "unsupported_command",
    "message": "unsupported move direction 'move_up' (expected move_n/move_s/move_e/move_w)"
  }
}
```

### Error codes

| code                  | recoverable? | meaning                                                                                                                                                        |
| --------------------- | ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `malformed_json`      | yes          | the line is not a JSON object (`id` echoed as `null` when unreadable)                                                                                          |
| `bad_request`         | yes          | structurally invalid: missing/mistyped field, unknown `op`, invalid `name`                                                                                     |
| `unsupported_command` | yes          | vocabulary rejection from `command_to_action()` — **both** an unknown verb and an unsupported direction (`move_up`, diagonals) map here, detail passed through |
| `export_failed`       | **no**       | a snapshot could not be written; the session ends (process exit 9, like run-script)                                                                            |
| `game_over`           | **no**       | the game ended while a command was in flight (exit 11)                                                                                                         |
| `backend_stalled`     | **no**       | the engine stopped consuming input — e.g. the avatar fell asleep (exit 10)                                                                                     |

Recoverable errors never terminate the session: the backend answers and keeps reading. After any
fatal error the in-flight request (if any) is answered with `ok: false` first, so a client is never
left waiting on a response that cannot come.

## Lifecycle

```text
load world ONCE → ready → ┌ request loop (one at a time) ┐ → quit/EOF → final snapshot →
                          │  export  → snapshot → response │            session_end → exit 0
                          │  command → action → snapshot → response
                          └ bad request → error response ──┘
```

- The first provider call happens inside the engine's **bootstrap turn** (load-once lifecycle,
  unchanged from run-script): the first turn processes at the loaded turn `T` without advancing the
  calendar; every later turn advances it. Multi-action turns work exactly as in the GUI — a 0-AP
  blocked move and the next command share one turn's input loop.
- `quit` and **EOF** both end the session **cleanly**: final-on-exit snapshot (`NNN_final.json`,
  the explain pipeline's `no_command` pair), then `session_end` with **status `"ok"`**. The task
  brief floated an EOF-specific status, but the transcript convention is `"ok"`/`"error"` and the
  Spike 9A consumer's contract check requires `"ok"` — so EOF-vs-quit is visible in stderr
  diagnostics only (a documented decision, revisitable with an additive field).

## How this reuses the input seam (the load-bearing design)

Live mode registers a **pull source** on the existing backend session
(`backend_session_options.live_source`); `next_backend_action()` delegates to it, and the two
engine seams — the provider branch in `handle_action()` and the clean-park in `game::do_turn()` —
are **untouched**. The source **blocks on `std::getline(std::cin, …)` inside the seam**: the exact
instant the GUI blocks on a keypress, so "the client is thinking" is the same engine state as "the
player is thinking". Turn-end (`moves <= 0`), the world tick, and multi-action turns stay entirely
engine-owned.

The rejected alternative — park after every request and re-enter `do_turn()` per request — is
**unfaithful**: re-entering re-runs the turn's top half (`calendar::turn += 1` and friends) for a
turn whose input loop never finished, so a 0-AP blocked move would advance the clock where the GUI
would not. Blocking in the provider is the design the GUI itself implies. Two timing facts make the
blocking safe: the seam bypasses the input-context timeout machinery entirely, and the only
wall-clock consumer on the path (`user_turn::moves_elapsed()`) returns 0 under the run-script-era
`TURN_DURATION <= 0.005` guard, which live mode enforces identically.

A **command's response is deferred to the next input-rest instant**: the action is handed to the
engine, and when the input loop next asks for input (same turn if moves remain, next turn's top half
otherwise), the pump first writes the post-command snapshot and answers with it — the same
"the observable result of a command is the FOLLOWING export" rule the script transcript has always
used. `next_backend_action()` has exactly one engine caller, so nothing can consume input between a
turn-ending command and its deferred response.

### Deliberate divergences from `run_script` (each commented in `run_live`)

| divergence                                | why                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| in-memory `AUTOSAVE` off after load       | `do_turn` autosaves once `AUTOSAVE_TURNS` calendar turns AND `AUTOSAVE_MINUTES` wall-minutes pass; a live session is designed to sit open, so it WOULD eventually save the world mid-session — breaking the in-memory-session contract and fixture determinism. The override is session-lifetime only: `get_options().save()` is never called, nothing persists, no user config is mutated, and no **simulation** state is touched. |
| stall backstop counts requests            | run-script's idle check keys on `backend_cursor()`, which live never advances — a verbatim copy would false-trip `backend_stalled` after 1000 healthy turn-ending commands. Live counts the pump's accepted requests instead. While the pump blocks in `getline`, `do_turn` never returns, so the backstop fires only for the input-loop-skipped case (e.g. the avatar fell asleep), where requests pile up unread.                 |
| `fail_pending()` on abnormal exits        | a command's response is deferred, so game-over / stall / export-failure must answer the in-flight request (`ok: false`) before exiting — a client must never hang on a response that cannot come.                                                                                                                                                                                                                                   |
| transcript `error` events stay fatal-only | a rejected request never touched the engine, and the consumers treat any `error` event as a failed session — so recoverable rejections live in the protocol stream only. **Gap (documented):** a rejected request leaves no transcript trace; an additive `"rejected"` event kind is deferred.                                                                                                                                      |

## Why stdout must be protocol-only (and how that was verified)

A client parses every stdout line as JSON; one stray human line corrupts the stream. Findings:

- The exe is a **`/SUBSYSTEM:WINDOWS`** (WinMain) binary, but redirected pipes work: the MSVC CRT
  binds fds 0/1/2 from the process's redirected handles regardless of subsystem — the existing
  regression scripts have captured this exe's stderr for spikes, and the engine never read stdin
  before this spike (no competition for the handle).
- The arcopolis flags set `test_mode`, so curses/SDL UI never initializes; a stdout-writer sweep of
  the live path found none (`cata_printf` is confined to `--version`/`--paths`/help/Lua-doc-gen;
  the game Lua state's `print` goes to the Lua log; `debugmsg` goes to the debug log; popups/uilists
  auto-cancel under `test_mode` without writing).
- Headless modes exit via `std::_Exit`, which does **not** flush iostreams — so every protocol line
  is **flushed at the write site**.
- The harness `live` probe **verifies** purity rather than assuming it: every backend stdout line is
  teed to `protocol.jsonl` and must parse as a JSON object; the first non-JSON line is a hard fatal.

(Contingency, designed but **not built**: if a stray writer ever appears, dup the protocol fd and
point fd 1 at stderr before load, keeping the duped handle protocol-only.)

## The harness live probe — `harness.py live`

```text
harness.py live --exe PATH --out DIR --commands move_n,move_s,wait
                [--world ArcopolisTest] [--userdir DIR] [--seed S]
                [--timeout 120] [--negative-probe] [--force] [--json] [--reveal-paths]
```

A probe, not the final frontend. It whitelists the same tokens as run mode, refuses a non-empty
`--out` without `--force`, always passes `--userdir`, launches the backend with redirected pipes,
reads `ready`, then sends `export start` and one command per response — **each next request only
after the previous response arrived and its referenced snapshot was verified to exist**. A daemon
reader thread + queue gives every read a deadline (`readline` on a Windows pipe is uninterruptible),
and early backend death is reported as such rather than as a timeout. `quit` must yield
`status: "session_end"` and process exit 0. It then delegates to the **existing explain pipeline**
and (with `--json`) emits the explain document plus a `live` block:
`{ protocol_version, ready_seen, responses, process_exit_code, duration_s, negative_probe? }`.
`--negative-probe` appends: send `move_up` (expect a recoverable `ok: false` /
`unsupported_command`), verify the process survived, send a recovery `wait` (expect ok + snapshot),
then quit.

## Regression — [`live_protocol_regression.ps1`](live_protocol_regression.ps1)

Fixture-driven (needs a loaded world + a real child process; the pure parser/formatters are covered
by `cata_test-tiles "[arcopolis]"`), structured like the sibling scripts (prereq exits 3=exe,
4=fixture, 5=world, 6=python, 7=harness, 8=viewer; `Stop-WithCode`; sandbox refresh). Thirteen hard
gates across two scenarios: **happy path** (`live --commands move_n,move_s,wait --json` → probe
exit 0 · `ready_seen`/protocol 1/backend exit 0 · five ok responses in order with snapshots named ·
`contract_check.ok` · outcome sequence exactly `blocked_no_op,moved,waited,no_command` · the
NPC-block pair naming **Edwardo Stovall** with `turn_delta` 0 and `pos_abs_delta` 0,0,0 · the moved
pair `0,1,0`/T≥1 · the wait pair T≥1 · the final `no_command` pair · `session.jsonl` + exactly 5
snapshots · the Spike 4 viewer exits 0 on the same live session · standalone explain exits 0) and
**recoverability** (`live --commands wait --negative-probe` → `unsupported_command`, session
survived, recovery wait snapshotted, clean quit, contract-clean transcript,
`waited,waited,no_command`).

## Validation (this run, 2026-06-10, MSVC/Ninja/ccache `win-rel-deb`)

- **Build:** `cataclysm-bn-tiles` + `cata_test-tiles` in the single `win-rel-deb` dir → exit 0.
- **Unit:** `cata_test-tiles "[arcopolis]"` → **All tests passed (293 assertions in 53 test cases)**
  — the 12 new live-protocol cases (parser + formatters) on top of the prior 41/204.
- **Manual protocol smoke** (redirected pipes, the feasibility checkpoint): `ready` →
  `export start`(turn 1324801) → `move_n`(ok, **same turn** — the blocked 0-AP no-op shares the
  bootstrap turn's input loop) → `move_s`(ok, 1324802) → `wait`(ok, 1324803) → `move_up`(**ok:false
  `unsupported_command`, session survived**) → unknown op(**ok:false `bad_request`, survived**) →
  `quit`(ok, `session_end`) → backend exit **0**; **every stdout line parsed as JSON** (purity OK);
  5 snapshots + a contract-clean `session.jsonl` (`session_end` status ok, snapshots 5, commands 3);
  stderr empty. **Redirected stdin/stdout is fully reliable on Windows for this WINDOWS-subsystem
  exe** — the question this spike was chartered to answer.
- **Regression** [`live_protocol_regression.ps1`](live_protocol_regression.ps1) → **exit 0, all 13
  gates green**: one persistent backend (8s session) re-derived exactly
  `blocked_no_op,moved,waited,no_command` through the unchanged explain pipeline — the harness's own
  explanation: _"move_n did not move the avatar and the turn did not advance: NPC Edwardo Stovall
  (neutral, stationary) occupies the destination tile [85,84,0]."_ — plus the recoverability
  scenario (`move_up` → `unsupported_command`, recovery `wait` snapshotted, clean quit,
  contract-clean transcript, `waited,waited,no_command`).
- **Sibling regressions** (no collateral): `movement_regression.ps1`, `npc_export_regression.ps1`,
  `item_export_regression.ps1`, `monster_export_regression.ps1`, `client_harness_regression.ps1` —
  **all exit 0** against the same build.

## Known limitations

- **stdin/stdout JSONL only** — no sockets/named pipes yet; no framing beyond line-delimited JSON.
- **No concurrent requests** — strictly one in flight; the backend blocks while idle.
- **No inline snapshots** — responses point at files; a frontend reads them from the export dir.
- **No save/resume of a live session** — the backend never saves the world (in-memory `AUTOSAVE`
  off, see divergences); every session starts from the on-disk save, exactly like run-script.
- **No pickup/drop/use, no NPC interaction** — the Edwardo tile is explained, still not actionable.
- **Fields/traps/vehicles export still deferred**; passability in the harness stays heuristic until
  explicitly exported.
- **Rejected requests leave no transcript trace** (protocol stream + `protocol.jsonl` tee only).
- A future **activity-starting** command (sleep, crafting, reading) would interact with
  `process_voluntary_act_interrupt`, which polls the real keyboard while an activity runs — flagged
  for the command-vocabulary spikes, irrelevant to `wait`/`move`.

## Next possible steps

- Live transport hardening: sockets or named pipes, framing/acks, request pipelining.
- A first graphical frontend prototype consuming `ready`/responses + snapshot files.
- Fields/hazards export (the next observability slice), then item/NPC **interaction** commands —
  the two things a real frontend loop asks for first.
