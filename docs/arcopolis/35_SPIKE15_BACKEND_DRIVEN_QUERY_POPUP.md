# Arcopolis Spike 15 — one backend-driven real `query_popup` path at level 4

**Status: implementation + decision record (2026-06-16).** The first backend-driven **`query_popup`** path,
proving the Spike 13A backend-UI-mode design generalizes from `uilist` (Spikes 13B/14) to a **different
Class 2 mechanism**: a `query_yn` using `input_context("YESNO")`. The witness is the deployed-furniture
take-down query_yn raised by `iexamine::deployed_furniture` (`src/iexamine.cpp:1428`) when the player
examines a deployed furniture. Under a backend session that opts in, the `query_popup::query_once()`
`test_mode` abort (`src/popup.cpp:277`) is bypassed **for exactly that one query_yn**, so its real
`input_context("YESNO")::handle_input` loop runs headlessly and the backend drives its selection at level 4.

> **Equivalence level proved: 4.** The chosen answer (YES/NO) is produced solely by registered `YESNO`
> actions (`LEFT`/`CONFIRM`) consumed by the **real** `query_popup` loop through
> `input_context::handle_input()`, which sets `result.action`. Arcopolis never sets `result.action` or the
> popup's cursor as a substitute for input. Proven at runtime (Gate Y2 below).

## Target witness (and why it, not the move→water alternative)

A live `examine direction=move_e` on `ArcopolisDeployedFurnitureTest` (a clone of `ArcopolisTest` with ONE
`f_floor_mattress` placed on the clean floor tile one EAST of the avatar). `game::examine` dispatches to
`iexamine::deployed_furniture`, whose **first and only** prompt is `query_yn("Take down the %s?")`.

- **YES** → `take_down_deployed_furniture` (`src/map_utils.cpp:33-42`) removes the furniture (→ `f_null`) and
  drops a real `mattress` item — proven side-effect-only by `tests/deployed_furniture_test.cpp` (no debugmsg,
  exactly one item dropped, no prompts). The examine "pickup tail" (`game::examine` → `pickup::pick_up(p,0)`)
  then opens the old `"PICKUP"` menu for the dropped mattress, which the existing Spike-11A nested-input
  guard auto-cancels (witnessed by `examine_regression.ps1`), so the mattress stays on the ground.
- **NO** → the function returns; nothing changes. The avatar never moves.

The alternative `query_yn("Dive into the water?")` (`src/avatar_action.cpp:396`, reached by `move` into deep
water) was **rejected**: its YES path runs `avatar_action::swim`, which can hit `popup()` / "You sink like a
rock!" (`src/avatar_action.cpp:602-612`) depending on avatar load — non-deterministic — and
`avatar_action::move` holds other `query_yn` calls (`:306`, `:359`). The furniture take-down is test-proven
clean for **both** YES and NO and needs only a one-line furniture-append fixture.

## Source audit (read at the implementing line, current tree)

```
game::examine(p)                                 src/game.cpp (dispatches the furniture examine action; no query_popup of its own)
  -> iexamine::deployed_furniture                src/iexamine.cpp:1418
       query_popup_witness_guard guard(...)      src/iexamine.cpp:1427 (NEW: arms the witness transaction)
       query_yn("Take down the %s?")             src/iexamine.cpp:1428 (the witnessed query_popup)
       YES -> take_down_deployed_furniture        src/map_utils.cpp:33-42 (furniture -> f_null, drops mattress; NO prompts)
query_yn(text)                                   src/output.cpp:708
  builds query_popup .context("YESNO")           src/output.cpp:716  (category "YESNO")
        .option("YES").option("NO").cursor(1)    src/output.cpp:720-722 (options 0=YES / 1=NO; cursor starts on NO=1)
  Spike 15 drive-block (gated)                    src/output.cpp:731-740 (resolve from the REAL options + cursor)
  return pop.query().action == "YES"             src/output.cpp:742
query_popup::query_once()                        src/popup.cpp:264
  test_mode abort (gated !mode_active)            src/popup.cpp:277-279 (NEW gate)
  create_or_get_adaptor(); ui_manager::redraw()   src/popup.cpp:281-283 (redraw is a test_mode no-op)
  input_context ctxt(category)                    src/popup.cpp:285 (category "YESNO")
  register LEFT/RIGHT/CONFIRM + option actions    src/popup.cpp:290-295 (QUIT only if cancelable -> query_yn: none)
  do { res.action = ctxt.handle_input(); ... }    src/popup.cpp:309-317 (default timeout=-1)
  LEFT -> --cur ; RIGHT -> ++cur                  src/popup.cpp:321-332 (horizontal button row)
  CONFIRM -> res.action = options[cur].action     src/popup.cpp:333-337 (FILTER-FREE; sets the result)
seam: backend_nested_input_action(cat,regs,t)    src/input.cpp:943 (top of handle_input; hook short-circuits)
  "YESNO" serve branch                            src/arcopolis_backend_input.cpp:900 (NEW, mirrors the "UILIST" branch)
```

**The two `test_mode` jobs (doc 32):** `test_mode` both (1) suppresses render/keyboard — Arcopolis wants
this — and (2) aborts `query_popup::query_once` before the real loop runs — Arcopolis does not. Spike 15
drops only job (2), for exactly one query_yn.

**Renderer neutrality is automatic — NO window, and NO special setup path needed (the key difference from
`uilist`).** `query()`/`query_once()` create a `ui_adaptor` and call `ui_manager::redraw()`, but
`mark_resize()` (`src/ui_manager.cpp:199-202`) only sets `deferred_resize`, and `redraw_invalidated()`
(`src/ui_manager.cpp:325-330`) **early-returns under `test_mode` before** the deferred-resize loop (which
would call `screen_resized_cb` → `init()` → `catacurses::newwin`) **and before** the redraw loop (`show()`).
So the un-aborted path creates **no curses window and calls no render primitive in any build**. Unlike a
`uilist` (whose `fentries`/`vmax` are populated only by the suppressed callbacks, forcing Spike 13B to call
`setup()` directly), a `query_popup`'s selection state (`options`, `cur`) is populated by the **builder
methods before `query()`** — so query_once needs no callback-driven setup, and never dereferences `win` on
the YES/NO path. Verified at runtime: the unit test "backend-driven query_popup runs query() headless with NO
window" drives a real `query()` through the seam and asserts `!popup.has_window()`. `ime_sentry`
(`src/popup.cpp:358`, constructed unconditionally even today) is headless-safe: `getWindowHandle()`
(`src/sdltiles.cpp:4274`) returns a null HWND when `::window` is null and the IMM calls tolerate it.

## Witness-scoping — the un-abort is per-prompt, never command/session-wide

A command-scoped arming ("drive any query_yn during a live examine") would silently turn this into **generic
query_yn support** — examine can reach other query_yn calls (e.g. a second `query_yn("Take down the %s?")` at
`src/iexamine.cpp:1489` in another function, and `iexamine.cpp`'s "Slip through the %s?") the spike never
audited. So, exactly as the `uilist` spikes keyed the un-abort on a per-prompt transaction (not
`backend_session_active()`), Spike 15 uses **three nested scopes, the innermost being the discriminator**:

| Scope                                                                                                 | What                          | Armed by                                                                                                                                                                                                                                                       | Cleared by                                   |
| ----------------------------------------------------------------------------------------------------- | ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| **command precondition** `examine_query_popup_command`                                                | a live `examine` is in flight | `backend_arm_examine_query_popup_command` (`src/arcopolis_live.cpp:247`, at examine dispatch)                                                                                                                                                                  | the seam return (`clear_stale_nested_input`) |
| **witness guard (discriminator)** `query_popup_witness_guard("examine_deployed_furniture_take_down")` | THIS one audited call site    | its ctor (`src/iexamine.cpp:1427`) → `backend_begin_query_popup_transaction`, which arms only when BOTH `backend_examine_query_popup_command_active()` AND `backend_query_popup_prompt_available()` hold (an armed live examine + a registered answer channel) | its dtor                                     |
| **per-prompt gate** `query_popup_transaction`                                                         | the un-abort itself           | the guard's ctor (via `backend_begin_query_popup_transaction`, `src/arcopolis_backend_input.cpp:705`)                                                                                                                                                          | the guard's dtor / `clear_stale`             |

`backend_query_popup_mode_active()` (`src/arcopolis_backend_input.cpp:679`) = `session.active &&
session.query_popup_transaction` is the **only** gate the `popup.cpp` un-abort and the `query_yn` drive-block
key off. Because the witness guard exists at **exactly one call site**, no other query_yn is ever un-aborted.
Pinned by a unit test (command precondition armed but no witness guard → gate stays false → query_yn aborts).

## Action mapping (CONFIRM-on-cursor — filter-free, robust)

The client's single choice index `K` (0 = YES, 1 = NO) is translated into cursor navigation from the popup's
**real** `cursor_start` (1 for `query_yn`, read via `query_popup::current_index()`) to `K`, then `CONFIRM`:

- `K < start` → `[LEFT × (start − K), CONFIRM]`; `K > start` → `[RIGHT × (K − start), CONFIRM]`;
  `K == start` → `[CONFIRM]`.
- So **YES → `["LEFT", "CONFIRM"]`** (cursor NO→YES, then confirm) and **NO → `["CONFIRM"]`** (cursor already
  on NO). Both witnessed at runtime (Gates Y2 / N).

`CONFIRM` is chosen over serving the literal `"YES"`/`"NO"` option action because the `CONFIRM` branch
(`src/popup.cpp:333-337`) sets `res.action = options[cur].action` **without consulting the per-option key
filter** — robust under `FORCE_CAPITAL_YN` and independent of the synthetic input event the seam returns
(the direct-option branch consults `options[i].filter(res.evt)`). `LEFT`/`RIGHT`/`CONFIRM` are all registered
in the `"YESNO"` context (`src/popup.cpp:290-295`). This is a real player path (arrow + enter). The engine's
own `query_once` loop moves the cursor and sets the result; the backend never does.

## Cancel / EOF — query_yn is not cancelable, and that is not faked

`query_yn` registers **no `QUIT`** (`allow_cancel` is never set), so it cannot be cancelled. Spike 15 does
**not** invent a cancel:

- The prompt is emitted `cancelable:false`.
- A client `prompt_cancel` on it is **rejected** (`prompt_failed` reason `noncancelable`); the prompt stays
  OPEN and the client must answer YES or NO. (Gate R.)
- On **EOF / closed client** (the only way the live source returns `nullopt`), to avoid a headless hang the
  resolve serves `["CONFIRM"]` — confirming the popup's **pre-selected visible default** (the starting
  cursor, NO for query_yn). This is logged as a **closed** prompt (`prompt_cancelled` reason
  `noncancelable_closed`), **NOT** `prompt_answered`: the transcript never implies the client intentionally
  chose NO.

**The "EOF → empty-queue read → guard hard-fail (exit 12)" hypothesis is refuted, empirically (Gate E).** A
`CONFIRM` that drains the queue also sets `wait_input=false`, so `query()` exits without a second blocking
read; and headless the inner do-while (`src/popup.cpp:309-317`) cannot repeat — the seam-served event's type
is `error` (`input_event()`'s default), not mouse/keyboard-empty. Gate E closes stdin mid-prompt and asserts
the backend **exits 0** (not 12) with a clean `session_end`.

## Exact level-4 equivalence claim

```
same engine action          ACTION_EXAMINE via handle_action -> game::examine -> iexamine::deployed_furniture
same active input loop       input_context("YESNO")::handle_input() in query_popup::query_once (src/popup.cpp), UNMODIFIED
same registered actions      LEFT then CONFIRM (YES) or CONFIRM (NO) -- exactly a player's arrow+enter on the YES/NO buttons
same selection               done by the engine loop (LEFT/RIGHT -> cur; CONFIRM -> res.action = options[cur].action), NEVER by Arcopolis
same continuation            action=="YES" -> take_down_deployed_furniture (engine state change); "NO" -> nothing
ONLY difference              the answer's TRANSPORT: a JSON prompt + a single choice index, not a curses keypress
```

## Protocol shape (additive — reuses the Spike 13B prompt/answer wire, new `kind`)

Backend→client (mid-command), distinguished by `kind:"query_popup"` and `cancelable:false`:

```json
{"type":"prompt","id":<cmd-id>,"prompt_id":1,"kind":"query_popup","title":"Take down the mattress? (Case Sensitive)",
 "choices":[{"index":0,"text":"YES","enabled":true},{"index":1,"text":"NO","enabled":true}],
 "cancelable":false}
```

`title` carries the **same message a GUI player sees**, including the `" (Case Sensitive)"` suffix `query_yn`
appends when `FORCE_CAPITAL_YN` is set (its default; on in the fixture) — it is the popup's formatted message,
not the raw `query_yn` argument (Codex PR#43 P3).

**`choices[].text` contract (deliberate).** For `kind:"query_popup"`, `text` carries the option **action id**
(`YES`/`NO`), NOT the GUI's rendered label — an intentional divergence from the menu/uilist convention (where
`text` is the displayed entry label). Rationale: the option's identity is the **`index`** (0=YES, 1=NO), which
is what the client keys off, and a stable, locale-independent id is more useful to a renderer-neutral frontend
than the keyboard-entangled string a GUI player actually sees — `input_context::get_desc` (`src/popup.cpp` →
`src/input.cpp`) renders `query_yn`'s buttons as `"(Y)es"`/`"(N)o"` with the bound-key hint, an artifact
meaningless to a mouse-first frontend. The same id `text` appears in the `prompt_opened` transcript record.
(Codex PR#43 weighed sending the clean localized name `get_action_name` → "Yes"/"No" instead; deferred, since
`index` already encodes identity — revisit if the frontend is ever specified to display `choices[].text`
verbatim.)

Answer (client→backend, single-select, same parser as the uilist): `{"op":"prompt_answer","prompt_id":1,"choice":0}`
(0 = YES, 1 = NO). Wire behavior: a valid choice → `ok:true` ack then the command's terminal response;
invalid / out-of-range / multi-choice / wrong `prompt_id` / `prompt_cancel`-on-a-non-cancelable-prompt →
`ok:false`/`bad_request`, the prompt stays OPEN.

## Transcript shape (`session.jsonl`)

Reuses the existing `prompt_*` events with `kind:"query_popup"` (no new event kinds): `prompt_opened`
(kind=query_popup, the 2 real choices, plus `witness:"examine_deployed_furniture_take_down"` naming WHICH
audited call site armed it — Spike 15 adds this one `prompt_opened` field, omitted for menu/uilist records so
they stay byte-identical) · `prompt_answered` (kind=query_popup, `choices:[0]`,
`actions:["LEFT","CONFIRM"]`) · `prompt_completed` (kind=query_popup, `actions_served:2`). A rejected attempt
logs `prompt_failed` (reason `invalid_answer` / `prompt_id_mismatch` / `noncancelable`); a closed channel
logs `prompt_cancelled` (reason `noncancelable_closed`).

## Exact UI-mode / test_mode behavior

| Context                                                | `test_mode` | `backend_query_popup_mode_active()` | `query_popup::query_once()`                                                              |
| ------------------------------------------------------ | ----------- | ----------------------------------- | ---------------------------------------------------------------------------------------- |
| Normal GUI play                                        | false       | false                               | renders + real input (unchanged)                                                         |
| cata_test (no backend session)                         | true        | false                               | aborts → `{false,"ERROR",{}}` (unchanged)                                                |
| Backend session, examine command but no witness guard  | true        | false                               | aborts (e.g. a non-witnessed examine query_yn like "Slip through")                       |
| Backend session, the deployed-furniture query_yn armed | true        | **true**                            | runs the real `input_context("YESNO")` loop; served `LEFT`/`CONFIRM` set `result.action` |

## Source code

- `src/popup.cpp` / `src/popup.h` — the `query_once` test_mode abort is gated on
  `!arcopolis::backend_query_popup_mode_active()` (`:277`); two additive const accessors `current_index()`
  (`:369`, the real cursor, for the navigation) and `has_window()` (`:374`, the no-window test pin).
- `src/output.cpp` — `query_yn` (`:708`) refactored to a named `query_popup popup` + a gated drive-block
  (`:731-740`) that builds the request from the REAL options + cursor and calls
  `backend_resolve_query_popup_choice`. Behaviorally inert unless the witness guard armed a transaction.
- `src/iexamine.cpp` — one `query_popup_witness_guard` added to `deployed_furniture` (`:1427`, the sole
  discriminator).
- `src/arcopolis_backend_input.{h,cpp}` — the `backend_query_popup_request` struct, the
  `backend_query_popup_source` hook, the session flags, `backend_query_popup_mode_active` (`:679`) /
  `backend_examine_query_popup_command_active` / `backend_query_popup_prompt_available`,
  `backend_arm_examine_query_popup_command` (`:694`), `backend_begin/end_query_popup_transaction` (`:705`),
  the `query_popup_witness_guard` RAII type (`:812`), `backend_resolve_query_popup_choice` (`:727`), the
  `"YESNO"` serve branch (`:900`), and the seam-return clear.
- `src/arcopolis_live.{h,cpp}` — `live_query_popup_prompt` (`:431`; kind="query_popup", single-select,
  non-cancelable cancel-rejection, EOF→closed-default), wired as `opts.query_popup_source` (`:861`); the
  examine command arms the precondition (`:247`).
- `tests/arcopolis_backend_input_test.cpp` — the gate/witness-scoping pin, the channel-availability test, the
  YESNO queue-mapping test (YES/NO/closed), the full-drive + no-window test (runs the real `query()` loop
  through the seam and asserts `!popup.has_window()`), and the cata_test abort invariant.

## Regression witness

[`query_popup_regression.ps1`](query_popup_regression.ps1) (driver
[`prompt_menu_live_driver.py`](prompt_menu_live_driver.py), reused unchanged) on
`ArcopolisDeployedFurnitureTest` (built by [`make_furniture_fixture.py`](make_furniture_fixture.py)), with
`AUTOSELECT_SINGLE_VALID_TARGET=false` + `AUTO_PICKUP=false` pinned, run with `pwsh`. Six gates:

- **Y1 (accept probe):** the examine opens one `prompt` kind=query_popup, prompt_id 1, title EXACTLY "Take
  down the mattress? (Case Sensitive)" (the GUI player's formatted message; FORCE_CAPITAL_YN is on in the
  fixture), 2 choices [YES, NO] in order, both enabled, cancelable:false.
- **Y2 (level-4 transcript):** answering choice:0 (YES) served `[LEFT, CONFIRM]`; prompt_opened/answered/
  completed kind=query_popup, actions_served=2; no prompt_force_cancelled.
- **Y3 (state change, YES):** the east tile's furniture `f_floor_mattress` → gone, a `mattress` item dropped,
  "You take down the mattress." logged.
- **N (reject, NO):** choice:1 served `[CONFIRM]` (actions_served=1); furniture STAYS, no item, no message.
- **R (recovery + non-cancelable cancel):** out-of-range + wrong prompt_id + prompt_cancel each rejected
  ok:false with the prompt OPEN (prompt_failed invalid_answer + prompt_id_mismatch + noncancelable), then a
  valid answer completes the SAME examine.
- **E (EOF/closed):** the client closes stdin mid-prompt; the backend serves the visible default and exits
  CLEAN (backend exit 0, NOT hard-fail 12); transcript prompt_cancelled noncancelable_closed (NOT
  prompt_answered), no error event, session_end ok.

## Validation — PASS (2026-06-16, RelWithDebInfo + ccache, MSVC)

- **Build:** `cataclysm-bn-tiles` + `cata_test-tiles` linked clean in one `win-rel-deb` dir (only pre-existing
  MSVC `C4267`/`D9025` warnings). _Build note:_ the game target's post-build `deno task docs:gen` step
  **launches** the freshly-relinked exe and can be blocked by Windows Application Control (os error 4551),
  making `cmake --build` report exit 1 even though the exe linked and runs fine (the live regressions launch
  it directly without issue). _ccache note (reconfirmed gotcha):_ adding the `query_popup_source` field to
  the public `backend_session_options` struct made ccache serve a STALE object for the **un-edited** non-live
  callers (`arcopolis_script.cpp` `run_script`, `arcopolis_export.cpp` one-shot), whose old-layout struct
  crashed `begin_backend_session` with an access violation; live mode (edited `arcopolis_live.cpp`) was safe.
  Fixed by deleting the arcopolis objects and rebuilding with `CCACHE_RECACHE=1` so every TU shares the new
  layout — then the previously-crashing `movement_regression` passed.
- **`[arcopolis]` unit suite:** **778 assertions / 111 test cases pass** (the five new Spike 15 cases incl.
  the full-`query()`-drive no-window test).
- **[`query_popup_regression.ps1`](query_popup_regression.ps1):** all 6 gates exit 0 (`pwsh`).
- **No regression (all exit 0, `pwsh`, against the same final binary):** `examine_` (its pickup tail still
  ESC-cancels — the new examine query_popup arming is inert for non-furniture examines), `prompt_menu_` (all
  Spike 12A/13B/14 pickup + uilist gates), `movement_`, `live_protocol_`, `client_harness_`,
  `frontend_prototype_` (18 gates), `item_`/`monster_`/`npc_export_`.
- **Adversarial review** (4 design properties): witness-scoping, level-4 equivalence, and regression
  robustness all hold; the one flagged "blocker" (an EOF hard-fail) was a false positive — empirically
  refuted by Gate E (EOF exits 0).

> **Run the regressions with `pwsh` (PowerShell 7), not `powershell` (5.1)** — see the memory note: PS 5.1
> misreads BOM-less UTF-8 snapshots and writes a BOM into options.json, causing spurious gate failures.

## Remaining unsupported (named backlog)

- **Generic `query_popup`** and **every other `query_yn`** (e.g. "Slip through the %s?" at
  `src/iexamine.cpp:1409`, or the second deployed-furniture-style "Take down the %s?" at `:1489`): only the
  ONE deployed-furniture witness is driven; no broader query_yn support is claimed.
- **`popup()` / `popup_getkey()` family** (context `"POPUP_WAIT"`; `PF_GET_KEY` registers `ANY_INPUT`, not a
  normal option/cancel shape — a distinct hazard, doc 32): not driven.
- **Cancelable query_popups** (a `query_popup` with `allow_cancel`, registering `QUIT`): the witness is
  `query_yn`, which is not cancelable; a cancelable shape is a separate, narrow follow-up.
- **The rejected move→deep-water `query_yn`** candidate (swim-popup side effects).
- **Non-live prompt-answer support** (`--arcopolis-run-script`, one-shot): no answer channel, so the witness
  guard never arms and the query_yn aborts (NO) — examine stays usable, just undriven there. **Superseded for
  `--arcopolis-run-script` (Spike 16, [36_SPIKE16_SCRIPT_PROMPT_ANSWERS.md](36_SPIKE16_SCRIPT_PROMPT_ANSWERS.md)):**
  a scripted `examine` step may declare a `{ "kind":"query_popup", ... }` answer, which the script query_popup
  source feeds into this spike's `backend_resolve_query_popup_choice` — so the deployed-furniture take-down
  query_yn is now driven at level 4 in run-script too (a furniture examine with no declared answer fails loud,
  `script_prompt_failed`/exit 13). One-shot `--arcopolis-command` still has no channel.
- `inventory_selector`, `string_input`, computer UI, NPC dialogue, ranged `TARGET`, per-unit quantities, and
  pipes as a robust boundary — all still backlog (doc 32's audit).

## Why this still satisfies GUI behavior == engine behavior == backend input behavior

The backend exposes a JSON prompt instead of the curses YES/NO popup (a different external frontend UX, which
AGENTS.md allows), but what reaches the engine is the player's **registered** `LEFT`/`CONFIRM` actions,
consumed in order by the **same** `input_context("YESNO")::handle_input` loop a player drives, which sets
`result.action` itself. The backend never sets the result, the cursor, or any menu/world state as a
substitute for input; `take_down_deployed_furniture` (or the NO no-op) is the engine's own outcome. Where the
backend cannot faithfully drive (a non-cancelable cancel, a non-witnessed query_yn, non-live mode), it fails
loud / rejects / aborts — never a silent success.

## Claim → cite → verdict audit

Per [[cite-the-implementing-line]] — each load-bearing claim, the verification TYPE, and the evidence:

| Load-bearing claim                                                                                         | Cite / evidence                                                                              | Type                              | Verdict |
| ---------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | --------------------------------- | ------- |
| `query_popup::query_once` aborts under test_mode before its `input_context`                                | `src/popup.cpp:277-279` vs `:285`/`:309`                                                     | structural (read)                 | ✅      |
| `query_yn` uses `input_context("YESNO")`, options YES/NO, cursor 1 (NO), not cancelable                    | `src/output.cpp:714-724`                                                                     | structural (read)                 | ✅      |
| `CONFIRM` sets `res.action = options[cur].action` filter-free; the direct-option branch consults a filter  | `src/popup.cpp:333-337` vs `:338-346`                                                        | structural (read)                 | ✅      |
| `redraw_invalidated` early-returns under test_mode BEFORE the resize/redraw callbacks (no `newwin`/`show`) | `src/ui_manager.cpp:325-330, 360-388, 390-430`                                               | structural (read)                 | ✅      |
| the un-aborted query_popup creates NO curses window (renderer-neutral)                                     | unit test: full-`query()` drive asserts `!popup.has_window()`                                | behavioral (test)                 | ✅      |
| served `LEFT`/`CONFIRM` reach the real `input_context("YESNO")` loop and set `result.action`               | Gate Y2 (`actions:["LEFT","CONFIRM"]`, level-4) + unit drive                                 | behavioral (run)                  | ✅      |
| the witnessed continuation (YES) is the engine's own `take_down_deployed_furniture`                        | Gate Y3 (furniture→f_null, mattress dropped, engine message)                                 | behavioral (run)                  | ✅      |
| witness-scoping: only the guarded call site is driven; the command precondition alone does not arm         | unit test (precondition armed, no guard → gate false)                                        | behavioral (test)                 | ✅      |
| `query_yn` is not cancelable; cancel is rejected, EOF is marked closed (not an answer), no hang/exit-12    | Gate R (reject) + Gate E (EOF exits 0, `noncancelable_closed`)                               | behavioral (run)                  | ✅      |
| cata_test query_popup still aborts (no backend session)                                                    | unit test (`query_yn` returns false, no input loop)                                          | behavioral (test)                 | ✅      |
| `iexamine::deployed_furniture`'s query_yn is the first/only prompt; `take_down` is prompt-free             | `src/iexamine.cpp:1418-1433`; `src/map_utils.cpp:33-42`; `tests/deployed_furniture_test.cpp` | structural+behavioral (read+test) | ✅      |
| `f_floor_mattress` has `examine_action:"deployed_furniture"` + `deployed_item:"mattress"`                  | `data/json/furniture_and_terrain/furniture-sleep.json:128-140`                               | structural (read)                 | ✅      |
