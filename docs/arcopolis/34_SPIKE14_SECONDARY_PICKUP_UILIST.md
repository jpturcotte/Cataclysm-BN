# Arcopolis Spike 14 — drive the secondary pickup capacity/wield/spill `uilist` at level 4

**Status: implementation + decision record (2026-06-16).** The second backend-driven `uilist` path, building
on Spike 13B's mechanism ([33_SPIKE13B_BACKEND_DRIVEN_UILIST.md](33_SPIKE13B_BACKEND_DRIVEN_UILIST.md)). The
witness is the **in-activity capacity/wield/spill** `uilist` raised by `pickup_activity_actor` via
`handle_problematic_pickup` (`src/pickup.cpp:165`) when a picked item does not fit. Spike 12A's follow-up
([31_SPIKE12A_FOLLOWUP_FAIL_LOUD.md](31_SPIKE12A_FOLLOWUP_FAIL_LOUD.md)) made that prompt **MARKED**
(`forced_cancel`/`partial`/`unsupported_prompt:"secondary_capacity"`). Spike 14 **DRIVES** it: the same
Spike 13B mechanism (`backend_ui_mode_active` un-abort gate, `backend_resolve_uilist_choice` queue,
`input_context("UILIST")::handle_input` loop) is reused unchanged at a second site.

> **Equivalence level proved: 4.** The chosen entry (WEAR/WIELD/EMPTY/SPILL, or QUIT) is produced solely
> by registered `UILIST` actions (`DOWN`/`CONFIRM`/`QUIT`) consumed by the **real** `uilist` loop through
> `input_context::handle_input()`, which sets `amenu.ret`. Arcopolis never mutates
> `ret`/`selected`/`fentries` as a substitute for input.

## Target witness

Two witnesses on two fixtures, both run by [`prompt_menu_regression.ps1`](prompt_menu_regression.ps1):

- **Gate E (single-entry, `ArcopolisTest`)** — the existing 7-item pile witnesses the **WIELD-blanket**
  path: a multi-select `[0,6]` on the PICKUP menu (over-capacity blanket + tiny shard) raises the secondary
  capacity uilist for the blanket. The avatar is unarmed and the blanket is not armor, not a bucket, no
  children, so the uilist has exactly **one** entry: `Wield blanket`. Answering `choice:0` (WIELD) serves
  `[CONFIRM]` (no DOWN; position 0) through `input_context("UILIST")`; the engine sets `amenu.ret = WIELD`
  and `pick_one_up` calls `u.wield` — the blanket leaves the ground AND becomes `primary_weapon`. The
  shard is stashed; the south tile goes 7 → 5. (Spike 12A's old Gate E asserted force-cancel markers; Spike
  14 converts it to drive, since the markers would now be testing the old bug.)
- **Gate J (multi-entry, `ArcopolisCapacityTest`)** — a clone of `ArcopolisTest` with ONE bulky armor item
  (**`jacket_leather`**, `data/json/items/armor/coats.json`: ARMOR/OUTER, 4500 ml, not a bucket, no
  children) injected onto the south pile via [`make_capacity_fixture.py`](make_capacity_fixture.py).
  Picking the jacket exceeds the unarmed avatar's volume capacity, so the secondary uilist opens with
  exactly **two** entries — `Wear leather jacket` + `Wield leather jacket` — both **enabled** (the WEAR
  entry's `enabled` comes from `u.can_wear(it).success()`, which succeeds against the avatar's basic
  underwear). DOWN navigation is exercised: `choice:1` (WIELD) → served `[DOWN, CONFIRM]` → engine wields;
  `choice:0` (WEAR) → served `[CONFIRM]` → engine wears.

## Source audit (read at the implementing line)

```
pickup::do_pickup -> pick_one_up                            src/pickup.cpp:267
  with_det branch -> handle_problematic_pickup              src/pickup.cpp:336 / :345 / :354
                                                            (too heavy / bucket nonempty / no capacity)
handle_problematic_pickup                                   src/pickup.cpp:165
  if( offered_swap ) return CANCEL                          src/pickup.cpp:168-170
  Spike 14 drive-or-fall-back block                         src/pickup.cpp:172-200 (new)
    drive = pickup_transaction_active && uilist_prompt_available
    !drive && pickup_transaction_active
      -> backend_report_pickup_secondary_forced_cancel       (no-channel fallback, doc 31 markers)
      -> return CANCEL
    drive -> backend_begin_uilist_transaction                (must precede uilist ctor; init() reads gate)
  uilist_transaction_guard                                  (RAII, inert if not armed)
  uilist amenu; amenu.text = explain;                       src/pickup.cpp:186-188
  offered_swap = true; addentry(WEAR if armor); addentry(WIELD); addentry(EMPTY if has_children);
    addentry(SPILL if bucket_nonempty)                       src/pickup.cpp:190-212
  drive -> build backend_uilist_prompt_request from amenu.entries
        -> backend_resolve_uilist_choice                     (logs prompt_opened/answered/cancelled,
                                                              arms the registered-action queue)
  amenu.query()                                             src/pickup.cpp:214 (under the gate: runs setup()
                                                              headless, no newwin, real handle_input loop)
  int choice = amenu.ret                                    src/pickup.cpp:215
  clamp + cast -> pickup_answer                             src/pickup.cpp:217-221

Shared Spike 13B gates (unchanged):
  uilist::init test_mode abort                              src/ui.cpp:159-162 (gated on !backend_ui_mode_active)
  uilist::query test_mode abort                             src/ui.cpp:933-937 (gated on !backend_ui_mode_active)
  uilist::query setup() direct call under gate              src/ui.cpp:957-959
  uilist::setup() newwin skip under gate                    src/ui.cpp:638-643
  backend_nested_input_action "UILIST" serve branch         src/arcopolis_backend_input.cpp:653-662
```

**The load-bearing timing fact.** The pickup activity drains in the **same `do_turn` iteration** as the
original `ACTION_PICKUP` dispatch — `game::do_turn` calls `game::process_activity()` right after
`game::handle_action()` returns. `next_backend_action()` (which calls `clear_stale_nested_input` and
**clears `pickup_transaction`**) is NOT called between the CONFIRM and the secondary uilist. So the gating
on `arcopolis::backend_pickup_transaction_active()` continues to hold at `handle_problematic_pickup`'s call
site for a single-tick activity — the same flag the doc-31 fail-loud check already relies on. See "Hard
acceptance criteria" below for the multi-tick edge case.

## Chosen implementation shape

A drive-or-fall-back block at the top of `handle_problematic_pickup`. **Reuse only** — no new public
symbols, no new transcript event kinds, no new protocol shape; the Spike 13B uilist machinery
(`backend_ui_mode_active`, `backend_begin/end_uilist_transaction`, `uilist_transaction_guard`,
`backend_resolve_uilist_choice`, the `"UILIST"` serve branch, the live `uilist_prompt_source`) generalizes
to a second site verbatim. **One rename** — `live_vehicle_source_prompt` →
`live_uilist_prompt`: the body was already generic (writes a `prompt` event using `request.kind` /
`request.title` / `request.choices`, enforces single-select, returns the chosen index), but the name and
its error message suggested vehicle-specificity; Spike 14 makes the channel's generic purpose explicit. The
wire format is **byte-unchanged** (Gate H continues to pass identically — confirmed by acceptance criterion
#4).

The block:

```cpp
const bool transaction = arcopolis::backend_pickup_transaction_active();
const bool drive = transaction && arcopolis::backend_uilist_prompt_available();
if( transaction && !drive ) {                        // misconfigured live: no channel -> doc-31 marked partial
    arcopolis::backend_report_pickup_secondary_forced_cancel();
    return CANCEL;
}
if( !transaction && arcopolis::backend_session_active() ) {   // PR #42 review: resumed multi-tick, orphaned
    arcopolis::backend_report_pickup_orphaned_secondary();    // MARK in transcript -> never a silent CANCEL
    return CANCEL;
}
if( drive ) {
    arcopolis::backend_begin_uilist_transaction();   // BEFORE the uilist ctor reads the gate
}
arcopolis::uilist_transaction_guard uilist_guard;    // closes the transaction on EVERY return path
// ... unchanged engine code (addentry sequence + amenu.query() + amenu.ret read) ...
if( drive ) {
    // expose REAL amenu.entries as the prompt
    arcopolis::backend_resolve_uilist_choice( request_built_from( amenu.entries ) );
}
amenu.query();   // under the gate: setup() headless, no newwin, real handle_input loop
```

The guard's RAII makes the un-abort gate flip back off **before** control returns to
`pick_one_up`/`do_pickup`. The next call to `handle_problematic_pickup` for a subsequent activity target
re-arms a fresh transaction.

## Exact UI-mode / test_mode behavior (a row added to doc 33's table)

| Context                                               | `test_mode` | `backend_ui_mode_active()` | `uilist::query()`                                                                   |
| ----------------------------------------------------- | ----------- | -------------------------- | ----------------------------------------------------------------------------------- |
| Normal GUI play                                       | false       | false                      | renders + real input (unchanged)                                                    |
| cata_test (no backend session)                        | true        | false                      | aborts → `UILIST_ERROR` (unchanged)                                                 |
| Backend session, no uilist transaction                | true        | false                      | aborts → `UILIST_ERROR` (e.g. a uilist outside the pickup transaction)              |
| Backend session, vehicle-source submenu armed (13B)   | true        | **true**                   | runs `setup()` headless + real loop; served `DOWN`/`CONFIRM` set `amenu.ret`        |
| Backend session, secondary capacity uilist armed (14) | true        | **true**                   | runs `setup()` headless + real loop; served `[DOWN×K, CONFIRM]` or `[QUIT]` set ret |

## Exact level-4 equivalence claim

```
same engine action          ACTION_PICKUP via handle_action -> game::pickup -> pick_up -> activity
same active input loop       input_context("UILIST")::handle_input() in uilist::query (src/ui.cpp), UNMODIFIED
same registered actions      DOWN x choice + CONFIRM (WEAR / WIELD / EMPTY / SPILL) or QUIT (cancel),
                              one action per blocking handle_input read, exactly a player's keystrokes
same selection               done by the engine loop (scrollby -> selected; CONFIRM -> ret =
                              entries[selected].retval), NEVER by Arcopolis
same continuation            ret = WIELD -> pick_one_up's WIELD branch -> u.wield (engine state change)
                              ret = WEAR  -> WEAR branch -> u.wear_item
                              ret = UILIST_CANCEL -> CANCEL -> item left behind (engine's own outcome)
ONLY difference              the answer's TRANSPORT: a JSON prompt + a single choice index, not a curses keypress
```

## Protocol shape (additive — uses Spike 13B's existing kind)

A secondary capacity prompt (backend→client, mid-command), distinguished by `kind:"uilist"` and the
varying title (the engine's `explain` string):

```json
{"type":"prompt","id":<cmd-id>,"prompt_id":2,"kind":"uilist","title":"Not enough capacity to stash leather jacket",
 "choices":[{"index":0,"text":"Wear leather jacket","enabled":true},
            {"index":1,"text":"Wield leather jacket","enabled":true}],"cancelable":true}
```

Answer (client→backend, single-select, same as Spike 13B):
`{"op":"prompt_answer","id":<n>,"prompt_id":2,"choice":1}` (or `{"op":"prompt_cancel","prompt_id":2}`).

For the witnessed flow, the **full prompt sequence** within one `pickup` command is:

1. `prompt #1` — the PICKUP item menu (`kind:"menu"`, Spike 12A).
2. `prompt #2` — the secondary capacity uilist (`kind:"uilist"`, Spike 14), if the activity hits one.

The same `prompt_id` increment + `should_send_next()` loop the existing driver uses for Spike 13B's
vehicle→PICKUP flow handles this without driver changes.

## Transcript shape (`session.jsonl`)

Reused Spike 13B events, the secondary capacity one also carrying `kind:"uilist"`: `prompt_opened`
(kind=uilist, the real entries) · `prompt_answered` (kind=uilist, the choice + served actions) ·
`prompt_completed` (kind=uilist, actions_served). Cancel logs `prompt_cancelled` (kind=uilist). **The doc-31
`prompt_force_cancelled kind=secondary_capacity` event is no longer emitted on the driven path**; it
remains for the no-channel fallback only (unit-tested).

## Hard acceptance criteria (BIND the equivalence claim — verbatim from the plan)

These bound what the spike claims and what it MUST NOT silently regress.

1. **All-enabled-entries only — ENFORCED in code, not just documented (PR #42 review, Codex P2).** The
   level-4 equivalence claim is **limited to uilists where every entry is `enabled:true`.**
   `backend_resolve_uilist_choice` maps choice index `K` → `[DOWN×K, CONFIRM]`, while the engine's
   `uilist::filterlist()` lands the initial highlight on the first _enabled_ entry and `uilist::scrollby()`
   skips disabled entries (both verified at the implementing line, `src/ui.cpp`), so a raw position index
   would mis-navigate to a _different_ enabled action when any entry is disabled. A **real** capacity prompt
   can present a disabled entry (e.g. a too-heavy WOOL armor item + `WOOLALLERGY` → WEAR disabled, WIELD
   enabled; or a `NO_UNWIELD` wielded weapon → WIELD disabled). Spike 14 therefore **refuses** a
   disabled-entry shape rather than risk the wrong selection, in **two** places: (a) `handle_problematic_pickup`
   (`src/pickup.cpp`) checks all-enabled before arming the prompt and, if any entry is disabled, takes the
   doc-31 **marked-partial** path (`backend_report_pickup_secondary_forced_cancel` — item left behind,
   response marked not-full-success) instead of driving; (b) `backend_resolve_uilist_choice` itself refuses
   any disabled-entry request as defense-in-depth — it serves `QUIT` (the engine's `UILIST_CANCEL`) without
   asking the client and logs `prompt_cancelled` reason `disabled_entry_unsupported`, protecting the
   vehicle-source path and any future caller (pinned by a unit test). The fixtures produce all-enabled
   entries; the regression and unit tests assert `enabled:true` on every driven choice. **Disabled-entry
   _navigation_ (translating over the selectable-only path) remains unresolved/deferred** — what changed is
   that the unsafe path now fails loud / marks instead of silently mis-selecting.

2. **Multi-tick pickup activities are marked, not silently succeeded (defensive guard implemented).** If
   `handle_problematic_pickup` is reached on a resumed activity tick (after `next_backend_action` has cleared
   `pickup_transaction`), the driven path cannot engage — neither `backend_pickup_transaction_active()` nor
   the no-channel fallback fires, and `uilist::query`'s test_mode abort would CANCEL **silently**. Spike 14
   does **both** plan options: (a) the witnesses use small piles (1 jacket on Gate J, 2 chosen items on
   Gate E) that provably complete in one tick on a healthy avatar; **and (b) a defensive guard** — when
   `handle_problematic_pickup` runs with `backend_session_active() && !backend_pickup_transaction_active()`,
   `backend_report_pickup_orphaned_secondary()` logs a `prompt_force_cancelled` transcript event
   (`kind="secondary_capacity_orphaned"`) before the engine's CANCEL, so the path is **MARKED, never
   silent**. The reporter sets **no** `pickup_outcome` (there is no owed command response for a resumed-tick
   prompt, and a leaked partial marker must not mis-mark an unrelated later command). **Driving** the prompt
   on a resumed tick (threading the transaction across activity resumes) remains the named follow-up — what
   Spike 14 does not do is _drive_ it; what it now guarantees is it is never a silent CANCEL. **The bar — no
   path through `handle_problematic_pickup` during a backend session may produce a silent CANCEL with no
   marker — is met by construction (single-tick witnesses) AND by the defensive guard (resumed ticks).**

   _Reachability note (why the guard is safe and fires only here):_ `handle_problematic_pickup` during a
   backend session is reached **only** by a manual `pickup` whose activity runs it — examine's auto-pickup
   tail cancels at the `"PICKUP"` menu via the nested-input guard and never reaches it, and auto-pickup
   (`opts.autopickup`) sets `option = CANCEL` _without_ calling it (`src/pickup.cpp`). So the guard fires for
   exactly the resumed-multi-tick case and zero current witnessed scenarios (confirmed: no regression).

3. **Renderer neutrality** — pinned by the shared Spike 13B unit-test invariant
   (`!menu.window` after a backend-UI `setup()`). Spike 14 adds a second pin
   ("backend uilist setup leaves NO curses window") on the WEAR/WIELD-shaped uilist, asserting the invariant
   generalizes per acceptance criterion #3.

4. **Channel rename is byte-neutral.** `live_vehicle_source_prompt` → `live_uilist_prompt` does not change
   the wire format, the transcript events, or any unit-test fixture. Verified by re-running Gate H on
   `ArcopolisVehicleCargoTest` after the rename — it passes byte-identically (Gate H assertions on
   `kind=uilist`, the 2-choice sequence, the `[DOWN, CONFIRM]` queue, and `actions_served=2` are unchanged).

5. **No-channel fallback parity.** The `backend_report_pickup_secondary_forced_cancel` path stays intact
   for misconfigured live sessions. Wire format for that fallback (`forced_cancel`/`partial`/
   `unsupported_prompt:"secondary_capacity"` + transcript `prompt_force_cancelled kind=secondary_capacity`)
   matches the existing doc-31 contract byte-for-byte. Pinned by the existing `[arcopolis]` unit test
   ("arcopolis pickup reports a secondary prompt as a partial outcome").

## Regression witness

[`prompt_menu_regression.ps1`](prompt_menu_regression.ps1):

- **Gate E converted (driven WIELD on `ArcopolisTest`):** the existing blanket scenario now exercises the
  driven path. Assertions: 2 prompts in order (kind=menu then kind=uilist); the uilist has 1 enabled
  entry; answering `choice:0` (WIELD) is served `[CONFIRM]`; transcript `prompt_opened`/`answered`/
  `completed kind=uilist actions_served=1`; NO `prompt_force_cancelled`; south tile 7→5 (both blanket and
  shard gone); a "Wielding ... blanket" message appears; response is clean `ok:true` with NO
  `forced_cancel`/`partial`/`unsupported_prompt` markers.

- **Gate J new (driven multi-entry on `ArcopolisCapacityTest`):** five sub-gates J-probe (discover the
  jacket's PICKUP menu index), J-pick-wield (drive entry 1 → `[DOWN, CONFIRM]` → engine wields), J-pick-wear
  (drive entry 0 → `[CONFIRM]` → engine wears), J-cancel (prompt_cancel → `[QUIT]` → CANCEL → jacket
  stays; response clean ok:true NOT forced_cancel), J-recover (wrong prompt_id + out-of-range each
  rejected with the secondary uilist still open; a valid answer completes).

Driver [`prompt_menu_live_driver.py`](prompt_menu_live_driver.py): NO changes — the `should_send_next()`
loop already handles N sequential prompts per command (Gate H's two-prompt vehicle→PICKUP flow established
the pattern).

## Fixture

[`docs/arcopolis/make_capacity_fixture.py`](make_capacity_fixture.py) builds `ArcopolisCapacityTest`:
stdlib-only, read-only on `ArcopolisTest`, no GUI/build. Clones the world and save-edits the submap
`.map` JSON to append ONE `jacket_leather` (deep-copy of one existing pile item, only `typeid`
overridden; stale charges/poison/frequency/active/components fields cleared so the deserializer keys
only off the prototype) onto the existing 7-item ground pile one south of the post-`move_s` avatar.
The script verifies the source pile is non-empty and aborts if not, with a clear message. Documented in
the fixture `README.md` and AGENTS.md.

**Item swap procedure** (if a future BN sync renames or deprecates `jacket_leather`): choose another real
BN ARMOR item meeting the criteria — `is_armor()` true, `can_wear()` succeeds on a basic-clothes avatar,
volume > avatar capacity, NOT a bucket, NO children — and update both the script's `WITNESS_TYPEID` and
the Gate J text-match patterns in `prompt_menu_regression.ps1`. Do NOT invent JSON; only real items
already in BN.

## Source code

- `src/pickup.cpp` — the only behavior change: replaces the doc-31 fail-loud-only block at the top of
  `handle_problematic_pickup` (lines ~172-182) with the drive-or-fall-back block above. About 30 lines
  added. No other change in `pickup.cpp`.
- `src/arcopolis_live.{cpp,h}` — rename `live_vehicle_source_prompt` → `live_uilist_prompt`; update the
  doc comment to call out the second use site; generalize the "uilist prompt is single-select" error
  message (was "the 'Get items from where?' prompt is single-select"). The function body is unchanged.
- `src/arcopolis_backend_input.{h,cpp}` — one additive symbol: `backend_report_pickup_orphaned_secondary()`
  (the PR #42 review defensive guard — marks the resumed-multi-tick orphaned case in the transcript, sets no
  `pickup_outcome`). No change to the existing uilist transaction machinery.
- `src/ui.cpp` — NO change. Spike 13B's three gates serve this site verbatim.
- `tests/arcopolis_backend_input_test.cpp` — two new test cases: WEAR/WIELD-shaped queue building (the
  multi-entry secondary capacity shape) and the no-window invariant pinned for that shape.

## Validation — PASS (2026-06-16, RelWithDebInfo + ccache, MSVC)

- **Build:** `cataclysm-bn-tiles` + `cata_test-tiles` built clean in one `win-rel-deb` dir (719/719 ninja
  steps, exit 0). The three touched TUs (`pickup.cpp`, `arcopolis_live.cpp`,
  `arcopolis_backend_input_test.cpp`) compiled with no new warnings (only pre-existing MSVC-header /
  `sounds.h` noise).
- **`[arcopolis]` unit suite:** **729 assertions / 104 cases pass** (up from 713 / 102 — the two new
  Spike 14 cases: the WEAR/WIELD `[DOWN,CONFIRM]` queue on the `"UILIST"` seam, and the no-window invariant
  on the WEAR/WIELD uilist shape).
- **[`prompt_menu_regression.ps1`](prompt_menu_regression.ps1):** all gates exit 0 (`pwsh`). Highlights:
  - **Gate E (driven WIELD-blanket):** the secondary capacity uilist opened `kind=uilist` with the real
    single entry `Wield folded emergency blanket` (enabled); `choice:0` served `[CONFIRM]`; the engine
    wielded the blanket (`Wielding - folded emergency blanket`); south tile `7 → 5`; response clean
    `ok:true`, **no** `forced_cancel`/`partial`/`unsupported_prompt` markers, **no** `prompt_force_cancelled`.
  - **Gate J (multi-entry, `ArcopolisCapacityTest`):** the uilist opened with 2 enabled entries
    `[Wear / Wield leather jacket]`; `choice:1` (WIELD) served `[DOWN, CONFIRM]` → engine wielded the
    jacket; `choice:0` (WEAR) served `[CONFIRM]` → engine wore it; `prompt_cancel` → `[QUIT]` →
    `UILIST_CANCEL` (jacket stays, clean `ok:true`, **not** `forced_cancel`); wrong `prompt_id` +
    out-of-range each rejected with the secondary uilist still open, then a valid answer completed.
  - **Gate H (vehicle-source, byte-identical after the rename):** still `kind=uilist`, 2 choices in order,
    `[DOWN, CONFIRM]`, `actions_served=2` — confirming acceptance criterion #4.
  - **Scenario C (PICKUP-menu invalid recovery):** updated to pick a fitting item (the shard, last entry)
    so it stays off the now-driven secondary-uilist path; it would otherwise open a secondary uilist this
    driver does not answer. This was the one change my engine edit forced in an untouched scenario — it
    surfaced because over-capacity pickups in live mode now open a real uilist instead of silently
    force-cancelling, which is the intended new behavior.
- **No-regression (all exit 0, `pwsh`):** `examine_` (its pickup tail still ESC-cancels — my change is
  inert when no pickup transaction is armed), `movement_`, `live_protocol_`, `client_harness_`,
  `frontend_prototype_` (18 gates), `item_`/`monster_`/`npc_export_`.

> **Run with `pwsh` (PowerShell 7), not `powershell` (5.1)** — see the memory note: PS 5.1 misreads BOM-less
> UTF-8 snapshots and writes a BOM into options.json, causing spurious gate failures on unchanged code.

## Remaining unsupported (named backlog)

- **Multi-tick pickup activities** that span the seam re-entry: the pickup transaction is not (yet) threaded
  across activity resumes, so a long pickup whose capacity prompts open on later ticks cannot be **driven**.
  Per acceptance criterion #2 this is no longer a _silent_ hole — the defensive
  `backend_report_pickup_orphaned_secondary()` guard MARKS it (`prompt_force_cancelled
  kind="secondary_capacity_orphaned"`) and leaves the item behind. The named follow-up is to _drive_ it:
  thread the pickup transaction (and its uilist channel) across resumed activity ticks so a resumed-tick
  capacity prompt is answered through the same registered-action path instead of marked.
- **Disabled-entry uilist navigation** (acceptance criterion #1): the `[DOWN×K, CONFIRM]` translation
  assumes all entries before the target are enabled. Witnesses use all-enabled-entries. A future fix
  (account for `scrollby` skipping disabled entries) is the prerequisite for any witness with disabled
  entries.
- **EMPTY (container parent-child) and SPILL (bucket-nonempty) branches** of
  `handle_problematic_pickup` are not witnessed by Gate E or Gate J. Same machinery would drive them; the
  fixture additions are the open work.
- **Per-unit quantity** (still inherited from Spike 12A): the secondary uilist does not yet expose
  per-unit count keystrokes either.
- **`query_popup` / `popup()` family, `inventory_selector`, computer UI, NPC dialogue, ranged TARGET, the
  full new `NEW_PICKUP_MENU`** — all backlog, all the named follow-ups in doc 32's audit.

## Claim → cite → verdict audit

Per [[cite-the-implementing-line]] — each load-bearing claim verified at the implementing line in the
current tree:

| Load-bearing claim                                                                                             | Cite                                                                                         | Type       | Verdict     |
| -------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ---------- | ----------- |
| `handle_problematic_pickup` opens a `uilist` (the Spike 14 witness)                                            | `src/pickup.cpp:165, 186-214`                                                                | structural | ✅ verified |
| The uilist's entries are added with explicit retvals WEAR/WIELD/EMPTY/SPILL                                    | `src/pickup.cpp:193-212` (matches enum `pickup_answer` in src/pickup.cpp earlier)            | structural | ✅ verified |
| `handle_problematic_pickup` is called inside `pick_one_up`'s capacity branches                                 | `src/pickup.cpp:336 / :345 / :354`                                                           | behavioral | ✅ verified |
| `pickup_activity_actor` drains in the same `do_turn` as `ACTION_PICKUP` (process_activity after handle_action) | `src/game.cpp` (game::do_turn calls process_activity after handle_action returns)            | behavioral | ✅ verified |
| Spike 13B `backend_ui_mode_active` gate keys `uilist::init`/`query` un-abort                                   | `src/ui.cpp:159-162, 933-937`                                                                | behavioral | ✅ verified |
| `uilist::query` runs `setup()` directly under the gate (non-render init path)                                  | `src/ui.cpp:957-959`                                                                         | behavioral | ✅ verified |
| `setup()` skips `catacurses::newwin` under the gate                                                            | `src/ui.cpp:638-643`                                                                         | behavioral | ✅ verified |
| `backend_resolve_uilist_choice` translates choice K → `[DOWN×K, CONFIRM]` or `[QUIT]`                          | `src/arcopolis_backend_input.cpp:540-561`                                                    | behavioral | ✅ verified |
| `"UILIST"` serve branch in `backend_nested_input_action`                                                       | `src/arcopolis_backend_input.cpp:653-662`                                                    | behavioral | ✅ verified |
| `live_uilist_prompt` (renamed) writes `prompt` events with the request's `kind` / `title` / `choices`          | `src/arcopolis_live.cpp` (renamed function body unchanged from `live_vehicle_source_prompt`) | behavioral | ✅ verified |
| `jacket_leather` is ARMOR with 4500 ml volume (the over-capacity witness item)                                 | `data/json/items/armor/coats.json:531-553`                                                   | structural | ✅ verified |
| Doc-31 no-channel fallback markers still emitted only when `pickup_transaction_active && !drive`               | `src/arcopolis_backend_input.cpp:415-427` (`backend_report_pickup_secondary_forced_cancel`)  | behavioral | ✅ verified |
