# Arcopolis Spike 19 — renderer-neutral backend UI boundary cleanup (rename + regroup + doc)

**Status: bounded refactor + decision record (2026-06-18). NO behavior change — comments, names, struct
grouping, and docs only.** No new gameplay, no `NEW_PICKUP_MENU=true` support, no `INVENTORY` /
`inventory_selector` serve branch, no wire/transcript/exit-code change, no new curses window or render
primitive. This spike makes the existing backend UI / prompt boundary **legible** so future work cannot
accidentally treat the narrow witnessed PICKUP / UILIST / YESNO paths as a generic renderer-neutral UI mode.

> **Equivalence level proved by this spike: NONE changed.** The witnessed level-4 paths stay exactly level-4
> (backend-input + engine); the unsupported paths stay fail-loud. This is a clarity/refactor spike, not a
> capability spike. Terminology (backend-input vs engine vs frontend equivalence) is the three senses pinned
> in [37_SPIKE17_CLAIM_AUDIT.md](37_SPIKE17_CLAIM_AUDIT.md) §Terminology and `AGENTS.md:83-120`.

> **Citations.** Line numbers are current-tree at write time and drift as the gated call sites move (the
> recurring reason the audits exist); **confirm by symbol name**, prefer the symbol over the number when they
> disagree.

## 1. Why refactor now, after Spike 18

Spike 18 ([39_SPIKE18_NEW_PICKUP_MENU_AUDIT.md](39_SPIKE18_NEW_PICKUP_MENU_AUDIT.md)) audited
`NEW_PICKUP_MENU=true` / `inventory_selector` and **stopped at audit**, with the headline finding that a
`test_mode` **un-abort witness** (Spikes 13B/14/15) is **NOT** a renderer-neutral backend UI mode (§5.1).

But the code still carried the exact name that **embodied that false equivalence**: the UILIST un-abort gate
was `backend_ui_mode_active()` even though its body is literally `session.active && session.uilist.armed` — a
UILIST-only, per-transaction flag. A reader scanning `src/ui.cpp`'s `if( test_mode &&
!arcopolis::backend_ui_mode_active() )` could reasonably conclude a generic "backend UI mode" exists. It does
not. Its sibling `backend_query_popup_mode_active()` carried the same misleading `_mode_active` suffix. And the
per-transaction state was a **flat scattering of `<class>_transaction` / `<class>_queue` / `<class>_cursor`
booleans** on one struct, so the family structure was implicit.

Per [37_SPIKE17_CLAIM_AUDIT.md](37_SPIKE17_CLAIM_AUDIT.md) ("make the project more honest, not more
impressive") and the doc-39 distinction, this spike fixes the names and surfaces the structure **before** any
further prompt-class work, so the next reader starts from an honest baseline.

## 2. `test_mode` un-abort witness ≠ renderer-neutral backend UI mode

The backend drives a **small, fixed set of WITNESSED prompt paths** headlessly at **level 4**: BN's real
`input_context`/menu/query loop consumes backend-served **registered actions**, and the **real engine caller**
consumes the result (the backend never sets the retval — the uilist loop sets `amenu.ret`, `query_once` sets
`res.action`; doc 38). Each is a **per-transaction un-abort** at one or a small number of **hardcoded call
sites** (PICKUP: one — the old "PICKUP" menu; UILIST: **two** — the vehicle-source submenu (13B) + the
secondary capacity/wield/spill uilist (14), both reusing the same UILIST machinery under the same
`backend_uilist_transaction_active()` gate; QUERY_POPUP: one — the deployed-furniture take-down query_yn), where
the data is already populated window-free.

That is **not** a renderer-neutral backend UI **mode**. doc 39 §5.1 names the gap precisely on
`inventory_selector`: there is no single narrow `test_mode` abort to pierce (its suppression is the **global**
`ui_adaptor::redraw_invalidated` early-return, `src/ui_manager.cpp`), its window creation is **entangled** with
the renderer-neutral layout pass and **ungated** (`src/inventory_ui.cpp`, incl. the `TOGGLE_FAVORITE`
`prepare_layout()` reachable outside the redraw suppression), there are no headless dimensions, and it carries
three direct-mutation side channels. A faithful witness would be the **start of a renderer-neutral selector
architecture**, not "one more prompt path." Generalization here is by **reuse of the seam at new hardcoded
sites**, never by a general UI abstraction (doc 38).

This spike encodes that distinction in the code: the gate names now say **`*_transaction_active`** (per
witnessed transaction), there is a central boundary block at the top of
[src/arcopolis_backend_input.h](../../src/arcopolis_backend_input.h), and the served categories are grouped so
the witnessed set is visible in one place.

## 3. Currently served / witnessed prompt families (the structure)

Each family has its **own** per-transaction gate, serve branch, resolve function, and RAII guard — grouped (as
of this spike) under a named `prompt_transaction` member of the TU-local `backend_session`
(`src/arcopolis_backend_input.cpp`), so the family state is no longer a flat scatter of booleans.

| Family                                 | Category          | Gate predicate                                                             | Witness scope                                                                                                                              | Engine site (current tree)                                                                                                   |
| -------------------------------------- | ----------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| One-shot nested direction answer (11A) | `"DEFAULTMODE"`   | armed `nested` slot + `decide_nested_input`                                | examine/pickup "where?" chooser                                                                                                            | `input_context::handle_input` hook, `src/input.cpp` (~`:941-947`)                                                            |
| **PICKUP** menu (12A)                  | `"PICKUP"`        | `backend_pickup_transaction_active()` = `active && pickup.armed`           | the **OLD** pickup item menu, **not** generic pickup UI                                                                                    | gated pre-loop block, `src/pickup.cpp` (~`:761`)                                                                             |
| **UILIST** (13B/14)                    | `"UILIST"`        | `backend_uilist_transaction_active()` = `active && uilist.armed`           | **two** witnessed sites (vehicle-source submenu; secondary capacity/wield/spill), all-enabled only, **not** generic uilist                 | `uilist::init`/`query`/`setup` gate, `src/ui.cpp` (`:159`/`:638`/`:933`/`:957`); drives `src/pickup.cpp` (~`:215`, ~`:1378`) |
| **QUERY_POPUP** (15)                   | `"YESNO"`         | `backend_query_popup_transaction_active()` = `active && query_popup.armed` | **one** witnessed `query_yn` (deployed-furniture take-down), **not** generic query_popup/query_yn                                          | `query_once` gate `src/popup.cpp:277`; `query_yn` drive-block `src/output.cpp:735`; witness guard `src/iexamine.cpp:1427`    |
| Script replay of the above (16)        | (same categories) | (same gates)                                                               | the SAME `backend_resolve_*` machinery; only the answer **transport** differs (declared field vs stdin line) — "level-4-replayed" (doc 38) | `run_script` installs `script_*_prompt`, `src/arcopolis_script.cpp`                                                          |

All five create **no curses window and call no render primitive in any build** — pinned by the no-window unit
assertions (`tests/arcopolis_backend_input_test.cpp`: `!menu.window`, `!popup.has_window()`).

## 4. What stays unsupported / fail-loud (must remain)

- **`NEW_PICKUP_MENU=true` / `inventory_selector`** — rejected at Arcopolis **pre-flight**, not at a selector
  abort: live `src/arcopolis_live.cpp:213-218` (`unsupported_command`, exit 6) and run-script
  `src/arcopolis_script.cpp:357-365` (exit 6). Load-bearing: without it the path reaches the selector, the
  unserved `"INVENTORY"` read is cancelled, `execute()` returns empty, and `game::pickup` assigns an **empty**
  activity — a silent no-op pickup, exit 0 (doc 39 §10). **`"INVENTORY"` is deliberately NOT a served
  category** (`backend_nested_input_action` serves only `PICKUP`/`UILIST`/`YESNO`).
- **Generic `uilist`** (cata_test, computer, NPC dialogue, monster menus) — `test_mode` abort → `UILIST_ERROR`
  (`src/ui.cpp:933`, gated on `backend_uilist_transaction_active()`).
- **Generic `query_yn` / `query_popup`** — exactly one site arms a transaction (`src/iexamine.cpp:1427`);
  every other `query_yn` aborts to NO. **One documented silent prompt-default** (not a fabricated success): an
  unguarded `query_yn` reachable through the supported `examine` verb defaults to NO, unmarked, exit 0
  (`src/popup.cpp:277-279` → `src/output.cpp:748`; doc 38). Unchanged here.

## 5. Invariant for adding a NEW served category (do not violate)

Mirrors the block now at the top of the `arcopolis` namespace in
[src/arcopolis_backend_input.h](../../src/arcopolis_backend_input.h). A new category may be served **only** when
ALL hold; otherwise it stays fail-loud:

1. a **real** BN `input_context`/menu/query loop (no parallel or mock loop);
2. **real registered actions** served through it (never a forced retval / direct result injection);
3. the **real engine caller** consumes the result and mutates real state;
4. **no curses window and no render primitive**, in any build (`AGENTS.md` no-window invariant);
5. its **own per-transaction** begin/resolve/end (+ RAII guard) and gate predicate — **never** a widened
   session-wide flag;
6. **no equivalence claim from final state alone** — the witness is scoped to its proven shape.

## 6. What was renamed / regrouped / centralized (no behavior change)

**Gate rename (pure token substitution; bodies byte-identical):**

| Old (≤ Spike 18)                               | New (Spike 19)                                        | Body (unchanged)                              |
| ---------------------------------------------- | ----------------------------------------------------- | --------------------------------------------- |
| `arcopolis::backend_ui_mode_active()`          | `arcopolis::backend_uilist_transaction_active()`      | `session.active && session.uilist.armed`      |
| `arcopolis::backend_query_popup_mode_active()` | `arcopolis::backend_query_popup_transaction_active()` | `session.active && session.query_popup.armed` |

The three un-abort gates are now a parallel, self-describing family —
`backend_pickup_transaction_active()` / `backend_uilist_transaction_active()` /
`backend_query_popup_transaction_active()` — and the misleading "mode" word is gone. Call sites updated in
`src/ui.cpp`, `src/popup.cpp`, `src/output.cpp`, comment refs in `src/pickup.cpp`, the unit tests (incl. two
`TEST_CASE` titles), `AGENTS.md`, and `ARCOPOLIS_STATE.md`. The dated historical docs `32_`–`38_` keep their
as-written references (supersession discipline); this table is the old→new map.

**State regrouped (TU-local `backend_session`, `src/arcopolis_backend_input.cpp`):** the three queue-based
families' previously-flat booleans (`<class>_transaction` / `<class>_opened` / `<class>_step_index` /
`<class>_queue` / `<class>_cursor` / `<class>_served`) are grouped under a shared **state-only**
`prompt_transaction` struct, held as named members `pickup` / `uilist` / `query_popup`. `prompt_transaction`
has **no methods** and does **not** genericize behavior — each family keeps its own distinct serve branch,
resolve function, gate, and RAII guard. The one-shot nested answer keeps its own `nested_input_slot` type; the
class-specific extras (`prompt_source`, `pickup_outcome`, `uilist_prompt_source`, `query_popup_source`,
`query_popup_witness`, `examine_query_popup_command`) stay as named fields on the owning family.

**Central documentation added:**

- a **backend UI / prompt boundary** block at the top of `namespace arcopolis` in
  `src/arcopolis_backend_input.h` (served categories + the deliberate `INVENTORY` non-support + the §5
  invariant);
- a one-line **back-reference** at the serve-branch cluster in `backend_nested_input_action`
  (`src/arcopolis_backend_input.cpp`) pointing to that block;
- two loose `src/ui.cpp` comments ("in backend UI mode") tightened to "while a backend uilist transaction is
  armed";
- `ARCOPOLIS_STATE.md` gains a Spike 19 capability row + pointers to this doc from the Terminology and
  Backend-UI-mode-backlog sections.

**Prior cleanup built on, not redone:** the `clear_stale_nested_input()` → four per-concern helpers +
`clear_stale_backend_prompt_state()` wrapper split landed in **Spike 18 / PR #46** (doc 39 §15.3). This spike
keeps that structure and only regroups the underlying state.

## 7. What behavior intentionally did NOT change

- Wire/protocol (the JSONL request/response shapes, `prompt`/`prompt_answer`, `kind` strings) — identical.
- Transcript events + ordering (`prompt_opened`/`answered`/`cancelled`/`failed`/`completed`,
  `nested_input_*`, `prompt_force_cancelled`) — identical.
- Exit codes — `unsupported_command` 6, `nested_input_failed` 12, `script_prompt_failed` 13 — identical.
- Gate **semantics** — each predicate returns the same `bool` for the same state; only the spelling changed.
- Fail-loud boundary — `NEW_PICKUP_MENU=true`, disabled-entry uilist, no-channel, orphaned secondary, scripted
  answer mismatches — all unchanged.
- The no-window invariant — no new window/render call introduced.

## 8. Validation

_Recorded after the build (PowerShell only); see the session summary for the run log._

- Scope grep: the live surfaces (`src/*.cpp`, `src/*.h`, `tests/*.cpp`, `AGENTS.md`,
  `ARCOPOLIS_STATE.md`) carry **zero** `backend_ui_mode_active` / `backend_query_popup_mode_active`
  occurrences; the only survivors are the dated `32_`–`38_` historical records and this doc's §6 map.
- `AStyle --options=.astylerc -n` on every touched `.cpp`/`.h` (CI-formatted; only the edited lines changed).
- Build `cataclysm-bn-tiles` + `cata_test-tiles` (expect zero errors — the rename's whole risk is a missed
  call site; the struct regroup's risk is a missed field access) and run `"[arcopolis]"` (expect the suite
  green: behavior is unchanged).
- Confirmatory: `prompt_menu_regression.ps1`, `query_popup_regression.ps1`, `script_prompt_regression.ps1`
  (run with `pwsh`) — behavior unchanged, so identical passes; if the build cannot run (disk/Smart App
  Control), the summary states exactly what compiled.

## 9. Claim → cite → verdict

Per [[cite-the-implementing-line]]. Static/structural claims verified at the implementing line this session;
the behavior-preservation claims rest on the unchanged statements + the build/test pass (§8).

| Claim                                                                                                 | Cite                                                                           | Type               | Verdict                 |
| ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ------------------ | ----------------------- |
| `backend_uilist_transaction_active()` body is `active && uilist.armed` (UILIST-only, per-transaction) | `src/arcopolis_backend_input.cpp` `backend_uilist_transaction_active`          | structural         | ✅ verified             |
| `backend_query_popup_transaction_active()` body is `active && query_popup.armed`                      | `src/arcopolis_backend_input.cpp` `backend_query_popup_transaction_active`     | structural         | ✅ verified             |
| Rename is a pure token substitution (no overloads/macros/string-literal symbol uses/ABI)              | grep both tokens across `src/`,`tests/`                                        | behavioral/absence | ✅ verified             |
| `INVENTORY` is NOT a served category; `backend_nested_input_action` serves only PICKUP/UILIST/YESNO   | `src/arcopolis_backend_input.cpp` serve branches                               | behavioral         | ✅ verified             |
| `NEW_PICKUP_MENU=true` stays fail-loud at pre-flight (exit 6), live + script                          | `src/arcopolis_live.cpp:213-218`; `src/arcopolis_script.cpp:357-365`           | behavioral         | ✅ verified (untouched) |
| `prompt_transaction` is state-only (no methods); each family keeps a distinct serve/resolve/gate      | `src/arcopolis_backend_input.cpp` `struct prompt_transaction` + serve branches | structural         | ✅ verified             |
| `begin_backend_session` designated initializers remain in declaration order (valid C++20)             | `src/arcopolis_backend_input.cpp` `begin_backend_session`                      | structural         | ✅ verified             |
| No new curses window / render primitive on the backend path                                           | no new `newwin`/draw call added; no-window unit asserts unchanged              | absence            | ✅ verified (static)    |
| Wire/transcript/exit codes unchanged                                                                  | no edit to formatters / `session_log_*` / `exit_code_for`                      | absence            | ✅ verified (static)    |
| `[arcopolis]` suite passes; game + tests compile                                                      | §8 build run                                                                   | behavioral         | ⏳ see §8 / summary     |

**Residual uncertainties (kept):** (1) behavior-preservation of the rename + struct regroup is argued from
unchanged statements + the build/`[arcopolis]` pass — it is not a separate runtime differential vs the
pre-spike binary; (2) the confirmatory regression scripts re-prove no runtime change only if a usable
exe + fixtures are available; if the build is blocked (disk / Smart App Control), the summary says so and what
did compile; (3) line numbers in this doc are current-tree and drift — confirm by symbol.
