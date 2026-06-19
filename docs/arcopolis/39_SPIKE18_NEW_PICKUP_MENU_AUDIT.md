# Arcopolis Spike 18 — `NEW_PICKUP_MENU` / `inventory_selector` feasibility audit (NO witness)

**Status: audit-only decision record (2026-06-18). NO witness implemented, driven, or proven. NO behavior
change; NO build/run.** A trial of the PR #45 equivalence reframe
([37_SPIKE17_CLAIM_AUDIT.md](37_SPIKE17_CLAIM_AUDIT.md),
[38_LEVEL4_TRUTH_AUDIT.md](38_LEVEL4_TRUTH_AUDIT.md)). It asks ONE question — can Arcopolis drive **one
witnessed `NEW_PICKUP_MENU=true` path** at backend-input **level 4** that is **external GUI-equivalent enough
for this witness** — traces the exact call path at the implementing line, classifies every `test_mode` /
window / graphical-interface abort in it, and decides. **Outcome: stop at audit (Outcome A).** The pre-flight
**fail-loud** for `NEW_PICKUP_MENU=true` **remains**, unweakened. This is **not** generic
`inventory_selector` support, and **no `NEW_PICKUP_MENU` path is driven, witnessed, or proven here.**

> **Headline finding (read before §8): a `test_mode` un-abort witness (Spikes 13B/14/15) is NOT equivalent to
> a renderer-neutral backend UI mode.** Driving `inventory_selector` honestly is **qualitatively different**
> from the prior prompt witnesses — it is the *start of a renderer-neutral selector architecture*, not "one
> more prompt path." §8's sketch is a **seam map, not authorization**: any implementation needs its own design
> spike first.

> **Method + honesty caveats.** Multi-agent leaf trace → classification → two-sided adversarial feasibility
> (argue-feasible vs argue-audit-only) + a completeness critic, with the load-bearing leaves hand-verified
> this session. **No build was run; no `--arcopolis-*` session was executed.** Every runtime claim about the
> `NEW_PICKUP_MENU=true` selector path is reasoned from the cited source leaves — and that path is **rejected
> pre-flight today**, so its "what would happen" behavior is the *counterfactual the fail-loud exists to
> prevent*, not an observed run. Line numbers are current-tree at audit time; confirm by symbol (they drift).
> Terminology (backend-input vs engine vs frontend equivalence) is the three senses pinned in
> [37](37_SPIKE17_CLAIM_AUDIT.md) §Terminology and `AGENTS.md:83-120`.

## 1. Purpose

Determine, at the implementing line, whether BN's `NEW_PICKUP_MENU=true` pickup path (the
`inventory_selector`) can be driven by Arcopolis as **one witnessed path** that is *both*:

1. **backend-input level 4** — BN's real prompt/input/selector loop consumes backend-served registered
   actions, and the real engine caller consumes the result; and
2. **external GUI-equivalent enough for this witness** — an external frontend could expose the same
   meaningful choice and consequence while BN stays authoritative.

If the answer is "not yet," document exactly **why**, **where the seam is**, and **what would be required
next**. (It is "not yet.")

## 2. Why this is a trial of the PR #45 reframe

PR #45 reframed the project: **external GUI equivalence is the goal; backend-input level 4 is the proof
mechanism**, not a replacement for it; and **one witnessed path is not generic support** (doc 37/38). Spike
18 is the first *new* prompt-class probe under that reframe. The discipline it tests: state the equivalence
level honestly, refuse "equivalent-ish," and — per the standing amendment recorded for this spike — treat the
`test_mode` / "missing graphical interface" abort as a **primary audit target**, not a test flake. The
**forbidden** moves (each yields an "equivalent-ish" result that is *worse* than audit-only): fake graphics,
pretend tiles/curses exists, weaken `test_mode` globally, route around the selector, set the selector result
directly, or use the final item transfer as the proof of equivalence.

## 3. Current old-pickup baseline (the legacy old PICKUP witness — preserved)

Under **`NEW_PICKUP_MENU=false`** (the BN default, `src/options.cpp:1861`) `game::pickup` takes the `else`
branch `pickup::pick_up( p, 0 )` (`src/game.cpp:8786`). That is the **legacy old PICKUP witness**: an
`input_context("PICKUP")` loop (`src/pickup.cpp:831`) driven at **backend-input level 4** by the Spike 12A
pickup transaction (the gated pre-loop block `src/pickup.cpp:761-769` exposes the real `stacked_here` entries;
the **unmodified** loop consumes the served `[DOWN×K, RIGHT, …, CONFIRM]`; the engine's `pickup_activity_actor`
performs the transfer). It is live- and (Spike 16) script-drivable. **This audit changes none of it.** It is a
*legacy* witness — BN's default and forward direction is the `inventory_selector` — exactly as doc 37 §"Why
the old pickup menu is a legacy witness" states.

## 4. The `NEW_PICKUP_MENU=true` call path (traced at the implementing line)

```
ACTION_PICKUP                                            src/handle_action.cpp:2305-2307 (game::pickup() / pickup(*mouse_target))
 -> game::pickup( const tripoint_bub_ms &p )             src/game.cpp:8773
    add_draw_callback( hilite_cb )  [render closure]     src/game.cpp:8776-8779  (drawsq body only runs in a draw pass; suppressed under test_mode)
    if( get_option<bool>( "NEW_PICKUP_MENU" ) )          src/game.cpp:8781
      -> std::vector<pick_drop_selection> pickup_list =
           game_menus::inv::pickup_from_tile( g->u, p )   src/game.cpp:8782  ->  src/game_inventory.cpp:1693
            pickup_inventory_preset preset( p )           src/game_inventory.cpp:1698
            inventory_pickup_selector inv_s( p, preset )  src/game_inventory.cpp:1699   (input_context "INVENTORY")
            inv_s.add_map_items( target )                 src/game_inventory.cpp:1707   -> map_column
            inv_s.add_vehicle_items( target )             src/game_inventory.cpp:1708   -> SAME map_column (vehicle cargo folded in; NO "Get items from where?" uilist)
            if( inv_s.empty() ) popup( ..., PF_GET_KEY )  src/game_inventory.cpp:1710-1713  (empty tile only; not the witness)
            result = inv_s.execute()                      src/game_inventory.cpp:1715
              -> inventory_pickup_selector::execute()     src/inventory_ui.cpp:2540
                 create_or_get_ui_adaptor()               src/inventory_ui.cpp:2542  (wires on_screen_resize->prepare_layout, on_redraw->refresh_window)
                 while(true){ ui_manager::redraw();        src/inventory_ui.cpp:2545  (no-op under test_mode)
                              get_input(); ... }            src/inventory_ui.cpp:2547  -> get_input() :1883 -> ctxt.handle_input() :1887   (THE real loop; NO test_mode abort)
                   RIGHT  -> mark highlighted entry        src/inventory_ui.cpp:2561
                   CONFIRM-> result = optimize_pickup(...) src/inventory_ui.cpp:2607  (SHARED with the old path); return :2613  (popup_getkey + continue if empty :2608-2611)
                   QUIT   -> return {}                     src/inventory_ui.cpp:2615
                   loop-tail no_items -> return {}         src/inventory_ui.cpp:2621-2630  (third empty-return exit)
    -> g->u.assign_activity( pickup_activity_actor( pickup_list, ... ) )   src/game.cpp:8783-8784
```

**Answers to the audit's Phase-1 questions** are tabulated in §11. The two findings that govern the decision:

- The selector reaches **the real input loop** — `get_input()` calls `ctxt.handle_input()` on
  `input_context("INVENTORY")` (`src/inventory_ui.cpp:1837`, `:1887`) with **no `test_mode` abort anywhere in
  `inventory_ui.cpp`** (grep: zero hits) — *unlike* `uilist::query` (`src/ui.cpp:933`) and
  `query_popup::query_once` (`src/popup.cpp:277`), which abort at the top under `test_mode`.
- The selector's **navigable/sorted state and its window are produced by the SAME suppressed callback**:
  `create_or_get_ui_adaptor` wires `on_screen_resize -> prepare_layout()` (`src/inventory_ui.cpp:1471-1472`);
  the no-arg `prepare_layout()` (`:1446`) runs the renderer-neutral 2-arg `prepare_layout(w,h)` (`:1420`,
  which does the sort + category headers + initial-highlight snap + invlet assignment + `refresh_active_column`)
  **and then** `resize_window()` → `catacurses::newwin` (`:1463`, `:1630`). Under `test_mode`
  `ui_adaptor::redraw_invalidated()` returns early (`src/ui_manager.cpp:328`), so that callback **never fires**
  — neither the window **nor the layout pass** runs.

## 5. CENTRAL GATE — abort / window / `test_mode` classification

Per the standing amendment, every early abort / window-or-render dependency / `test_mode` shortcut on the
witnessed minimal path (one live ground item, `NEW_PICKUP_MENU=true`) is classified below. Classes:
**R** = renderer/window/drawing dependency · **T** = `test_mode` shortcut that skips real input · **G** =
missing graphical-interface assumption · **U** = legitimate unsupported selector path · **N** =
renderer-neutral input logic.

| Site | What | Class | Fires on witness? | Renderer-neutrally drivable? |
| --- | --- | --- | --- | --- |
| `src/game.cpp:8776-8779` | `add_draw_callback( [drawsq w_terrain] )` | R | installed, body never executes (draw pass suppressed) | avoidable on witness (never fabricate `w_terrain`) |
| `src/game.cpp:8781-8784` | `NEW_PICKUP_MENU` branch → `pickup_from_tile` + `assign_activity` | N | yes (the dispatch) | only with a new init path below |
| `src/game_inventory.cpp:1698-1708` | build selector, `add_map_items`/`add_vehicle_items` | N | yes | **yes** — window-free data population |
| `src/game_inventory.cpp:1710-1713` | empty-pile `popup(…, PF_GET_KEY)` | G | no (witness pile non-empty) | avoidable on witness |
| `src/inventory_ui.cpp:2542` | `create_or_get_ui_adaptor()` (wires resize+redraw callbacks) | R | yes (object created) | only with a new init path |
| `src/inventory_ui.cpp:2545` | `ui_manager::redraw()` each iteration | T | yes (pure no-op under `test_mode`) | **yes** — this is the *wanted* half of `test_mode` |
| `src/inventory_ui.cpp:1471/1446-1463` | `on_screen_resize → prepare_layout()` (no-arg) | T+R | **never fires** under `test_mode` → layout AND window both skipped | only with a new init path |
| `src/inventory_ui.cpp:1420-1444` | 2-arg `prepare_layout(w,h)` (sort/headers/snap/invlets/`refresh_active_column`) | N | does not fire (only via the suppressed no-arg) | **yes** — window-free, but needs explicit dims (height > 1) |
| `src/inventory_ui.cpp:1628-1639` | `resize_window → catacurses::newwin` | R | never fires under `test_mode` **on the redraw path** (but see TOGGLE_FAVORITE below) | **no** — must never run; **ungated** here (contrast `uilist::setup` `src/ui.cpp:638`) |
| `src/inventory_ui.cpp:1641-1653` | `refresh_window` (`assert(w_inv)` + `werase`/`draw_*`) | R | never fires under `test_mode` | **no** — pure drawing |
| `src/inventory_ui.cpp:1908-1915` | `on_input` **TOGGLE_FAVORITE** → no-arg `prepare_layout()` | R | **NOT suppressed** — reachable via a served action, calls `newwin` | **no** — ungated `newwin` outside the redraw path |
| `src/inventory_ui.cpp:1883-1896` | `get_input()` → `ctxt.handle_input()` ("INVENTORY") | N | yes (the real loop) | **yes** — renderer-neutral level-4 seam |
| `src/arcopolis_backend_input.cpp:1090-1116` | guard for an "INVENTORY" read (no serve branch) | N | yes → `cancel_quit` serves `QUIT` | semantically WRONG for pickup (silent no-op) |
| `src/inventory_ui.cpp:2549-2614` | digit/select/RIGHT/CONFIRM dispatch | N | per served action | only with a new init path (needs the layout pass) |
| `src/inventory_ui.cpp:2615-2630` | QUIT / loop-tail empty returns | N | yes (QUIT served) | empty selection → silent no-op |

**Sub-prompt hazard surface (renderer dependencies the selector can raise).** None fires on the witnessed
path (the seam serves the unserved "INVENTORY" context only `QUIT`, and `execute()` exits on the first read),
but they bound what stays unsupported:

| Sub-prompt | Site | Mechanism | Status |
| --- | --- | --- | --- |
| empty-pile popup | `src/game_inventory.cpp:1711` | `popup(…, PF_GET_KEY)` → `query_once` `test_mode`-abort (`src/popup.cpp:277`) | off-witness; defaulted |
| per-unit `query_count` | `src/inventory_ui.cpp:2552` → `:2128` | `string_input_popup` on context `"STRING_INPUT"` (unserved) + a window | unsupported |
| filter `INVENTORY_FILTER` | `src/inventory_ui.cpp:1907` → `:1657` | `string_input_popup` `"STRING_INPUT"` + `ime_sentry` | unsupported |
| "No items selected" | `src/inventory_ui.cpp:2609` | `popup_getkey` → `query_once` `test_mode`-abort | off-witness; defaulted |
| `EXAMINE` item info | `src/inventory_ui.cpp:756-759` | `draw_item_info` → `catacurses::newwin` + a `handle_input` loop on the default context (**no `test_mode` abort**, only its `newwin` is callback-suppressed) | unsupported |
| `WIELD`/`WEAR` | `src/inventory_ui.cpp:1916-1921` → `:1714`/`:1733` | direct state mutation mid-selector (`u.wield`/`u.wear_item`), `popup_getkey` on failure | unsupported; **direct mutation** |
| `TOGGLE_FAVORITE` | `src/inventory_ui.cpp:766-771` → `set_stack_favorite` `:692` | direct world mutation mid-selector; the selector-level branch also calls `newwin`-bearing `prepare_layout()` (`:1915`) | unsupported; **direct mutation + window** |

### 5.1 The named distinction this spike establishes: **`test_mode` un-abort witness ≠ renderer-neutral backend UI mode**

Spikes 13B/14/15 are **`test_mode` un-abort witnesses**: each pierces exactly **one** `test_mode` abort
(`uilist::query` `src/ui.cpp:933`; `query_popup::query_once` `src/popup.cpp:277`) at **one** hardcoded site,
under a per-transaction gate, where the data is already populated window-free (`uilist::setup` runs while
**skipping** `newwin` at `src/ui.cpp:638`). That is **not** the same as a general **renderer-neutral backend
UI mode**. The `inventory_selector` exposes the gap between the two precisely:

- There is **no single `test_mode` abort to pierce** — the loop calls `handle_input()` directly. The thing
  that suppresses the selector's layout is the **global** render suppression
  (`ui_adaptor::redraw_invalidated` early-return, `src/ui_manager.cpp:328`), which un-aborting would mean
  **weakening `test_mode` globally** (forbidden) and would *also* fire the window half.
- Window creation is **entangled** with the renderer-neutral layout in one callback, and the selector's
  `newwin` is **not gated** anywhere (contrast `uilist::setup` `src/ui.cpp:638`). Worse, the no-arg
  `prepare_layout()` (which calls `newwin`) is reachable **outside** the suppressed redraw path, via
  `on_input`'s `TOGGLE_FAVORITE` branch (`src/inventory_ui.cpp:1915`) — so the no-window invariant
  (`AGENTS.md:56`) is upheld today only because the "INVENTORY" context is **unserved** (so that action is
  never delivered), not because the code separates choice/input from drawing.

So the selector's **choice/input logic is renderer-neutral in principle** (the `handle_input` loop +
in-memory entries/columns) but is **NOT currently separable from its renderer-specific drawing without new
engine surgery**.

## 6. Selector / input mechanism findings

- **Selector class:** `inventory_pickup_selector` (a `inventory_multiselector` → `inventory_selector`),
  built in `game_menus::inv::pickup_from_tile` (`src/game_inventory.cpp:1699`).
- **Input loop:** `input_context("INVENTORY")` (`src/inventory_ui.cpp:1837`); `get_input()` →
  `ctxt.handle_input()` (`:1887`). Registered actions include `DOWN`/`UP`/`PAGE_*`/`RIGHT`/`LEFT`/`CONFIRM`/
  `QUIT`/`CATEGORY_SELECTION`/`TOGGLE_FAVORITE`/`HOME`/`END`/`INVENTORY_FILTER`/`EXAMINE`/`WIELD`/`WEAR`/
  `ANY_INPUT` (`:1844-1861`), plus `RIGHT`(re-described "Mark/unmark") + `DROP_NON_FAVORITE` from the
  multiselector ctor (`:2103-2104`). For pickup, a single-item selection is `[DOWN×K, RIGHT, CONFIRM]` (RIGHT
  marks the highlighted entry; `src/inventory_ui.cpp:2561`).
- **Result consumption:** `execute()` builds the selection via the **shared** `pickup::optimize_pickup`
  (`src/inventory_ui.cpp:2607`; same function the old path uses at `src/pickup.cpp:1330`) and returns a
  `std::vector<pick_drop_selection>`; `game::pickup` then assigns the **same** `pickup_activity_actor`
  (`src/game.cpp:8783-8784`) the old path assigns (`src/pickup.cpp:1331-1333`). The selector loop runs
  **synchronously inside `handle_action → game::pickup`, before** the activity is assigned. The secondary
  capacity/wield/spill `uilist` (`handle_problematic_pickup`) lives in the **shared activity tail**
  (`src/pickup.cpp:414` via `pick_one_up`/`do_pickup`), reached by **both** paths — Spike 14 already drives it
  at level 4, unchanged.
- **The selection data path** runs through the `selection_column` via `on_change`
  (`src/inventory_ui.cpp:1100-1114`); `CONFIRM` reads it exclusively from `get_selection_column_items()`
  (`:2592`/`:2168`), not from `map_column`. `set_chosen_count` (`:2159`) is the trigger that fills it.

## 7. Equivalence analysis

- **Backend-input level 4 possible (mechanically)?** *Yes in principle.* The selector consumes
  `input_context("INVENTORY")::handle_input()`, the real loop a player uses; the backend could synthesize
  `[DOWN×K, RIGHT, CONFIRM]` (the fourth instance of the `backend_resolve_*` keystroke mechanism) and let the
  loop compute its own selection. **But not as-is:** today "INVENTORY" is **not a served category**
  (`src/arcopolis_backend_input.cpp:1134-1177` serve only `PICKUP`/`UILIST`/`YESNO`), so the guard serves
  `QUIT` (`decide_nested_input` `:1110`) → empty selection → silent no-op. Driving it requires a **new served
  "INVENTORY" category + queue + transaction**, *and* a **new window-free init path** to run the suppressed
  layout pass (so the navigated/exposed entry order, the snapped highlight, and the active column match what a
  player sees), with explicit headless dimensions (TERMX/TERMY are 0 on the `--arcopolis-*` path —
  `init_ui` is bypassed by the `std::_Exit` branches in `src/main.cpp`).
- **Engine equivalence possible?** *Yes, if the above were built* — `optimize_pickup` and
  `pickup_activity_actor` are shared with the old path; the engine would compute and mutate. The risk is the
  **three direct-mutation side channels** (`u.wield`/`u.wear_item`/`set_stack_favorite`,
  `src/inventory_ui.cpp:1714`/`1733`/`692`) that bypass the returned selection entirely — harmless only while
  "INVENTORY" is unserved; if it became served they would be unguarded.
- **External GUI equivalence possible (for this witness)?** *Not demonstrable here.* A frontend would render
  the `map_column` entries (display name + per-unit count) as a selectable list and surface the same
  consequence (items leave the ground → carried). But no external frontend was driven against this path; per
  doc 37/38, frontend equivalence is witnessed today **only** for the planar move/examine surface (Spike
  11B). So even with the mechanism built, the GUI-equivalence claim would be argued, not observed — and the
  spike forbids inferring equivalence from final state.

## 8. What a witness would require — qualitatively, a new selector architecture (seam map, NOT authorization)

This is **not** "one more prompt path." The selector *does* have a real `handle_input()` seam, but driving it
honestly is **qualitatively different** from the Spikes 13B/14/15 `test_mode` un-abort witnesses: there is no
served `"INVENTORY"` branch today (the backend serves only the existing `PICKUP`/`UILIST`/`YESNO` nested
categories, `src/arcopolis_backend_input.cpp:1134-1177`), and the layout/window entanglement means support
would be the **start of a renderer-neutral selector architecture**, requiring at least:

1. **A new served `"INVENTORY"` category** at the seam (a 4th branch parallel to `PICKUP`/`UILIST`/`YESNO`,
   `src/arcopolis_backend_input.cpp:1134-1177`).
2. **A real queue / transaction model** for it (constant, cursor/served counters, a dedicated
   `backend_inventory_mode_active()` gate, begin/end + RAII guard, `backend_resolve_inventory_choice`
   synthesizing `[DOWN×K, RIGHT, CONFIRM]`).
3. **A window-free selector initialization path** — run the 2-arg `prepare_layout(w,h)`
   (`src/inventory_ui.cpp:1420`) directly under the gate (analog of `uilist::query`'s direct `setup()` at
   `src/ui.cpp:957`) so the suppressed sort / category headers / highlight-snap / `refresh_active_column` run.
4. **Chosen headless dimensions** (height > 1; TERMX/TERMY are 0 on the `--arcopolis-*` path) — passed as
   layout arguments, explicitly **not** by writing TERMX/TERMY or creating a window.
5. **Gating or splitting `resize_window()` / `refresh_window()`** (`src/inventory_ui.cpp:1630`/`:1641`,
   currently ungated) and the entangled no-arg `prepare_layout`, including the **`TOGGLE_FAVORITE`** path
   (`:1915`) that reaches `newwin` outside the redraw suppression — so the no-window invariant
   (`AGENTS.md:56`) holds even if a stray action is served. Plus the populate hook exposing the real
   `map_column` entries (analog of the old path's `src/pickup.cpp:761-769`), never a parallel model.
6. **Protection against the dangerous selector actions** the served context would expose — favorite / wield /
   wear / filter / examine (§5) — each made unreachable or fail-loud on the witness path; and the fail-loud
   **narrowed, not removed** (live could narrow in place to the provable single-ground-item / no-vehicle /
   single-stack tile; run-script `src/arcopolis_script.cpp:355` cannot narrow pre-load, so a witness would be
   live-only or need a new per-dispatch guard).

That is a selector-architecture spike, not a one-line un-abort, and every one of these done carelessly lands
on the forbidden list (a fabricated terminal; a global `test_mode` weakening; an ungated `newwin`; directly
setting the selection; item-transfer-as-proof). **This sketch is a seam map, not authorization: it is NOT
authorized by this audit and would need its own design spike before any implementation.**

## 9. Implementation decision — STOPPED AT AUDIT (Outcome A), and why

**Decision: audit-only.** Against the spike's gate — proceed only if (a) the selector has a renderer-neutral
input loop we can drive, or (b) the abort is a *narrow* `test_mode` shortcut over a window-free loop —
neither cleanly holds:

- The input *loop* is renderer-neutral (a), but it is **not drivable without** a new served category **and** a
  new window-free init path; the suppression is the **global** render gate, not a narrow abort, so (b) fails.
- The selector's `newwin` is **ungated and reachable outside `test_mode` suppression**
  (`src/inventory_ui.cpp:1915`); layout and window are **entangled**; there are **no headless dimensions**;
  and there are **three direct-mutation side channels**. Making it "continue" by any shortcut is a forbidden
  move; making it continue *faithfully* is a renderer-neutral selector **architecture** (§8) — **qualitatively
  different from the prior `test_mode` un-abort witnesses, not "one more prompt path" and not "at most one
  minimal witness."**

Per the project's honesty-over-impressiveness reframe, an "equivalent-ish" inventory_selector member (not full
GUI, not true backend, not renderer-neutral) would be **worse than this audit-only result**. So: keep the
fail-loud, document the seam gap, do not force implementation (design shape C).

## 10. What remains unsupported / fail-loud (must remain)

- **`NEW_PICKUP_MENU=true` (the `inventory_selector`) stays fail-loud**, unweakened: live
  `src/arcopolis_live.cpp:213-218` (`unsupported_command`, exit 6) and run-script
  `src/arcopolis_script.cpp:355-359` (exit 6). This is **load-bearing**: without it, the path reaches the
  selector, the unserved "INVENTORY" read is served `QUIT`, `execute()` returns empty, and
  `game::pickup` assigns an **empty** `pickup_activity_actor` — a **silent no-op pickup, exit 0**
  (`src/inventory_ui.cpp:2615` → `src/game.cpp:8783`).
- **Unchanged old PICKUP path** (NEW_PICKUP_MENU=false): `game::pickup`'s `else` (`src/game.cpp:8786`),
  `pickup::pick_up`/`pick_up_from_items`, the Spike 12A gated pre-loop block (`src/pickup.cpp:761`), the
  `input_context("PICKUP")` loop, the Spike 13B vehicle-source `uilist`, and the shared Spike 14
  `handle_problematic_pickup` tail — none touched.
- **Within the selector, even if it were driven:** vehicle cargo (folded into the same selector via
  `add_vehicle_items`), containers / nested children, per-unit quantities (`query_count` string-input),
  filtering (`INVENTORY_FILTER` string-input), `EXAMINE`/`WIELD`/`WEAR`/`TOGGLE_FAVORITE`, multi-column
  navigation, `pickup_nearby`/`pickup_feet`, and the empty-pile `popup(PF_GET_KEY)` — all remain unsupported.

## 11. The Phase-1 audit questions, answered

| # | Question | Answer (cite) |
| --- | --- | --- |
| 1 | Where does `game::pickup` branch when `NEW_PICKUP_MENU=true`? | `src/game.cpp:8781` → `game_menus::inv::pickup_from_tile( g->u, p )` `:8782`, then `assign_activity(pickup_activity_actor)` `:8783-8784` |
| 2 | Which selector/menu class? | `inventory_pickup_selector` (`inventory_multiselector`→`inventory_selector`), `src/game_inventory.cpp:1699`; `execute()` `src/inventory_ui.cpp:2540` |
| 3 | Does it call `input_context::handle_input()`? | **Yes** — `get_input()` → `ctxt.handle_input()` `src/inventory_ui.cpp:1887`; **no `test_mode` abort** in `inventory_ui.cpp` |
| 4 | Context / action ids? | `input_context("INVENTORY")` `:1837`; `DOWN/UP/PAGE_*/RIGHT/LEFT/CONFIRM/QUIT/CATEGORY_SELECTION/TOGGLE_FAVORITE/HOME/END/INVENTORY_FILTER/EXAMINE/WIELD/WEAR/ANY_INPUT` `:1844-1861` + `DROP_NON_FAVORITE` `:2104`. Pickup = `[DOWN×K, RIGHT, CONFIRM]` |
| 5 | Can Arcopolis observe the choices without duplicating selector logic? | Partially — entries live in `map_column` (`add_map_items` `:1314`), but faithful order/headers/highlight require the **suppressed** `prepare_paging`/`refresh_active_column` (`src/inventory_ui.cpp:809`/`:1443`) |
| 6 | Can Arcopolis serve registered actions into the real loop? | **Not as-is** — "INVENTORY" is unserved (`src/arcopolis_backend_input.cpp:1134-1177`); guard serves `QUIT` (`:1110`). Needs a new served category + the layout pass |
| 7 | Where does the engine consume the result? | `pickup_from_tile` returns the selection → `game::pickup` assigns `pickup_activity_actor` `src/game.cpp:8783`; result built by **shared** `optimize_pickup` `src/inventory_ui.cpp:2607` |
| 8 | Smallest safe witness? | **None that is minimal** — see §8 (≈5 new gated touches = a renderer-neutral backend UI mode, not a one-line un-abort) |
| 9 | What would a frontend render? | The `map_column` entries (name + per-unit count) as a selectable list; consequence = items leave ground → carried. Not driven/observed (frontend equivalence proven only for planar move/examine, doc 38) |
| 10 | What old PICKUP code must stay unchanged? | The whole `NEW_PICKUP_MENU=false` path (§10) — `src/game.cpp:8786`, `src/pickup.cpp` PICKUP loop + 12A/13B blocks + shared 14 tail |
| 11 | What docs/fail-loud would change **if proven**? | live/script pre-flight rejects (`arcopolis_live.cpp:213`, `arcopolis_script.cpp:355`), STATE.md fail-loud table + capability rows, doc 37/38 "not yet" lists — **none changed** (no witness) |
| 12 | What must remain unsupported? | Everything in §10 |

## 12. Regression / validation

**Docs + comments + ONE behavior-identical refactor (the §15 split); no behavior change.** Verification
performed:

- `AStyle --options=.astylerc -n` on every touched `.cpp`/`.h` (`arcopolis_command.cpp`, `arcopolis_script.cpp`,
  `arcopolis_backend_input.cpp`, `arcopolis_backend_input.h`, `pickup.cpp`) → all **Unchanged** (CI-formatted).
- **Build + `[arcopolis]` (for the split, run via the main-repo `win-rel-deb` build dir as a sandbox — the
  worktree has none — then the main repo was restored clean):** `cata_test-tiles` + `cataclysm-bn-tiles`
  compiled with **zero errors** (every TU built, including `arcopolis_backend_input.cpp`), and the
  `[arcopolis]` suite **passed — 888 assertions in 139 test cases, exit 0** — confirming the function split is
  behavior-identical. (A post-link `applocal`/`mesa` packaging step failed on an env path the CMake
  re-configure disturbed; `link.exe` produced the exes first, so the test ran from the freshly-linked binary.)
- Overclaim grep over the new doc (`supports inventory_selector|supports new pickup|GUI equivalent|…`) → no
  new overclaim introduced (only sanctioned witness-scoped phrasing).
- The existing `NEW_PICKUP_MENU=true` fail-loud gates (`prompt_menu_regression.ps1` Scenario D,
  `script_prompt_regression.ps1` F5) are **untouched** and remain valid; no engine behavior, wire format,
  transcript event, or fail-loud check changed.

## 13. Follow-up options

- **A — leave as fail-loud backlog (recommended).** `inventory_selector` is a named future un-abort site
  (`AGENTS.md:56`) but not the minimal next step; richer export, `open`/`close`, or NPC interaction are
  smaller. Whether it is ever the next spike is an open product/architecture decision (doc 37 §"a backlog
  candidate, NOT a committed next step").
- **B — renderer-neutral selector mode (the real prerequisite).** If pursued, build §8 as an explicit
  **renderer-neutral backend UI mode** for `inventory_selector` (un-wire/gate `newwin`, split
  `prepare_layout`, new served "INVENTORY" queue, chosen headless dims, guard the three direct-mutation side
  channels), witness one ground item, keep every other variant fail-loud. Larger than 13B/14/15.
- **C — comment/doc hygiene (done here).** Done: the stale `src/arcopolis_command.cpp` pickup comment, the
  `src/arcopolis_script.cpp` "auto-resolves" gloss (§15), **and** the name-drift split — the monolithic
  `clear_stale_nested_input()` (`src/arcopolis_backend_input.cpp:133`), which also cleared the
  pickup/uilist/query_popup transactions, is now four per-concern helpers (`clear_stale_nested_input` /
  `clear_stale_pickup_transaction` / `clear_stale_uilist_transaction` / `clear_stale_query_popup_transaction`)
  behind a `clear_stale_backend_prompt_state()` wrapper, behavior-identical (same statements, same transcript
  order). The single caller (`next_backend_action`) and the referencing comments were updated.
- **D — fail-loud pointer (optional, NOT done).** The live/script error strings could append a pointer to
  this audit; deferred because they are user-facing wire output matched by regression substrings — propose
  before touching.

## 14. Claim → cite → verdict audit

Per [[cite-the-implementing-line]] — load-bearing claims, verified at the implementing line this session
(static reads; **no build/run** — see the method caveat).

| Claim | Cite | Type | Verdict |
| --- | --- | --- | --- |
| `game::pickup` branches on `NEW_PICKUP_MENU`; true → `pickup_from_tile` + `pickup_activity_actor` | `src/game.cpp:8781-8784` | behavioral | ✅ verified |
| Selector is `inventory_pickup_selector`; `execute()` is the loop | `src/game_inventory.cpp:1699`; `src/inventory_ui.cpp:2540` | structural | ✅ verified |
| Loop reaches `input_context("INVENTORY")::handle_input()`; **no `test_mode` abort** in `inventory_ui.cpp` | `src/inventory_ui.cpp:1837`,`:1887`; grep | behavioral/absence | ✅ verified |
| Layout + window share one suppressed callback; no-arg `prepare_layout` does 2-arg layout **then** `newwin` | `src/inventory_ui.cpp:1471`,`:1446-1463`,`:1630` | behavioral | ✅ verified |
| The resize/redraw callbacks never fire under `test_mode` | `src/ui_manager.cpp:328` | behavioral | ✅ verified |
| 2-arg `prepare_layout(w,h)` is window-free; needs height > 1 (TERMX/TERMY = 0 headless) | `src/inventory_ui.cpp:1420-1444`,`:548`; `src/output.cpp:49` | behavioral | ✅ verified |
| Selector `newwin` is **ungated**; reachable outside redraw via `TOGGLE_FAVORITE` `on_input` | `src/inventory_ui.cpp:1628-1631`,`:1915` | behavioral | ✅ verified (vs gated `uilist::setup` `src/ui.cpp:638`) |
| "INVENTORY" is **not** a served category; guard serves `QUIT` → empty → silent no-op | `src/arcopolis_backend_input.cpp:1134-1177`,`:1110`; `src/inventory_ui.cpp:2615`; `src/game.cpp:8783` | behavioral | ✅ verified |
| `add_vehicle_items` folds vehicle cargo into the **same** selector (no "Get items from where?" uilist) | `src/game_inventory.cpp:1708`; `src/inventory_ui.cpp:1334` | behavioral | ✅ verified |
| Result via **shared** `optimize_pickup`; **same** `pickup_activity_actor` as old path | `src/inventory_ui.cpp:2607`; `src/pickup.cpp:1330-1333` | behavioral | ✅ verified |
| Three direct-mutation side channels (wield/wear/favorite) bypass the returned selection | `src/inventory_ui.cpp:1714`,`:1733`,`:692` | behavioral | ✅ verified |
| Fail-loud lives at the two pre-flight sites, exit 6 | `src/arcopolis_live.cpp:213-218`; `src/arcopolis_script.cpp:355-359` | behavioral | ✅ verified |
| `inventory_selector` is a named future un-abort site that must uphold the no-window invariant | `AGENTS.md:56` | structural | ✅ verified |

**Residual uncertainties (kept, not polished away):** (1) the silent-no-op chain and the "would-need" witness
behavior are reasoned from leaves, **not run** (the path is rejected pre-flight, so it cannot be exercised
without code changes); (2) TERMX/TERMY = 0 is established from `init_ui` being bypassed, not a live print —
no loader-internal setter was exhaustively excluded; (3) per-unit count, container child marks, and the exact
driven action sequence for a multi-stack/headerful pile were not nailed (out of the witness scope and audit
remit).

## 15. Comment corrections made by this audit (code; no behavior change)

1. **`src/arcopolis_command.cpp`** — the pickup comment that said *"Script/one-shot modes resolve the verb but
   arm no transaction, so the menu auto-cancels"* was **stale** after Spike 16: `--arcopolis-run-script`
   **does** arm the pickup transaction + install the script prompt sources when the step declares
   `prompt_answers` (`next_backend_action` `src/arcopolis_backend_input.cpp:578-584`). Rewritten to: live +
   run-script-with-`prompt_answers` drive; one-shot `--arcopolis-command` has no channel and is rejected;
   `NEW_PICKUP_MENU=true` → inventory_selector, rejected (pointer to this audit).
2. **`src/arcopolis_script.cpp`** — the `parse_prompt_answers` comment *"absent is fine (…or a prompt the
   engine auto-resolves)"* glossed a **silent default**: an unguarded examine `query_yn` `test_mode`-aborts to
   **NO** (`src/popup.cpp:277` → `src/output.cpp:748`; doc 38). Tightened to say a player-visible prompt with
   no declared answer must be witnessed as no-choice or fail loud, not glossed as "auto-resolved."

3. **`src/arcopolis_backend_input.cpp` + `.h`** — the misleadingly-named `clear_stale_nested_input()`, which
   also cleared the pickup/uilist/query_popup transactions (name drift), is **split** into four per-concern
   helpers (`clear_stale_nested_input` / `clear_stale_pickup_transaction` / `clear_stale_uilist_transaction` /
   `clear_stale_query_popup_transaction`) behind a `clear_stale_backend_prompt_state()` wrapper —
   behavior-identical (same statements, same transcript order). The single caller (`next_backend_action`) and
   the referencing comments (incl. `src/pickup.cpp`) were updated.

(All three verified at the leaf; the first two surfaced by the independent review, the third its "do not
block" cleanup, done here at the user's request.)

## Summary

The `inventory_selector` (`NEW_PICKUP_MENU=true`) path reaches BN's real `input_context("INVENTORY")` loop, so
its choice/input logic is renderer-neutral **in principle** — but it is **not separable from its
renderer-specific drawing without new engine surgery**: there is no narrow `test_mode` abort to pierce (the
suppression is global), the window creation is entangled with the layout pass and **ungated** (and reachable
outside the `test_mode` suppression via `TOGGLE_FAVORITE`), there are no headless dimensions, "INVENTORY" is
an unserved category, and the selector carries three direct-mutation side channels. A faithful witness is the
**start of a renderer-neutral selector architecture** (a new served `"INVENTORY"` category + queue/transaction
model + window-free init + chosen headless dimensions + gated/split `resize_window`/`refresh_window` +
protection against favorite/wield/wear/filter/examine) — **qualitatively different from the prior `test_mode`
un-abort witnesses, not one more prompt path** — so this spike **stops at audit** and authorizes nothing. The
`NEW_PICKUP_MENU=true` **fail-loud remains** (and is load-bearing against a silent no-op pickup). This is **one
`inventory_selector` feasibility audit**, not generic `inventory_selector` support, and **no `NEW_PICKUP_MENU`
path** was driven, witnessed, or proven.
