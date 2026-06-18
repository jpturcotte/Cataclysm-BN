# Arcopolis Spike 16 — non-live script prompt answers for already-proven prompt paths

**Status: implementation + decision record (2026-06-18).** Spikes 12A/13B/14/15 proved **live-mode** prompt
transactions through real engine input loops at equivalence **level 4** (the old `"PICKUP"` menu, the
vehicle-source `uilist`, the secondary capacity `uilist`, and the deployed-furniture `query_yn`). This spike
makes those **same** transactions replayable in **non-live `--arcopolis-run-script`** mode — without
inventing a second prompt semantics — by letting a command step declare ordered `prompt_answers` that feed
the SAME `backend_resolve_*` machinery the live stdin source feeds.

> **Equivalence level proved: 4** (for the supported scripted prompted paths). The script answer is matched
> to the prompt the engine actually opens, becomes the SAME registered actions a player presses
> (`DOWN`/`RIGHT`/`CONFIRM` · `DOWN×K, CONFIRM` · `LEFT, CONFIRM`), is consumed by the engine's own
> UNMODIFIED `input_context` loop, which sets the result; the engine caller mutates world/inventory/activity
> state. The **only** difference from live is the answer's TRANSPORT: a pre-declared script field instead of
> a stdin JSONL line. No new UI mechanism, no generic prompt support, no direct state mutation.

## Why this is strategically useful now

After the live `uilist` (13B/14) and `query_popup` (15) witnesses, the backend can drive four real prompt
classes at level 4 — but only with a **live** answer channel. Non-live `--arcopolis-run-script` (the
deterministic, reproducible mode the regressions and an offline frontend author use) rejected `pickup` at
pre-flight (`is_live_only_command`, exit 6) and silently `test_mode`-aborted a furniture-examine query_yn,
because the steps-walk provider installed no `prompt_source`/`uilist_prompt_source`/`query_popup_source`.
Spike 16 closes that gap for the already-proven paths: a script can now _record_ the prompt answers a player
would give and replay the exact same engine input path deterministically.

## What was added (the smallest additive script format — Option A)

An optional `prompt_answers` array on a `command` step (valid only on the prompted verbs `pickup`/`examine`).
Each entry answers one prompt, **in the order the engine opens them**:

```json
{
  "op": "command",
  "command": "pickup",
  "direction": "move_s",
  "prompt_answers": [
    { "kind": "uilist", "choice": 1, "title_contains": "Get items from where" },
    { "kind": "menu", "choices": [5] }
  ]
}
```

Entry fields:

- `kind` (required) — `"menu"` | `"uilist"` | `"query_popup"`; asserted against the prompt class the engine
  actually opens.
- `choice` (int) **or** `choices` (int array) — the chosen index/indices. The parser **canonicalizes** both
  into one internal `choices` vector (`choice: 3` → `[3]`). `menu` allows multi-select; `uilist`/`query_popup`
  require exactly one (a 2+ array is a schema error). Mutually exclusive with `cancel`.
- `cancel` (bool, default false) — request a cancel. Accepted only where the prompt is cancelable (a `cancel`
  on a non-cancelable `query_yn` fails loud at runtime). Then `choices` is empty.
- `title_contains` / `title_exact` (optional, mutually exclusive) — title assertion to prevent answering the
  wrong prompt. Allowed for `uilist`/`query_popup` only (the `menu` `prompt_source` hook receives no title;
  the parser rejects a title on `menu`).

Schema version stays `1` (the field is optional/additive; existing scripts are unaffected). Compatibility
with older binaries is **not** a guarantee — an older binary may reject or fail-loud a prompted script.

## How it reuses the live machinery (no second semantics)

`run_script` installs three **script** prompt sources as the session's
`prompt_source`/`uilist_prompt_source`/`query_popup_source` (`src/arcopolis_script.cpp`):
`arcopolis::script_pickup_prompt` / `script_uilist_prompt` / `script_query_popup_prompt`
(`src/arcopolis_backend_input.{h,cpp}`). They implement the EXACT hook signatures the live stdin sources
implement, and return the EXACT internal result types (`std::optional<std::vector<int>>` for the multi-select
menu; `std::optional<int>` for the single-select uilist/query_popup). The backend then runs the unchanged
`backend_resolve_pickup_choice` / `backend_resolve_uilist_choice` / `backend_resolve_query_popup_choice`,
which build the registered-action queue, serve it through the real `input_context` loop, and emit the same
`prompt_opened` / `prompt_answered` / `prompt_cancelled` / `prompt_completed` transcript events as live mode.

Instead of blocking on stdin, a script source consumes the **next** declared answer from a per-command queue
(loaded at dispatch by `next_backend_action`, when it also arms the pickup transaction / the examine
query_popup precondition — mirroring `live_next_action`). It matches the answer's `kind` (and `title`) against
the open prompt, validates the choice range / single-select / cancelability, and returns the choice(s) — or
`nullopt` for a legitimate cancel. The sources write **no** stdout (script mode has no client); only the
shared transcript events and (on failure) `prompt_failed` are recorded.

## Fail-loud — and never confuse a fatal fallback with a real cancel

A non-live script aborts honestly (`command_error_kind::script_prompt_failed` → **exit 13**, `session_end`
status `"error"`, no final snapshot) when:

| Case                                                                                           | Reason                                                                                           | Where                         |
| ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ----------------------------- |
| a prompted command has no declared answers                                                     | `requires --arcopolis-live or a 'prompt_answers' declaration`                                    | pre-flight (exit **6**)       |
| a scripted `pickup` under `NEW_PICKUP_MENU=true`                                               | `requires NEW_PICKUP_MENU=false` (the new `inventory_selector` is undriven, symmetric with live) | post-load reject (exit **6**) |
| a prompt opens but the queue is empty                                                          | `no_scripted_answer`                                                                             | source (exit 13)              |
| the next answer has the wrong `kind`                                                           | `kind_mismatch`                                                                                  | source (exit 13)              |
| a title assertion does not match                                                               | `title_mismatch`                                                                                 | source (exit 13)              |
| the choice is out of range                                                                     | `choice_out_of_range`                                                                            | source (exit 13)              |
| `cancel` on a non-cancelable prompt                                                            | `noncancelable`                                                                                  | source (exit 13)              |
| answers remain unused at command end                                                           | (an `error` record)                                                                              | seam return (exit 13)         |
| a pickup hits an unsupported in-activity sub-prompt (disabled-entry secondary capacity uilist) | (`error` record; transcript also has `prompt_force_cancelled`)                                   | seam return (exit 13)         |

**The fatal fallback is not a user cancel.** On a fatal failure the source emits `prompt_failed` (with the
reason + detail) **before** returning `nullopt`. The resolve then serves the engine loop-exit action
(`QUIT` for menu/uilist; the default-`CONFIRM` for the non-cancelable query_popup), which may log
`prompt_cancelled` — but that is only an engine **escape hatch** so the loop never hangs. The authoritative
signal is `prompt_failed` + `session_end status="error"` + exit 13. A **legitimate** scripted `cancel`
(`cancel:true` on a cancelable prompt) is the opposite: it emits **no** `prompt_failed`, records **no**
failure, and the run ends `ok` (exit 0). So `prompt_failed` present ⇒ broken script (never read as "the user
cancelled"); a `prompt_cancelled` with no preceding `prompt_failed` and `session_end ok` ⇒ a real cancel.

## Scope — single-turn prompts only

Script prompt answers are scoped to the **command turn currently being driven**: the per-command answer queue
is loaded at dispatch and cleared (with the unused-answer check) at the seam return for that same command.
This covers exactly the already-witnessed one-turn prompt paths. A **multi-tick resumed pickup activity**
whose secondary prompt opens on a _later_ `do_turn` — after the transaction and queue were cleared — is **not**
solved here: it inherits Spike 14's behavior, where `handle_problematic_pickup` finds no armed pickup
transaction and the existing defensive guard `backend_report_pickup_orphaned_secondary()` **marks** it
(`prompt_force_cancelled kind=secondary_capacity_orphaned`) and the engine's own CANCEL leaves the item
behind — never a silent success, but **not driven**. Threading the transaction + answer queue across activity
resumes remains backlog (doc 34).

## Which paths are now script-supported

- **`--arcopolis-run-script`** with declared `prompt_answers`: the old `"PICKUP"` item menu, the
  vehicle-source `uilist`, the **all-enabled** secondary capacity/wield/spill `uilist`, and the
  deployed-furniture `query_yn`/`query_popup` — the same four classes 12A/13B/14/15 drive live. The secondary
  capacity `uilist` carries Spike 14's bound verbatim: it is driven at level 4 **only when every entry is
  enabled**. A real capacity prompt can present a **disabled** entry (e.g. a too-heavy WOOL armor item +
  `WOOLALLERGY` → WEAR disabled, or a `NO_UNWIELD` wielded weapon → WIELD disabled), which the engine
  force-cancels _before_ the prompt is exposed (`src/pickup.cpp` all-enabled gate); in script mode that
  force-cancel is **surfaced as fail-loud** (`script_prompt_failed`, exit 13) by the seam-return cleanup —
  the over-capacity item is left behind and the run aborts honestly, never a silent exit-0 "ok". (Live mode
  marks the same case a partial; script mode has no per-command marker channel, so it fails loud instead.)
- **Still fail-loud / unsupported:** one-shot `--arcopolis-command` pickup (no answer channel — deliberately
  kept fail-loud; a prompted command belongs in a script); `NEW_PICKUP_MENU=true` (rejected loud and early —
  exit 6, symmetric with live mode `src/arcopolis_live.cpp`; the new `inventory_selector` is not a script-driven
  menu); a deployed-furniture
  examine with no declared answer; a **disabled-entry** secondary capacity `uilist` (fails loud per above);
  multi-tick resumed secondary prompts (orphaned-marked).
- **Still backlog (no change):** generic `uilist`/`query_popup`, the `popup()`/`popup_getkey()` family
  (`PF_GET_KEY`/`ANY_INPUT`), `inventory_selector`, `string_input`, NPC talk, computer UI, ranged targeting,
  containers, per-unit quantities, and pipes/named pipes.

## Transcript examples (`session.jsonl`)

A scripted pickup of the last menu entry (W1), abbreviated:

```jsonl
{"schema_version":1,"event":"command","step_index":2,"command":"pickup","direction":"move_s","action_id":"pickup","status":"queued"}
{"schema_version":1,"event":"prompt_opened","step_index":2,"kind":"menu","choices":[{"index":0,"text":"...","enabled":true}, ... ]}
{"schema_version":1,"event":"prompt_answered","step_index":2,"choices":[6],"actions":["DOWN","DOWN","DOWN","DOWN","DOWN","DOWN","RIGHT","CONFIRM"]}
{"schema_version":1,"event":"prompt_completed","step_index":2,"actions_served":8}
```

(The transcript discriminator key is `event`, not `type` — `type` is the LIVE-wire field, not the
`session.jsonl` field; every record also carries a leading `schema_version`.)

A scripted query_popup YES (W4): `prompt_opened kind=query_popup witness=examine_deployed_furniture_take_down`
→ `prompt_answered kind=query_popup choices=[0] actions=["LEFT","CONFIRM"]` → `prompt_completed kind=query_popup`.

A fatal wrong-kind answer (F2): `prompt_opened kind=menu` →
`prompt_failed reason=kind_mismatch detail="scripted answer kind 'uilist' does not match the open 'menu' prompt"`
→ `error kind=script_prompt_failed` → `prompt_cancelled reason=client_cancel` (the escape hatch) →
`session_end status=error`; process exit 13.

## Source code

- `src/arcopolis_script.{h,cpp}` — the `script_prompt_answer` struct + the `prompt_answers` field on
  `script_step`; `parse_script` gains the `pickup` direction branch and `parse_prompt_answers` (structural
  validation + `choice`→`choices` canonicalization); `run_script` relaxes the `is_live_only_command`
  pre-flight to allow `pickup` **with** declared answers and installs the three script sources.
- `src/arcopolis_backend_input.{h,cpp}` — the per-command answer queue in the session; the dispatch arming +
  queue load in `next_backend_action` (for `pickup`/`examine`); the `done`-guard that stops the steps walk on
  a fatal failure; `clear_stale_scripted_prompt_answers` (the unused-answer check at the seam return);
  `record_script_prompt_failure`; `match_scripted_answer` / `match_single_select_scripted`; and the three
  exposed sources `script_pickup_prompt` / `script_uilist_prompt` / `script_query_popup_prompt` +
  `backend_load_scripted_prompt_answers`. **No change** to the resolve functions, the registered-action
  queues, the serve branches, or the engine un-abort sites (12A–15 are reused verbatim).
- `src/arcopolis_command.{h,cpp}` — `command_error_kind::script_prompt_failed` → exit 13; updated
  `is_live_only_command` doc.
- `tests/arcopolis_script_test.cpp` — `prompt_answers` parsing (accept menu/uilist/query_popup/cancel +
  pickup direction; reject bad kind / choice+cancel / neither / multi-choice uilist / title-on-menu /
  both-titles / prompt_answers on a non-prompted command) + the exit-13 mapping.
- `tests/arcopolis_backend_input_test.cpp` — the script sources produce the SAME registered-action queue as
  the live sources (menu multi-select, uilist single-select, query_popup YES/NO), sequential consumption in
  order, a legitimate cancel, and the fail-loud cases (missing / wrong-kind / title-mismatch / out-of-range /
  cancel-on-noncancelable / unused → `script_prompt_failed`).

## Regression witness

[`script_prompt_regression.ps1`](script_prompt_regression.ps1) (pure run-script — no live driver) on the four
existing fixtures, run with **`pwsh`**, `AUTOSELECT_SINGLE_VALID_TARGET=false` + `AUTO_PICKUP=false` pinned:

- **W1 pickup menu** (`ArcopolisTest`): `pickup` answering `{menu, choice 6}` → served `[DOWN×6, RIGHT,
  CONFIRM]`, south pile 7 → 6.
- **W2 vehicle uilist** (`ArcopolisVehicleCargoTest`): `pickup` answering `{uilist, choice 1}` then `{menu,
  choice 6}` → `kind=uilist` then `kind=menu`, ground pile 7 → 6.
- **W3 secondary capacity uilist** (`ArcopolisCapacityTest`): a probe discovers the jacket's menu index; the
  real run picks the jacket then answers `{uilist, choice 1}` (WIELD) → `kind=menu` then `kind=uilist`
  (driven, **not** force-cancelled), the jacket leaves the ground.
- **W4 query_popup** (`ArcopolisDeployedFurnitureTest`): `examine move_e` answering `{query_popup, choice 0}`
  (YES) → `[LEFT, CONFIRM]`, furniture gone + a mattress dropped; the NO variant (`choice 1` → `[CONFIRM]`)
  leaves it.
- **W5 legitimate cancel** (`ArcopolisTest`): `pickup` answering `{menu, cancel}` → `prompt_cancelled` with NO
  preceding `prompt_failed`, a clean exit 0, the pile unchanged (distinct from a fatal fallback).
- **Failure gates:** pickup with no answers → exit 6; a scripted pickup under `NEW_PICKUP_MENU=true` → exit 6
  (`requires NEW_PICKUP_MENU=false`); a wrong-kind answer → exit 13 (`prompt_failed kind_mismatch`, with the
  Amendment-1 ordering check); an unused answer → exit 13 (`error kind=script_prompt_failed`); an out-of-range
  choice → exit 13 (`prompt_failed choice_out_of_range`).

## Validation

See the run log appended after the build/regression pass (the unit suite `[arcopolis]`, the new
`script_prompt_regression.ps1`, and the no-regression matrix). Commands:

```powershell
cmake --build .\out\build\win-rel-deb --target cataclysm-bn-tiles cata_test-tiles
& .\out\build\win-rel-deb\tests\cata_test-tiles.exe "[arcopolis]"
pwsh -File docs\arcopolis\script_prompt_regression.ps1
pwsh -File docs\arcopolis\prompt_menu_regression.ps1   # gate I (non-live pickup fail-loud) unchanged
pwsh -File docs\arcopolis\query_popup_regression.ps1
pwsh -File docs\arcopolis\examine_regression.ps1
```

## Remaining backlog

Generic UI mechanisms; `popup_getkey` / `PF_GET_KEY` / `ANY_INPUT`; `inventory_selector`; `string_input`;
NPC talk; computer UI; targeting; containers; quantities; pipes/named pipes — and, specific to this spike,
one-shot `--arcopolis-command` prompts and multi-tick resumed-activity secondary prompts.
