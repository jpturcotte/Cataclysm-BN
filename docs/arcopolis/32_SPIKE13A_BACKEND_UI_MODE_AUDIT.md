# Arcopolis Spike 13A — backend UI mode audit & design

**Status: source-audit + design record (2026-06-15).** A docs/source-audit follow-up to
[30_SPIKE12A_PROMPT_MENU_TRANSACTION.md](30_SPIKE12A_PROMPT_MENU_TRANSACTION.md) and
[31_SPIKE12A_FOLLOWUP_FAIL_LOUD.md](31_SPIKE12A_FOLLOWUP_FAIL_LOUD.md). It determines what must be
true for Arcopolis to run real BN interactive UI/input loops headlessly **without** using
`test_mode` in a way that aborts those loops — and proposes (without implementing) a conservative
backend UI mode. **No C++ behavior changes, no gameplay/prompt change, no new protocol command, no
attempt to drive `uilist`.**

> **Equivalence level proved: N/A — observation/audit only.** No command is driven and no engine
> input path is exercised by this PR. The doc _designs toward_ a future level-4 capability but
> proves none. (Per the AGENTS.md "every Arcopolis plan must state the equivalence level"
> requirement.)

## Executive summary

`test_mode` does **two** jobs that Arcopolis must separate:

1. **Suppress rendering / real keyboard / curses dependency** — Arcopolis **needs** this.
2. **Abort certain UI code paths before their real input loops run** — Arcopolis does **not** want
   this; it is exactly what blocks driving those prompts.

Spike 12A drove the old `"PICKUP"` menu at **level 4** precisely because that menu builds a real
`input_context("PICKUP")` loop and reaches `input_context::handle_input()` — the seam the Spike 11A
guard hooks. But the Spike 12A follow-up found the wall: **`uilist::query()` short-circuits to
`UILIST_ERROR` _before_ it ever constructs its `input_context`** (`src/ui.cpp:918-922`), so the
guard never sees it. `query_popup::query_once()` does the same (`src/popup.cpp:269-271`). These two
are the **blocked class**: their real input loops exist, but `test_mode` aborts ahead of them.

The audit sorts every audited mechanism into four behavioral classes:

- **Class 1 — suppression** (render/keyboard/curses): what Arcopolis wants; **keep**.
- **Class 2 — abort-before-input** (`uilist`, `query_popup`): the blocker; **must not short-circuit
  under a backend UI mode**. Crucially, _past_ the abort both use the real
  `input_context::handle_input` seam — so un-aborting them routes through the **existing** guard,
  not a raw read.
- **Class 3 — already reaches `handle_input`** (`choose_direction`, old PICKUP, `inventory_selector`,
  `string_input_popup`, computer `query_ynq`): guard-able today; PICKUP and the direction chooser
  are already driven (Spikes 12A/11A). The rest are a _driving-complexity_ problem, **not** a
  test_mode-abort problem.
- **Class 4 — direct `get_input_event` read** (`wait_for_any_key`, NPC dialogue): bypasses the
  `handle_input` seam entirely; needs **per-site** guards regardless of any UI mode, because
  `get_input_event` has **no** test_mode guard and busy-waits headless.

**Answer to the spike's question:** yes — a distinct Arcopolis backend UI mode _can_ disable
rendering and real keyboard dependency while still allowing real UI/input loops to execute and
consume registered backend actions. It must be a flag **distinct from `test_mode`** (so cata_test
is untouched), it must keep Class 1 suppression, it must **not** take the Class 2 abort, it must
keep the Class 4 `wait_for_any_key` guard, and any prompt class it does not actually drive must
**fail loud or be explicitly marked**, never silently auto-cancel-as-success. A backend UI mode is
the named prerequisite before broader prompt/menu support and before treating pipes as a robust
frontend boundary.

## Problem statement

For a supported interactive player action, the AGENTS.md "backend input equivalence" rule requires
Arcopolis to drive the **same registered backend input actions, in the same order, through the same
active engine input loop** a player would use (level 4). That mechanism, for BN's
`input_context`-based prompts, is `input_context::handle_input()` on the real active loop.

The headless `--arcopolis-*` modes set `test_mode = true`. That single flag is doing double duty:
it both suppresses the curses/SDL surface (good — there is no display or keyboard) and aborts some
UI loops before they read input (bad — the loop never runs, so there is nothing to drive). For the
`uilist` and `query_popup` families, the abort fires _before_ the loop is even constructed, so the
Spike 11A nested-input guard — which sits at the top of `handle_input` — cannot intercept anything.
Worse, the abort returns an error sentinel (`UILIST_ERROR`, `{false,"ERROR"}`) that a naive caller
mis-handles silently: in Spike 12A the vehicle "Get items from where?" `uilist` returned
`UILIST_ERROR` and `pick_up` fell through to a **silent ground-only pickup**.

So the question is precise: **can we create a backend UI mode that keeps job (1) — no
render/keyboard — while dropping job (2) — the abort — so that the real `input_context` loops run
and the Arcopolis input hooks can serve them registered actions, without polluting stdout, without
real keyboard blocking, and without weakening the level-4 rule or changing GUI/test behavior?**

## Source audit

All findings below were read at the **implementing line** in the current tree (not from prior
docs/memory). `test_mode` is declared `extern bool test_mode` at `src/cached_options.h:12` (defined
`= false` at `src/cached_options.cpp:5`) and set `true` by the flag handlers in `src/main.cpp` (the
cluster at `:485–:580` covers the `--arcopolis-*` modes; the same global is set for
`--test-mode`/cata_test at `:305–:344`). It is **one** flag shared by the backend and the unit
tests — which is the crux of the conflation.

### Class 1 — render / keyboard / curses suppression (Arcopolis WANTS this → KEEP)

| Mechanism                           | Implementing line        | Behavior                                                                                                    |
| ----------------------------------- | ------------------------ | ----------------------------------------------------------------------------------------------------------- |
| `refresh_display`                   | `src/sdltiles.cpp:507`   | `if( test_mode ) { return; }` before any SDL present — pure render suppression                              |
| `game::draw`                        | `src/game.cpp:4531`      | `if( test_mode ) { return; }` before terrain/entity draw                                                    |
| `ui_adaptor` / `ui_manager::redraw` | `src/ui_manager.cpp:328` | redraw no-ops under test_mode — pure render suppression                                                     |
| `input_manager::pump_events`        | `src/sdltiles.cpp:3938`  | `if( test_mode ) { return; }` before `CheckMessages()` — skips the SDL event poll                           |
| `debugmsg`                          | `src/debug.cpp:518`      | under test_mode logs then returns **without** the interactive prompt; **does not abort** in the game binary |

None of these aborts a logic/input loop; all are safe to keep verbatim under a backend UI mode.

### Class 2 — UI ABORT before the input loop (Arcopolis does NOT want → the blocker)

| Mechanism                 | Abort site                                               | Real loop underneath                                                                                                                                                                              | Notes                                                                                                  |
| ------------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `uilist::query`           | `src/ui.cpp:918-922` returns `UILIST_ERROR`              | builds `input_context` via `create_main_input_context()` at `:930` (category member = `"UILIST"`, set `src/ui.cpp:210`, used `:216`) and loops `ret_act = ctxt.handle_input( timeout )` at `:945` | abort is _before_ the `input_context`; `uilist::init` also short-circuits at `:154-156` (window setup) |
| `query_popup::query_once` | `src/popup.cpp:269-271` returns `{ false, "ERROR", {} }` | builds `input_context( category )` at `:277` and loops `res.action = ctxt.handle_input()` at `:302`; registers `QUIT` if cancelable (`:294-296`)                                                  | `query_yn`/`query_int` route through this — a silent "ERROR"/"No" today                                |

**The load-bearing fact:** past their test_mode early-returns, **both use the real
`input_context::handle_input` seam.** Un-aborting them does not create a new raw-read path — it
routes through the seam Arcopolis already hooks. The current guard would see category `"UILIST"` (or
the popup's category), which is **not** `"DEFAULTMODE"`, so the existing one-shot serve branch
would not serve it; it would return the registered cancel (`QUIT`) or hard-fail. Driving them
therefore needs a new category-keyed serve branch (see strategy), not a new seam.

### Class 3 — already reaches `input_context::handle_input` (guard-able today)

| Mechanism                                | Implementing line                                                                                                                                                                               | Category       | Current Arcopolis status                                                                                                                                                                                                                |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `choose_direction`                       | `input_context("DEFAULTMODE")` `src/action.cpp:1081`, loop `:1099`                                                                                                                              | `DEFAULTMODE`  | **DRIVEN** (Spike 11A one-shot direction answer); uses a `static_popup`, **not** a `uilist` — no abort                                                                                                                                  |
| `choose_adjacent_highlight`              | `src/action.cpp:1138` → `choose_adjacent` → `choose_direction`                                                                                                                                  | `DEFAULTMODE`  | **DRIVEN** (delegates to the above)                                                                                                                                                                                                     |
| old `"PICKUP"` menu                      | `input_context("PICKUP")` `src/pickup.cpp:753`, loop `:1196`                                                                                                                                    | `PICKUP`       | **DRIVEN** level-4 (Spike 12A queue serve branch)                                                                                                                                                                                       |
| `inventory_selector` / `NEW_PICKUP_MENU` | entry `src/game.cpp:8781-8782` → `game_menus::inv::pickup_from_tile` (`src/game_inventory.cpp:1699/1715`) → `inventory_selector::get_input` `src/inventory_ui.cpp:1887` (`ctxt.handle_input()`) | its own        | **FAILS LOUD** (`NEW_PICKUP_MENU=true` → `unsupported_command`); the **main loop reaches handle_input**, so it is a driving-complexity problem, _not_ a test_mode-abort blocker (its internal filter/sub-prompts may still hit Class 2) |
| `string_input_popup` / `string_input`    | `create_context()` `input_context("STRING_INPUT")` `src/string_input_popup.cpp:107-109` (cancel `"TEXT.QUIT"`), loop `:437`                                                                     | `STRING_INPUT` | reaches handle_input, **no abort**; the guard returns `TEXT.QUIT` (clean cancel — no hang); not driven (needs a text-answer channel)                                                                                                    |
| computer `query_ynq`                     | `input_context("YESNOQUIT")` → `handle_input` (`src/computer_session.cpp`)                                                                                                                      | `YESNOQUIT`    | reaches the seam (guard-able); no computer verb exists yet                                                                                                                                                                              |

### Class 4 — direct `get_input_event` read (bypasses the handle_input seam)

| Mechanism                         | Implementing line                                                                                                                                                  | Status                                                                                                                                                                                     |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `input_manager::wait_for_any_key` | reads `inp_mngr.get_input_event()` directly at `src/input.cpp:1489`; Arcopolis early-return guard at `:1482` (`if( arcopolis::backend_session_active() ) return;`) | **GUARDED** — returns immediately (faithful key-dismiss). Necessary because `get_input_event` has **no** test_mode guard and busy-waits on `inputdelay < 0` (`src/sdltiles.cpp:3967-3975`) |
| NPC dialogue main read            | `src/npctalk.cpp:2247` `inp_mngr.get_input_event()` (the `input_context` at `:2219` is Android-only)                                                               | **UNGUARDED** — would busy-wait; only reachable via a future talk verb (not built)                                                                                                         |
| computer main menu / `query_any`  | menu `uilist` `src/computer_session.cpp:153/163` (Class 2); `query_any` → `wait_for_any_key` `:1571` (Class 4, guarded)                                            | no computer verb exists yet                                                                                                                                                                |

`get_input_event`'s blocking busy-wait (`do { CheckMessages(); … } while( error )`,
`src/sdltiles.cpp:3967-3975`) has no test_mode guard, so **a backend UI mode alone does not make
Class 4 direct-read UIs safe** — each needs its own guard (as `wait_for_any_key` already has).

## Classification table

| Mechanism                                        | Source path/function                                                                              | test_mode behavior                                         | Reaches input_context?                                   | Current Arcopolis behavior                                                                   | Backend UI mode requirement                                                                                                                              |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| old PICKUP menu                                  | `pick_up_from_items`, `src/pickup.cpp:753` (ctxt), loop `:1196`                                   | no abort (runs)                                            | **Yes** (`PICKUP`)                                       | DRIVEN level-4 (Spike 12A)                                                                   | keep Class 1 suppression; already drivable — no change                                                                                                   |
| `uilist::query`                                  | `src/ui.cpp:916`; abort `:918-922`; real loop `:930/:945`                                         | **ABORTS** → `UILIST_ERROR` before its `input_context`     | No under test_mode; **Yes** if un-aborted                | NOT drivable; abort silently mis-handled by callers (vehicle submenu → silent ground pickup) | do **not** short-circuit `query`/`init` under backend UI mode; let it reach `handle_input`; add a category-keyed serve branch to drive it; render no-ops |
| `query_popup` (`query_yn`/`query_int`)           | `query_popup::query_once`, `src/popup.cpp:263`; abort `:269-271`; real loop `:277/:302`           | **ABORTS** → `{false,"ERROR"}` (a silent cancel/"No")      | No under test_mode; **Yes** if un-aborted                | silent cancel                                                                                | same as `uilist`; un-abort + serve via the seam; beware silent-"No" semantics                                                                            |
| `string_input_popup` / `string_input`            | `src/string_input_popup.cpp:107-109` (ctxt `STRING_INPUT`), loop `:437`                           | no abort (runs)                                            | **Yes** (`STRING_INPUT`)                                 | guard returns `TEXT.QUIT` (clean cancel); not driven                                         | needs a text-answer channel to drive; safe (no hang) without one                                                                                         |
| `choose_direction` / `choose_adjacent_highlight` | `src/action.cpp:1081/1099`; `:1138`                                                               | no abort (`static_popup`)                                  | **Yes** (`DEFAULTMODE`)                                  | DRIVEN (Spike 11A)                                                                           | already drivable; keep render suppression                                                                                                                |
| `inventory_selector` / `NEW_PICKUP_MENU`         | `src/game.cpp:8781`→`game_inventory.cpp:1699/1715`→`inventory_ui.cpp:1887`                        | main loop no abort (sub-prompts may)                       | **Yes** (own ctx)                                        | FAILS LOUD (`unsupported_command`)                                                           | driving-complexity, not abort; future serve branch; sub-prompts still Class 2                                                                            |
| `wait_for_any_key`                               | `src/input.cpp:1473`; direct read `:1489`; guard `:1482`                                          | no test_mode guard; only the Arcopolis guard prevents hang | **No** (direct read)                                     | GUARDED (immediate return = key-dismiss)                                                     | keep this guard; backend UI mode does not replace it                                                                                                     |
| NPC talk UI                                      | `dialogue::opt`, `src/npctalk.cpp:2247` (direct read)                                             | no guard                                                   | **No** (direct read; `input_context :2219` Android-only) | UNGUARDED; would busy-wait; unreachable (no talk verb)                                       | a future talk verb needs a `wait_for_any_key`-style guard or refactor to `input_context`; UI mode alone insufficient                                     |
| computer UI                                      | `computer_session.cpp`: menu `uilist :163`; `query_any`→`wait_for_any_key :1571`; `query_ynq` ctx | menu uilist ABORTS; `query_any` guarded; `query_ynq` runs  | mixed                                                    | menu uilist auto-errors; no computer verb                                                    | uilist menu = same as `uilist` row; computer verb is future work                                                                                         |

## Proposed backend UI mode semantics

A distinct mode (name candidates `backend_interactive_ui` / `arcopolis_backend_ui_mode` /
`headless_interactive_ui` — name TBD; the semantics are fixed) must mean:

- **No real curses/tiles rendering required** — Class 1 render suppression stays in force.
- **No real keyboard input required** — no SDL event pump, no blocking on a key source.
- **stdout remains JSONL protocol only** — no UI ever prints to stdout.
- **stderr/logs remain diagnostics only** — `debugmsg`/log lines are diagnostics, never protocol.
- **UI redraw may safely no-op** — `ui_adaptor`/`ui_manager` redraw is suppressed.
- **Real `input_context` loops are still allowed to run** — Class 2 must **not** short-circuit;
  the loop executes and reads through `input_context::handle_input`.
- **Registered actions may be supplied by Arcopolis backend input hooks** — the existing
  `backend_nested_input_action` seam serves the loop, extended with category-keyed branches.
- **Unsupported prompt classes fail loud or are explicitly marked** — never a silent
  auto-cancel-as-success. A class the backend cannot yet drive answers `unsupported_command` (or a
  marked partial), exactly as Spike 12A/31 already do for the vehicle submenu and the secondary
  capacity prompt.

It must be **distinct from `test_mode`**: cata_test keeps the Class 2 abort (it has no input source
and relies on the abort), and the backend takes the new mode instead. It must be **inert unless a
backend session is active**, so normal GUI play is byte-unchanged.

## Candidate implementation strategy (for a later spike — NOT implemented here)

A conservative shape, sketched only:

1. Add a distinct gate, e.g. `arcopolis::backend_ui_mode_active()` (true only inside an active
   `--arcopolis-*` session that opts in), separate from the `test_mode` global.
2. At the Class 2 short-circuits — `uilist::query` (`src/ui.cpp:918`), `uilist::init`
   (`src/ui.cpp:154`), `query_popup::query_once` (`src/popup.cpp:269`) — take the abort **only when
   `test_mode && !backend_ui_mode_active()`**. cata_test (test_mode, no backend session) is
   byte-unchanged; the backend lets the real `input_context` loop run.
3. Keep **all** Class 1 suppression and the Class 4 `wait_for_any_key` guard exactly as-is.
4. To _drive_ a `uilist`/`query_popup`, add a **category-keyed serve branch** in
   `backend_nested_input_action` (mirroring the Spike 12A `"PICKUP"` registered-action queue) keyed
   on `"UILIST"` / the popup category, fed by a `prompt_source` like Spike 12A's. Anything not
   armed still fails loud or cancels — never silent success.

This is a sketch to bound a future spike, not a committed design; the audit's job is to establish
that it is _possible_ and what it must guarantee.

## Explicit non-goals

- No general backend UI mode implementation (this PR is audit/design only).
- No gameplay, prompt, or protocol behavior change; no new protocol command.
- No attempt to drive `uilist` — not even a compile-only probe.
- No making `test_mode` false globally (that would risk real rendering, keyboard blocking, stdout
  pollution).
- No bypass of `game::handle_action` or `game::do_turn`.
- No direct mutation of UI/menu state and no fake/synthesized menu answers.
- No making unsupported prompts succeed silently.
- No weakening of the AGENTS.md level-4 equivalence rule; no claim of generic prompt/menu support.

## Risks / blockers

- **The Class 2 abort doubles as a fail-safety net.** Un-aborting `uilist`/`query_popup` without an
  armed driver routes them to the guard, which cancels (`QUIT`) or hard-fails (exit 12). That must
  be a deliberate, gated decision, not an accident of flipping a flag.
- **`get_input_event` has no test_mode guard** (`src/sdltiles.cpp:3967-3975`): any Class 4
  direct-read UI (NPC talk) would busy-wait under any UI mode. The backend UI mode alone does not
  make those safe — each needs a per-site guard.
- **stdout pollution / `debugmsg` spam.** A un-aborted `uilist` still calls `debugmsg` on some paths
  and could print; the mode must keep stdout JSONL-only and route diagnostics to stderr/log.
- **Unit-test semantics.** cata_test relies on the `uilist` abort. The new gate **must** be distinct
  from `test_mode` so the test suite is untouched; a witness must assert cata_test `uilist` still
  auto-errors.
- **Accidental GUI change.** The gate must be inert outside an active backend session, or normal
  play could lose the abort/suppression behavior.
- **Half-driven screens.** A UI that partially runs but is not protocol-covered is a silent hole;
  the fail-loud/marked rule must bind to every un-aborted class that is not actually driven.

## Recommended next spike — Spike 13B (proposed, NOT implemented)

The narrowest proof of this design:

- Under the new backend UI mode, let **one** `uilist` run to its real
  `input_context::handle_input` loop (do **not** take the Class 2 abort for it).
- Feed **one** registered action through the seam via a new category-keyed serve branch, and assert
  the engine's own loop consumes it (equivalence **level 4**).
- Assert **stdout remains pure JSONL** throughout.
- Assert **normal `test_mode` behavior outside Arcopolis is unchanged** — cata_test `uilist` still
  returns `UILIST_ERROR`.

One fixture/witness, one prompt class, no new command surface. If it holds, broader prompt/menu
support (the new inventory_selector, computer menus, NPC dialogue) can build on the proven mode.

## Claim → cite → verdict audit

Per [[cite-the-implementing-line]] — each load-bearing claim verified at the implementing line:

| Load-bearing claim                                                                       | Cite                                                                                | Type       | Verdict     |
| ---------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- | ---------- | ----------- |
| `uilist::query` aborts before its `input_context`                                        | `src/ui.cpp:918-922` vs `:930`/`:945`                                               | behavioral | ✅ verified |
| Past the abort, `uilist::query` uses `input_context::handle_input`                       | `src/ui.cpp:930, 945`                                                               | behavioral | ✅ verified |
| `uilist::init` also short-circuits under test_mode                                       | `src/ui.cpp:154-156`                                                                | behavioral | ✅ verified |
| `uilist` category default = `"UILIST"` (not DEFAULTMODE)                                 | `src/ui.cpp:210, 216`                                                               | structural | ✅ verified |
| `query_popup::query_once` aborts to `{false,"ERROR"}` before its `input_context`         | `src/popup.cpp:269-271` vs `:277`/`:302`                                            | behavioral | ✅ verified |
| `string_input_popup` reaches handle_input (no abort), cat `STRING_INPUT`/`TEXT.QUIT`     | `src/string_input_popup.cpp:107-109, 437`                                           | behavioral | ✅ verified |
| `choose_direction` = DEFAULTMODE handle_input, not a uilist                              | `src/action.cpp:1081, 1099`                                                         | behavioral | ✅ verified |
| old PICKUP = `input_context("PICKUP")` handle_input                                      | `src/pickup.cpp:753, 1196`                                                          | behavioral | ✅ verified |
| `inventory_selector` main loop reaches handle_input                                      | `src/inventory_ui.cpp:1887`                                                         | behavioral | ✅ verified |
| `wait_for_any_key` reads `get_input_event` directly, guarded by `backend_session_active` | `src/input.cpp:1489, 1482`                                                          | behavioral | ✅ verified |
| `get_input_event` has no test_mode guard, busy-waits on `inputdelay < 0`                 | `src/sdltiles.cpp:3967-3975`                                                        | behavioral | ✅ verified |
| NPC talk reads `get_input_event` directly (Android ctx only)                             | `src/npctalk.cpp:2247, 2219`                                                        | behavioral | ✅ verified |
| `test_mode` declared / set for arcopolis modes                                           | `src/cached_options.h:12`; `src/main.cpp:485-580`                                   | structural | ✅ verified |
| Class 1 suppression sites (render/pump/draw/debugmsg)                                    | `sdltiles.cpp:507`, `:3938`; `game.cpp:4531`; `ui_manager.cpp:328`; `debug.cpp:518` | behavioral | ✅ verified |
