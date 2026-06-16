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
guard never sees it. `query_popup::query_once()` does the same (`src/popup.cpp:269-271`), and so does
the whole `popup()`/`popup_getkey()` family that builds on it. These are the **blocked class**: their
real input loops exist, but `test_mode` aborts ahead of them.

The audit sorts every audited mechanism into four behavioral classes:

- **Class 1 — suppression** (render/keyboard/curses): what Arcopolis wants; **keep** — _with one
  caveat_ (the redraw no-op also skips the callbacks that populate `uilist` loop state; see
  "Callback-populated loop state").
- **Class 2 — abort-before-input** (`uilist`, `query_popup`, the `popup()` family): the blocker;
  **must not short-circuit under a backend UI mode**. Crucially, _past_ the abort all use the real
  `input_context::handle_input` seam — so un-aborting them routes through the **existing** guard,
  not a raw read.
- **Class 3 — already reaches `handle_input`** (`choose_direction`, old PICKUP, `inventory_selector`,
  `string_input_popup`, `query_int`, computer `query_ynq`, `draw_item_info`, ranged `TARGET`):
  guard-able today; PICKUP and the direction chooser are already driven (Spikes 12A/11A). The rest
  are a _driving-complexity_ problem, **not** a test_mode-abort problem.
- **Class 4 — direct `get_input_event` read** (`wait_for_any_key`, NPC dialogue, the hit-animation
  skip-read): bypasses the `handle_input` seam entirely; needs **per-site** guards regardless of any
  UI mode, because `get_input_event` has **no** test_mode guard and busy-waits on a blocking read.

**Answer to the spike's question:** yes — a distinct Arcopolis backend UI mode _can_ disable
rendering and real keyboard dependency while still allowing real UI/input loops to execute and
consume registered backend actions. It must be a flag **distinct from `test_mode`** (so cata_test
is untouched), it must keep Class 1 suppression _but still run the redraw/resize callbacks that
populate loop state_ (suppressing only the actual draw), it must **not** take the Class 2 abort, it
must keep the Class 4 `wait_for_any_key` guard, and any prompt class it does not actually drive must
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
`uilist`, `query_popup`, and `popup()` families, the abort fires _before_ the loop is even
constructed, so the Spike 11A nested-input guard — which sits at the top of `handle_input` — cannot
intercept anything. Worse, the abort returns an error sentinel (`UILIST_ERROR`, `{false,"ERROR"}`,
`UNKNOWN_UNICODE`) that a naive caller mis-handles silently: in Spike 12A the vehicle "Get items
from where?" `uilist` returned `UILIST_ERROR` and `pick_up` fell through to a **silent ground-only
pickup**.

So the question is precise: **can we create a backend UI mode that keeps job (1) — no
render/keyboard — while dropping job (2) — the abort — so that the real `input_context` loops run
and the Arcopolis input hooks can serve them registered actions, without polluting stdout, without
real keyboard blocking, and without weakening the level-4 rule or changing GUI/test behavior?**

## Source audit

All findings below were read at the **implementing line** in the current tree (not from prior
docs/memory). `test_mode` is declared `extern bool test_mode` at `src/cached_options.h:12` (defined
`= false` at `src/cached_options.cpp:5`). In the **game binary** it is set `true` by the
`--arcopolis-*` flag handlers in `src/main.cpp` at `:528` / `:542` / `:556` / `:570` / `:580` (the
flag block spans `:520–:584`); the same global is also set by the diagnostic flags `--jsonverify`
(`:305`), `--check-mods` (`:316`), `--check-all-mods` (`:331`), `--dump-stats` (`:344`) and the Lua
export flags `--lua-doc` (`:485`), `--lua-types` (`:499`). **There is no `--test-mode` flag**: the
unit-test binary (`cata_test`) is a _separate_ binary that sets the same global unconditionally at
its own entry point (`tests/test_main.cpp:380`). So `test_mode` is **one global shared by two
binaries** (not shared flag handlers) — which is the crux of the conflation.

### Class 1 — render / keyboard / curses suppression (Arcopolis WANTS this → KEEP)

| Mechanism                        | Implementing line        | Behavior                                                                                                                                                                                        |
| -------------------------------- | ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `refresh_display`                | `src/sdltiles.cpp:507`   | `if( test_mode ) { return; }` before any SDL present — pure render suppression                                                                                                                  |
| `game::draw`                     | `src/game.cpp:4531`      | `if( test_mode ) { return; }` before terrain/entity draw                                                                                                                                        |
| `ui_adaptor::redraw_invalidated` | `src/ui_manager.cpp:328` | `if( test_mode \|\| ui_stack.empty() ) { return; }` — skips invoking the `on_redraw`/`on_screen_resize` callbacks **entirely**, not just the screen present (see Callback-populated loop state) |
| `input_manager::pump_events`     | `src/sdltiles.cpp:3938`  | `if( test_mode ) { return; }` before `CheckMessages()` — skips the SDL event poll                                                                                                               |
| `debugmsg`                       | `src/debug.cpp:518`      | under test_mode logs then returns **without** the interactive prompt; **does not abort** in the game binary                                                                                     |

None of these aborts a logic/input loop. All are safe to keep verbatim **except** the
`redraw_invalidated` no-op, which is benign for rendering but also silently skips the
callback-driven `setup()` a `uilist` loop depends on once Class 2 is un-aborted (see below).

### Class 2 — UI ABORT before the input loop (Arcopolis does NOT want → the blocker)

| Mechanism                                                    | Abort site                                                                                                                                                        | Real loop underneath                                                                                                                                                                    | Notes                                                                                                                                                                                                                                                                                                                                                                                                  |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `uilist::query`                                              | `src/ui.cpp:918-922` returns `UILIST_ERROR`                                                                                                                       | builds `input_context` via `create_main_input_context()` at `:930` (category member = `"UILIST"`, set `:210`, used `:216`) and loops `ret_act = ctxt.handle_input( timeout )` at `:945` | abort is _before_ the `input_context`; `uilist::init` also short-circuits at `:154-156`                                                                                                                                                                                                                                                                                                                |
| `query_popup::query_once`                                    | `src/popup.cpp:269-271` returns `{ false, "ERROR", {} }`                                                                                                          | builds `input_context( category )` at `:277`, loops `res.action = ctxt.handle_input()` at `:302`; registers `QUIT` only if cancelable (`:294-296`)                                      | `query_yn` (`src/output.cpp:707`) routes through this → silent "No". (`query_int` does **not** — it uses `string_input_popup`; see Class 3.)                                                                                                                                                                                                                                                           |
| `popup` / `popup_getkey` / `popup_top` / `full_screen_popup` | builds `query_popup pop` (`src/output.cpp:773`), `pop.context("POPUP_WAIT")` (`:789`), `pop.query()` (`:790`) → same `query_once` abort (`src/popup.cpp:269-271`) | same `input_context("POPUP_WAIT")` loop underneath                                                                                                                                      | the **dominant** Class 2 surface (wield/wear errors, item compare, bionics, armor layers; thin wrappers at `src/output.h:467/472/483`). On abort `popup()` silently returns `UNKNOWN_UNICODE` (`src/output.cpp:791-794`) — same silent-mis-handle hazard as the vehicle submenu. `PF_GET_KEY` registers `ANY_INPUT` not `QUIT`, so it needs its **own** serve category, distinct from the cancel path. |

**The load-bearing fact:** past their test_mode early-returns, **all three use the real
`input_context::handle_input` seam.** Un-aborting them does not create a new raw-read path — it
routes through the seam Arcopolis already hooks. The current guard serves only `"DEFAULTMODE"` (the
one-shot direction answer) and `"PICKUP"` (the queue); a `"UILIST"`, popup `"POPUP_WAIT"`, or other
category is **not** served, so for a blocking (`timeout < 0`) read it returns the registered cancel
(`QUIT` if registered) or hard-fails (exit 12). Driving any of them therefore needs a new
category-keyed serve branch (see strategy) — and, for `uilist`, the callback-driven setup below.

### Class 3 — already reaches `input_context::handle_input` (guard-able today)

| Mechanism                                          | Implementing line                                                                                                                                      | Category       | Current Arcopolis status                                                                                                                                                                                                                                                                                                              |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `choose_direction`                                 | `input_context("DEFAULTMODE")` `src/action.cpp:1081`, loop `:1099`                                                                                     | `DEFAULTMODE`  | **DRIVEN** (Spike 11A one-shot direction answer); uses a `static_popup`, **not** a `uilist` — no abort                                                                                                                                                                                                                                |
| `choose_adjacent_highlight`                        | `src/action.cpp:1138` → `choose_adjacent` → `choose_direction`                                                                                         | `DEFAULTMODE`  | **DRIVEN** (delegates to the above)                                                                                                                                                                                                                                                                                                   |
| old `"PICKUP"` menu                                | `input_context("PICKUP")` `src/pickup.cpp:753`, loop `:1196`                                                                                           | `PICKUP`       | **DRIVEN** level-4 (Spike 12A queue) — but only by dodging callback-populated scroll geometry (`maxitems=0`; see below)                                                                                                                                                                                                               |
| `inventory_selector` / `NEW_PICKUP_MENU`           | entry `src/game.cpp:8781-8782` → `pickup_from_tile` (`src/game_inventory.cpp:1699/1715`) → `inventory_selector::get_input` `src/inventory_ui.cpp:1887` | its own        | **FAILS LOUD** (`NEW_PICKUP_MENU=true` → `unsupported_command`); the **main loop reaches handle_input** (driving-complexity, not abort). Its sub-prompts split: **filter/count are `string_input` (Class 3**, `src/inventory_ui.cpp:1657/2128`); the **error notices are `popup_getkey` (Class 2**, `:1716/1735/2204/2291/2484/2609`) |
| `string_input_popup` / `string_input`              | `create_context()` `input_context("STRING_INPUT")` `src/string_input_popup.cpp:107-109` (cancel `"TEXT.QUIT"`), loop `:437`                            | `STRING_INPUT` | reaches handle_input, **no abort**; the guard returns `TEXT.QUIT` (clean cancel); not driven (needs a text-answer channel)                                                                                                                                                                                                            |
| `query_int`                                        | `string_input_popup` `popup.query()` `src/output.cpp:733/746`                                                                                          | `STRING_INPUT` | same as string_input (no abort, not driven). **Not** a `query_popup`/Class 2 path                                                                                                                                                                                                                                                     |
| computer `query_ynq`                               | `input_context("YESNOQUIT")` `src/computer_session.cpp:1582`, loop `:1599`                                                                             | `YESNOQUIT`    | reaches the seam (guard-able); no computer verb exists yet                                                                                                                                                                                                                                                                            |
| `draw_item_info` (window/`std::function` overload) | `input_context ctxt;` (**empty** category) `src/output.cpp:1039`, loop `:1053-1055`; `without_getch` early-return `:1023-1027`                         | _empty_        | reached on item examine and inside `inventory_selector` (`src/inventory_ui.cpp:756`). Has `QUIT` (`:1045`) so guard cancels cleanly; the empty category is a gap for any category-keyed serve branch                                                                                                                                  |
| ranged `TARGET` (fire/throw/cast)                  | `input_context("TARGET")` `src/ranged.cpp:3140`, loop `:2991`                                                                                          | `TARGET`       | reaches handle_input, no abort, guard-able; not served (would cancel/hard-fail). The combat-relevant Class 3 surface                                                                                                                                                                                                                  |

### Class 4 — direct `get_input_event` read (bypasses the handle_input seam)

| Mechanism                         | Implementing line                                                                                                                                                  | Status                                                                                                                                                                                     |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `input_manager::wait_for_any_key` | reads `inp_mngr.get_input_event()` directly at `src/input.cpp:1489`; Arcopolis early-return guard at `:1482` (`if( arcopolis::backend_session_active() ) return;`) | **GUARDED** — returns immediately (faithful key-dismiss). Necessary because `get_input_event` has **no** test_mode guard and busy-waits on `inputdelay < 0` (`src/sdltiles.cpp:3967-3975`) |
| NPC dialogue main read            | `src/npctalk.cpp:2247` `inp_mngr.get_input_event()` (the `input_context` at `:2219` is inside `#if defined(__ANDROID__)`)                                          | **UNGUARDED** — would busy-wait; only reachable via a future talk verb (not built)                                                                                                         |
| hit-animation skip-read           | `src/animation.cpp:748` `inp_mngr.get_input_event()` preceded by `set_timeout(ANIMATION_DELAY)` (`:746`)                                                           | direct read but `timeout >= 0` (a **timed poll**, self-returns) → does **not** busy-wait headless; safe. Listed for an exhaustive Class 4 census                                           |
| computer main menu / `query_any`  | menu `uilist` `src/computer_session.cpp:153/163` (Class 2); `query_any` → `wait_for_any_key` `:1571` (Class 4, guarded)                                            | no computer verb exists yet                                                                                                                                                                |

`get_input_event`'s blocking busy-wait (`do { CheckMessages(); … } while( error )`,
`src/sdltiles.cpp:3967-3975`) has no test_mode guard, so **a backend UI mode alone does not make
Class 4 direct-read UIs safe** — each needs its own guard (as `wait_for_any_key` already has).

### Callback-populated loop state (the deeper blocker — generalizes doc 30)

Un-aborting a Class 2 loop is **necessary but not sufficient**, because some loops read state that is
populated _only_ as a side effect of the redraw/resize callbacks that Class 1 suppression disables:

- **`uilist`:** `fentries`, `keymap`, and `vmax` are populated only inside `uilist::setup()`
  (`keymap` `src/ui.cpp:490/527`, `vmax` `:597`) and `filterlist()` (`fentries` `:299`, called from
  `setup()` at `:633`). `setup()` is reachable **only** via the `on_redraw`→`show()` (`:678`) and
  `on_screen_resize`→`reposition()` (`:641`) callbacks registered at `:901-906`; `uilist::query()`
  itself never calls `setup()`. Under render suppression `ui_adaptor::redraw_invalidated()`
  early-returns (`src/ui_manager.cpp:328`), so neither callback fires → `fentries` stays empty →
  `CONFIRM` no-ops at `src/ui.cpp:974` and hotkeys find nothing in `keymap`. **The loop runs but
  cannot select.**
- **old `"PICKUP"` menu:** doc 30 already documented the identical phenomenon — `maxitems` stays `0`
  because `on_screen_resize` never fires (`src/pickup.cpp:697`, assigned only in the resize callback
  `:705-714`), so `UP`/`PREV_TAB` would divide by zero (`:968/984`). Spike 12A's driver works around
  this by navigating **forward `DOWN`/`RIGHT`/`CONFIRM` only** — it _dodges_ the callback-dependent
  scroll geometry rather than solving it.

So "redraw may no-op" and "let the loop run" are in tension. A backend UI mode must run the loop's
**layout/data-population** half (`setup()`/`filterlist()` — the resize/redraw callbacks) on a
non-render path, suppressing only the actual draw/present, **not** skip the callbacks wholesale.
This is the single most important prerequisite for driving any `uilist`, and the reason Spike 13B
below is scoped around it.

## Classification table

| Mechanism                                              | Source path/function                                                                                     | test_mode behavior                                         | Reaches input_context?                                   | Current Arcopolis behavior                                                        | Backend UI mode requirement                                                                                                                                                                                    |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- | -------------------------------------------------------- | --------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| old PICKUP menu                                        | `pick_up_from_items`, `src/pickup.cpp:753`, loop `:1196`                                                 | no abort (runs)                                            | **Yes** (`PICKUP`)                                       | DRIVEN level-4 (Spike 12A) — works around `maxitems=0` via forward-only nav       | keep Class 1 suppression; already drivable for forward nav; full nav needs the setup-path fix below                                                                                                            |
| `uilist::query`                                        | `src/ui.cpp:916`; abort `:918-922`; real loop `:930/945`                                                 | **ABORTS** → `UILIST_ERROR` before its `input_context`     | No under test_mode; **Yes** if un-aborted                | NOT drivable; abort silently mis-handled (vehicle submenu → silent ground pickup) | do **not** short-circuit `query`/`init`; let it reach `handle_input`; **also run `setup()`/`filterlist()` on a non-render path** (else `fentries` empty); category-keyed serve branch (`"UILIST"`) to drive it |
| `query_popup` (`query_yn`)                             | `query_popup::query_once`, `src/popup.cpp:263`; abort `:269-271`; real loop `:277/302`                   | **ABORTS** → `{false,"ERROR"}` (silent "No")               | No under test_mode; **Yes** if un-aborted                | silent cancel                                                                     | un-abort + serve via the seam (`YESNO`/category); beware silent-"No" semantics                                                                                                                                 |
| `popup`/`popup_getkey`/`popup_top`/`full_screen_popup` | `src/output.cpp:773` → `query_popup` `POPUP_WAIT` `:789-790`                                             | **ABORTS** → `UNKNOWN_UNICODE` (`:791-794`)                | No under test_mode; **Yes** if un-aborted                | silent `UNKNOWN_UNICODE`; callers comparing to specific keys can busy-**spin**    | un-abort; serve a `"POPUP_WAIT"` branch (note `PF_GET_KEY` registers `ANY_INPUT`, not `QUIT`)                                                                                                                  |
| `string_input_popup` / `string_input` / `query_int`    | `src/string_input_popup.cpp:107-109`, loop `:437`; `query_int` `src/output.cpp:733/746`                  | no abort (runs)                                            | **Yes** (`STRING_INPUT`)                                 | guard returns `TEXT.QUIT` (clean cancel); not driven                              | needs a text-answer channel to drive; safe (no hang) without one                                                                                                                                               |
| `choose_direction` / `choose_adjacent_highlight`       | `src/action.cpp:1081/1099`; `:1138`                                                                      | no abort (`static_popup`)                                  | **Yes** (`DEFAULTMODE`)                                  | DRIVEN (Spike 11A)                                                                | already drivable; keep render suppression                                                                                                                                                                      |
| `inventory_selector` / `NEW_PICKUP_MENU`               | `src/game.cpp:8781`→`game_inventory.cpp:1699/1715`→`inventory_ui.cpp:1887`                               | main loop no abort                                         | **Yes** (own ctx)                                        | FAILS LOUD (`unsupported_command`)                                                | driving-complexity, not abort; future serve branch + setup-path; filter/count sub-prompts are Class 3 `string_input`, error notices are Class 2 `popup_getkey`                                                 |
| `draw_item_info`                                       | `input_context ctxt;` (empty cat) `src/output.cpp:1039`, loop `:1053-1055`                               | no abort                                                   | **Yes** (empty cat)                                      | reachable via examine; cancels cleanly (QUIT `:1045`)                             | empty category is a gap for category-keyed serve; `without_getch` path is abort-free                                                                                                                           |
| ranged `TARGET`                                        | `input_context("TARGET")` `src/ranged.cpp:3140`, loop `:2991`                                            | no abort                                                   | **Yes** (`TARGET`)                                       | not served (cancel/hard-fail); no fire verb yet                                   | driving-complexity; future serve branch                                                                                                                                                                        |
| `wait_for_any_key`                                     | `src/input.cpp:1473`; direct read `:1489`; guard `:1482`                                                 | no test_mode guard; only the Arcopolis guard prevents hang | **No** (direct read)                                     | GUARDED (immediate return = key-dismiss)                                          | keep this guard; backend UI mode does not replace it                                                                                                                                                           |
| NPC talk UI                                            | `dialogue::opt`, `src/npctalk.cpp:2247` (direct read)                                                    | no guard                                                   | **No** (direct read; `input_context :2219` Android-only) | UNGUARDED; would busy-wait; unreachable (no talk verb)                            | a future talk verb needs a `wait_for_any_key`-style guard or refactor to `input_context`                                                                                                                       |
| computer UI                                            | `computer_session.cpp`: menu `uilist :163`; `query_any`→`wait_for_any_key :1571`; `query_ynq :1582/1599` | menu uilist ABORTS; `query_any` guarded; `query_ynq` runs  | mixed                                                    | menu uilist auto-errors; no computer verb                                         | uilist menu = same as `uilist` row; computer verb is future work                                                                                                                                               |

## Proposed backend UI mode semantics

A distinct mode (name candidates `backend_interactive_ui` / `arcopolis_backend_ui_mode` /
`headless_interactive_ui` — name TBD; the semantics are fixed) must mean:

- **No real curses/tiles rendering required** — Class 1 render suppression stays in force.
- **No real keyboard input required** — no SDL event pump, no blocking on a key source.
- **stdout remains JSONL protocol only** — no UI ever prints to stdout.
- **stderr/logs remain diagnostics only** — `debugmsg`/log lines are diagnostics, never protocol.
- **UI rendering may no-op, but the redraw/resize _callbacks_ must still run** — suppress only the
  actual draw/present, **not** the callback-driven `setup()`/`filterlist()` that populate a `uilist`'s
  `fentries`/`keymap`/`vmax`. A pure no-op redraw leaves the loop unable to select (see
  Callback-populated loop state).
- **Real `input_context` loops are still allowed to run** — Class 2 must **not** short-circuit;
  the loop executes and reads through `input_context::handle_input`.
- **Registered actions may be supplied by Arcopolis backend input hooks** — the existing
  `backend_nested_input_action` seam serves the loop, extended with category-keyed branches
  (`"UILIST"`, `"POPUP_WAIT"`, …), and only for **blocking** (`timeout < 0`) reads (the guard passes
  through `timeout >= 0` polls).
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
   (`src/ui.cpp:154`), `query_popup::query_once` (`src/popup.cpp:269`, which also covers the
   `popup()` family) — take the abort **only when `test_mode && !backend_ui_mode_active()`**.
   cata_test (test_mode, no backend session) is byte-unchanged; the backend lets the real
   `input_context` loop run. **Scope the un-abort to the targeted menu** — a _global_ flip would also
   un-abort `timeout >= 0` uilist callers (`src/editmap.cpp` passes `BLINK_SPEED`,
   `src/messages.cpp:630` passes `true`), which the guard passes through to the real `get_input_event`
   rather than serving — not drivable, and a residual hazard.
3. Provide the **non-render setup path**: run `uilist::setup()`/`filterlist()` (the
   `on_screen_resize`/`on_redraw` callbacks) headlessly so `fentries`/`keymap`/`vmax` are populated,
   while still suppressing the actual draw/present. Without this the un-aborted loop selects nothing.
4. Keep **all** Class 1 render suppression and the Class 4 `wait_for_any_key` guard exactly as-is.
5. To _drive_ a `uilist`/`query_popup`/`popup`, add a **category-keyed serve branch** in
   `backend_nested_input_action` (mirroring the Spike 12A `"PICKUP"` registered-action queue) keyed
   on `"UILIST"` / `"POPUP_WAIT"` / the popup category, fed by a `prompt_source` like Spike 12A's, and
   only for blocking reads. Anything not armed still fails loud or cancels — never silent success.

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

- **Callback-populated loop state (the load-bearing one).** Un-aborting `uilist::query` alone yields
  a live `handle_input` loop over **empty** `fentries`/`keymap` (`vmax=0`), because `setup()` runs
  only via the suppressed redraw/resize callbacks — `CONFIRM` no-ops at `src/ui.cpp:974`. The mode
  must drive `setup()` on a non-render path, not just skip the abort. Same root cause as doc 30's
  `maxitems=0` for the PICKUP menu.
- **The Class 2 abort doubles as a fail-safety net.** Un-aborting `uilist`/`query_popup`/`popup`
  without an armed driver routes them to the guard, which cancels (`QUIT`) or hard-fails (exit 12)
  for a blocking read. That must be a deliberate, gated decision, not an accident of flipping a flag.
- **`timeout >= 0` reads bypass the guard.** The guard only intercepts blocking (`timeout < 0`)
  reads; a global un-abort would expose `timeout >= 0` uilists (`editmap`, `messages` filter) to the
  real `get_input_event` (not served). Scope the un-abort to the targeted default-timeout menu.
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
- **Half-driven screens.** A UI that partially runs but is not protocol-covered is a silent hole.
  Concrete example: `game_menus::inv::prompt_reassign_letter` (`src/game_inventory.cpp:1864-1885`) is
  a `while(true)` loop over `popup_getkey` whose only breaks are `KEY_ESCAPE`/`' '`/a valid invlet —
  the abort's `UNKNOWN_UNICODE` matches none, so it busy-**spins**, and even the guard's `QUIT` cancel
  is not `KEY_ESCAPE`. The fail-loud/marked rule must bind to every un-aborted class not actually
  driven, with caller-aware cancel semantics.

## Recommended next spike — Spike 13B (proposed, NOT implemented)

The narrowest proof of this design:

- Under the new backend UI mode, let **one** `uilist` run to its real
  `input_context::handle_input` loop (do **not** take the Class 2 abort for it).
- **First** establish the non-render setup path: run `uilist::setup()`/`filterlist()` (the
  `on_screen_resize`/`on_redraw` callbacks) headlessly and **assert `fentries` is non-empty** before
  driving — otherwise "the engine consumed the action" would pass vacuously while selecting nothing.
- Feed **one** registered action through the seam via a new category-keyed serve branch (blocking
  read), and assert the engine's own loop consumes it and the selection actually changes
  (equivalence **level 4**).
- Assert **stdout remains pure JSONL** throughout.
- Assert **normal `test_mode` behavior outside Arcopolis is unchanged** — cata_test `uilist` still
  returns `UILIST_ERROR`.

One fixture/witness, one prompt class, no new command surface. If it holds, broader prompt/menu
support (the new inventory_selector, computer menus, NPC dialogue) can build on the proven mode.

> **Spike 13B result (2026-06-15) — it holds.** Built exactly per this design and proven at runtime in
> [33_SPIKE13B_BACKEND_DRIVEN_UILIST.md](33_SPIKE13B_BACKEND_DRIVEN_UILIST.md): the vehicle-source
> `"Get items from where?"` `uilist` runs headlessly to its real `input_context("UILIST")::handle_input`
> loop, with `setup()`/`filterlist()` populating `fentries`/`vmax`/retvals on a non-render path (the
> direct-call variant of strategy point 3 — `setup()` is called from `uilist::query()` under the gate
> rather than via the redraw/resize callbacks, which avoids touching `ui_manager.cpp` and un-suppressing
> draws globally), and the engine's own loop consuming registered `DOWN`/`CONFIRM` (equivalence **level
> 4**). The gate is `arcopolis::backend_ui_mode_active()` = `session.active && session.uilist_transaction`
> (strategy point 1), scoped to exactly the one armed menu (strategy point 2's "scope the un-abort to the
> targeted menu"). cata_test's `uilist` still returns `UILIST_ERROR` (asserted). The audit history above is
> unchanged; this note only records that the proposed spike was implemented and passed.

## Claim → cite → verdict audit

Per [[cite-the-implementing-line]] — each load-bearing claim verified at the implementing line
(re-verified by an adversarial multi-agent pass, 2026-06-15):

| Load-bearing claim                                                                                                                                                       | Cite                                                                                 | Type       | Verdict     |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------ | ---------- | ----------- |
| `uilist::query` aborts before its `input_context`                                                                                                                        | `src/ui.cpp:918-922` vs `:930`/`:945`                                                | behavioral | ✅ verified |
| Past the abort, `uilist::query` uses `input_context::handle_input` (default `timeout = -1`)                                                                              | `src/ui.cpp:930, 945`; `src/ui.h:243`                                                | behavioral | ✅ verified |
| `uilist::init` also short-circuits under test_mode                                                                                                                       | `src/ui.cpp:154-156`                                                                 | behavioral | ✅ verified |
| `uilist` category default = `"UILIST"` (not DEFAULTMODE)                                                                                                                 | `src/ui.cpp:210, 216`                                                                | structural | ✅ verified |
| `uilist` `fentries`/`keymap`/`vmax` populated only via `setup()`/`filterlist()`, reachable only via the redraw/resize callbacks                                          | `src/ui.cpp:490/527/597/633/299`, callbacks `:901-906`, `setup()` callers `:641/678` | behavioral | ✅ verified |
| `redraw_invalidated` no-op under test_mode skips the callbacks entirely                                                                                                  | `src/ui_manager.cpp:325, 328`                                                        | behavioral | ✅ verified |
| `CONFIRM` selects nothing when `fentries` empty                                                                                                                          | `src/ui.cpp:974`                                                                     | behavioral | ✅ verified |
| old PICKUP `maxitems=0` under suppression (forward-only nav)                                                                                                             | doc 30; `src/pickup.cpp:697, 705-714, 968, 984`                                      | behavioral | ✅ verified |
| `query_popup::query_once` aborts to `{false,"ERROR"}` before its `input_context`                                                                                         | `src/popup.cpp:269-271` vs `:277`/`:302`                                             | behavioral | ✅ verified |
| `query_yn` routes through `query_popup`; `query_int` uses `string_input_popup` (NOT query_popup)                                                                         | `src/output.cpp:714-724` vs `:733/746`                                               | behavioral | ✅ verified |
| `popup()` family → `query_popup` `POPUP_WAIT`, returns `UNKNOWN_UNICODE` on abort                                                                                        | `src/output.cpp:773, 789-794`; wrappers `src/output.h:467/472/483`                   | behavioral | ✅ verified |
| `string_input_popup` reaches handle_input (no abort), cat `STRING_INPUT`/`TEXT.QUIT`                                                                                     | `src/string_input_popup.cpp:107-109, 437`                                            | behavioral | ✅ verified |
| `choose_direction` = DEFAULTMODE handle_input, not a uilist                                                                                                              | `src/action.cpp:1081, 1099`                                                          | behavioral | ✅ verified |
| old PICKUP = `input_context("PICKUP")` handle_input                                                                                                                      | `src/pickup.cpp:753, 1196`                                                           | behavioral | ✅ verified |
| `inventory_selector` main loop reaches handle_input; sub-prompts = `string_input` + `popup_getkey`                                                                       | `src/inventory_ui.cpp:1887, 1657/2128, 1716/1735/2204/2291/2484/2609`                | behavioral | ✅ verified |
| `draw_item_info` uses an empty-category `input_context` loop                                                                                                             | `src/output.cpp:1039, 1053-1055`                                                     | behavioral | ✅ verified |
| ranged `TARGET` loop reaches handle_input                                                                                                                                | `src/ranged.cpp:3140, 2991`                                                          | behavioral | ✅ verified |
| `wait_for_any_key` reads `get_input_event` directly, guarded by `backend_session_active`                                                                                 | `src/input.cpp:1489, 1482`                                                           | behavioral | ✅ verified |
| `get_input_event` has no test_mode guard, busy-waits on `inputdelay < 0`                                                                                                 | `src/sdltiles.cpp:3967-3975`                                                         | behavioral | ✅ verified |
| `animation.cpp` direct read is a timed poll (`timeout >= 0`), self-returns                                                                                               | `src/animation.cpp:746-749`                                                          | behavioral | ✅ verified |
| NPC talk reads `get_input_event` directly (Android ctx only)                                                                                                             | `src/npctalk.cpp:2247, 2219`                                                         | behavioral | ✅ verified |
| `prompt_reassign_letter` busy-spins on the `popup_getkey` abort sentinel                                                                                                 | `src/game_inventory.cpp:1864-1885`                                                   | behavioral | ✅ verified |
| `test_mode` declared `cached_options.h:12`; arcopolis sets at `main.cpp:528/542/556/570/580` (block `:520-584`); cata_test at `test_main.cpp:380`; no `--test-mode` flag | `src/cached_options.h:12`; `src/main.cpp:528-580`; `tests/test_main.cpp:380`         | structural | ✅ verified |
| Class 1 suppression sites (render/pump/draw/debugmsg)                                                                                                                    | `sdltiles.cpp:507`, `:3938`; `game.cpp:4531`; `ui_manager.cpp:328`; `debug.cpp:518`  | behavioral | ✅ verified |
