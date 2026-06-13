# Arcopolis Spike 11A — Directed examine through a backend nested-input seam

**Status: implemented and validated (2026-06-12).** This spike implements exactly the mechanism
recommended by the decision record
[25_SPIKE11A_EXAMINE_FEASIBILITY.md](25_SPIKE11A_EXAMINE_FEASIBILITY.md): a new `examine` command
(Option A's protocol surface) delivered through a **one-slot queued direction answer** plus an
**auto-cancel guard** at the `input_context::handle_input` choke point (the minimal Option-B
mechanism), both gated on `backend_session_active()`. **The guard is the spike's primary
architectural artifact** — it converts the entire raw-nested-read deadlock class into the
already-accepted ESC class; examine is the witness that exercises all three prompt classes in one
verb.

## The command

```json
{ "id": 2, "op": "command", "command": "examine", "direction": "move_n", "name": "examine_npc" }
```

- `direction` is **required** and is one of `move_n` / `move_s` / `move_e` / `move_w` / `here`
  (`here` = the avatar's own tile, the engine chooser's real `"pause"` path —
  `src/action.cpp:1108-1109`). Diagonals and vertical stay rejected, exactly like `move`.
- All three entry points accept it identically: the live protocol, `--arcopolis-run-script` step
  scripts, and the one-shot `--arcopolis-command` file (which reuses the steps walk).
- The top-level action is the engine's own `ACTION_EXAMINE` dispatched at the unchanged
  `game::handle_action()` seam (`command_to_action`, `src/arcopolis_command.cpp`); the backend
  never calls `game::examine(tripoint)` or any examine internals.
- **`direction` is the answer to the engine's prompt _if the engine asks_** — the mirror of the
  keystroke a GUI player would press at "Examine where?" — not a commanded target tile. With
  `AUTOSELECT_SINGLE_VALID_TARGET=true` the engine may pick a target (or fail with a message)
  without ever asking; the post-command snapshot shows what the engine actually did, and the
  armed answer is force-cleared and logged (below). Target validity is decided entirely by the
  engine's `can_examine_at`; nothing is pre-validated backend-side.

## The mechanism

### One-shot answer slot (`src/arcopolis_backend_input.cpp`)

Arming happens at the two command-resolution sites, **after** the transcript `command` event is
written (arming itself emits nothing, so each dispatch's events always order
`command → nested_input_answer/guard → nested_input_unconsumed → export`):

- script/one-shot: the steps walk in `next_backend_action()`;
- live: the `op:"command"` branch of `live_next_action()` (`src/arcopolis_live.cpp`).

The slot stores the chooser action id (`move_n→"UP"`, `move_s→"DOWN"`, `move_e→"RIGHT"`,
`move_w→"LEFT"`, `here→"pause"` — register_directions ids, `src/input.cpp:994-1001`; no iso
rotation can apply headless, doc 25 point 4), the direction token, and the arming step_index. It
is kept (marked consumed) until control returns to the top-level seam, so later guard events in
the **same** dispatch still cite the arming command.

**Stale answers cannot leak** (doc 25 design point 1): the entry of `next_backend_action()` —
before the live pull, and therefore before the pending live response is written — force-clears an
armed-but-unconsumed answer and emits `nested_input_unconsumed`. Terminal paths (game over, stall,
quit/EOF, `end_backend_session()`) clear silently; the transcript is already closed there.

### Auto-cancel guard (`input_context::handle_input`, `src/input.cpp`)

The hook sits at the top of `handle_input( const int timeout )`, before any input-manager state is
touched. During a backend session the seam supplies the only top-level action, so **every**
`handle_input` call is a nested read. Decision rules (pure, unit-tested —
`decide_nested_input()`):

1. **`timeout >= 0` → pass through untouched.** Such reads are polls — they return by themselves
   headless (`src/sdltiles.cpp:3976-3996`); only an `inputdelay < 0` read enters the forever
   `CheckMessages()/SDL_Delay(1)` busy-wait (`:3967-3975`). This gate is load-bearing: the
   engine's activity-interrupt check polls a `DEFAULTMODE` context with `handle_input( 0 )`
   (`game::handle_key_blocking_activity`, `src/game.cpp:3169-3172`) — a context that registers
   direction actions but **no** cancel — so a guard without the timeout gate would mis-serve or
   kill every long activity. All four audited nested loops (chooser, PICKUP, STRING_INPUT,
   INVENTORY) use the blocking no-arg overload (member default `-1`, `src/input.h:734`).
2. **Serve** iff an unconsumed answer is armed **and** the asking category is `"DEFAULTMODE"` (the
   chooser's, `src/action.cpp:1081`) **and** the context registered the armed action. The category
   gate stops the armed `"UP"` being eaten as a PICKUP menu scroll (PICKUP registers UP/DOWN,
   `src/pickup.cpp:722-725`). Serving is one-shot; the returned reference points at stable
   backend-owned storage (handle_input returns `const std::string &`).
3. **Cancel** otherwise: `"QUIT"` if registered, else `"TEXT.QUIT"` (the text-input context's
   cancel, `src/string_input_popup.cpp:109`). **Faithful cancellation means the engine runs its
   own cancel path** — `choose_direction` prints "Never mind." and returns nullopt, the pickup
   menu exits with nothing taken — exactly as if the GUI player pressed ESC. No state is faked.
4. **Hard-fail** when no cancel action is registered, or after 64 guard fires within one command
   (a nested loop ignoring its cancel — the doc 25 "guard fire-limit" residual): transcript
   `error` (kind `nested_input_failed`), a stderr line, then `std::_Exit(12)`. This is a
   **last-resort defensive path, deliberately fatal**: it skips the final snapshot / `session_end`
   tail, and in live mode the in-flight request gets no response — the client observes **stdout
   EOF + exit code 12**, never a recoverable protocol error. Every audited examine-path context
   registers QUIT or TEXT.QUIT, so this path is expected unreachable (and is classification-tested
   only; invoking it would exit the test runner).

The engine's own `test_mode` auto-cancel of `uilist`/`query_popup` (`src/ui.cpp:916-922`,
`src/popup.cpp:269-271`) is untouched and remains a **distinct mechanism**: the NPC menu an
examine-at-NPC opens is cancelled by the engine gate before any `handle_input` call, so it
produces no guard event — by design.

### Implementation corrections to doc 25

- **Design point 6's "existing public API" claim was wrong for desktop builds**:
  `is_action_registered()` / `get_category()` (`src/input.h:469-478`) sit inside the
  `#if defined(__ANDROID__)` block that opens at `src/input.h:429` — MSVC rejects them. The
  shipped hook still adds **zero** engine API: the call site is a _member_ of `input_context`, so
  it passes the private `category` and `registered_actions` to the backend directly
  (`arcopolis::backend_nested_input_action( category, registered_actions, timeout )`), and the
  backend stays fully decoupled from `input.h`.
- **The `timeout >= 0` pass-through rule is new** (decision rule 1) — doc 25's analysis covered
  blocking reads only; the activity-interrupt poll made the blocking/poll split mandatory.

## Transcript observability (`session.jsonl`, schema_version stays 1 — additive)

- `nested_input_answer` — `{ step_index, context, direction, action }`: the armed answer was
  served (e.g. context `"DEFAULTMODE"`, direction `"move_n"`, action `"UP"`).
- `nested_input_guard` — `{ step_index?, context, action, reason, fires }`: the guard cancelled a
  nested read; `action` is `"QUIT"`/`"TEXT.QUIT"`, `reason` is `no_answer` / `context_mismatch` /
  `answer_not_registered`, `fires` is the running per-command count.
- `nested_input_unconsumed` — `{ step_index, direction, action, reason:"command_completed" }`:
  an armed answer was never asked for and was force-cleared at the seam return.
- `session_start` gains `autoselect_single_valid_target` — the **recorded** (never overridden)
  loaded value of the interface option that decides whether the chooser prompts at 0/1 valid
  targets (doc 25 gate (h) and the fidelity corollary of design point 2). The fixture now declares
  `false` in its `options.json` (+ README), the same declared-property class as
  `TURN_DURATION <= 0.005`; the backend does **not** hard-require it because correctness never
  depends on it — the unconsumed path handles `true` gracefully.
- A new fatal error kind `nested_input_failed` → process exit code **12**.

All existing consumers (harness.py view/explain/run/live, make_report.py, the frontend bridge)
tolerate unknown event types by construction — verified before shipping; none were changed.

## What the regression proves (`examine_regression.ps1`, 10 gates, exit 0)

Driven raw through the new stdlib-only `examine_live_driver.py` (reuses the client harness's
`LiveSession`; **every response is read under a strict per-response timeout, and a breach kills
the backend and fails the run** — a hang is a FAIL, never a stuck script). Two scenarios against
ONE persistent backend each, with `AUTOSELECT_SINGLE_VALID_TARGET` pinned per scenario in the
sandbox copy's `options.json` (deployment config — never an in-memory override):

Scenario A (`false`, the fixture's declared value):

1. 10 requests → 10 in-time responses, ready seen, backend exit 0 (the no-deadlock gate).
2. `session_start` records `autoselect_single_valid_target=false`; zero `error` events;
   `session_end` ok.
3. `examine move_n` toward the shelter NPC: `command` event carries `action_id:"examine"`; exactly
   one `nested_input_answer` (`DEFAULTMODE`/`UP`); the NPC menu auto-cancels engine-side (no guard
   event); avatar did not move; no calendar tick (a zero-cost cancelled interaction).
4. `wait` after examine: zero nested events in its dispatch window (the stale-slot gate).
5. Examine with a missing direction and with `move_up`: both `ok:false` /
   `unsupported_command`, and the session keeps serving (recoverability).
6. Baseline unchanged: `move_n` blocked by the NPC (no move), `move_s` moved `[0,1]`.
7. **The guard witness**: after `move_s` the doc-25 item pile is adjacent south (witness prereq
   asserted explicitly — observed: **7 ground items** incl. `evac_pamphlet` at the tile, and the
   gate FAILS loudly with "fixture witness not found" if the fixture ever changes, rather than
   silently testing something else). `examine move_s`: answer `DOWN` served to the chooser, then
   the examine pickup tail's raw `"PICKUP"` loop is guard-cancelled
   (`nested_input_guard{context:"PICKUP", action:"QUIT", reason:"no_answer", fires:1}`), and the
   item count at the tile is unchanged — **nothing taken, no hang**.
8. The session stays usable after the guard (wait ticks), quit answers, final snapshot +
   transcript present.

Scenario B (`true`, the engine default):

9. Same examine, no hang, 4 in-time responses, exit 0; `session_start` records `true`.
10. **The unconsumed witness, pinned from observed fixture truth**: at spawn the NPC's tile is the
    only valid adjacent target, so the engine auto-selects it, the chooser never asks, and the
    armed answer is force-cleared as `nested_input_unconsumed` — the doc-25 stale-slot class,
    witnessed live instead of leaking.

Also validated: the full `[arcopolis]` unit suite (70 cases / 430 assertions — parser, mapping,
slot lifecycle, the pure decision matrix incl. the timeout gate and cancel preference, the new
formatters), and the three sibling regressions unchanged
(`live_protocol_regression.ps1`, `client_harness_regression.ps1`,
`frontend_prototype_regression.ps1` — all exit 0).

## What this deliberately does NOT do

- No generic menu/prompt protocol (Option C stays deferred); no pickup-as-a-command, no talk, no
  computer UI, no open/close verbs yet.
- No frontend examine UX — the protocol surface is proven backend-first; the frontend remains an
  unchanged consumer.
- It does **not** make every iexamine actor safe — it bounds the damage of any raw nested read to
  a logged auto-cancel. The per-target-class second-order audit rule of doc 25 still applies
  before exposing richer interactions.
- The hard-fail path is untested at runtime by design (it `_Exit`s; all audited contexts register
  a cancel) — its decision classification is unit-tested.

## Known limitations / accepted residuals

- **Same-dispatch wrong-serve under `autoselect=true`** (doc 25 risk, still open): if the engine
  skips the chooser and a _later_ prompt in the same dispatch is itself a `DEFAULTMODE` chooser
  that registers the armed action (e.g. liquid handling's "Pour where?",
  `src/handle_liquid.cpp:226`), the answer would be served there. Not reachable through any
  audited examine target class today; bounded by the per-class audit rule and by the fixture's
  declared `autoselect=false`; every serve names its context in the transcript, so a wrong-serve
  is observable, never silent.
- **Hard-fail leaves a live request unanswered** — the contract is EOF + exit 12 (above).
- **`timeout >= 0` loops are out of guard scope**: a caller looping on TIMEOUT until a real key
  arrives would still spin headless — a pre-existing engine property, unreachable through the
  audited examine paths, and untouched by this spike.
- `here` self-examine and the four cardinal targets beyond the two fixture witnesses are
  vocabulary-complete but not individually fixture-witnessed.

## Next

- **`open` / `close`** are the near-free follow-ups: the same `choose_adjacent_highlight` shape,
  prompt-free bodies, plus the clean `moves -= 100` turn-economy witness examine cannot provide.
- NPC interaction (the move-into-NPC no-op's missing half) and a prompt-aware protocol remain
  deferred per doc 25; the guard's transcript events are the survey data for designing the latter.

## Citation audit

| Claim                                                                 | Implementing line(s)                                                                                                           |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Hook site, before any input-manager state changes                     | `src/input.cpp` `input_context::handle_input( const int timeout )` top                                                         |
| The accessors doc 25 cited are Android-only                           | `src/input.h:429` (block start), `:469-478` (the accessors inside it)                                                          |
| Activity-interrupt poll: DEFAULTMODE, `handle_input( 0 )`, no cancel  | `src/game.cpp:3169-3172`, `:3314-3472`                                                                                         |
| Poll reads return by themselves headless; `inputdelay < 0` blocks     | `src/sdltiles.cpp:3976-3996`, `:3967-3975`                                                                                     |
| Nested loops use the blocking no-arg overload (member default `-1`)   | `src/input.h:734`; `src/action.cpp:1099`, `src/pickup.cpp:1164`, `src/string_input_popup.cpp:437`, `src/inventory_ui.cpp:1887` |
| Chooser shape: `"DEFAULTMODE"`, directions + `pause` + `QUIT`         | `src/action.cpp:1078-1119`                                                                                                     |
| PICKUP registers UP/DOWN (the scroll-leak hazard) and QUIT            | `src/pickup.cpp:722-725, :732`                                                                                                 |
| Arming after the command event, script + live                         | `src/arcopolis_backend_input.cpp` (steps walk), `src/arcopolis_live.cpp` (command branch)                                      |
| Entry-clear before the live pull (event precedes the response export) | `src/arcopolis_backend_input.cpp` `next_backend_action()` top                                                                  |
| Exit code 12 for `nested_input_failed`                                | `src/arcopolis_command.cpp` `exit_code_for`                                                                                    |
| Recorded (never overridden) autoselect in `session_start`             | `src/arcopolis_script.cpp` / `src/arcopolis_live.cpp` `begin_session_log` call sites                                           |
