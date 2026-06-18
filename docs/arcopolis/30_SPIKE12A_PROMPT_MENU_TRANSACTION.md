# Arcopolis Spike 12A — GUI-equivalent prompt/menu transaction (pickup witness)

> **Superseded in part (Spike 16, 2026-06-18,
> [36_SPIKE16_SCRIPT_PROMPT_ANSWERS.md](36_SPIKE16_SCRIPT_PROMPT_ANSWERS.md)):** the "live mode only" /
> "script/one-shot modes have no answer channel" claims below now hold only for **one-shot
> `--arcopolis-command`**. A **`--arcopolis-run-script`** command step may declare `prompt_answers`, which the
> script prompt sources feed into the SAME `backend_resolve_*` machinery this spike built — so the old
> `"PICKUP"` menu is now drivable non-live at level 4 too (a missing/wrong/unused answer fails loud,
> `script_prompt_failed`/exit 13). A run-script pickup with NO declared answers, and every one-shot pickup,
> still fail loud (exit 6). This historical record is otherwise accurate as of its date.

**Status: implementation + decision record (2026-06-14).** This spike answers, end-to-end, whether
Bright Nights can enter a _real_ in-action prompt/menu flow, expose that prompt to an external client,
accept the client's answer, continue the _same_ engine action, and return a truthful final
snapshot/transcript — with no fake state, no direct mutation, and no hidden auto-cancel-as-success.

It builds **doc 25's "Option C — prompt-aware protocol"** (deferred there as premature) for **one** prompt
class: the **item-pickup menu**. The bar is the merged AGENTS.md **"Arcopolis backend input equivalence
(NON-NEGOTIABLE)"** rule — **equivalence level 4**: the supported interactive action is driven by the
_same registered input actions, in the same order, consumed by the same active engine input loop_ a player
would use, never by mutating menu/selection state directly.

## Target witness

The **`pickup` command** (`ACTION_PICKUP`) against `ArcopolisTest`'s deterministic in-window ground items
(Spike 8A). Pickup was chosen because it is a real player action, reaches a real BN selection menu, mutates
real engine state, and is validatable through ground items + messages + moves + transcript.

## GUI path traced from ACTION_PICKUP (read at the implementing line)

```
ACTION_PICKUP                                  (src/handle_action.cpp:2299-2309)
 -> game::pickup()                             (src/game.cpp:8761)
    -> choose_adjacent_highlight("Pickup where?", ACTION_PICKUP, allow_vertical=false)  (:8763)
       == the SAME planar adjacent chooser examine uses (Spike 11A one-shot answer serves it)
 -> game::pickup( const tripoint_bub_ms &p )   (src/game.cpp:8773)
    -> NEW_PICKUP_MENU false (DEFAULT, src/options.cpp:1861-1864)
       -> pickup::pick_up(p, 0)                (src/game.cpp:8786)
          -> pick_up_from_items(here, min=0, pos)   (call src/pickup.cpp:1343 -> def :628)
             min=0 -> single-item auto-grab branch SKIPPED (:636) -> the menu ALWAYS shows
             entries  = stacked_here  (local, src/pickup.cpp:643-646)
             selection= getitem[i].pick / .count (local, :647)
             input_context "PICKUP" registers UP/DOWN/LEFT/RIGHT/CONFIRM/SELECT_ALL/QUIT  (:741-757)
             loop: ui_manager::redraw(); action = ctxt.handle_input();  (:1183-1184)
                   do{...}while(action != "QUIT" && action != "CONFIRM")  (do :930, while :1187)
             RIGHT (when !picked) -> idx=selected (:988-991) -> ENGINE sets selected_stack.pick (:1095)
             CONFIRM + >=1 selected -> optimize_pickup -> assign_activity(pickup_activity_actor(targets,pos))  (:1240-1243)
             else -> "Never mind." return (cancel)  (:1196-1199)
```

## Prompt/menu mechanism identified

A raw `input_context("PICKUP")` loop — the **old** picker. Not a `uilist`, not a `query_popup`, not the
`inventory_selector`. The `NEW_PICKUP_MENU` inventory_selector path is a **different** mechanism and is
**not** supported (see Scope). The GUI player sees the ground-item entries, navigates with the registered
actions, marks an entry, and confirms; the engine then queues a real `pickup_activity_actor` that transfers
items and spends `moves` (100/item: `moves_taken = 100` at src/pickup.cpp:262, deducted at :434).

## What the client sees / answers — and what Arcopolis must NOT fake

- **Sees:** a structured `prompt` event whose `choices` are the engine's **real** `stacked_here` entries
  (display name + index), read live — never synthesized from a snapshot.
- **Answers:** a `prompt_answer` carrying a `choices` array — one or more entry indices to select in a
  single menu visit (a single `choice:K` is still accepted) — or a `prompt_cancel`.
- **Must not fake:** the choice list (comes from the live menu), the selection (done by the engine loop),
  the item transfer (the engine's activity), or the move cost. No direct `getitem`/stack/inventory/activity
  mutation; no hidden auto-cancel presented as success.

## Equivalence framing (LEVEL 4 — stated exactly, do not soften)

```
same engine action          ACTION_PICKUP via handle_action
same active input loop       input_context("PICKUP")::handle_input() (src/pickup.cpp:1184), UNMODIFIED
same registered actions      DOWN x K, RIGHT, CONFIRM (or QUIT) -- exactly a player's keystrokes, in order
same selection mutation      done by the engine loop (selected_stack.pick, src/pickup.cpp:1095), NEVER by Arcopolis
same finalization/activity   optimize_pickup (src/pickup.cpp:1240) -> pickup_activity_actor (:1241)
ONLY difference              the answer's TRANSPORT: a JSON prompt + choice index(es), not curses keypresses
```

The chosen indices are translated into the registered keystrokes a GUI player would press. The indices are
sorted and de-duplicated, then walked **forward only** from the cursor's start at entry 0: for each chosen
index, `DOWN` × (delta from the previous cursor) to reach it, `RIGHT` to mark it, and a single trailing
`CONFIRM` to finalize. One choice `K` → `K`×`DOWN`, `RIGHT`, `CONFIRM`; two choices `[5,6]` → the witnessed
`[DOWN×5, RIGHT, DOWN, RIGHT, CONFIRM]`. The sequence is queued and served one action per blocking
`handle_input` read to the engine's own `"PICKUP"` loop. The loop reacts exactly as to a keypress; **the
engine performs every `getitem` mutation and the item transfer.** This is **not** a `getitem` write +
fall-through (the rejected design / a guardrail violation).

`matches == stacked_here` (so K maps to entry K) holds because no `FILTER` is ever sent and an empty filter
is match-all (the filter-build loop at src/pickup.cpp:1131-1135 + src/item_search.h:19-24). Navigation is
**forward `DOWN` only**: headless `on_screen_resize` never fires (`ui_manager::redraw` is a `test_mode`
no-op, src/ui_manager.cpp:328), so `maxitems` stays `0` and `UP`/`PREV_TAB` would divide by zero
(src/pickup.cpp:972 and :956) — the queue is strictly `DOWN`/`RIGHT`/`CONFIRM`/`QUIT`.

## Protocol added (additive; existing commands keep one-request/one-response)

- **Command:** `{"op":"command","command":"pickup","direction":"<planar|here>"}` — reuses the existing
  `direction` field, served to the "Pickup where?" chooser by the Spike 11A one-shot slot. The menu answer
  is a **separate** exchange, never pre-supplied.
- **Prompt event (backend→client, mid-command):**
  `{"type":"prompt","id":<cmd-id>,"prompt_id":<n>,"kind":"menu","title":"Pick up which items?","choices":[{"index":0,"text":"…","enabled":true},…],"cancelable":true}`
  — **every exposed entry is `enabled:true`** (the GUI never disables them; see Scope).
- **Answer (client→backend):** `{"op":"prompt_answer","id":<n>,"prompt_id":<n>,"choices":[K,…]}` (a single
  `"choice":K` is still accepted); cancel = `{"op":"prompt_cancel","id":<n>,"prompt_id":<n>}`.
- **Wire behavior:** a valid answer (a non-empty `choices` array, every index in range) → `ok:true` ack,
  then the command's terminal `response` at the next input-rest; an **invalid** answer — an empty array or
  any out-of-range index → `ok:false`, the **prompt stays open** for a retry (no engine state touched),
  mirroring the GUI menu ignoring an unbound key; **cancel / EOF** → the engine's "Never mind." no-op,
  `ok:true`, session stays ready. The backend cannot hang: EOF mid-prompt is a clean cancel, and the
  regression imposes a strict external per-response timeout.

## Transcript events added (`session.jsonl`)

`prompt_opened` (step_index, kind, the real choices) · `prompt_answered` (the `choices` array + the served
action sequence `[DOWN…,RIGHT,…,CONFIRM]`) · `prompt_cancelled` (reason) · `prompt_failed` (a rejected/invalid
attempt; prompt stayed open) · `prompt_completed` (actions_served — the count the engine loop consumed). A
reader can reconstruct: which command opened the menu, the real choices, the answer, the registered actions
it became, that the engine consumed them, and (via the command's `export` record) the final state change.

## Source code

- `src/arcopolis_command.{h,cpp}` — `pickup` verb; the examine direction helpers generalized to
  `target_direction_answers` / `target_direction_nested_answer` / `is_supported_target_direction` (examine
  and pickup share the `allow_vertical=false` chooser).
- `src/arcopolis_backend_input.{h,cpp}` — a DISTINCT `pickup_transaction` flag + `pickup_action_queue` (the
  existing one-shot serve gate is hard-coded to the `"DEFAULTMODE"` chooser, so the queue needs its own
  serve branch in `backend_nested_input_action`, after the `timeout>=0` pass-through); a pluggable
  `prompt_source` hook; `backend_resolve_pickup_choice` (reads choices, asks the client, arms the queue);
  queue + flag cleared at the seam return (`clear_stale_nested_input`).
- `src/arcopolis_live.{h,cpp}` — `prompt`/`prompt_answer` wire format + `parse_prompt_answer`; the live
  `prompt_source` (`live_pickup_prompt`); arms the transaction for a live `pickup`; **fails loud
  (`unsupported_command`) if `NEW_PICKUP_MENU` is true**.
- `src/arcopolis_session_log.{h,cpp}` — the five `prompt_*` transcript events.
- `src/pickup.cpp` — a minimal gated pre-loop block inside the existing `else`, before the UNMODIFIED loop:
  builds choices from `stacked_here` (**all exposed entries enabled** — the GUI never disables them), calls
  `backend_resolve_pickup_choice`. No `getitem` touch.

## Scope (named, not glossed)

- Supported: the **old `"PICKUP"` menu**, **live mode only**, **`NEW_PICKUP_MENU=false`**. The client may
  select **one or many** entries in a single menu visit (multi-select), each driven as a real `RIGHT` mark.

### Gaps — characterized as defects, not "acceptable limitations"

Per the merged equivalence rule, a documented subset of a GUI primitive is a **tracked defect**, not a soft
limitation. The three gaps from the design review are recorded here as such; two are now fixed.

1. **Container / parent-child entries — disabling removed; nested path UNEXERCISED & UNWITNESSED (open
   defect).** Arcopolis no longer disables container entries; **every exposed `stacked_here` entry is
   `enabled:true`**, exactly as the GUI shows them — the self-imposed `enabled:false` restriction is gone.
   The engine's own loop _would_ propagate a parent's mark to its children (`src/pickup.cpp:1107-1123`),
   with Arcopolis not special-casing it. But that path is **not exercised** by this fixture: `children` is
   populated only by `calculate_parents` (`src/pickup.cpp:648-653`) for drop-token-grouped items, and the
   witness pile's only container (the protein ration's resealable bag) surfaces as a **single** `stacked_here`
   entry, not an expanded parent with separate child entries. So `selected_stack.children` is empty for every
   entry, the propagation loop body never runs, and the regression only ever marks flat distinct entries.
   This path is therefore **neither exercised nor witnessed** — a tracked open defect, _not_ a merely
   "unwitnessed" one. Closing it needs a nested-container witness (a container whose contents list as child
   entries).
2. **Per-unit quantity — UNFIXED, tracked defect (deferred).** Selecting an entry takes its ENTIRE stack; the
   client cannot pick N of M. `RIGHT` is served with no preceding digit, so `getitem.count` stays unset and
   finalization takes the full stack (`src/pickup.cpp:1204-1228`); the digit/count keystrokes a GUI player
   would type before `RIGHT` are not driven. This is a real GUI capability Arcopolis does not yet reproduce —
   a defect to close (drive the count keystrokes), not an acceptable scope cut. The witness uses distinct
   single-unit entries so "pick entry K" is unambiguous, but that does not make the gap acceptable.
3. **Multi-entry selection — FIXED (level 4), witnessed.** `prompt_answer.choices` accepts an array; the arm
   builds one `RIGHT` mark per chosen entry, navigated forward by `DOWN`, terminated by a single `CONFIRM`
   (`[DOWN×5, RIGHT, DOWN, RIGHT, CONFIRM]` for `[5,6]`). The engine's loop performs both marks. Witnessed by
   the regression's carry-both gate on the backpack avatar (`ArcopolisBackpackTest`): two distinct entries
   leave the ground (7 → 5) in one menu visit. (Carry-both needs real capacity — see the next section.)

### Secondary in-activity prompts are NOT YET DRIVEN — a tracked defect (now MARKED; see doc 31)

> **Follow-up update (doc 31):** still not _driven_, but no longer silent. The command response is now
> explicitly marked `{ forced_cancel, partial, unsupported_prompt:"secondary_capacity" }` and the transcript
> records `prompt_force_cancelled`. The mechanism note below is also corrected there: in test_mode the
> secondary `uilist` auto-errors (`UILIST_ERROR`) and never reaches the guard — it is reported by a gated
> `src/pickup.cpp` call site, not "force-cancelled by the guard."

After `CONFIRM`, the `pickup_activity_actor` may itself raise a **secondary** prompt for an item it cannot
trivially stash — "too heavy" / "not enough capacity" / bucket-spill / wield-swap — via
`handle_problematic_pickup`'s `uilist` (`src/pickup.cpp:165-210, 320-346`). **Driving these is not
implemented**: the transaction answers only the top-level `"PICKUP"` menu, so the secondary query is
cancelled (no answer channel is armed for it), the client can only ever reach its "cancel" branch, and
the activity halts on that item (`src/pickup.cpp:440,459`). This is an **open defect** — drive the secondary
capacity/wield/spill prompts as their own transactions — **not** a supported path; the forced-cancel is a
not-yet-implemented gap, not fidelity, and should not be described as "the player declining."

What the spike _does_ guarantee is that the current behaviour stays **honest** rather than faking the part it
cannot do: a multi-select deposits only what the avatar can actually carry, and any item it cannot carry is
left on the ground and never logged as picked up. The regression pins both directions, on two avatars:

- **Rejected items** — on the default `ArcopolisTest` avatar (basic clothes, room for ~one small item),
  selecting `[0,6]` (the bulky 500 ml blanket + the tiny glass shard) carries only the shard; the
  over-capacity blanket **stays on the ground and is never logged as picked up**, while the transcript still
  shows the client's full two-entry intent (two `RIGHT` marks). No fake success.
- **Carry-both** — on `ArcopolisBackpackTest` (a copy of the same world whose avatar additionally wears a
  backpack), the same kind of two-entry selection deposits **both** items, confirming the single-item
  outcome above was the avatar's capacity, not a selection-mechanism limit.

### Known silent-cancel-as-success holes — FIXED in the follow-up (doc 31)

The "no hidden auto-cancel-as-success" guarantee held for the **witnessed** path (live-mode, ground-item
`pickup`). Two ADJACENT paths the fixture never exercised violated it; both are now **fixed** in
[31_SPIKE12A_FOLLOWUP_FAIL_LOUD.md](31_SPIKE12A_FOLLOWUP_FAIL_LOUD.md):

- **Vehicle-cargo tile, live mode (FIXED → fail loud).** A tile with BOTH vehicle cargo and ground items
  makes `pickup::pick_up` open a `uilist( "Get items from where?" )` (`src/pickup.cpp:1268`) BEFORE the
  `"PICKUP"` menu. **Mechanism correction:** in test_mode this `uilist` auto-errors (`UILIST_ERROR`) at the
  top of `uilist::query` (`src/ui.cpp:918`) and never reaches the nested-input guard; `pick_up` would then
  fall through to a _silent ground-only pickup_ (not "no pickup"). The follow-up intercepts it at the engine
  call site (gated) and **fails loud** — `ok:false`/`unsupported_command`, no prompt, transcript
  `prompt_force_cancelled kind=vehicle_submenu`. Witnessed by gate H on `ArcopolisVehicleCargoTest`.
- **Non-live (`--arcopolis-run-script` / one-shot `--arcopolis-command`) mode (FIXED → fail loud).** `pickup`
  is now `is_live_only_command()` and rejected at the non-live pre-flight with `unsupported_command`
  (exit 6) before the world load. Witnessed by gate I.

### Not supported (named backlog)

The `NEW_PICKUP_MENU` inventory_selector, `WEAR`/`WIELD`, `SELECT_ALL`, filtering, pagination, and every
non-pickup menu class (`uilist`, `query_popup`, `string_input`, computer). Script/one-shot modes have no
answer channel, so a pickup there now **fails loud** with `unsupported_command` (doc 31), instead of the
earlier silent auto-cancel-as-success.

This is a **feasibility bridge for one prompt class**, named as such — not generic prompt/menu support.

## Validation — PASS (2026-06-14, RelWithDebInfo + ccache, MSVC)

Gated by [`prompt_menu_regression.ps1`](prompt_menu_regression.ps1) (driver
[`prompt_menu_live_driver.py`](prompt_menu_live_driver.py)) on `ArcopolisTest`, one persistent
`--arcopolis-live` backend per scenario, strict per-response timeout (a hang KILLS + FAILS). Witness: after
one `move_s`, the tile one south of the avatar holds a **7-item ground pile**; `pickup direction=move_s`
targets it.

Fixture config is pinned in the sandbox `options.json` (deployment config, never overridden in memory —
doc 25 design point 2): `AUTOSELECT_SINGLE_VALID_TARGET=false` (so "Pickup where?" always prompts) and
**`AUTO_PICKUP=false`** (so the master auto-pickup system never silently grabs the witness pile during the
`move_s` approach — the `pickup` command is the always-menu `min=0` path, not the `min=-1` autopickup path,
but this keeps the witness deterministic across fixture drift). `NEW_PICKUP_MENU` defaults `false` (absent
from the fixture) for A–C; scenario D inserts it `true` to prove the fail-loud.

Two fixtures back the multi-select gates (both documented in the fixture `README.md`). The default
`ArcopolisTest` avatar wears only basic clothing — room for ~one small item — so it witnesses the
**rejected-items** path: a two-entry selection deposits only what fits, leaving the over-capacity item on
the ground (never faked as picked up). A **third fixture, `ArcopolisBackpackTest`** (a copy of `ArcopolisTest` whose avatar
additionally wears a backpack), supplies the carrying capacity needed to witness **carry-both**: the same
kind of two-entry selection deposits both items. `ArcopolisTest`'s avatar/world **state is unchanged**
(its `.sav` is content-identical to the pre-spike save — same character, position, worn list, turn, and
monsters; only the file's on-disk timestamp was touched when the backpack copy was made), so every other
spike's regression is unaffected.

- **Real menu, real choices:** the `pickup` opened a `prompt` with **7 choices**, each text matching a
  ground item on that tile (read live from `stacked_here`, not the snapshot).
- **Level-4 selection (the headline):** answering **choice 6 (the last entry)** drove the engine's own
  loop with the served sequence **`[DOWN, DOWN, DOWN, DOWN, DOWN, DOWN, RIGHT, CONFIRM]`** —
  `prompt_answered` records exactly that, `prompt_completed actions_served=8`. Six real `DOWN`
  keystrokes navigated the menu (discrimination proof), `RIGHT` marked it, `CONFIRM` finalized.
- **Real state change:** the south tile went **7 → 6** ground items, the chosen `glass shard (1)` left the
  ground (others remained), the engine logged `You pick up: 1 glass shard (1)`, and the turn advanced
  (`1324802 → 1324804`) across the pickup activity + the follow-up `wait`. No `getitem`/inventory mutation
  by Arcopolis — the engine loop selected and its `pickup_activity_actor` transferred.
- **Multi-select carry-both (level-4, witnessed, `ArcopolisBackpackTest`):** answering `choices:[5,6]` drove
  the engine's own loop with **`[DOWN, DOWN, DOWN, DOWN, DOWN, RIGHT, DOWN, RIGHT, CONFIRM]`** — two real
  `RIGHT` marks in one menu visit (`prompt_answered.choices == [5,6]`, `actions` exactly that). The south
  tile went **7 → 5**: both the FEMA pamphlet and the glass shard left the ground while the other five
  entries remained, and the engine logged a `You pick up:` line per item.
- **Rejected items (honest partial pickup, `ArcopolisTest`):** on the no-backpack avatar, answering
  `choices:[0,6]` (over-capacity blanket + shard) carried only the shard (**7 → 6**); the rejected blanket
  **stayed on the ground** and was **never** logged as picked up, while the transcript still recorded both
  `RIGHT` marks. The in-activity capacity `uilist` was force-cancelled by the guard (driving it is a tracked
  defect — see above), so the engine carried only what fit; nothing was faked.
- **Cancel:** `prompt_cancel` was the GUI ESC path — `ok:true` no-op, `Never mind.`, all 7 items untouched.
- **Invalid recovery:** an out-of-range `choice` answered `ok:false`/`bad_request` with the **prompt still
  open**; a follow-up valid answer completed the **same** command.
- **`NEW_PICKUP_MENU=true` fail-loud:** the `pickup` was rejected `ok:false`/`unsupported_command` with **no
  prompt emitted** (no silent route to the unsupported inventory_selector); the session still served a
  later `wait`.
- **No hang; clean exit 0** on every scenario.

**No-regression:** `[arcopolis]` unit suite 582 assertions / 83 cases pass; `examine_regression.ps1` (its
pickup tail still auto-cancels — the critical check), `movement_`, `live_protocol_`,
`client_harness_regression.ps1`, `frontend_prototype_regression.ps1` (18 gates), and the
`item_`/`monster_`/`npc_export_regression.ps1` trio all exit 0. The backpack lives in the **new**
`ArcopolisBackpackTest` fixture only — `ArcopolisTest`'s state is unchanged (content-identical save) — and snapshots never export worn items
or inventory, so carrying capacity is invisible to every non-pickup regression regardless.

**Answer to the spike's question: YES.** Bright Nights can enter a real in-action menu, expose it
externally, accept a client answer, drive the _same_ engine action with the _same_ registered inputs a
player would press, and return a truthful state change — for the old pickup menu, at equivalence level 4,
with no fake state and no hidden auto-cancel. That guarantee is **witnessed for the live-mode ground-item
path**; the two adjacent paths in "Known silent-cancel-as-success holes" (a vehicle-cargo submenu, and
non-live mode) are tracked defects fixed in a follow-up, not part of the witnessed claim. Generic
prompt/menu support is **not** claimed; this is the one-prompt-class feasibility bridge described above.
