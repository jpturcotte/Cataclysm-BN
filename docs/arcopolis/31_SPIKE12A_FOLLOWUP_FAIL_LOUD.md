# Arcopolis Spike 12A follow-up — the pickup transaction fails loud, never silently auto-cancel-as-success

**Status: implementation + decision record (2026-06-15).** A direct follow-up to
[30_SPIKE12A_PROMPT_MENU_TRANSACTION.md](30_SPIKE12A_PROMPT_MENU_TRANSACTION.md). Spike 12A proved a
GUI-equivalent (level-4) prompt/menu transaction for the old `"PICKUP"` ground-item menu, but three
adjacent prompt paths still violated the spike's own non-negotiable rule — **no hidden
auto-cancel-as-success**. This follow-up closes all three, holding to the merged AGENTS.md **backend input
equivalence** rule: a supported interactive action is driven through the same engine input loop a player
uses, and anything the transaction does NOT drive either fails loud or is honestly marked — never a silent
success.

It addresses the two Codex review comments on [PR #37](https://github.com/jpturcotte/Cataclysm-BN/pull/37)
(P1 at `src/arcopolis_backend_input.cpp:457`, P2 at `:295`) plus the secondary in-activity prompt that
Spike 12A itself flagged as a tracked defect.

## Foundation this PR establishes (stated plainly)

- **Live** mode can drive prompt/menu transactions (the Spike 12A pickup menu).
- **Non-live** modes (`--arcopolis-run-script`, one-shot `--arcopolis-command`) **fail loud for promptful
  commands** — a command whose core action _requires_ a prompt/menu answer channel (which only live
  provides) is rejected with `unsupported_command`, never silently no-op'd as success.
- This PR fixes the previous PR's non-live **dishonesty**. It deliberately does **not** make non-live as
  capable as live; that capability gap is a documented, honest limitation, not a hidden one. `examine` is
  unaffected — it still faithfully examines in non-live mode (its auto-pickup tail's force-cancel is the
  engine's own "Never mind.", not a command silently failing its purpose).

## The load-bearing discovery: uilists never reach the nested-input guard (test_mode)

The Codex P1 comment hypothesised that the vehicle "Get items from where?" submenu "falls through to the
generic nested-input guard and returns QUIT". **That mechanism is wrong**, and verifying it at the
implementing line changed the whole design:

The `--arcopolis-*` modes set `test_mode = true` (`src/main.cpp`). In test_mode, `uilist::query()` returns
**immediately** at its top — `debugmsg("Tried to open UI in test mode"); ret = UILIST_ERROR; return;`
(`src/ui.cpp:918`) — **without ever calling `input_context::handle_input()`**. So the Spike 11A nested-input
guard (a hook at the top of `handle_input`) **cannot see any uilist**. Proven live by instrumenting
`pickup::pick_up`: the vehicle submenu returned `UILIST_ERROR` (not `UILIST_CANCEL`), and `pick_up` fell
through `static_cast<from_where>(UILIST_ERROR)` to a **silent ground-only pickup** — not the "no pickup"
Codex assumed, and nothing the guard ever touched.

Consequence: to fail-loud or mark a `uilist`-based prompt in the backend you must intercept it **in the
engine call site**, gated, **before** the uilist opens. A guard at `handle_input` is useless for uilists.
(The guard still correctly handles `input_context`-based prompts — the `"DEFAULTMODE"` "Pickup where?"
chooser and the old `"PICKUP"` menu — which are not uilists.) `debugmsg` under test_mode in the _game_
binary is benign (logs to debug.log, does not abort), unlike in cata_test.

This is why the fix lives in two small **gated** blocks in `src/pickup.cpp` (consistent with Spike 12A's
own gated pre-loop block), not in the `backend_nested_input_action` guard.

## The three paths, and the fix for each

### P1 — vehicle "Get items from where?" submenu → FAIL LOUD

When a live `pickup` targets a tile with **both** vehicle cargo and ground items, `pickup::pick_up` opens
`uilist("Get items from where?")` (`src/pickup.cpp:1268`, the `veh_has_items && map_has_items` branch)
_before_ `pick_up_from_items`. Before the uilist, a gated block calls
`arcopolis::backend_report_pickup_unsupported_submenu()` and `return`s — no pickup. The live response
writer reads the recorded outcome and answers **`ok:false` / `unsupported_command`**; the transcript
records `prompt_force_cancelled kind=vehicle_submenu`. The session stays usable (a later command succeeds).
No silent ground-only pickup.

### P2 — non-live pickup → FAIL LOUD (pre-flight)

`pickup` is now `is_live_only_command()` (its core action needs the live `prompt_source`). The two non-live
pre-flight points — `run_script` (`src/arcopolis_script.cpp`) and one-shot `export_current_view`
(`src/arcopolis_export.cpp`) — reject it with **`unsupported_command` (exit 6)** _before_ the world load,
with a clear "requires `--arcopolis-live`" message and no snapshot. Mirrors the existing `NEW_PICKUP_MENU`
live fail-loud precedent. `examine` is **not** live-only and is unaffected.

### Secondary capacity/wield/spill prompt → honest PARTIAL, explicitly MARKED

After CONFIRM, `pickup_activity_actor` may raise a capacity/wield/spill `uilist` via
`handle_problematic_pickup` (`src/pickup.cpp:165-210`) for an item that does not fit. The transaction does
not drive it (driving it is still deferred). A gated block at the top of `handle_problematic_pickup` calls
`arcopolis::backend_report_pickup_secondary_forced_cancel()` and returns `CANCEL` — exactly the engine's own
test_mode outcome (the item is left behind). This is a **truthful partial pickup**: what fits is carried,
the rejected item stays on the ground and is **never** logged as picked up. The follow-up makes it
**non-silent**: the live command response carries the explicit marker set

```
{ "ok": true, "forced_cancel": true, "partial": true, "unsupported_prompt": "secondary_capacity" }
```

and the transcript records `prompt_force_cancelled kind=secondary_capacity`. **This is NOT full success** —
it is a partial engine result with an unsupported secondary prompt force-cancelled and explicitly marked.
`ok` stays `true` because a real partial pickup did happen; the markers make the partiality unmistakable
(we do **not** fake `ok:false`, which would imply nothing happened).

## Source code (scoped to `src/arcopolis_*` + two gated `src/pickup.cpp` blocks)

- `src/arcopolis_command.{h,cpp}` — `is_live_only_command()` (`true` for `pickup` only; the extension point
  for future promptful verbs).
- `src/arcopolis_backend_input.{h,cpp}` — `pickup_command_outcome` { ok, unsupported_submenu,
  secondary_forced_cancel }; `backend_report_pickup_unsupported_submenu()` /
  `backend_report_pickup_secondary_forced_cancel()` (set the outcome + log `prompt_force_cancelled`, gated on
  an armed pickup transaction); `backend_take_pickup_outcome()` (read-and-reset; the outcome outlives the
  seam's stale-clear so the response writer can consume it).
- `src/arcopolis_live.{h,cpp}` — the owed-response path reads the outcome: `unsupported_submenu` →
  `unsupported_command` (no snapshot, recoverable); `secondary_forced_cancel` → success snapshot + the
  `forced_cancel`/`partial`/`unsupported_prompt` marker set (additive; absent for every other response, so
  existing wire output is byte-unchanged).
- `src/arcopolis_script.cpp`, `src/arcopolis_export.cpp` — non-live pre-flight rejection via
  `is_live_only_command()`.
- `src/arcopolis_session_log.{h,cpp}` — the `prompt_force_cancelled` transcript event (kind + reason).
- `src/pickup.cpp` — two gated blocks (vehicle submenu; `handle_problematic_pickup`). Both inert outside an
  armed backend pickup transaction, so normal play and the GUI are untouched.

## The new fixture: `ArcopolisVehicleCargoTest`

The P1 witness needs a tile with **both** vehicle cargo and ground items. `ArcopolisTest` has no vehicle to
clone (unlike the monster fixture's stock wildlife), so `docs/arcopolis/make_vehicle_fixture.py` (stdlib-only,
read-only on `ArcopolisTest`, no build/GUI) injects an **exact structural replica of the stock
`folding_wagon`** — a real single-tile cart whose one mount (0,0) stacks `folding_frame` (structure,
`INITIAL_PART`), `wheel_caster`, and `basketlg_folding` (the `CARGO` basket) — into the submap `.map` JSON
(`map.sqlite3`), ON the ground-item pile one south of the post-`move_s` avatar. The CARGO item is a deep copy
of a real engine-written ground item from that pile (so it carries every serialized field), and only the
loader-read vehicle fields are written (`vehicle::deserialize`/`vehicle_part::deserialize` `allow_omitted_members`
and `data.read` with defaults; `read_saved_vehicle_parts` skips, never aborts, an unreadable part). Documented
in `C:\dev\arcopolis-fixtures\README.md` and the AGENTS.md fixture section.

## Validation — PASS (2026-06-15, RelWithDebInfo + ccache, MSVC)

- `[arcopolis]` unit suite: **95 cases / 669 assertions** pass (new tests for the report functions, the
  marker serialization, `is_live_only_command`, and the `prompt_force_cancelled` formatter).
- [`prompt_menu_regression.ps1`](prompt_menu_regression.ps1) **14 gates exit 0** (`pwsh`): the original A–G
  plus **gate H** (vehicle submenu fail-loud on `ArcopolisVehicleCargoTest` — no prompt,
  `ok:false`/`unsupported_command`, transcript `prompt_force_cancelled kind=vehicle_submenu`, session
  recovers) and **gate I** (non-live fail-loud — script + one-shot pickup exit 6 before load, no snapshot).
  Gate E now also asserts the secondary marker set + `prompt_force_cancelled kind=secondary_capacity`.
- No regression: `examine_` (its pickup tail still auto-cancels), `movement_`, `live_protocol_`,
  `client_harness_`, `frontend_prototype_`, and `item_`/`monster_`/`npc_export_` all exit 0.

> **Run these with `pwsh` (PowerShell 7), not `powershell` (5.1).** PS 5.1 reads BOM-less UTF-8 snapshots
> as the system codepage (corrupting item names with non-ASCII glyphs) and writes a BOM into options.json
> that the engine's option loader ignores — both produce spurious gate failures on unchanged code.

**Answer:** the pickup transaction now upholds Spike 12A's non-negotiable rule on every path. Where it can
drive the prompt (the ground-item `"PICKUP"` menu, live), it does, at level 4. Where it cannot (the vehicle
submenu, non-live pickup, the secondary capacity prompt), it fails loud or marks the result honestly —
never a silent auto-cancel presented as success.
