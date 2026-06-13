# Arcopolis — guard the `wait_for_any_key` raw-read class (headless hang fix)

**Status: implemented (2026-06-13). Engine hardening, gated on a backend session.** Closes a
reachable headless busy-wait hang and corrects an overclaim in the Spike-11A directed-examine
design.

## The hazard

The Spike-11A directed-examine guard (doc 26) hooks `input_context::handle_input`
(`src/input.cpp`), on the premise that during a backend session **every** blocking input read funnels
through that one choke point — so guarding it converts the whole raw-nested-read deadlock class into
the accepted ESC class. That premise is **incomplete**: there is a second raw-read path that does
**not** go through `input_context::handle_input` at all.

`input_manager::wait_for_any_key()` (the engine's "Press any key…" primitive) loops on
`inp_mngr.get_input_event()` **directly** (`src/input.cpp`, the `while(true)` in `wait_for_any_key`),
bypassing `input_context::handle_input` and therefore the Spike-11A guard inside it. Headless, with
`inputdelay < 0`, `get_input_event()` loops internally (`CheckMessages()` + `SDL_Delay(1)`,
`src/sdltiles.cpp:3967-3975`) until a non-error event arrives — which never happens with no key
source — so it **never returns**. `wait_for_any_key`'s own `case error: return` is never reached,
because `get_input_event` does not return an error event under `inputdelay < 0`; it spins inside.
Result: an undetectable headless busy-wait hang, invisible to both runner stall backstops (which only
fire between `do_turn` returns).

It is **reachable**: examining a `CONSOLE`-flagged tile dispatches `game::use_computer`
(`src/game.cpp:8680-8682`); the unsecured computer path calls `computer_session::query_any`
(`src/computer_session.cpp`), which calls `inp_mngr.wait_for_any_key()` directly
(`src/computer_session.cpp:1568-1573`). So a frontend that sends `examine` toward a console tile
would hang the backend, despite doc 26's claim that the guard bounds the entire raw-read class. Found
by the GUI-equivalence sweep, leaf-verified.

## The fix

Guard `input_manager::wait_for_any_key()` at its top: while a backend session is active
(`arcopolis::backend_session_active()`), **return immediately** instead of entering the read loop.

This is faithful: a "Press any key to continue…" prompt advances the moment any key is pressed;
returning at once is exactly "the player pressed a key to dismiss it." The headless contract has no
key source, and the engine's own `test_mode` auto-cancels the menus that follow (`uilist`,
`query_yn`), so an examined unsecured computer now prints its lines, the press-any-key prompts
auto-dismiss, the options menu auto-cancels, and the session continues — a clean, GUI-shaped
"looked at the console and stepped away," not a hang.

The guard is placed at `wait_for_any_key` (not `get_input_event`) on purpose: `get_input_event` is the
shared engine read used by `handle_input` itself, and `handle_input`'s own guard already returns
_before_ reaching it for served/cancelled reads while still allowing its timeout-poll path through —
guarding `get_input_event` globally would interfere with that. `wait_for_any_key` is the specific
blocking "press any key" entry that bypasses `handle_input`, so it is the correct, minimal choke
point, and the guard bounds **every** `wait_for_any_key` caller at once (computers, debug menu, the
game-over prompt, …), not just the console-via-examine path.

## Blast-radius audit (so this is not itself a subset fix)

The raw-read class = direct `inp_mngr.get_input_event()` callers that bypass
`input_context::handle_input`. Enumerated from source:

| Direct caller                     | Blocking?                                                        | Reachable from wait/move/examine?                                                          |
| --------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `input_context::handle_input`     | n/a — this IS the guarded seam (Spike 11A)                       | —                                                                                          |
| `input_manager::wait_for_any_key` | **yes** (`inputdelay < 0`) → **hang**                            | **yes** (examine → console) → **fixed here**                                               |
| `animation.cpp` hit-animation     | **no** — preceded by `set_timeout(ANIMATION_DELAY)` (timed read) | possibly (combat animations) — but returns, never hangs                                    |
| `npctalk.cpp` dialogue read       | depends                                                          | **no** — examine's NPC menu auto-cancels before talk; a future `talk` verb must revisit it |
| `debug.cpp` debug menu            | depends                                                          | no — debug-only, unreachable in normal play                                                |

So guarding `wait_for_any_key` closes the only **reachable blocking-hang** for the current verbs.
`npctalk`'s dialogue read is recorded here as a latent reader the future `talk` verb must guard
before exposing dialogue; it is not reachable today.

## What this does and does not do

- **Does:** make any `wait_for_any_key` "press any key" prompt non-blocking during a backend session,
  closing the reachable console-examine hang and any other press-any-key prompt.
- **Does not** make computer interaction _drivable_ — the computer's option `uilist` still
  auto-cancels under `test_mode`; this only prevents the hang, it does not add a computer verb.
- **No transcript event** is emitted for the auto-dismiss, matching how the engine's own `test_mode`
  `uilist`/`query_popup` auto-cancels are silent to the Arcopolis transcript (they are upstream engine
  behavior, not a backend nested-input intervention).
- **End-to-end witness deferred:** the current fixtures (evac shelter) have no adjacent `CONSOLE`
  tile, so an `examine`-of-console no-hang regression would need a save-edit fixture
  (the `make_monster_fixture.py` precedent). The unit test proves `wait_for_any_key` returns under a
  backend session directly; the full examine→console→no-hang path is deferred to a console fixture.

## Relation to doc 26

This corrects doc 26's statement that the Spike-11A guard "converts the **entire** raw-nested-read
deadlock class into the accepted ESC class." Precisely: the `handle_input` guard bounds the
`input_context::handle_input` subclass; the `wait_for_any_key`/`get_input_event` direct-read subclass
is bounded by **this** guard. doc 26's wording is narrowed accordingly (on the Spike-11A branch).

## Validation

- `[arcopolis]` unit suite: a new case begins a backend session and calls
  `inp_mngr.wait_for_any_key()`, asserting it returns (the test would hang if the guard regressed).
- The guard is inert outside a backend session (`backend_session_active()` is false during normal
  play), so GUI "press any key" prompts behave exactly as before — covered by the existing
  gate-inertness test.
