# Arcopolis Spike 20 — fail-loud for unexpected player-visible prompts (query_popup/query_yn)

**Status: narrow fail-loud implementation (2026-06-19).** Closes one documented honesty hole: during an
active Arcopolis session, an UNARMED player-visible `query_popup`/`query_yn` reached under `test_mode` no
longer silently defaults to NO/CANCEL — it fails loud. NO new prompt support, NO new served category, NO
`NEW_PICKUP_MENU=true` / `inventory_selector` support, NO curses window or render primitive. The `uilist`
family is **audited, not changed** (§6) — guarding it would have changed the witnessed `blocked_no_op`
baseline and is deferred to a follow-up.

> **Equivalence level proved: NONE changed.** This is an architecture/honesty spike, not a capability spike.
> The witnessed level-4 paths (PICKUP / UILIST / query_popup) stay exactly level 4; this spike only converts a
> SILENT prompt-default into a LOUD failure for the unarmed query_popup family. Terminology (backend-input vs
> engine vs frontend equivalence) is the three senses in [37_SPIKE17_CLAIM_AUDIT.md](37_SPIKE17_CLAIM_AUDIT.md)
> §Terminology and `AGENTS.md:83-120`.

> **Citations** are current-tree at write time and drift; **confirm by symbol name**.

## 1. Problem statement

The fail-loud boundary was leaf-comprehensive against silent _fake success_, but NOT against "no silent prompt
at all" ([38_LEVEL4_TRUTH_AUDIT.md](38_LEVEL4_TRUTH_AUDIT.md) §"No silent path is refuted";
[40_SPIKE19_BACKEND_UI_BOUNDARY.md](40_SPIKE19_BACKEND_UI_BOUNDARY.md) §4): an unguarded `query_yn` reachable
through the supported `examine` verb hit `query_popup::query_once`'s `test_mode` abort
(`src/popup.cpp`, returns `{false,"ERROR",{}}`) → `query_yn` mapped that to a **silent NO, unmarked, exit 0**
(`src/output.cpp`). A decision a player would be asked was silently answered NO with no transcript mark and no
nonzero exit — a **hidden lost interaction** that can make an unsupported path look equivalent. That is worse
than failing loud.

Spike 20's rule: during an active backend command/script/live step, if BN reaches a player-visible
prompt/query Arcopolis has NOT armed as a witnessed transaction, **fail loud** instead of silently defaulting.

## 2. What is guarded in this spike (the query_popup/query_yn family — one chokepoint)

`query_popup::query_once` is the single chokepoint for `query_yn`, `popup()`, `popup_getkey`, and `PF_GET_KEY`
(all funnel through it). At its existing `test_mode` abort
(`src/popup.cpp` `query_popup::query_once`, the `if( test_mode && !arcopolis::backend_query_popup_transaction_active() )`
branch) the spike adds, **before** returning the safe default:

```cpp
arcopolis::backend_report_unexpected_prompt( "query_popup", "query_once" );
return { false, "ERROR", {} };
```

`backend_report_unexpected_prompt` (`src/arcopolis_backend_input.cpp`) is **inert outside a session**, so
cata_test and normal play keep the plain abort. Inside a session, with no `query_popup` transaction armed, it
records a fail-loud `unexpected_prompt`. The safe default (`{false,"ERROR",{}}` → `query_yn` returns NO) is
still returned as a **transport fallback** so nothing hangs; the command runner turns the recorded state into
the failure — the fallback is never treated as success.

## 3. The runtime fail-loud channel (smallest explicit one)

A **new** error kind and a **separate** generic helper, reusing the existing `session.failure` storage +
transcript plumbing (NOT the script-named `record_script_prompt_failure`, which would mislabel a live/one-shot
prompt as a "script" failure):

- `command_error_kind::unexpected_prompt` → exit code **14** (`src/arcopolis_command.h`,
  `src/arcopolis_command.cpp` `exit_code_for`). Distinct from `unsupported_command` (6, pre-flight) and
  `script_prompt_failed` (13, scripted-answer mismatch).
- `arcopolis::backend_report_unexpected_prompt( family, site )` — **no `step_index` parameter**: generic UI code
  (`popup.cpp`) must not know Arcopolis script internals; the current command's step index is inferred
  internally (the examine/query_popup step, else the script step, else absent) for transcript correlation.
  First-report-wins.
  - **NON-LIVE** (script / one-shot — `!session.live_source`): sets `session.failure`
    (kind `unexpected_prompt`) + `session.done`, and logs a transcript `error` event. Surfaced as exit 14.
  - **LIVE** (`session.live_source` set): sets a RECOVERABLE `session.unexpected_prompt_pending`
    (does NOT set `failure`/`done`), and logs a transcript `prompt_failed` event (the recoverable marker — an
    `error` event in the live transcript means the session FAILED, which this does not).
- `arcopolis::backend_take_unexpected_prompt_error()` — returns + clears the pending error (live runner).

Mode surfacing:

- **one-shot/export** (`src/arcopolis_export.cpp`): checks `backend_session_failure()` **immediately after
  `g->do_turn()` and BEFORE the success snapshot** is written — a hidden lost interaction never produces
  success-looking output. (One-shot arms no transaction, so e.g. an `examine` of deployed furniture fails loud
  here rather than silently answering NO.)
- **run-script** (`src/arcopolis_script.cpp`): no new code — the existing post-loop `backend_session_failure()`
  check surfaces exit 14, and `session.done` stops the steps walk.
- **live** (`src/arcopolis_live.cpp` `live_next_action` block (a)): after the per-request `do_turn`, calls
  `backend_take_unexpected_prompt_error()`; if present, sends a **visibly-failed** `ok=false` /
  `unexpected_prompt` response (new `live_error_code::unexpected_prompt`) for that request and keeps serving —
  the command is NOT reported successful and the transcript marks it failed, but the session stays open
  (recoverable, because `query_once`'s fallback was a safe cancel/default the engine already handled).
- **In-repo live consumer** (`tools/arcopolis_frontend/prototype_server.py`): because the live protocol's
  recoverable-error set gained `unexpected_prompt`, the prototype bridge adds it to `RECOVERABLE_ERROR_CODES`.
  Without that, `_op_backend_step` would treat the `ok=false`/`unexpected_prompt` as **fatal** — `reap()` the
  backend and block waiting for an exit it deliberately does NOT make — falsely killing a still-serving session,
  contradicting the recoverable contract above. (The Spike 9A client harness `tools/arcopolis_client/harness.py`
  needs no change: it keeps no recoverable set, and its scripted live commands — wait/move + the `move_up`
  negative probe — never reach an unarmed prompt.)

## 4. Why this adds no prompt support

Nothing new is driven, exposed, or answered. No served category is added (`backend_nested_input_action` still
serves only `PICKUP`/`UILIST`/`YESNO`); no `query_popup` transaction is armed by this spike. The change is
purely **detection**: an unarmed prompt that previously defaulted silently now records a typed failure. The
engine still proceeds down its own NO/CANCEL branch (no state is faked, nothing is mutated) — the spike just
makes that silent default **observable and fatal/visible** instead of hidden.

## 5. How it preserves witnessed transactions and non-Arcopolis behavior

- **Witnessed query_popup (Spike 15):** the deployed-furniture take-down arms its per-prompt transaction, so
  `backend_query_popup_transaction_active()` is true and `query_once` does NOT abort — `backend_report_unexpected_prompt`
  is never called. Unit-pinned: the armed `query()` witness asserts `backend_session_failure()` stays empty
  (`tests/arcopolis_backend_input_test.cpp`).
- **Witnessed PICKUP (12A) / UILIST (13B/14):** untouched — they use `input_context("PICKUP")` / `uilist::query`,
  not `query_once`. Their gates and serve branches are unchanged.
- **Non-Arcopolis test_mode (cata_test / normal play):** `backend_report_unexpected_prompt` is inert when
  `!session.active`, so `query_once` returns its usual `{false,"ERROR",{}}` and `query_yn` returns NO exactly as
  before. Pinned by the existing "cata_test query_popup still aborts" test (unchanged).

## 6. What remains unsupported / fail-loud (and the deliberately-deferred uilist)

- **The `uilist` family is AUDITED, not changed.** An unarmed `uilist` (`uilist::query`'s `test_mode` abort,
  `src/ui.cpp`) still returns `UILIST_ERROR` silently during a session. Guarding it would convert the witnessed
  **move-into-NPC** no-op into a fail-loud failure: `move_n` into the shelter NPC Edwardo →
  `avatar_action::move` → `game::npc_menu` → `amenu.query()` (`src/game.cpp`) → that abort. Today that is the
  witnessed `blocked_no_op` (doc 15) hard-gated by `npc_export_regression.ps1` and
  `client_harness_regression.ps1` (both assert backend exit 0 + the `blocked_no_op` outcome), and the client
  harness classifies it (`tools/arcopolis_client/harness.py`). **Follow-up (a "Spike 21"):** guard
  `uilist::query` the same way, and deliberately update those two regressions + `harness.py`'s classification +
  the docs so move-into-NPC fails loud. Deferred here to keep this spike narrow and avoid silently changing a
  witnessed baseline.
- **`NEW_PICKUP_MENU=true` / `inventory_selector`** — still rejected at pre-flight (`unsupported_command`, exit
  6), unweakened (docs 39/40).
- **Generic `query_popup`/`query_yn` support** — still none; exactly one site arms a transaction
  (`src/iexamine.cpp` deployed-furniture). Spike 20 makes every OTHER one fail loud during a session instead of
  silently defaulting; it does not DRIVE any of them.
- **`string_input_popup` / `query_int`** — these have no `test_mode` abort (they would reach a real input loop);
  they are out of scope here and not made to fail loud by this narrow chokepoint. (The seam's nested-input
  guard already cancels their unserved contexts; no new silent-default was introduced.)

## 7. Validation (RECORDED 2026-06-19, PowerShell only)

- **AStyle** (`C:\dev\astyle\bin\AStyle.exe --options=.astylerc -n`) on every touched `.cpp`/`.h`: all `src`
  files **Unchanged** (already CI-formatted); `tests/arcopolis_backend_input_test.cpp` reformatted to CI style.
- **Build** `cataclysm-bn-tiles` + `cata_test-tiles` (incremental, in `out\build\win-rel-deb`): every TU
  compiled with **zero errors** (incl. all edited TUs + the test TU). The build's `cmake --build` exit was
  nonzero ONLY from the known **cosmetic post-link packaging tail** (`applocal`/`mesa`/`deno docs:gen` →
  "system cannot find the path specified"; doc 39 §12) — `link.exe` produced both exes first (verified by
  fresh timestamps), so the tests ran from the freshly-linked binary.
- **Unit tests** `cata_test-tiles.exe "[arcopolis]"`: **All tests passed — 903 assertions in 141 test cases,
  exit 0** (doc-39 baseline was 888/139; +2 cases = the new fail-loud tests). Covers: "unarmed query_popup
  during a session fails loud (non-live)", "unarmed query_popup during a LIVE session is recoverable", the
  armed-witness "no failure" assertion (extends the Spike-15 no-window witness), and the unchanged "cata_test
  query_popup still aborts".
- **End-to-end fail-loud witness** (existing fixture, no new fixture): a **one-shot**
  `--arcopolis-command examine move_e` on `ArcopolisDeployedFurnitureTest` reached the deployed-furniture
  `query_yn` UNARMED (one-shot arms no transaction; the engine auto-resolved the single examine target) →
  **exit 14** with the exact `unexpected_prompt` stderr message, and **NO success snapshot was written**
  (amendment 3 — the failure was surfaced before the export).
- **Confirmatory regression** `query_popup_regression.ps1` (run with `pwsh`, against the freshly-built exe) —
  proves the ARMED live deployed-furniture `query_yn` still drives at level 4 (Spike 15 unbroken, no spurious
  fail-loud): _see §7a for the recorded result._
- Other existing regressions (`examine`, `movement`/`npc_export`/`client_harness`, `script_prompt`,
  `prompt_menu`) were not re-run this session; the unit tests + the static `uilist`-untouched fact (§6) cover
  their invariants. The `uilist` move-into-NPC `blocked_no_op` is unchanged by construction (no `src/ui.cpp`
  edit).
- **Frontend bridge consumer fix (follow-up after the [#50](https://github.com/jpturcotte/Cataclysm-BN/pull/50)
  review):** `tools/arcopolis_frontend/prototype_server.py` added `unexpected_prompt` to
  `RECOVERABLE_ERROR_CODES` (see §3). `python -m py_compile` clean; `"unexpected_prompt" in
  RECOVERABLE_ERROR_CODES` asserted by import; `frontend_prototype_regression.ps1` (run with `pwsh` against the
  built exe) — **all 18 gates pass, exit 0** (the bridge change is non-breaking; the gate-10/13 recoverable
  rejection paths still behave). The `[arcopolis]` unit suite was re-run after the fix: **903/141, exit 0**
  (Python-only change; the C++ binary is unaffected).

### 7a. query_popup_regression result

**ALL 6 GATES PASS, exit 0** (run 2026-06-19 against the freshly-built exe): Y1 (examine opens the
`query_popup`, 2 ordered YES/NO choices, cancelable:false), Y2 (level-4 transcript: `prompt_opened`
witness=examine_deployed_furniture_take_down / `prompt_answered` [0]→[LEFT,CONFIRM] / `prompt_completed`
actions_served=2, no force-cancel), Y3 (YES → `f_floor_mattress`→`f_null`, mattress dropped, "You take down
the mattress."), N (NO → furniture stays, no item, no message), R (out-of-range + wrong prompt_id +
non-cancelable cancel each rejected ok:false with the prompt OPEN, then a valid answer completes), E
(EOF/closed → visible default served, backend exit 0, `prompt_cancelled noncancelable_closed`, no error). The
**armed** query_popup path is unbroken and produced **no spurious `unexpected_prompt`** — confirming the
Spike 20 guard fires ONLY when the transaction is unarmed.

## 8. Claim → cite → verdict

Per [[cite-the-implementing-line]].

| Claim                                                                                   | Cite                                                                                     | Type       | Verdict                           |
| --------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ---------- | --------------------------------- |
| query_once reports an unexpected prompt before its safe-default abort, gated on session | `src/popup.cpp` `query_popup::query_once`                                                | behavioral | ✅ one-shot exit 14 + unit        |
| Inert outside a session (cata_test unchanged)                                           | `src/arcopolis_backend_input.cpp` `backend_report_unexpected_prompt` (`!session.active`) | behavioral | ✅ static                         |
| Non-live sets failure+done (exit 14); live sets recoverable pending (no done)           | `src/arcopolis_backend_input.cpp` `backend_report_unexpected_prompt`                     | behavioral | ✅ static                         |
| New kind maps to exit 14                                                                | `src/arcopolis_command.cpp` `exit_code_for`                                              | structural | ✅ static                         |
| One-shot checks failure before the success snapshot                                     | `src/arcopolis_export.cpp` (post-`do_turn` block)                                        | behavioral | ✅ one-shot: exit 14, no snapshot |
| Live surfaces ok=false `unexpected_prompt`, session stays open                          | `src/arcopolis_live.cpp` `live_next_action` block (a)                                    | behavioral | ✅ unit (channel) / static (wire) |
| Armed query_popup witness records no failure                                            | `tests/arcopolis_backend_input_test.cpp` (armed `query()` witness)                       | behavioral | ✅ unit pass                      |
| uilist family unchanged (move-into-NPC still `blocked_no_op`)                           | `src/ui.cpp` `uilist::query` (no edit)                                                   | absence    | ✅ static                         |
| No new curses window / render primitive                                                 | no new `newwin`/draw call added                                                          | absence    | ✅ static                         |

## 9. Residual uncertainties (kept)

1. Runtime greens (the new unit tests + the one-shot fail-loud witness + the unchanged regressions) rest on the
   build/run recorded in the session summary; if the build was blocked, only what compiled is claimed.
2. The **live** visibly-failed path is unit-witnessed at the channel level
   (`backend_take_unexpected_prompt_error`); no current fixture triggers an unarmed live `query_yn` (live
   `examine` arms the precondition and the only witnessed site is deployed-furniture), so the live `ok=false`
   wire shape is argued from the runner code, not a live-driver gate.
3. The `uilist` silent-cancel and the `string_input_popup`/`query_int` no-abort paths remain (§6) — this spike
   is deliberately the narrow query_popup case.
4. Line numbers drift; confirm by symbol.
