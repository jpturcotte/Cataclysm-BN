# Arcopolis Spike 13B — one backend-driven `uilist` path at level 4

**Status: implementation + decision record (2026-06-15).** The narrow proof of the Spike 13A design
([32_SPIKE13A_BACKEND_UI_MODE_AUDIT.md](32_SPIKE13A_BACKEND_UI_MODE_AUDIT.md)): drive **one** real BN
`uilist` headlessly to its `input_context::handle_input` loop, with real callback-populated state, consuming
registered actions supplied by Arcopolis, and returning the same `amenu.ret` a player would produce. The
witness is the `"Get items from where?"` vehicle-source submenu in `pickup::pick_up`, previously **fail-loud**
(Spike 12A follow-up, [31_SPIKE12A_FOLLOWUP_FAIL_LOUD.md](31_SPIKE12A_FOLLOWUP_FAIL_LOUD.md)).

> **Equivalence level proved: 4.** The chosen entry is produced solely by registered `UILIST` actions
> (`DOWN`/`CONFIRM`/`QUIT`) consumed by the **real** `uilist` loop through `input_context::handle_input()`,
> which sets `amenu.ret`. Arcopolis never mutates `ret`/`selected`/`fentries` as a substitute for input.

## Target witness

A live `pickup direction=move_s` on `ArcopolisVehicleCargoTest` (a clone of `ArcopolisTest` with an exact
`folding_wagon` replica — one `CARGO` item — injected onto the ground-item pile one tile south of the
post-`move_s` avatar). That tile has **both** vehicle cargo and ground items, so `pickup::pick_up` opens the
`uilist( "Get items from where?" )` with entries `from_cargo` (0) and `from_ground` (1).

## Source audit (read at the implementing line, current tree)

> **Line-number caveat (Spike 17 audit, 2026-06-18).** The `src/ui.cpp` numbers in this block were
> accurate when written but **pre-date PR #40's own newwin-skip insertion** (`src/ui.cpp:638-643`), which
> shifted the `query()` body down. In the current tree the gated `UILIST_ERROR` abort is at
> **`src/ui.cpp:933-937`** (not `:918-922`), `create_main_input_context` at `:945`, the redraw at `:961`,
> the do-loop at `:971-1028`, the CONFIRM branch at `:1001-1007`, and QUIT→`UILIST_CANCEL` at `:1008-1009`.
> doc 34:66 already cites the corrected `:933-937`. The behavior described below is unchanged; only the
> numbers drifted. See [37_SPIKE17_CLAIM_AUDIT.md](37_SPIKE17_CLAIM_AUDIT.md).

```
pickup::pick_up( p, min=0, get_items_from=prompt )      src/pickup.cpp:1267
  veh_has_items && map_has_items                        src/pickup.cpp:1278-1280
   -> uilist( "Get items from where?", {cargo, ground}) src/pickup.cpp (the witnessed menu)
uilist::init()       aborts under test_mode             src/ui.cpp:154-156   (debugmsg; return)
uilist::query()      aborts under test_mode             src/ui.cpp:918-922   (debugmsg; ret=UILIST_ERROR)
  past the abort: ctxt = create_main_input_context()    src/ui.cpp:930  (input_category default "UILIST")
                  ui_manager::redraw()                  src/ui.cpp:934  (NO-OP under test_mode, ui_manager.cpp:328)
                  do { ret_act = ctxt.handle_input(t);…} src/ui.cpp:944-1001 (default timeout=-1)
  DOWN -> scrollby(+1) -> selected = fentries[1]         src/ui.cpp:950, 842-893
  CONFIRM (needs !fentries.empty()) -> ret=entries[selected].retval  src/ui.cpp:974-980
  QUIT  -> ret = UILIST_CANCEL                           src/ui.cpp:981-982
uilist::setup()  assigns entries[i].retval (when -1),    src/ui.cpp:494-496
                 computes vmax, calls filterlist()       src/ui.cpp:597-614, 633 (fentries), newwin :627
uilist::addentry(str) == entries.emplace_back(str)       src/ui.cpp:1014-1016
enum from_where { from_cargo=0, from_ground=1, prompt=2 } src/pickup.h:35
seam: backend_nested_input_action(category, regs, t)     src/input.cpp:941-947 (top of handle_input)
existing "PICKUP" queue serve branch                     src/arcopolis_backend_input.cpp (Spike 12A)
vehicle fail-loud (replaced)                             src/pickup.cpp (backend_report_pickup_unsupported_submenu)
secondary capacity block (unchanged)                     src/pickup.cpp handle_problematic_pickup (gated, returns CANCEL)
```

**The two `test_mode` jobs (doc 32):** `test_mode` both (1) suppresses render/keyboard — Arcopolis wants
this — and (2) aborts `uilist::init`/`query` before the real loop runs — Arcopolis does not. 13B drops only
job (2), for exactly one menu.

**Headless-safety of `setup()` — NO window is created (build-independent):** under the gate `setup()` skips
its `window = catacurses::newwin(...)` (and the `if(!window) abort()`) entirely; the loop never needs a
window (`show()` is not called — `ui_manager::redraw()` is a `test_mode` no-op — and `query()`/`scrollby`/
`CONFIRM` read only `fentries`/`selected`/retvals). This matters for the **curses** build: there
`catacurses::newwin` is the real ncurses `::newwin` (`src/ncurses_def.cpp:71`, guarded `#if !(TILES||_WIN32)`),
and `--arcopolis-live` skips `initscr()`/`init_interface()` (`test_mode`, `src/main.cpp:882` `if(!test_mode)`),
so a `::newwin` before `initscr` would abort/crash; skipping it keeps the non-render path safe in **both**
builds. (The tiles pseudo-curses `newwin` returns a non-null buffer even at 0×0, `src/cursesport.cpp:65`, so
the tiles build was already safe — but the loop needs no window at all.) `setup()` still runs `filterlist()`
(window-free): `fentries=[0,1]`, retvals `0`/`1`; `vmax` is unused for a single `DOWN` (the literal `+1`,
`src/ui.cpp:828`). Found by the Codex review on PR #40.

This is a **backend invariant, not a frontend requirement**: the eventual Arcopolis GUI will render through
its own protocol/snapshot path, not through BN tiles or BN curses (see the "Frontend boundary" section in
[ARCOPOLIS_STATE.md#frontend-boundary-arcopolis-is-neither-bn-tiles-nor-bn-curses](ARCOPOLIS_STATE.md#frontend-boundary-arcopolis-is-neither-bn-tiles-nor-bn-curses)).
The backend must depend on _neither_ renderer.

**INVARIANT (build-independent, pinned by a unit test):** the Arcopolis backend headless path creates **no
curses window and calls no render primitive, in any build**. `tests/arcopolis_backend_input_test.cpp` arms a
backend uilist transaction, runs `setup()`, and asserts `!menu.window` (plus the retvals it populated) — in
the tiles `cata_test` the pseudo-curses `newwin` would leave `menu.window` **non-null**, so the assertion
fails the instant a regression re-adds an unconditional `newwin`, catching the curses-build crash in the
build we can actually run. **Every future un-abort site (`query_popup`, `popup()`, `inventory_selector`) must
uphold this invariant** — see the Risks section.

## Chosen implementation shape (and why)

A **per-transaction gate** `arcopolis::backend_ui_mode_active()` = `session.active && session.uilist_transaction`,
armed only immediately around the witnessed submenu. This — and **nothing weaker** (never
`backend_pickup_transaction_active()` or `backend_session_active()` alone) — is the single switch the
`uilist` un-abort keys off, so the un-abort fires for **exactly** this one menu and no other `uilist`
(considered alternatives: a broad session-level UI mode would also un-abort `timeout>=0` uilists in
`editmap`/`messages` and the in-activity secondary-capacity `uilist` — rejected).

Three gated touches in `src/ui.cpp` (include `arcopolis_backend_input.h`):

- `uilist::init()` / `uilist::query()` take the `test_mode` abort only when `!backend_ui_mode_active()`.
- `uilist::query()`, after building the input context, runs `setup()` **directly** under the gate
  (`if( backend_ui_mode_active() && !started ) { setup(); }`). This is a **non-render initialization** path:
  `ui_manager::redraw()` stays a test_mode no-op, so `show()` is never called and nothing draws. It runs the
  engine's **own** layout/data pass (the same `setup()` the GUI runs via its resize callback) so
  `fentries`/`keymap`/`vmax`/retvals exist for the loop to act on — but under the gate `setup()` **skips
  creating the curses window** (see Headless-safety above), so the path needs no `initscr`/render in any
  build. It does **not** set `ret` or the final selection — those come solely from the served actions. (This deviates from doc 32's "via the redraw/resize
  callbacks" sketch; the direct call is **safer** because it avoids un-suppressing draws globally, and it
  touches only `this` uilist.)

`src/pickup.cpp` vehicle block — replaced the fail-loud with the driven transaction, building the prompt from
the **real** `amenu.entries` (not a parallel model). Because `uilist::addentry(str) == entries.emplace_back(str)`,
the explicit `uilist amenu; amenu.text=…; addentry; addentry; query()` sequence is **byte-for-byte
GUI-equivalent** to the old `uilist( msg, {a,b} )` convenience constructor, and lets the prompt exchange sit
between entry population and `query()`. A scope guard clears the transaction on **every** exit path. With no
answer channel (non-live / misconfigured) the block **fails loud** (`backend_report_pickup_unsupported_submenu`),
preserving doc-31 behavior.

`src/arcopolis_backend_input.{h,cpp}` — `backend_ui_mode_active`, `backend_uilist_prompt_available`,
`backend_begin_uilist_transaction` (arms the gate; **must precede the uilist's construction** — `init()`
reads the gate), `backend_resolve_uilist_choice` (called **after** `addentry`, with choices from the real
`amenu.entries`; logs `prompt_opened`, asks the live client, builds the queue, logs
`prompt_answered`/`prompt_cancelled`), `backend_end_uilist_transaction` (logs `prompt_completed`, clears),
the `uilist_transaction_guard` RAII type, and a category-keyed serve branch for `"UILIST"` mirroring the
Spike 12A `"PICKUP"` queue (blocking reads only, TU-local stable storage).

`src/arcopolis_live.{h,cpp}` — `live_vehicle_source_prompt` (writes a `prompt` line `kind="uilist"`,
single-select, reuses `parse_prompt_answer`); wired as `opts.uilist_prompt_source` in `run_live`.

`src/arcopolis_session_log.{h,cpp}` — an **optional** `kind` field on `prompt_answered`/`prompt_cancelled`/
`prompt_completed`, emitted only when non-empty (`prompt_opened` already has `kind`), so the old "PICKUP"
menu wire is byte-identical.

## Exact UI-mode / test_mode behavior

| Context                                       | `test_mode` | `backend_ui_mode_active()` | `uilist::query()`                                                                  |
| --------------------------------------------- | ----------- | -------------------------- | ---------------------------------------------------------------------------------- |
| Normal GUI play                               | false       | false                      | renders + real input (unchanged)                                                   |
| cata_test (no backend session)                | true        | false                      | aborts → `UILIST_ERROR` (unchanged)                                                |
| Backend session, no uilist transaction        | true        | false                      | aborts → `UILIST_ERROR` (e.g. the secondary-capacity uilist)                       |
| Backend session, vehicle-source submenu armed | true        | **true**                   | runs `setup()` headlessly + the real loop; served `DOWN`/`CONFIRM` set `amenu.ret` |

## Exact level-4 equivalence claim

```
same engine action          ACTION_PICKUP via handle_action -> game::pickup -> pick_up
same active input loop       input_context("UILIST")::handle_input() in uilist::query (src/ui.cpp:944), UNMODIFIED
same registered actions      DOWN, CONFIRM (ground) or QUIT (cancel) -- exactly a player's keystrokes, in order
same selection               done by the engine loop (scrollby -> selected; CONFIRM -> ret=entries[selected].retval), NEVER by Arcopolis
same continuation            ret=1=from_ground flows into the existing ground path -> pick_up_from_items -> Spike 12A "PICKUP" menu
ONLY difference              the answer's TRANSPORT: a JSON prompt + a single choice index, not a curses keypress
```

The client's single choice K is translated into `[DOWN×K, CONFIRM]` (or `["QUIT"]` for cancel), served one
action per blocking `handle_input` read to the engine's own loop. The prompt **choices are the real
`amenu.entries`** (`txt`/`enabled` + position index) of the constructed engine `uilist` — presenting them is
presenting the real menu, not a fake. Arcopolis does **not** read or write `amenu.ret`/`selected`/`fentries`
as a substitute for selection.

## Protocol shape (additive)

Vehicle-source prompt (backend→client, mid-command), distinguished by `kind:"uilist"`:

```json
{"type":"prompt","id":<cmd-id>,"prompt_id":1,"kind":"uilist","title":"Get items from where?",
 "choices":[{"index":0,"text":"Get items from vehicle cargo","enabled":true},
            {"index":1,"text":"Get items on the ground","enabled":true}],"cancelable":true}
```

Answer (client→backend, **single-select**): `{"op":"prompt_answer","id":<n>,"prompt_id":1,"choice":1}`
(or `{"op":"prompt_cancel","prompt_id":1}`). On choosing ground the old item menu then emits its existing
`{"type":"prompt","prompt_id":2,"kind":"menu","title":"Pick up which items?",…}`. Wire behavior matches the
Spike 12A pickup menu: valid → `ok:true` ack then the command's terminal response; invalid / out-of-range /
multi-choice / wrong `prompt_id` → `ok:false`/`bad_request`, **prompt stays open**; cancel / EOF → the loop's
`UILIST_CANCEL` (no pickup), `ok:true`.

## Transcript shape (`session.jsonl`)

Reused events, the uilist ones carrying `kind:"uilist"`: `prompt_opened` (kind=uilist, the 2 real choices) ·
`prompt_answered` (kind=uilist, `choices:[1]`, `actions:["DOWN","CONFIRM"]`) · `prompt_completed`
(kind=uilist, `actions_served:2`) · then the item menu's `prompt_opened` (kind=menu) /
`prompt_answered` / `prompt_completed` (kind unset). Cancel logs `prompt_cancelled` (kind=uilist). A reader
can see the `UILIST` prompt opened, the exact served action sequence, that the engine consumed it, and that
the old "PICKUP" item prompt then opened and was served **separately**.

## Regression witness

[`prompt_menu_regression.ps1`](prompt_menu_regression.ps1) gate H is converted from fail-loud to **driven**,
on `ArcopolisVehicleCargoTest`, via the unchanged generic driver
[`prompt_menu_live_driver.py`](prompt_menu_live_driver.py) (which already serves two sequential prompts per
command). Sub-gates: **H-probe** (vehicle prompt `kind=uilist`, 2 choices in order, answer ground served
`[DOWN,CONFIRM]`, `prompt_completed kind=uilist actions_served=2`, the item menu opens, its cancel is a
no-op) · **H-pick** (the last ground entry is driven and leaves the ground: `7→6`, "You pick up: 1 glass
shard (1)") · **H-cancel** (`prompt_cancel` on the uilist opens **no** item menu, takes **no** ground items,
`prompt_cancelled kind=uilist`) · **H-recover** (wrong `prompt_id` + out-of-range each rejected with the
prompt open, then a valid answer completes). Gate I (non-live fail-loud) and gate D (`NEW_PICKUP_MENU=true`
fail-loud) are unchanged.

## Validation — PASS (2026-06-15, RelWithDebInfo + ccache, MSVC)

- `[arcopolis]` unit suite: **713 assertions / 102 cases** pass (new: the `backend_ui_mode_active` gate, the
  `"UILIST"` serve branch + queue builder, the no-channel fail-loud, the `kind` formatter field, the
  **cata_test invariant** — a `uilist` with no backend session still returns `UILIST_ERROR`, asserted via
  `capture_debugmsg_during` — and the **no-window invariant** — a backend-UI `setup()` leaves `menu.window`
  empty while populating retvals, so a regression re-adding an unconditional `newwin` fails here).
- [`prompt_menu_regression.ps1`](prompt_menu_regression.ps1) all gates exit 0 (`pwsh`).
- No regression: `examine_`, `movement_`, `live_protocol_`, `client_harness_`, `frontend_prototype_`, and
  `item_`/`monster_`/`npc_export_` all exit 0.

**Answer to the spike's question: YES.** One real BN `uilist` runs headlessly to its
`input_context::handle_input` loop, with real callback-populated state, consuming registered actions Arcopolis
supplies through the seam, and returns the same `amenu.ret` a player would — at equivalence level 4, with no
fake state and no direct selection mutation.

## Remaining unsupported surfaces (backlog)

Generic `uilist`, the `query_popup`/`popup()` family, `inventory_selector`/`NEW_PICKUP_MENU`, `string_input`,
ranged `TARGET`, NPC dialogue, computer UI, per-unit quantities, nested-container child marks, the secondary
capacity/wield/spill `uilist` (still **marked-partial**, not driven), and pipes as a robust boundary. Non-live
`pickup` remains fail-loud. **This spike proves ONE `uilist` path; it does not claim generic `uilist`, popup,
or prompt/menu support.**

## Risks / follow-up

- The un-abort is per-transaction; any future un-abort site **must** key on `backend_ui_mode_active()`, never
  a weaker gate, or unrelated uilists would un-abort.
- **The no-window/no-render invariant binds every future un-abort site** (`query_popup`, `popup()`,
  `inventory_selector`), not just this `uilist`: each must run its data-population without creating a curses
  window or calling a render primitive, because the headless backend has no `initscr` and the curses build's
  `catacurses::newwin` is fatal before it. The tiles-only regression cannot witness this, so the invariant is
  pinned by a unit test (`!menu.window` after a backend-UI `setup()`); add an equivalent pin for each new
  site. This was missed in the original spike (verified `newwin` safe for the tiles build only — the symbol
  has a second, unsafe ncurses definition) and caught by the Codex review on PR #40.
- The `setup()` direct call **skips** the curses window under the gate (see Headless-safety), so it no longer
  depends on `catacurses::newwin` behaviour and is safe in both the tiles and curses builds. A future change
  that makes the backend uilist loop actually need a window would have to provide a headless-safe one.
- Next: drive the secondary capacity/wield/spill `uilist` as its own transaction (close the marked-partial
  defect), then `query_popup`/`popup()` (a distinct `"POPUP_WAIT"` category + the `PF_GET_KEY` `ANY_INPUT`
  caveat from doc 32), building on this proven mode.
