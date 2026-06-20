# Spike 10A — Minimal live browser frontend prototype

**Status: implemented & validated (2026-06-10).** First external, mouse-first, graphical client
driving the persistent `--arcopolis-live` backend (Spike 9B) end-to-end: a stdlib-only Python HTTP
bridge plus a plain HTML/CSS/JS page. Zero engine/C++ changes; no snapshot or protocol change.

## Why 10A

Spike 9B proved a persistent live protocol at the real `game::handle_action()` seam, and the Spike
9A harness proved it can be driven programmatically. The open question was the project's actual
goal: can a **separate graphical, mouse-first frontend** drive the backend — display state, send
commands from clicks, refresh, explain outcomes, and quit cleanly — without any new engine surface?
10A answers that with the smallest useful prototype, not a final UI architecture.

```
browser (static HTML/CSS/JS)
  -> prototype_server.py (stdlib HTTP bridge, loopback)
    -> stdin/stdout JSON Lines live protocol (Spike 9B)
      -> game::handle_action() input seam   (engine owns turns/world tick)
  <- read-only snapshots NNN_<name>.json + session.jsonl transcript
```

## What it proves / what it deliberately does not

Proves:

1. A local client can start ONE persistent BN live backend process and end it cleanly (quit →
   backend exit 0 → final snapshot + transcript).
2. A browser can render the radius-12 snapshot window (terrain/furniture glyph heuristics, avatar
   `@`, NPC `N`, monster `M`, ground item `i`, unseen tiles dimmed) and a tile inspector.
3. Mouse-first input works: clicking an adjacent cardinal tile (or N/S/E/W buttons) sends a real
   `move` through the live protocol; Wait/Export/Quit are buttons. (**Update (Spike 11B):** the click
   map + d-pad were widened to all 8 adjacent tiles and a Move/Examine mode was added that sends
   `examine` in the 8 planar directions + `here`; see
   [29_SPIKE11B_GUI_EQUIVALENT_PLANAR_MOVE_EXAMINE.md](29_SPIKE11B_GUI_EQUIVALENT_PLANAR_MOVE_EXAMINE.md).)
4. The UI refreshes from the post-command snapshot (the deferred-response contract) and shows a
   basic outcome explanation (`moved`, `blocked_no_op` + blocker, `waited`, `no_command`,
   `error`).
5. Recoverable backend rejections are survivable data: `move_up` surfaces the authoritative
   `unsupported_command` and the session continues.

Deliberately NOT proven (out of scope):

- a final UI architecture, art direction, or tilesets (text glyphs only);
- push/streamed updates (the page polls; the bridge serializes one request at a time);
- multi-client, authentication, or non-loopback deployment;
- any new backend command, snapshot field, or protocol feature;
- richer interactions the snapshot/commands do not carry yet (NPC interaction, examine, pickup).

## Files

| Path                                               | Role                                             |
| -------------------------------------------------- | ------------------------------------------------ |
| `tools/arcopolis_frontend/prototype_server.py`     | stdlib-only HTTP bridge owning one live backend  |
| `tools/arcopolis_frontend/static/index.html`       | UI skeleton                                      |
| `tools/arcopolis_frontend/static/style.css`        | plain dark theme                                 |
| `tools/arcopolis_frontend/static/app.js`           | fetch/render loop, grid, inspector, controls     |
| `docs/arcopolis/frontend_prototype_regression.ps1` | 14-gate API-level regression (no browser needed) |

The bridge is the **third share-nothing contract consumer** beside the Spike 4 viewer and the Spike
9A harness: it re-derives snapshot loading, the outcome decision table, and the glyph precedence
from the docs/source instead of importing them, so "independent consumers accept the same
artifacts" stays a real cross-check rather than a shared-library tautology.

## How to run (Windows, PowerShell)

```powershell
# one-time per worktree: copy the canonical fixture (AGENTS.md, "Arcopolis test world fixture")
Copy-Item C:\dev\arcopolis-fixtures\arcopolis_user .\arcopolis_user -Recurse -Force

python tools\arcopolis_frontend\prototype_server.py `
    --exe <built cataclysm-bn-tiles.exe> `
    --userdir .\arcopolis_user `
    --world ArcopolisTest
# then open http://127.0.0.1:8765/ and press Start
```

Arguments (all have repo-relative defaults; nothing is machine-specific):

| Flag                 | Default                                              | Meaning                                   |
| -------------------- | ---------------------------------------------------- | ----------------------------------------- |
| `--exe`              | `.\out\build\win-rel-deb\src\cataclysm-bn-tiles.exe` | built game binary                         |
| `--userdir`          | `.\arcopolis_user`                                   | userdir holding the prepared world        |
| `--world`            | `ArcopolisTest`                                      | world inside the userdir's `save/`        |
| `--out-root`         | `.\out\arco_frontend`                                | receives one `session_NNN/` per start     |
| `--host` / `--port`  | `127.0.0.1` / `8765`                                 | loopback only — the bridge has no auth    |
| `--seed`             | (none)                                               | forwarded to the backend for transcripts  |
| `--response-timeout` | `60`                                                 | seconds per protocol response (and ready) |

## How it talks to `--arcopolis-live`

- `POST /api/start` spawns `<exe> --world <w> --arcopolis-live --arcopolis-export-dir
  <out-root>/session_NNN --userdir <u>`, reads the `ready` event (asserts `protocol_version` 1),
  and immediately sends one `export` named `start` so the UI has a map.
- Backend stdout is the protocol stream: a daemon thread pumps lines into a queue (readline on a
  Windows pipe cannot be interrupted); every line is teed to `protocol.jsonl` and must parse as a
  JSON object — one non-JSON line is a hard purity violation. stderr goes to
  `backend_stderr.txt` (a file, never a pipe, which could fill and deadlock the child).
- Requests are strictly serial (one in flight), matching the protocol; the bridge serializes every
  backend-touching endpoint behind a non-blocking lock and answers `409 busy` meanwhile. A response
  timeout kills the backend and marks the session dead — a late response would desync the serial
  stream, so it is never retried.
- Command responses are deferred to the next input-rest instant, so the snapshot named by the
  response IS the post-command state; the bridge loads exactly that file (no globbing — single
  exception: the final-on-exit snapshot's label is contractually `final`).
- Recoverable `ok:false` codes (`malformed_json`, `bad_request`, `unsupported_command`) keep the
  session alive and surface as outcome data. Fatal codes (`export_failed`, `backend_stalled`,
  `game_over`) reap the process and flip the session to `dead`.
- Quit ladder: `quit` request → expect `status:"session_end"` → close stdin (EOF is the same
  documented clean path) → wait → kill as last resort. On clean exit 0 the bridge records the
  `NNN_final.json` snapshot. An atexit handler runs the same ladder so a dying server does not
  leave an orphan backend.

## The HTTP API

`GET /api/state` and every successful POST return the SAME state document (one shape, one renderer,
one regression parse path):

```jsonc
{
  "ok": true,
  "server": {
    "tool": "arcopolis_frontend_prototype",
    "version": "0.1.0",
    "protocol_version": 1,
    "schema_version": 1,
  },
  "state_serial": 17, // monotonic; the page never renders an older doc over a newer one
  "phase": "idle | starting | ready | ended | dead",
  "busy": false,
  "busy_op": null,
  "session": {
    "index": 1,
    "dir_name": "session_001",
    "world": "ArcopolisTest",
    "seed": null,
    "exit_code": null,
    "exit_meaning": null,
    "final_snapshot": null,
  },
  "backend": { "turn": 1324801, "export_index": 0, "snapshot": "000_start.json" },
  "avatar": {/* verbatim snapshot avatar block */},
  "map": {
    "bounds": {/* map_bounds */},
    "tiles": [/* tiles[] */],
    "entities": { "monsters": [], "npcs": [], "items": [] },
  },
  "messages": [/* verbatim messages[] */],
  "last_result": {
    "op": "command",
    "request": { "command": "move", "direction": "move_n" },
    "response": {/* raw backend response, verbatim */},
    "outcome": {
      "outcome": "blocked_no_op",
      "turn_delta": 0,
      "pos_abs_delta": [0, 0, 0],
      "moves_delta": 0,
      "expected_delta": [0, -1],
      "blocked_by": ["npc"],
      "blocker_name": "Edwardo Stovall",
      "explanation": "…",
      "error": null,
    },
  },
  "last_error": null,
}
```

`avatar` / `map` / `messages` are verbatim snapshot slices — the bridge re-serves the contract, it
never reshapes it.

| Endpoint                                     | Effect                                                            | Success                                                                                             | Failure                                  |
| -------------------------------------------- | ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| `GET /` `/static/app.js` `/static/style.css` | static UI (exact-path whitelist)                                  | 200                                                                                                 | 404 anything else                        |
| `GET /api/state`                             | cached state; never touches the backend                           | normally 200 (mid-command too, with `busy:true`)                                                    | 500 only on an unexpected bridge bug     |
| `POST /api/start`                            | spawn → ready → initial `start` export                            | 200, phase `ready`                                                                                  | 409 running/busy; 502 spawn/ready failed |
| `POST /api/command`                          | `{"command":"wait"}` or `{"command":"move","direction":"move_n"}` | 200 — a recoverable backend rejection is ALSO 200 with `outcome:"error"` (game data, not transport) | 400 shape; 409; 502 fatal/timeout        |
| `POST /api/wait`                             | alias for command `wait`                                          | as `/api/command`                                                                                   | as `/api/command`                        |
| `POST /api/export`                           | refresh snapshot                                                  | 200, outcome `no_command`                                                                           | 409; 502                                 |
| `POST /api/quit`                             | quit ladder                                                       | 200, phase `ended`, `exit_code` 0, `final_snapshot` recorded                                        | 409; 502 if the ladder ended in kill     |
| `POST /api/shutdown`                         | quit a live backend, then stop the server                         | 200, then the listener stops                                                                        | — (always attempts)                      |

Design decisions worth keeping:

- **The bridge validates JSON shape/types only; vocabulary belongs to the backend.** `move_up`
  passes through so the authoritative `unsupported_command` is what users (and the regression's
  negative gate) see. A bridge-side whitelist would shadow the contract.
- **Export labels are bridge-generated** (`start`, `after_NN_<dir>`, `export_NN`) — valid against
  the backend's `[A-Za-z0-9_.-]{1,64}` name whitelist by construction; clients cannot supply names
  in v0.
- **One fresh `session_NNN/` per start, never wiped** (transcripts and `backend_stderr.txt` survive
  for debugging; numbering continues across server restarts; cleanup is manual — `out/` is
  gitignored).
- **`POST /api/shutdown` writes its 200 response first** and only then stops the listener from a
  separate thread (`shutdown()` blocks until `serve_forever()` exits — calling it on the handler
  thread would deadlock).
- Every response carries `Cache-Control: no-store` (a stale cached `app.js` silently tests old UI),
  and every POST drains its request body even when ignored (with HTTP/1.1 keep-alive, unread body
  bytes would be parsed as the NEXT request line — found live as spurious 400s during the smoke).

## Outcome explanation (basic, heuristic)

Re-derived from the Spike 9A concept; keyed on the avatar **pos_abs** delta + calendar turn delta +
the command verb (never `pos_local` — bubble-relative; never `moves` — refilled at turn
processing, reported only):

| Condition                                  | Outcome                                                                                                                                                                |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| backend answered `ok:false` (recoverable)  | `error` (code/message attached)                                                                                                                                        |
| plain export, no command between snapshots | `no_command` (+ note if state changed anyway)                                                                                                                          |
| `wait`, no move                            | `waited` (turn_delta 0 = bootstrap turn, noted)                                                                                                                        |
| `move`, delta == expected                  | `moved`                                                                                                                                                                |
| `move`, no move, turn_delta 0              | `blocked_no_op` + `blocked_by`/`blocker_name` from the BEFORE-snapshot destination cell (npc > monster > wall/window heuristic — the snapshot has no passability flag) |
| `move`, no move, turn_delta ≥ 1            | `acted_in_place`                                                                                                                                                       |
| `move`, any other delta                    | `displaced`                                                                                                                                                            |
| anything else                              | `unknown`                                                                                                                                                              |

## Regression

[`frontend_prototype_regression.ps1`](frontend_prototype_regression.ps1) (fixture-driven, not CI)
starts the bridge on port 8799 against `ArcopolisTest` and gates the whole server/live-backend path
over plain HTTP — see its header for the 14 gates. The core sequence re-derives the fixture-proven
outcomes through the bridge: `move_n → blocked_no_op` (Edwardo Stovall), `move_s → moved
[0,1,0]`, `wait → waited`, `export → no_command`, plus the `move_up → unsupported_command`
recoverability probe, the quit ladder (backend exit 0 + final snapshot + `session.jsonl`), session
restartability (`session_002`), and a clean server shutdown. A busy-409 race gate is deliberately
omitted (not deterministically provocable without test hooks); the 409 path is covered by the
double-start gate.

## Validation (2026-06-10, real backend, zero C++ changes)

- `frontend_prototype_regression.ps1` — **all 14 gates passed, exit 0**.
- `live_protocol_regression.ps1` — **ok, exit 0** (no collateral).
- `client_harness_regression.ps1` — **ok, exit 0** (no collateral).
- `[arcopolis]` C++ unit tests — **not run: `cata_test-tiles.exe` is not currently built** in any
  local build dir; this spike changes no C++ (new files only), so the suite is unaffected.
- Manual browser sanity check (not automated, nothing committed): idle render → Start → the evac
  shelter renders with `@` and the `N` blocker one tile north → clicking the NPC tile yields the
  `blocked_no_op` badge naming Edwardo Stovall → Shift-click inspects without moving → S/Wait/
  Export/Quit buttons produce `moved`/`waited`/`no_command`/phase `ended` → zero browser console
  errors/warnings.

## Known limitations

- Polling (1 s fallback + render-on-POST), not push; fine at this scale, wrong for a real client.
- One session and one client at a time; loopback only; no auth.
- Glyphs and "blocking terrain" are id-substring heuristics — the snapshot carries no per-tile
  symbol/colour and no passability flag (already-tracked contract gaps, deferred backlog #1).
- `messages[].type` is blank (deferred backlog #4), so messages render untyped.
- Session dirs accumulate under `--out-root` by design; cleanup is manual.
- The inspector is keyed on `pos_local`, which is bubble-relative; entity lists in an unseen tile
  are authoritative export data, not player knowledge.

## Contract gaps observed (recorded, NOT added)

Nothing new: the prototype wanted per-tile symbol/colour, a passability flag, message types, and an
NPC-interaction command (the Edwardo tile is clickable but the only faithful action is the move
no-op) — all of which are already in the deferred backlog. No snapshot/protocol field was added.

## Next likely follow-up decisions

1. **Push updates** (SSE or chunked long-poll stays stdlib-able) once any UI needs sub-second
   freshness; with it, a transcript `"rejected"` event kind (deferred from 9B).
2. **NPC interaction command(s)** — the first thing a mouse user tries is clicking Edwardo.
3. **Examine/pickup commands** to make the 27 exported ground items actionable.
4. **Per-tile symbol/colour export** to retire the glyph heuristics.
5. Decide when the prototype graduates to a real client architecture (state cache, optimistic UI,
   one canonical client library) — explicitly out of 10A's scope.
