# Arcopolis backend — current state (truth as of Spike 16 non-live script prompt answers, 2026-06-18)

A single-page checkpoint of what the Arcopolis backend **is today**, so you don't have to
reconstruct it from the per-spike history. The numbered `NN_SPIKE*.md` docs are the chronological
record (including a **failed** Spike 3); **this page is the current truth.** When they disagree, this
page wins — or fix it.

> **Current-truth pointer (audited Spike 17, 2026-06-18 — see
> [37_SPIKE17_CLAIM_AUDIT.md](37_SPIKE17_CLAIM_AUDIT.md), and the level-4 truth pass
> [38_LEVEL4_TRUTH_AUDIT.md](38_LEVEL4_TRUTH_AUDIT.md)).** Four witnessed prompt paths are driven at **level 4
> = backend-input + engine equivalence** — the **proof mechanism** for the project's GUI-equivalence goal, not visual/frontend parity itself (see Terminology): the old `"PICKUP"` menu, the
> vehicle-source uilist, the **all-enabled** secondary capacity uilist, and the deployed-furniture
> `query_yn` — live and (Spike 16) non-live `--arcopolis-run-script`. Each is witness-scoped to **one
> hardcoded call site / one fixture** and per-transaction gated; the mechanism generalizes by **reuse** at
> new sites, not a general UI abstraction — "one witnessed path is level 4" ≠ "the prompt class is
> supported" (doc 38). **`move` itself is NOT level 4** (its `action_id` never enters `handle_input` — it
> is engine/frontend-equivalent only); only the examine direction-chooser sub-prompt is. Everything else
> fails loud or is honest backlog (see the **Known-unsupported / fail-loud** table below — which now notes
> the one silent prompt-default: an unguarded `query_yn` via `examine`). The backend creates **no curses
> window and calls no render primitive in any build**. When an older `NN_SPIKE*.md` disagrees with this
> page, this page wins.

## Purpose

Run Cataclysm-BN **headless as a simulation backend** for a separate "Arcopolis" frontend: load a
world, drive faithful engine turns from a script, and export read-only JSON the frontend (or an
offline viewer) consumes. No new gameplay; the engine remains the single source of truth.

## Repository layout (branch model)

The fork follows a fast-moving upstream while carrying this backend work, using a **mirror + rebased
dev branch** layout (set up 2026-06-04):

- **`main` mirrors `upstream/main`** (`cataclysmbn/Cataclysm-BN`) exactly — **no Arcopolis work lives
  on it.** Don't commit here; it only fast-forwards to upstream.
- **`arcopolis` is the development branch** — the Spike 0–5 commits plus all new work, kept linear on
  top of `main`, and the GitHub **default branch**. **Branch and PR off `arcopolis`.**
- `git diff main...arcopolis` is always exactly the backend patch set.

Sync with upstream:

```sh
git fetch upstream
git switch main && git merge --ff-only upstream/main && git push origin main   # mirror; never conflicts
git switch arcopolis && git rebase main                                        # replay patches onto upstream
git push --force-with-lease origin arcopolis
```

`git rerere` replays the recurring rebase conflicts automatically **once trained** (shapes as of
the 2026-06-10 sync): the `first_pass_arguments` array tail in `src/main.cpp` (upstream and Arcopolis
both append entries at the same spot), and the backend input branch in `src/handle_action.cpp` (it
leads `handle_action()`'s input-dispatch chain, inside upstream's `handle_action_get_action` scope).
Spike 11A adds a **third collision surface**: the nested-input hook at the top of
`input_context::handle_input( const int timeout )` in `src/input.cpp` — any upstream change to that
function's head collides there. The `do_turn` clean-park (`src/game.cpp`) currently merges clean
without a conflict. The resolution
cache (`.git/rr-cache`) is **local to each clone** and is not shared by git, so a fresh checkout hits
the conflicts and must resolve them by hand the first time (which trains that clone's cache); they
auto-replay only afterward. Enable it per clone with `git config rerere.enabled true`. Either way,
when upstream adds a **new** CLI argument the `<arg_handler, N>` literal needs a manual fix at the
tip: set N = upstream's count + the Arcopolis flags (17 + 5 = 22 as of 2026-06-10) and recount the
array entries — git auto-merges the literal silently and incorrectly, including inside commits that
replay **without** conflict markers.

## How to run

| Mode              | Flags                                                                                              | Output                                                                            |
| ----------------- | -------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| One-shot snapshot | `--arcopolis-export-current-view <path>` `--world <w>` [`--arcopolis-command <file>`]              | one snapshot JSON                                                                 |
| Stateful script   | `--arcopolis-run-script <script.json>` `--arcopolis-export-dir <dir>` `--world <w>` [`--seed <s>`] | `NNN_<name>.json` per `export` + `session.jsonl`                                  |
| Live protocol     | `--arcopolis-live` `--arcopolis-export-dir <dir>` `--world <w>` [`--seed <s>`]                     | stdin JSONL requests → stdout JSONL responses + snapshots + transcript (Spike 9B) |

Common: `--userdir <dir>`. Headless runs end with `std::_Exit(code)` (skips the fragile global
teardown that corrupts the heap on a fully-loaded game). World options must keep
`TURN_DURATION <= 0.005` or `handle_action` drains `moves` by wall-clock.

## Architecture (the load-bearing design)

The backend is a **pure input source**, not a turn driver:

- The engine's `game::do_turn()` runs **verbatim**. Each backend command resolves to an engine
  `action_id` consumed at the real `handle_action()` input seam (the same slot a keypress uses).
- The **engine alone** owns turn-end (`moves<=0`) and the world tick (bottom half of `do_turn`).
- **Clean-park:** when the script is exhausted while `moves > 0`, the provider sets
  `backend_input_done()` and `do_turn` returns **before** its bottom half — "the player walked away"
  (faithful; world not ticked). Gated on `backend_session_active()` so normal play never reaches it.
- Mechanism in use is **M1** (synchronous input-seam callback). **Spike 9B's live mode is the same
  M1 seam** with a blocking pull source: the provider blocks on a stdin `getline` exactly where the
  GUI blocks on a keypress, so a persistent process serves one request at a time with zero new
  engine seams. M2 (split `do_turn`) and M3 (coroutine) remain designed-but-unused.
- **Nested-input answer + auto-cancel guard (Spike 11A):** during a session, every
  `input_context::handle_input` call is by definition a NESTED read (the seam owns the only
  top-level one), and a **blocking** one (`timeout < 0`) would busy-wait forever headless. A hook
  at the top of `handle_input` therefore serves the command's armed one-shot direction answer when
  the engine's own chooser (`"DEFAULTMODE"`, with the action registered) is asking, else returns
  the context's registered cancel (`QUIT`/`TEXT.QUIT` — the engine runs its own ESC path), else
  hard-exits (code 12) rather than hang. Timeout-bounded polls (e.g. the activity-interrupt check)
  pass through untouched. Stale answers are force-cleared (and logged) at every seam return.
  Every intervention is a transcript event. See
  [26_SPIKE11A_DIRECTED_EXAMINE.md](26_SPIKE11A_DIRECTED_EXAMINE.md).

**Fidelity rules (non-negotiable):** GUI behavior == engine behavior == the behavior. Never fake
engine state. Answer GUI-vs-headless questions **from the code**, never by spinning up experiments.
The Spike 3 failure came from driving `command → do_turn` (which inverts action/top-half ordering);
3.1A replaced it with the input seam. Do not resurrect `apply_command`-style turn driving.

### Frontend boundary: Arcopolis is neither BN tiles nor BN curses

Arcopolis is **not** a replacement implementation of the existing BN tiles or curses UI. The eventual
Arcopolis GUI is a separate external frontend that talks to the BN process through the Arcopolis protocol
and renders snapshots/prompts itself — it is **Arcopolis-protocol-compatible, not tiles- or
curses-compatible** (no screen-scraping of either BN frontend).

Therefore the Arcopolis **backend** path must be **build-flavor-neutral** — it depends on _neither_
renderer:

- it must not depend on tiles pseudo-curses behaviour (e.g. `cursesport.cpp`'s `newwin` tolerating 0×0);
- it must not require real curses/ncurses initialization (`ncurses_def.cpp`'s `::newwin` needs `initscr`);
- it must not allocate renderer windows or call render primitives in backend mode;
- it must keep stdout reserved for protocol JSONL;
- it may use engine UI/input data structures **only** where those structures are needed to reach the real
  engine input loop and consume registered actions (the level-4 seam) — never to draw.

The existing BN tiles and curses frontends remain normal BN frontends, not Arcopolis targets. Arcopolis is
a new protocol-driven frontend path over the same authoritative simulation. PR #40 (Spike 13B) turned this
into a code invariant after the Codex review caught a backend path that leaned on tiles pseudo-curses (a
real `newwin` would have crashed a curses build): **backend-driven UI creates no curses window / calls no
render primitive in any build**, and every future un-abort site must uphold it (see
[33_SPIKE13B_BACKEND_DRIVEN_UILIST.md#risks--follow-up](33_SPIKE13B_BACKEND_DRIVEN_UILIST.md#risks--follow-up)).

## The export contract

### Snapshot `NNN_<name>.json` (`schema_version` 1)

`session` (export_index, step_index|null, export_name, final) · `backend` (game_version,
save_version, turn) · `avatar` (name, pos_local[xyz], pos_abs[xyz], z, hp, hp_max, stamina, moves,
pain, thirst, fatigue, stored_kcal, kcal_percent) · `map_bounds` (origin_abs_sm[xyz], size_x, size_y,
z) · `tiles[]` (x, y, z, ter, furn, seen, **is_avatar** on the avatar's tile only — Spike 5) ·
**`entities.monsters[]`** (index, type_id, name, symbol, pos_local[xyz], pos_abs[xyz], hp, hp_max,
moves, hallucination — Spike 6A) · **`entities.npcs[]`** (index, name, pos_local[xyz], pos_abs[xyz],
is_enemy, is_following, is_player_ally, is_stationary, hallucination — Spike 7A) ·
**`entities.items[]`** (index, type_id, name, symbol, pos_local[xyz], pos_abs[xyz], charges,
count_by_charges — Spike 8A) · `messages[]` (text, type — **type currently blank**, deferred) ·
`diagnostics.warnings[]`. Tiles **and the monster / NPC / item windows** are a radius-12 single-z square
around the avatar, clamped to the loaded bubble; `entities.monsters[]` and `entities.npcs[]` use the
**identical** window predicate (one shared `in_export_window` helper), and `entities.items[]` is gathered by
iterating that **same tile window** and reading each tile's ground stack, so every exported monster, NPC,
**and item** sits on an exported tile. Monsters and NPCs are **authoritative** engine lists
(`game::all_monsters()` / `game::all_npcs()`, the active non-dead ranges) — they include hallucinations and
out-of-LOS entities (flagged via `hallucination`), not a "what the player sees" or interaction list.
`entities.items[]` is the **top-level ground-item stack** on each windowed tile (`map::i_at`), read-only —
**not** vehicle cargo or nested-container contents (both deferred), and **not** a pickup/drop/use surface.

### Transcript `session.jsonl` (`schema_version` 1, one JSON object per line, flushed per event)

`session_start` (world, **seed** opt — Spike 5, export_dir, game_version,
**autoselect_single_valid_target** — Spike 11A records the loaded option, never overrides it) ·
`command` (step_index, command, direction opt, action_id opt, status="queued") · `export`
(step_index|null, export_index, name, path, final, turn, pos_abs, moves — scalars equal the named
snapshot) · `error` (step_index opt, kind, detail, exit_code) · `session_end` (status, snapshots,
commands, final_turn opt, final_pos_abs opt) · **Spike 11A nested-input events**:
`nested_input_answer` (step_index, context, direction, action — the armed answer was served to the
engine's chooser) · `nested_input_guard` (step_index opt, context, action QUIT/TEXT.QUIT, reason
no_answer/context_mismatch/answer_not_registered, fires — the guard auto-cancelled a nested read) ·
`nested_input_unconsumed` (step_index, direction, action, reason="command_completed" — an armed
answer was never asked for and was force-cleared at the seam return). New fatal error kind
`nested_input_failed` → exit code 12. · **Spike 12A pickup prompt/menu events**: `prompt_opened`
(step_index, kind, choices[] — the engine's real menu entries) · `prompt_answered` (step_index, choices[],
actions[] — the served `[DOWN×K, RIGHT, …, CONFIRM]`, one `RIGHT` per chosen entry) · `prompt_cancelled` (step_index, reason) ·
`prompt_failed` (step_index, reason, detail — an invalid answer rejected; the prompt stayed open) ·
`prompt_completed` (step_index, actions_served — the count the engine's menu loop consumed). Invalid
prompt answers are recoverable (no new fatal error kind).

### Commands

`wait` → `ACTION_PAUSE` (`do_pause`); `move` + any of the **eight planar directions**
(`move_n`/`move_s`/`move_e`/`move_w` + the diagonals `move_ne`/`move_nw`/`move_se`/`move_sw`)
→ `ACTION_MOVE_*` (eight-way since #34; `look_up_action` + `handle_action` route every one through the
**same** `avatar_action::move` body, so diagonals are as faithful as cardinals); **`examine` +
`direction` → `ACTION_EXAMINE` (Spike 11A)**, where `direction` is any of the **eight planar
directions** (`move_n`/`move_s`/`move_e`/`move_w` + the diagonals `move_ne`/`move_nw`/`move_se`/`move_sw`)
or `here` (the avatar's own tile) — the complete planar target set the GUI examine chooser offers
(vertical excluded: `game::examine` passes `allow_vertical=false`). The examine direction is the answer
to the engine's "Examine where?" prompt IF it asks (a keystroke mirror, served through the nested-input
seam), never a commanded target tile; with the engine's autoselect option on, the engine may pick the
target itself and the unconsumed answer is force-cleared + logged. For `move`, only **vertical**
(`move_up`/`move_down`) stays rejected — the separate `game::vertical_move` primitive (stairs/ropes/climb),
not a planar step; for examine, only vertical and garbage are rejected, with a typed error. The **browser
prototype** drives this whole planar surface 8-way (Spike 11B): click-to-move and the 3×3 d-pad reach all
eight neighbors, and a Move/Examine mode selector sends `examine` in any of the eight directions plus `here`.

**`pickup` + `direction` → `ACTION_PICKUP` (Spike 12A live; Spike 16 adds non-live script via declared
`prompt_answers`)** — a GUI-equivalent prompt/menu transaction (doc 25's "Option C" for one prompt class). The "Pickup where?" chooser is answered like
examine (the one-shot direction slot), then the engine reaches the **real old `"PICKUP"` item menu**; the
backend exposes that menu's **real** entries to the client as a `prompt` event and selects the client's
**choice(s)** — a `prompt_answer.choices` array, one or many entries — by feeding the **same registered
actions** a player would press: one `RIGHT` mark per chosen entry, navigated forward by `DOWN`, ended by a
single `CONFIRM` (`[DOWN×5, RIGHT, DOWN, RIGHT, CONFIRM]` for `[5,6]`), one action per blocking
`handle_input` read to the engine's **own unmodified loop** (equivalence **level 4**: the engine performs
every `getitem` mutation and its `pickup_activity_actor` does the transfer; the backend never mutates
menu/selection state). Supported: `NEW_PICKUP_MENU=false`; **every exposed entry is `enabled:true`** (the
GUI never disables them) and single- **or** multi-select works. The three design-review gaps are tracked as
defects: **(1) containers — the artificial `enabled:false` disabling is gone** (all entries exposed
selectable), but the engine's parent/child mark-propagation path (src/pickup.cpp:1107-1123) is **unexercised
and unwitnessed** by the fixture — no entry has child sub-entries, so the loop never runs (open defect);
**(2) per-unit quantity — unfixed defect**,
selecting an entry takes its WHOLE stack because the digit/count keystrokes are not driven (`RIGHT` with no
preceding digit, src/pickup.cpp:1204-1228); **(3) multi-entry selection — fixed**, witnessed by the carry-
both gate. After `CONFIRM`, the activity may raise a **secondary** capacity/wield/spill `uilist`
(`handle_problematic_pickup`). **Spike 14 now DRIVES the witnessed all-enabled WEAR/WIELD branches at level
4** (on the default `ArcopolisTest` avatar — the blanket is wielded through the real
`input_context("UILIST")` loop, south pile 7→5, the response carrying NO `forced_cancel`/`partial` markers;
doc 34). The earlier marked-partial **force-cancel is retained only as the no-channel / disabled-entry /
orphaned-multi-tick fallback** (in script mode it **fails loud**, `script_prompt_failed`/exit 13, never a
silent exit-0 partial). Carry-both (both selected items leave) is witnessed on the **3rd fixture
`ArcopolisBackpackTest`** whose avatar wears a backpack. `NEW_PICKUP_MENU=true` **fails loud**
(`unsupported_command`).

**Vehicle-source submenu is now DRIVEN at level 4 (Spike 13B, doc 33).** A live `pickup` on a tile with BOTH
vehicle cargo and ground items reaches the `"Get items from where?"` `uilist`. Spike 12A's follow-up made this
**fail loud**; **Spike 13B drives it** — a backend/session-gated `backend_uilist_transaction_active()` bypasses the
`uilist::init`/`query` `test_mode` abort for exactly that one armed menu, runs its `setup()` headlessly (no
draw), exposes the **real** `amenu.entries` as a `prompt` (`kind:"uilist"`), and serves the registered
`UILIST` actions (`[DOWN, CONFIRM]` for "ground", `["QUIT"]` for cancel) through the **real**
`input_context("UILIST")::handle_input` loop, which sets `amenu.ret` (equivalence **level 4**). Choosing
ground (`ret=1=from_ground`) flows into the existing old `"PICKUP"` item menu, driven as before. The
fail-loud is **retained as the no-channel fallback** (non-live / misconfigured: no `uilist_prompt_source` →
`unsupported_command`). Witness `ArcopolisVehicleCargoTest`.

**Non-live `--arcopolis-run-script` now answers prompts via declared `prompt_answers` (Spike 16, doc 36).** A
command step may carry an ordered `prompt_answers` array (pickup/examine only), e.g.
`{ "op":"command","command":"pickup","direction":"move_s","prompt_answers":[{ "kind":"menu","choice":6 }] }`.
The script runner installs **script** prompt sources (`script_pickup_prompt`/`script_uilist_prompt`/
`script_query_popup_prompt`) that consume those answers and feed the **SAME** `backend_resolve_*` machinery +
registered-action queues + `input_context` loops + `prompt_*` transcript events as live mode (only the
transport differs). All four classes (`"PICKUP"` menu, vehicle-source `uilist`, **all-enabled** secondary
capacity `uilist`, deployed-furniture `query_yn`) are now script-drivable at **level 4** (the secondary
capacity `uilist` carries Spike 14's all-enabled bound — a **disabled-entry** secondary force-cancels and, in
script mode, **fails loud** `script_prompt_failed`/exit 13 at the seam return, never a silent exit-0 partial).
A missing / wrong-kind / title-mismatch / out-of-range / cancel-on-noncancelable / unused answer (and a
forced-cancelled unsupported sub-prompt) **fails loud** (`script_prompt_failed` → exit 13,
`session_end status="error"`), with `prompt_failed` logged BEFORE the engine loop-exit escape action so it is
never misread as a user cancel. Scope is the single command turn; a multi-tick resumed secondary prompt stays
orphaned-marked / undriven (doc 34). **Still fail-loud:** a `--arcopolis-run-script` `pickup` with NO declared
answers, and **every one-shot `--arcopolis-command` pickup** (no answer channel) — both reject at pre-flight
with `unsupported_command` (exit 6) before the world load; and a scripted `pickup` under **`NEW_PICKUP_MENU=true`**
rejects with `unsupported_command` (exit 6) right after the load (symmetric with live mode — the new
`inventory_selector` is undriven). Witnessed by `script_prompt_regression.ps1` (5 witnesses + 5 fail-loud
gates). See [36_SPIKE16_SCRIPT_PROMPT_ANSWERS.md](36_SPIKE16_SCRIPT_PROMPT_ANSWERS.md).

**The secondary capacity/wield/spill `uilist` is now DRIVEN at level 4 too (Spike 14, doc 34).** When
`pickup_activity_actor` raises `handle_problematic_pickup`'s `uilist` for an item that does not fit, a live
session with the same Spike 13B mechanism (per-transaction `backend_uilist_transaction_active()` gate + the unchanged
`backend_resolve_uilist_choice`/`"UILIST"` serve branch) arms a fresh uilist transaction around the
construction, exposes the real `amenu.entries` (`Wear X` / `Wield X` / `Empty X` / `Spill X`, each with the
engine's own `enabled` flag) as `kind:"uilist"`, and the real `input_context("UILIST")::handle_input` loop
consumes the served `[DOWN×K, CONFIRM]` (or `[QUIT]`) — setting `amenu.ret = WEAR`/`WIELD`/`EMPTY`/`SPILL`,
which `pick_one_up` then routes to `u.wear_item`/`u.wield`/spill/empty. The `live_vehicle_source_prompt`
hook is renamed `live_uilist_prompt` to match its now-general use across both backend-driven uilists.
Witnesses: `ArcopolisTest`'s WIELD-blanket scenario (single-entry uilist; the existing Gate E converted
from force-cancel-marker to driven-WIELD) and the new `ArcopolisCapacityTest` fixture (a clone with
`jacket_leather` injected onto the south pile, giving WEAR+WIELD = 2 enabled entries — DOWN-navigation
witness, the new Gate J with five sub-gates). **Equivalence is bounded:** the claim is limited to
all-enabled uilist entries (`scrollby` skips disabled entries, so a `[DOWN×K, CONFIRM]` queue could
overshoot past disabled entries — unresolved). The doc-31 marked-partial behavior (`forced_cancel` /
`partial` / `unsupported_prompt:"secondary_capacity"` + `prompt_force_cancelled kind=secondary_capacity`)
is **retained as the no-channel fallback** for misconfigured live sessions (unit-tested). Generic
`uilist`, the new inventory_selector, per-unit quantities, multi-tick pickup activities (the pickup
transaction `session.pickup.armed` is not threaded across activity resumes), and every other menu class stay
backlog.
See [30_SPIKE12A_PROMPT_MENU_TRANSACTION.md](30_SPIKE12A_PROMPT_MENU_TRANSACTION.md),
[31_SPIKE12A_FOLLOWUP_FAIL_LOUD.md](31_SPIKE12A_FOLLOWUP_FAIL_LOUD.md),
[33_SPIKE13B_BACKEND_DRIVEN_UILIST.md](33_SPIKE13B_BACKEND_DRIVEN_UILIST.md), and
[34_SPIKE14_SECONDARY_PICKUP_UILIST.md](34_SPIKE14_SECONDARY_PICKUP_UILIST.md).

**A `query_yn` (`query_popup`) is now DRIVEN at level 4 too (Spike 15, doc 35) — a DIFFERENT Class 2
mechanism than `uilist`.** A live **`examine`** of a deployed furniture reaches
`iexamine::deployed_furniture`'s `query_yn("Take down the %s?")` (`input_context("YESNO")`). The un-abort is
**witness-scoped, never command/session-wide**: a `query_popup_witness_guard` at THAT one call site (gated on
a live `examine` precondition) arms a per-prompt query_popup transaction (`session.query_popup.armed`), and a new
`backend_query_popup_transaction_active()` gate un-aborts `query_popup::query_once`'s `test_mode` short-circuit
(`src/popup.cpp`) for **only** that one query_yn — every other `query_yn` an examine can reach (e.g. "Slip
through the %s?") still aborts (returns NO). The client's YES/NO choice is served as registered horizontal-
button-row actions (**YES → `[LEFT, CONFIRM]`**, **NO → `[CONFIRM]`** from the NO-default cursor) through the
real `input_context("YESNO")::handle_input` loop, which sets `result.action` (the backend never sets it);
`query_yn` returns it and `deployed_furniture` runs the engine's own `take_down_deployed_furniture` (YES) or
no-op (NO). **Renderer-neutral with NO extra setup path** (unlike `uilist`): `query_popup`'s `options`/`cur`
are builder-populated before `query()`, and the redraw/resize callbacks (`init()`→`newwin`/`show()`) are
`test_mode` no-ops in `ui_manager::redraw_invalidated()`, so no window is created (pinned by a unit test that
runs a real `query()` and asserts `!popup.has_window()`). `query_yn` is **not cancelable** (no `QUIT`): a
`prompt_cancel` is rejected (`prompt_failed noncancelable`, prompt stays open) and an EOF/closed client is
served the visible default and marked `prompt_cancelled noncancelable_closed` (NOT an answer) — never a
fabricated cancel, never a hang (the EOF path exits 0, gate-witnessed). Reuses the Spike 13B prompt/answer
wire with `kind:"query_popup"` and the existing `prompt_*` transcript events; no new event kinds. Witness
`ArcopolisDeployedFurnitureTest` (an `f_floor_mattress` placed one east of the avatar, built by
[`make_furniture_fixture.py`](make_furniture_fixture.py)), gated by
[`query_popup_regression.ps1`](query_popup_regression.ps1) (6 gates incl. accept/reject/recovery/EOF). See
[35_SPIKE15_BACKEND_DRIVEN_QUERY_POPUP.md](35_SPIKE15_BACKEND_DRIVEN_QUERY_POPUP.md).

**Movement into an occupied/obstructed tile is a faithful no-op.** A `move` whose destination holds a
creature, or a closed-but-not-bump-openable obstacle, runs the engine's real `avatar_action::move` leaf
and can end the turn with the avatar not having moved — exactly as in the GUI. The studied case
([15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md](15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md)): in `ArcopolisTest` the stock
evac-shelter NPC **Edwardo Stovall** stands one tile north of the avatar, so `move_n` opens the engine's
NPC interaction menu and returns without spending moves — and since the backend runs in `test_mode`, that
`uilist` **auto-cancels** (≡ a GUI player pressing ESC) rather than blocking. Result: no move, 0 AP,
clean-park (world not ticked). This is GUI-faithful, **not** a seam bug; there is simply no command yet to
_choose_ an NPC interaction. **Spike 7A now exports NPCs** (`entities.npcs[]`), so this blocker is visible
in the snapshot itself — the `before` snapshot carries a neutral NPC at the move_n destination
(`is_enemy=false`, `is_player_ally=false`); see [18_SPIKE7A_NPC_EXPORT.md](18_SPIKE7A_NPC_EXPORT.md).

## Terminology (backend-input vs engine vs frontend equivalence)

Anchored by `AGENTS.md:83-120`.

**The project goal is GUI equivalence: a separate, mouse-first Arcopolis frontend that exposes the SAME
meaningful choices and consequences a BN player has, while BN remains authoritative for all simulation.**
"Backend-input level 4" is the **proof mechanism** for that goal, **not** a replacement for it: it proves the
player's choices and consequences flow through BN's OWN real prompt/input loop and mutate real engine state,
so a frontend built on the exposed choices is provably driving the real engine — not a mock. Proving the
mechanism on a witnessed path is **necessary but not sufficient**: it does not mean the external frontend has
been built/validated for that path, nor that a whole prompt _class_ is supported. So on this page
**"GUI-equivalent" / "level 4" mean the BACKEND-INPUT sense** (the proof), never visual/pixel equivalence and
never a finished frontend.

- **Backend-input-equivalent** — the backend serves registered actions that BN's real
  `input_context`/menu/UI loop consumes (e.g. `input_context("UILIST")::handle_input`,
  `input_context("YESNO")` via `query_popup::query_once`).
- **Engine-equivalent** — the real engine caller receives the UI result and mutates
  world/inventory/activity state (e.g. `pickup_activity_actor` does the transfer; the engine sets
  `amenu.ret` / `result.action`). The backend **never** mutates menu/selection state directly.
- **Frontend-equivalent (the project goal)** — an external, mouse-first frontend exposes the same
  meaningful choices/consequences **while BN stays authoritative**, possibly with different visuals.
  **Proven today ONLY for the planar move + examine surface** (Spike 11B, doc 29); every prompt-path "level
  4" claim is the backend-input + engine _proof_ for that goal, **not** a validated frontend.

The per-transaction gates keep all of this **witness-scoped, never session/command-wide**:
`backend_uilist_transaction_active() = session.active && session.uilist.armed`
(`src/arcopolis_backend_input.cpp` ~~`:796`); `backend_query_popup_transaction_active() = session.active &&
session.query_popup.armed` (~~ `:918`). The `pickup`/`uilist`/`query_popup` members are `prompt_transaction`
state structs grouped on the TU-local `backend_session` (Spike 19, doc 40). Both gates are RAII-armed and
-cleared per witnessed prompt, so an
un-abort cannot leak into the next command. The gate names + the served-category boundary (and **why
`inventory_selector` stays fail-loud**) are documented at the top of `src/arcopolis_backend_input.h` and in
[40_SPIKE19_BACKEND_UI_BOUNDARY.md](40_SPIKE19_BACKEND_UI_BOUNDARY.md) (Spike 19 — gate names only, no
behavior change; doc 40 carries the old→new name map).
(Spike 17 audit: [37_SPIKE17_CLAIM_AUDIT.md](37_SPIKE17_CLAIM_AUDIT.md).)

## Capabilities by spike

| Spike | What                                                                                                                                                                                                                                                                                                                                                                       | State                                   |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| 0     | headless load + one-shot snapshot                                                                                                                                                                                                                                                                                                                                          | ✅                                      |
| 1     | `wait` command (bootstrap turn)                                                                                                                                                                                                                                                                                                                                            | ✅                                      |
| 2     | persistent `--arcopolis-run-script` + `--arcopolis-export-dir` (T→T→T+1)                                                                                                                                                                                                                                                                                                   | ✅                                      |
| 3     | movement via `command → do_turn`                                                                                                                                                                                                                                                                                                                                           | ❌ failed (turn inversion) — superseded |
| 3.1A  | input-seam architecture (the fix)                                                                                                                                                                                                                                                                                                                                          | ✅                                      |
| 3.1B  | clean-park hardening + final-on-exit snapshot                                                                                                                                                                                                                                                                                                                              | ✅                                      |
| 3.1C  | `session.jsonl` transcript                                                                                                                                                                                                                                                                                                                                                 | ✅                                      |
| 4     | offline viewer / contract consumer (Python → HTML)                                                                                                                                                                                                                                                                                                                         | ✅                                      |
| 5     | `is_avatar` marker + `seed` in `session_start`                                                                                                                                                                                                                                                                                                                             | ✅                                      |
| 6A    | nearby monster export (`entities.monsters[]`)                                                                                                                                                                                                                                                                                                                              | ✅                                      |
| 6B    | monster witness fixture (`ArcopolisNearMonsterTest`) + monster regression                                                                                                                                                                                                                                                                                                  | ✅ validated (vs 6A build)              |
| 7A    | nearby NPC export (`entities.npcs[]`) + NPC blocker regression                                                                                                                                                                                                                                                                                                             | ✅                                      |
| 8A    | nearby ground-item export (`entities.items[]`) + item regression                                                                                                                                                                                                                                                                                                           | ✅                                      |
| 9A    | external player-loop harness (cell bundles, HTML view/inspect, outcome explain, one-shot run; `tools/arcopolis_client`)                                                                                                                                                                                                                                                    | ✅                                      |
| 9B    | minimal persistent live protocol over stdin/stdout JSONL (`--arcopolis-live`, one request at a time, same seam)                                                                                                                                                                                                                                                            | ✅                                      |
| 10A   | browser frontend prototype: stdlib HTTP bridge + plain HTML/JS driving `--arcopolis-live` (`tools/arcopolis_frontend/`)                                                                                                                                                                                                                                                    | ✅                                      |
| 10B   | frontend-side snapshot diff: changed-tile highlights, before→after inspector, change summary, open/closed door glyphs                                                                                                                                                                                                                                                      | ✅                                      |
| 10C   | optional frontend tileset rendering: bridge re-serves `gfx/UltimateCataclysm`, browser paints sprites, glyph fallback                                                                                                                                                                                                                                                      | ✅                                      |
| 11A   | directed `examine` via a one-shot nested-input answer + auto-cancel guard at `input_context::handle_input`                                                                                                                                                                                                                                                                 | ✅                                      |
| 11B   | 8-way planar move + 8-way-plus-`here` examine in the **browser frontend + bridge** (backend was already 8-way: #34 move, #31 examine)                                                                                                                                                                                                                                      | ✅                                      |
| 12A   | GUI-equivalent `pickup` prompt/menu transaction (live mode): the real `"PICKUP"` menu exposed as a `prompt` + selected by registered actions through the engine's own loop (level 4); doc 30                                                                                                                                                                               | ✅                                      |
| 12A+  | follow-up: the pickup transaction fails loud (vehicle submenu → `unsupported_command`; non-live pickup → `unsupported_command`) or marks the secondary capacity prompt partial — never silent auto-cancel-as-success; doc 31                                                                                                                                               | ✅                                      |
| 13A   | backend-UI-mode audit: `test_mode` conflates render/keyboard suppression (wanted) with aborting UI loops before their real input (not wanted); classifies every mechanism; designs (not builds) the mode; doc 32                                                                                                                                                           | ✅ audit only                           |
| 13B   | one backend-driven `uilist` at level 4: the vehicle-source `"Get items from where?"` submenu un-aborted + setup-headless + driven via `input_context("UILIST")` (was fail-loud); doc 33                                                                                                                                                                                    | ✅                                      |
| 14    | second backend-driven `uilist` at level 4: the in-activity secondary capacity/wield/spill `uilist` (`handle_problematic_pickup`) reuses the 13B mechanism unchanged at a second site (was marked-partial); doc 34                                                                                                                                                          | ✅                                      |
| 15    | one backend-driven `query_popup` at level 4: the deployed-furniture take-down `query_yn` (`input_context("YESNO")`), driven via served `LEFT`/`CONFIRM` through the real `query_once` loop, witness-scoped to that one call site (a different Class 2 mechanism than `uilist`); doc 35                                                                                     | ✅                                      |
| 16    | non-live `--arcopolis-run-script` prompt answers: a command step's declared `prompt_answers` feed the SAME `backend_resolve_*` machinery as live mode (all four classes at level 4); missing/wrong/unused answers fail loud (`script_prompt_failed`, exit 13); one-shot pickup stays fail-loud; doc 36                                                                     | ✅                                      |
| 19    | backend UI/prompt **boundary cleanup** (NO behavior change): un-abort gates renamed to the per-transaction family `backend_uilist_transaction_active` / `backend_query_popup_transaction_active`; a central served-category + invariant block added to `arcopolis_backend_input.h`; the `test_mode` un-abort-witness vs renderer-neutral-UI-mode boundary recorded; doc 40 | ✅ refactor/docs only                   |

## Source & tests

`src/arcopolis_export.{h,cpp}` (snapshot; `write_entities` → `entities.monsters[]` Spike 6A +
`entities.npcs[]` Spike 7A + `entities.items[]` Spike 8A, one shared `in_export_window` predicate; items
iterate the tile window and read `map::i_at`) ·
`arcopolis_command.{h,cpp}` (verb→action_id, errors; Spike 11A adds the examine vocabulary + the
direction→chooser-action mapping; Spike 12A adds the `pickup` verb + the `target_*` rename so examine
and pickup share one chooser-direction table) ·
`arcopolis_script.{h,cpp}` (script runner) · `arcopolis_backend_input.{h,cpp}` (input-seam provider,
clean-park, final snapshot; Spike 9B adds the pluggable `live_source` pull hook + the public
step-snapshot writer; Spike 11A adds the one-shot nested-input slot, the pure guard decision and
the hard-fail; Spike 12A adds the DISTINCT pickup-transaction flag + registered-action queue + its serve
branch, the pluggable `prompt_source` hook and `backend_resolve_pickup_choice`; **Spike 13B adds
`backend_uilist_transaction_active()` (the per-transaction uilist un-abort gate), the `"UILIST"` serve branch +
single-select queue, `backend_begin/resolve/end_uilist_transaction`, the `uilist_transaction_guard` RAII
type, and the `uilist_prompt_source` hook**) ·
`arcopolis_live.{h,cpp}` (Spike 9B: the JSONL protocol parser/formatters +
the blocking stdin pump + `run_live`; Spike 12A adds the `prompt`/`prompt_answer` wire format + parser,
the live `prompt_source`, and the `NEW_PICKUP_MENU=true` fail-loud; **Spike 13B adds the live
`uilist_prompt_source` (`kind:"uilist"`, single-select)**) · `arcopolis_session_log.{h,cpp}`
(transcript; Spike 12A adds the five `prompt_*` events; **Spike 13B adds the optional `kind` field on
`prompt_answered`/`prompt_cancelled`/`prompt_completed`, emitted only when non-empty**). Flags wired in
`src/main.cpp`; the seam branch lives at `src/handle_action.cpp`, the clean-park at `src/game.cpp`,
and the Spike 11A nested-input hook at the top of `input_context::handle_input` in `src/input.cpp`
(the third engine touch point — and a third recurring upstream-rebase collision surface). **Spike 12A
adds a fourth gated engine touch:** a session-gated pre-loop block in `pick_up_from_items`
(`src/pickup.cpp`) that exposes the real menu choices and arms the registered-action queue, leaving the
`"PICKUP"` menu loop itself UNMODIFIED. **Spike 13B adds a fifth gated engine touch (a new
upstream-rebase collision surface):** `uilist::init`/`query` in `src/ui.cpp` take the `test_mode` abort
only when `!backend_uilist_transaction_active()`, and `query()` runs `setup()` directly under the gate (a non-render
init path); the vehicle-source block in `src/pickup.cpp` drives that uilist, leaving the `uilist::query`
loop itself UNMODIFIED. **Spike 14 reuses those touches verbatim at a second `src/pickup.cpp` site
(`handle_problematic_pickup`)** — no new gated engine touch, no new public Arcopolis symbol; the only
seam-layer change is the `live_vehicle_source_prompt` → `live_uilist_prompt` rename in
`src/arcopolis_live.cpp` (the body is unchanged), making the channel's now-general use across both
backend-driven uilists explicit in the name. **Spike 15 adds the parallel `query_popup` machinery**:
`arcopolis_backend_input.{h,cpp}` gain `backend_query_popup_transaction_active()`, the
`examine_query_popup_command` flag + the `query_popup.armed` per-prompt flag (a member of the Spike 19
`prompt_transaction` regroup),
`backend_arm_examine_query_popup_command`/`backend_begin/resolve/end_query_popup_transaction`, the
`query_popup_witness_guard` RAII type, the `backend_query_popup_request` struct + `query_popup_source` hook,
and a `"YESNO"` serve branch; `arcopolis_live.{h,cpp}` add `live_query_popup_prompt` (single-select,
non-cancelable) + arm the examine precondition; and **two new gated engine touches** — `query_popup::query_once`
in `src/popup.cpp` takes its `test_mode` abort only when `!backend_query_popup_transaction_active()` (plus two
additive const accessors `current_index()`/`has_window()`), and `query_yn` in `src/output.cpp` drives the
real loop under the gate — with the witness guard (the discriminator) in `iexamine::deployed_furniture`
(`src/iexamine.cpp`). The `prompt_*` transcript events + the prompt/answer wire are reused with
`kind:"query_popup"` (no new event kinds). **Spike 16 adds non-live script prompt answers with NO new engine
touch and NO change to the resolve functions / serve branches / un-abort sites (12A–15 reused verbatim):**
`arcopolis_script.{h,cpp}` gain the `script_prompt_answer` struct + `script_step.prompt_answers`, the
`parse_prompt_answers` structural validator (`choice`→`choices` canonicalization), the `pickup` direction
branch, the relaxed `is_live_only_command` pre-flight (allow `pickup` WITH answers), and the install of the
three script sources in `run_script`; `arcopolis_backend_input.{h,cpp}` gain the per-command answer queue in
the session, `backend_load_scripted_prompt_answers`, the three sources `script_pickup_prompt`/
`script_uilist_prompt`/`script_query_popup_prompt` (matching/validation + fail-loud), the
`record_script_prompt_failure` + `clear_stale_scripted_prompt_answers` (unused-answer check) + the steps-walk
dispatch arming (pickup transaction / examine query_popup precondition) and `done`-guard; `arcopolis_command.
{h,cpp}` gain `command_error_kind::script_prompt_failed` (→ exit 13). The script sources write NO stdout
(transcript-only).
Unit tests: `tests/arcopolis_*_test.cpp` (`[arcopolis]` tag). Consumers (all stdlib-only,
deliberately share-nothing so each independently re-derives the contract):
`tools/arcopolis_viewer/make_report.py` (Spike 4 offline HTML report) and
`tools/arcopolis_client/harness.py` (Spike 9A player-loop harness — cell bundles keyed by
`pos_local`, HTML local view + tile inspector, per-command outcome classification, one-shot `run`
mode, plus the Spike 9B `live` probe driving the persistent protocol with a verified protocol-only
stdout; subcommands now **view / explain / run / live**; see
[20_SPIKE9A_CLIENT_HARNESS.md](20_SPIKE9A_CLIENT_HARNESS.md) and
[21_SPIKE9B_LIVE_PROTOCOL.md](21_SPIKE9B_LIVE_PROTOCOL.md)), and
`tools/arcopolis_frontend/prototype_server.py` + `static/` (Spike 10A browser frontend prototype —
a stdlib-only HTTP bridge owning one `--arcopolis-live` backend, plus a plain HTML/JS map +
inspector UI; see [22_SPIKE10A_FRONTEND_PROTOTYPE.md](22_SPIKE10A_FRONTEND_PROTOTYPE.md); Spike 10B
adds **frontend-side snapshot diffing** to the same static assets — changed-tile highlights keyed
on snapshot identity with an origin-delta correction across bubble rebases, a before→after tile
inspector, a change-summary panel, per-cell exact-id tooltips, and open/closed door glyphs, with
zero bridge/snapshot/protocol change; see
[23_SPIKE10B_FRONTEND_SNAPSHOT_DIFF.md](23_SPIKE10B_FRONTEND_SNAPSHOT_DIFF.md); Spike 10C adds
**optional tileset rendering** — the bridge re-serves a whitelisted `gfx/UltimateCataclysm`
asset set under `/tileset/`, the browser parses `tile_config.json` itself (global 0-based sprite
indices over concatenated sheets, engine-cited) and paints cells as sprite layers behind a
[Glyph]/[Tileset] toggle, with the glyph renderer as the **safe visual fallback** per cell and
wholesale — NOT a faithful BN renderer (no multitile/rotation/variation-weights/animation/
looks_like/overhang); see
[24_SPIKE10C_FRONTEND_TILESET_RENDERING.md](24_SPIKE10C_FRONTEND_TILESET_RENDERING.md); Spike 11B
makes the static UI's planar surface GUI-equivalent — a 3×3 d-pad + click-to-move reaching all eight
neighbors and a Move/Examine mode selector that sends `examine` in any of the eight planar directions
plus `here`, with the bridge classifying diagonal moves and a non-misleading `examined` outcome; see
[29_SPIKE11B_GUI_EQUIVALENT_PLANAR_MOVE_EXAMINE.md](29_SPIKE11B_GUI_EQUIVALENT_PLANAR_MOVE_EXAMINE.md)).
Fixture-driven
regressions (need a loaded world, so not in CI; the fixture worlds themselves are cataloged in
[TEST_FIXTURES.md](TEST_FIXTURES.md)):
[`docs/arcopolis/movement_regression.ps1`](movement_regression.ps1) gates movement/NPC on **`ArcopolisTest`**,
[`docs/arcopolis/npc_export_regression.ps1`](npc_export_regression.ps1) gates the **NPC export** on the same
**`ArcopolisTest`** (the stock shelter NPC Edwardo is already in the radius-12 window, so it needs no save
edit — `ArcopolisTest` is now **both** the movement/NPC-blocker fixture **and** the NPC-export witness; see
[18_SPIKE7A_NPC_EXPORT.md](18_SPIKE7A_NPC_EXPORT.md)), and
[`docs/arcopolis/monster_export_regression.ps1`](monster_export_regression.ps1) gates the monster export on
**`ArcopolisNearMonsterTest`** — the monster-export witness, a clone of `ArcopolisTest` with one in-window
monster, built reproducibly by [`docs/arcopolis/make_monster_fixture.py`](make_monster_fixture.py) (save-edit,
no GUI/build, witness on **passable** terrain so it stays put); see
[16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md](16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md) and the load/wall-eject
analysis [17_MONSTER_LOAD_AND_WALL_EJECT.md](17_MONSTER_LOAD_AND_WALL_EJECT.md).
[`docs/arcopolis/item_export_regression.ps1`](item_export_regression.ps1) gates the **ground-item export** on
**`ArcopolisTest`** (its saved evac shelter already holds 27 deterministic in-window ground items, so it is
the item-export witness with **no** save edit; `export(items_before) → wait → export(items_after_wait)`); see
[19_SPIKE8A_ITEM_EXPORT.md](19_SPIKE8A_ITEM_EXPORT.md).
[`docs/arcopolis/client_harness_regression.ps1`](client_harness_regression.ps1) gates the **Spike 9A client
harness** end-to-end on **`ArcopolisTest`** (one session `export → move_n → export → move_s → export → wait →
export`; asserts the harness classifies `blocked_no_op` (naming Edwardo from the before-snapshot bundle),
`moved`, `waited`, and the final `no_command` pair, that the HTML view/inspector carries the blocker, that
run mode reproduces the sequence, and that the Spike 4 viewer accepts the same session; plus a
monster-fixture run-mode gate on **`ArcopolisNearMonsterTest`** — `waited` tick with ≥1 exported monster,
the `M` cell rendered, and the inspector listing the Spike 6B witness on its tile); see
[20_SPIKE9A_CLIENT_HARNESS.md](20_SPIKE9A_CLIENT_HARNESS.md).
[`docs/arcopolis/live_protocol_regression.ps1`](live_protocol_regression.ps1) gates the **Spike 9B live
protocol** end-to-end on **`ArcopolisTest`**: the harness `live` probe drives ONE persistent backend
(`ready` → `export start` → `move_n` → `move_s` → `wait` → `quit`, one request per response, every
stdout line verified JSON) and must re-derive the SAME `blocked_no_op,moved,waited,no_command`
sequence through the unchanged explain pipeline, plus a recoverability scenario (a rejected `move_up`
answers `ok=false`/`unsupported_command` without ending the session, then a recovery `wait` succeeds);
see [21_SPIKE9B_LIVE_PROTOCOL.md](21_SPIKE9B_LIVE_PROTOCOL.md).
[`docs/arcopolis/examine_regression.ps1`](examine_regression.ps1) gates the **Spike 11A directed
examine** on **`ArcopolisTest`** (raw requests through
[`docs/arcopolis/examine_live_driver.py`](examine_live_driver.py), strict per-response timeouts —
a hang kills the backend and FAILS; two scenarios with `AUTOSELECT_SINGLE_VALID_TARGET` pinned in
the sandbox options per scenario (13 gates): `false` witnesses the served cardinal answer toward the
shelter NPC, the pickup-tail `"PICKUP"` guard-cancel on the adjacent item pile with zero items taken,
a **diagonal** `examine move_sw` serving `"LEFTDOWN"` to the engine chooser (the full eight-direction
vocabulary, not a cardinal subset), the engine message stream as an independent second witness chain,
the recoverable bad-direction rejections and the unchanged move/wait baseline; `true` witnesses the
engine auto-select skip + the `nested_input_unconsumed` force-clear); see
[26_SPIKE11A_DIRECTED_EXAMINE.md](26_SPIKE11A_DIRECTED_EXAMINE.md).
[`docs/arcopolis/prompt_menu_regression.ps1`](prompt_menu_regression.ps1) gates the **Spike 12A pickup
prompt/menu transaction** on **`ArcopolisTest`** + **`ArcopolisBackpackTest`** (prompt-aware driver
[`docs/arcopolis/prompt_menu_live_driver.py`](prompt_menu_live_driver.py), strict per-response timeout —
a hang kills the backend and FAILS): after one `move_s` the south item pile is the witness; a `pickup`
opens a `prompt` carrying the menu's REAL choices, a `prompt_answer` selecting the last entry is served as
`[DOWN×K, RIGHT, CONFIRM]` through the engine's own `"PICKUP"` loop (transcript
`prompt_opened`/`prompt_answered`/`prompt_completed`), the chosen item leaves the ground (a real engine
state change + a "You pick up:" message), `prompt_cancel` is the GUI ESC no-op, an invalid answer is a
recoverable rejection with the prompt left open, and `NEW_PICKUP_MENU=true` fails loud. Further gates
cover multi-select: **rejected items** — a `choices:[0,6]` pick of an over-capacity item + a carriable one
carries only what fits and leaves the rejected item on the ground, never logged as picked up; the
**follow-up (doc 31)** additionally asserts the response is MARKED `{ forced_cancel, partial,
unsupported_prompt:"secondary_capacity" }` + a `prompt_force_cancelled` transcript event (NOT full success) —
and **carry-both** — a `choices:[5,6]` pick deposits BOTH
items (7 → 5) on the backpack avatar (`ArcopolisBackpackTest`). **Gate H is now the Spike 13B
backend-driven vehicle-source `uilist`** on **`ArcopolisVehicleCargoTest`** (a `folding_wagon` injected onto
the pile via [`docs/arcopolis/make_vehicle_fixture.py`](make_vehicle_fixture.py)) — four sub-gates: the
prompt opens `kind=uilist` with the 2 real choices in order, answering "ground" is served `[DOWN, CONFIRM]`
through `input_context("UILIST")` (`prompt_completed kind=uilist actions_served=2`), the old `"PICKUP"` menu
then opens separately and the chosen ground item leaves the ground (`7 → 6`), `prompt_cancel` on the uilist
takes no items (no silent ground-only pickup), and a wrong `prompt_id` + out-of-range choice are each
rejected with the prompt open then a valid answer completes. **Gate I** (non-live fail-loud — script +
one-shot `pickup` exit 6 before load) is unchanged. **Run with `pwsh`, not `powershell` 5.1** (the latter
mangles UTF-8 reads + options.json BOM → false failures). See
[30_SPIKE12A_PROMPT_MENU_TRANSACTION.md](30_SPIKE12A_PROMPT_MENU_TRANSACTION.md),
[31_SPIKE12A_FOLLOWUP_FAIL_LOUD.md](31_SPIKE12A_FOLLOWUP_FAIL_LOUD.md) and
[33_SPIKE13B_BACKEND_DRIVEN_UILIST.md](33_SPIKE13B_BACKEND_DRIVEN_UILIST.md).
[`docs/arcopolis/query_popup_regression.ps1`](query_popup_regression.ps1) gates the **Spike 15
backend-driven `query_popup`** on **`ArcopolisDeployedFurnitureTest`** (a clone of `ArcopolisTest` with one
`f_floor_mattress` placed one tile EAST of the avatar, built by
[`make_furniture_fixture.py`](make_furniture_fixture.py)), reusing
[`prompt_menu_live_driver.py`](prompt_menu_live_driver.py) unchanged — six gates: a live `examine move_e`
opens a `kind=query_popup` prompt (2 ordered YES/NO choices, `cancelable:false`); answering YES is served
`[LEFT, CONFIRM]` and NO `[CONFIRM]` through the real `input_context("YESNO")` loop (`prompt_completed
kind=query_popup`); YES takes down the furniture (`f_floor_mattress`→absent + a `mattress` item dropped +
"You take down the mattress.") while NO leaves it; an out-of-range/wrong-`prompt_id`/non-cancelable
`prompt_cancel` are each rejected with the prompt open then a valid answer completes; and an EOF/closed
client exits CLEAN (backend exit 0, transcript `prompt_cancelled noncancelable_closed`, not an answer). See
[35_SPIKE15_BACKEND_DRIVEN_QUERY_POPUP.md](35_SPIKE15_BACKEND_DRIVEN_QUERY_POPUP.md).
[`docs/arcopolis/script_prompt_regression.ps1`](script_prompt_regression.ps1) gates the **Spike 16 non-live
script prompt answers** — a PURE run-script regression (no live driver) across all four fixtures: W1 scripted
`pickup` menu answer on `ArcopolisTest` (served `[DOWN×6, RIGHT, CONFIRM]`, south pile `7 → 6`), W2
vehicle-source `uilist`→menu on `ArcopolisVehicleCargoTest` (`kind=uilist` then `kind=menu`, `7 → 6`), W3
secondary capacity `uilist` on `ArcopolisCapacityTest` (a probe finds the jacket index; the run drives
`kind=menu` then `kind=uilist` WIELD, **not** force-cancelled, the jacket leaves the ground), W4
`query_popup` YES/NO on `ArcopolisDeployedFurnitureTest` (YES `[LEFT, CONFIRM]` takes the furniture down +
drops a mattress; NO `[CONFIRM]` leaves it); plus 3 fail-loud gates — pickup with no answers → exit 6, a
wrong-kind answer → exit 13 (`prompt_failed kind_mismatch`), an unused answer → exit 13 (`error
kind=script_prompt_failed`). **Run with `pwsh`.** See [36_SPIKE16_SCRIPT_PROMPT_ANSWERS.md](36_SPIKE16_SCRIPT_PROMPT_ANSWERS.md).
[`docs/arcopolis/frontend_prototype_regression.ps1`](frontend_prototype_regression.ps1) gates the
**Spike 10A browser-frontend bridge** on **`ArcopolisTest`**: it starts
`tools/arcopolis_frontend/prototype_server.py`, drives the whole HTTP API (start → move_n → move_s
→ wait → export → a `move_up` recoverability probe → quit → restart → shutdown; **18 gates** incl.
the Spike 10B diff-UI static-hook gate 2b, the Spike 10C tileset gate 2c — `/tileset/info` +
config + config-derived sheet PNGs + whitelist/traversal 404s + served UI hooks — the Spike 11B
gate 2d (the 8 direction buttons + `here` + Move/Examine controls + 8 delta mappings + examine
dispatch served, the hint no longer "N/S/E/W"), the Spike 11B gate 13 (a fresh restartable
session_002 that examines move_n/here → `examined`, recoverably rejects examine move_up, and steps
the **diagonal** move_se → `moved` `[1,1,0]` as a HARD fixture assertion), and the Spike
10C gate 15, a second `--disable-tileset` server proving the glyph-only fail-safe) and
asserts the bridge re-derives the SAME `blocked_no_op,moved,waited,no_command` sequence through the
live protocol, that the backend exits 0 with a final snapshot + transcript, and that the server
stops cleanly; see [22_SPIKE10A_FRONTEND_PROTOTYPE.md](22_SPIKE10A_FRONTEND_PROTOTYPE.md),
[23_SPIKE10B_FRONTEND_SNAPSHOT_DIFF.md](23_SPIKE10B_FRONTEND_SNAPSHOT_DIFF.md),
[24_SPIKE10C_FRONTEND_TILESET_RENDERING.md](24_SPIKE10C_FRONTEND_TILESET_RENDERING.md) and
[29_SPIKE11B_GUI_EQUIVALENT_PLANAR_MOVE_EXAMINE.md](29_SPIKE11B_GUI_EQUIVALENT_PLANAR_MOVE_EXAMINE.md).

## Known-unsupported / fail-loud (single source)

Every unsupported path is **fail-loud** (typed error + nonzero exit) or an **honest marked partial** —
never a silent _fake success_. **Caveat (doc 38):** that guarantee covers fabricated success, NOT every
prompt — an unguarded `query_yn` reached through the **supported** `examine` verb silently defaults to NO
(unmarked, exit 0; row below). Line numbers are current-tree (Spike 17) and may drift; confirm by symbol.
Centralized here by the Spike 17 audit ([37_SPIKE17_CLAIM_AUDIT.md](37_SPIKE17_CLAIM_AUDIT.md)); the level-4
truth pass is [38_LEVEL4_TRUTH_AUDIT.md](38_LEVEL4_TRUTH_AUDIT.md).

| Trigger                                                                                                                          | Behavior                                                                                      | Exit            | Where                                                                                    |
| -------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | --------------- | ---------------------------------------------------------------------------------------- |
| `pickup` under `NEW_PICKUP_MENU=true` (live)                                                                                     | reject pre-flight, `unsupported_command`                                                      | 6               | `src/arcopolis_live.cpp`                                                                 |
| `pickup` under `NEW_PICKUP_MENU=true` (run-script)                                                                               | post-load reject                                                                              | 6               | `src/arcopolis_script.cpp`                                                               |
| one-shot `--arcopolis-command pickup` (no answer channel)                                                                        | reject pre-flight                                                                             | 6               | `src/arcopolis_export.cpp`; `is_live_only_command` `src/arcopolis_command.cpp:95-101`    |
| `--arcopolis-run-script pickup` with NO `prompt_answers`                                                                         | reject                                                                                        | 6               | `src/arcopolis_script.cpp`                                                               |
| vehicle/secondary uilist with a transaction but NO uilist channel                                                                | marked partial, CANCEL                                                                        | 13 (run-script) | `src/pickup.cpp:195-198`                                                                 |
| secondary capacity uilist with ANY disabled entry                                                                                | refuse (`scrollby` would mis-navigate); marked partial; backstop `disabled_entry_unsupported` | 13 (run-script) | `src/pickup.cpp:285-288`; `src/arcopolis_backend_input.cpp:817`                          |
| multi-tick resumed orphaned secondary                                                                                            | report marks, sets NO outcome, CANCEL                                                         | — (marked)      | `src/pickup.cpp:208-211`                                                                 |
| scripted answer missing/wrong-kind/title-mismatch/out-of-range/cancel-of-noncancelable/unused                                    | `script_prompt_failed` (first-failure-wins)                                                   | 13              | `src/arcopolis_backend_input.cpp`; `src/arcopolis_command.cpp:269-270`                   |
| generic `popup()`/`popup_getkey()`/`PF_GET_KEY`→`ANY_INPUT` (never arms a transaction)                                           | `query_once` test_mode abort `{false,"ERROR",{}}`                                             | — (aborted)     | `src/output.cpp`; `src/popup.cpp:277-279`                                                |
| any `query_yn` ≠ the deployed-furniture witness (incl. via the supported `examine` verb)                                         | test_mode abort → **silent NO, unmarked**                                                     | 0 (silent)      | `src/popup.cpp:277-279` → `src/output.cpp:748`                                           |
| any other `uilist` (cata_test, computer, NPC dialogue)                                                                           | test_mode abort → `UILIST_ERROR`                                                              | —               | `src/ui.cpp:933-937` (gated on per-transaction `backend_uilist_transaction_active()`)    |
| `pickup` under `NEW_PICKUP_MENU=true` / `inventory_selector` (NOT a `uilist`; no narrow `test_mode` abort to pierce — doc 39 §4) | reject pre-flight, `unsupported_command`                                                      | 6               | `src/arcopolis_live.cpp:213-218` (live); `src/arcopolis_script.cpp:357-365` (run-script) |

**Still backlog (no driving claim):** vertical `move` (`<`/`>`); explicit `open`/`close`/`smash`; per-unit
pickup quantity (whole-stack only); nested-container parent/child mark propagation (exposed but
**unexercised**, `src/pickup.cpp:1107-1123`); NPC talk/attack/swap; monster menus; computer use; the
examine auto-pickup tail (still ESC-cancels); the `inventory_selector` (`NEW_PICKUP_MENU=true`); multi-tick
resumed-activity secondary prompts; generic `popup()`/`query_popup` families.

## Deferred backlog

- **Richer read-only export:** dynamic entities — **monsters done (Spike 6A, `entities.monsters[]`), NPCs
  done (Spike 7A, `entities.npcs[]`), ground items done (Spike 8A, `entities.items[]`)**; fields and vehicles
  still deferred (#2), and so is **item depth beyond the ground-item v0** — avatar/NPC **inventory**,
  **vehicle cargo** (`vehicle::get_items`, a separate stack), **nested-container contents**, and
  weight/volume/damage/rot/per-item state — plus per-tile symbol/colour (#1), message type/severity (#4 —
  needs a public `Messages::` accessor), multi-z (#5), and **richer NPC fields** (faction / dialogue /
  mission / opinion detail, stable persistent IDs — explicitly deferred from 7A's conservative v0).
  Dynamic-entity export is the linchpin: monsters + NPCs + ground items now exist, bringing the deferred
  **world-tick regression harness** closer (still needs a `--arcopolis-new-world` generator + monster/field
  state to witness a tick — see [10_SPIKE3_1B_CLEAN_PARK_HARDENING.md](10_SPIKE3_1B_CLEAN_PARK_HARDENING.md)).
- **Live protocol:** **v0 done (Spike 9B)** — a persistent process serving stdin/stdout JSONL, one
  request at a time, through the M1 seam with a blocking pull source. Still deferred: sockets/named
  pipes, framing/acks beyond line-delimited JSON, concurrent/pipelined requests, inline snapshots,
  save/resume of a live session, and a transcript record for rejected requests (an additive
  `"rejected"` event kind). The Spike 10A browser prototype consumes v0 as-is over a polling HTTP
  bridge; push updates (SSE/long-poll) are deferred with the rest.
- **Frontend tileset rendering depth:** 10C's browser tileset mode is deliberately a v0 render
  skin, **not** a faithful BN renderer — still deferred: multitile/connection subtiles, rotation
  and variation-weight selection, animation, `looks_like` resolution (game-data JSON, a separate
  contract surface), sprite overhang for oversized art, progressive sheet loading, and avatar/NPC
  sprite identity (blocked on export fields, not frontend work); unresolved ids keep the glyph,
  the safe visual fallback (see [24_SPIKE10C_FRONTEND_TILESET_RENDERING.md](24_SPIKE10C_FRONTEND_TILESET_RENDERING.md)).
- **Richer commands:** **directed `examine` is implemented and runtime-proven (Spike 11A,
  [26_SPIKE11A_DIRECTED_EXAMINE.md](26_SPIKE11A_DIRECTED_EXAMINE.md), built exactly per the
  decision record [25_SPIKE11A_EXAMINE_FEASIBILITY.md](25_SPIKE11A_EXAMINE_FEASIBILITY.md)) — the
  nested-input answer + auto-cancel guard now exists for every future prompted verb.** Still
  deferred: `look`, interaction (**open/close are the near-free follow-ups** — same chooser shape,
  prompt-free bodies, plus the `moves -= 100` turn-economy witness — then smash), **NPC
  interaction (talk/attack/swap/push — needed to act on a creature-occupied destination, the
  move-into-NPC no-op in
  [15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md](15_MOVEMENT_NPC_NOOP_ROOTCAUSE.md))**, inventory, targeting, and
  **vertical** movement (`move_up`/`move_down` → the separate `game::vertical_move` primitive, NOT a
  planar step). **`pickup` as a user-selectable action is no longer deferred — IMPLEMENTED (Spike 12A's
  prompt/menu transaction, doc 30)** for the old `"PICKUP"` menu: doc 25's **Option C is now built for
  one prompt class** (NPC dialogue / computer menus still need it; the new inventory_selector, quantities,
  and nested containers stay deferred). The examine pickup tail still ESC-cancels (no transaction armed).
  **Planar diagonals are no longer deferred:** `move` is 8-way (#34) and `examine` is
  8-way-plus-`here` (#31), and the browser prototype now exposes both 8-way (Spike 11B,
  [29_SPIKE11B_GUI_EQUIVALENT_PLANAR_MOVE_EXAMINE.md](29_SPIKE11B_GUI_EQUIVALENT_PLANAR_MOVE_EXAMINE.md)).
- **Backend UI mode (named architectural prerequisite — Spike 13A audit,
  [32_SPIKE13A_BACKEND_UI_MODE_AUDIT.md](32_SPIKE13A_BACKEND_UI_MODE_AUDIT.md)).** Spike 12A proved
  **level-4** driving of the old `"PICKUP"` menu (it reaches a real `input_context::handle_input`
  loop), and the follow-up (doc 31) made the unsupported pickup-adjacent prompts **fail loud /
  marked** rather than silently auto-cancel-as-success. Spike 13A audited why broader prompt/menu
  support is blocked: **`test_mode` conflates two jobs** — suppressing rendering/real keyboard
  (Arcopolis needs this) **and** aborting some UI loops before their real input runs (Arcopolis does
  not), most notably **`uilist::query` short-circuiting to `UILIST_ERROR` before its `input_context`
  is even built** (`src/ui.cpp:933-937`), so the Spike 11A guard never sees it (`query_popup::query_once`
  is the same, `src/popup.cpp:277-279`). A distinct **backend UI mode** — one that keeps the
  render/keyboard suppression but lets the real `input_context` loops run and be served registered
  actions, failing loud on any class it cannot yet drive — is now a named backlog item **before**
  broader prompt/menu support (the new inventory_selector, computer menus, NPC dialogue) and
  **before** treating pipes as a robust frontend boundary. **The narrow proof spike (13B) is BUILT
  ([33_SPIKE13B_BACKEND_DRIVEN_UILIST.md](33_SPIKE13B_BACKEND_DRIVEN_UILIST.md)):** one `uilist` (the
  vehicle-source pickup submenu) runs headlessly to its real `input_context("UILIST")::handle_input`
  loop, with `setup()` populating `fentries`/retvals on a non-render path, consuming registered
  `DOWN`/`CONFIRM` Arcopolis supplies through the seam, at equivalence level 4 — gated on a
  per-transaction `backend_uilist_transaction_active()` so cata_test and every other `uilist` still abort. **Spike 14
  ([34_SPIKE14_SECONDARY_PICKUP_UILIST.md](34_SPIKE14_SECONDARY_PICKUP_UILIST.md)) reuses the same UILIST
  machinery unchanged at a second hardcoded call site under the same per-transaction gate:** the in-activity
  secondary capacity/wield/spill `uilist` (`handle_problematic_pickup`) is now driven too — same `"UILIST"`
  serve branch, same `backend_uilist_transaction_active()` gate, witness-scoped per arming. **Spike 15
  ([35_SPIKE15_BACKEND_DRIVEN_QUERY_POPUP.md](35_SPIKE15_BACKEND_DRIVEN_QUERY_POPUP.md)) adds a SEPARATE
  per-transaction family for a DIFFERENT Class 2 mechanism — `query_popup`:** the deployed-furniture take-down `query_yn`
  (`input_context("YESNO")`) is now driven at level 4 via served `LEFT`/`CONFIRM`, with its OWN per-prompt
  gate `backend_query_popup_transaction_active()` un-aborting `query_popup::query_once` (`src/popup.cpp:277`),
  witness-scoped to that one call site. **Spike 16
  ([36_SPIKE16_SCRIPT_PROMPT_ANSWERS.md](36_SPIKE16_SCRIPT_PROMPT_ANSWERS.md)) makes all four driven classes
  replayable in non-live `--arcopolis-run-script`:** a command step's declared `prompt_answers` feed the SAME
  `backend_resolve_*` machinery via three script prompt sources (no new engine touch), failing loud
  (`script_prompt_failed`, exit 13) on any missing/wrong/unused answer. Still backlog: the
  `popup()`/`popup_getkey()` family (`"POPUP_WAIT"`
  - the `PF_GET_KEY` `ANY_INPUT` caveat from doc 32), generic `query_popup` / any other `query_yn`, the new
    inventory_selector, computer menus, NPC dialogue, **one-shot `--arcopolis-command` prompts**, and
    **multi-tick resumed-activity secondary prompts** — each is a candidate for its OWN new per-family
    per-transaction gate + serve branch reusing the existing seam machinery (the per-family witness pattern of
    13B/14/15, NOT a shared "mode"); none are implemented yet. **Spike 19 ([40_SPIKE19_BACKEND_UI_BOUNDARY.md](40_SPIKE19_BACKEND_UI_BOUNDARY.md))
    renamed the un-abort gates to the per-transaction `*_transaction_active` family and centralized the
    served-category + invariant boundary in `src/arcopolis_backend_input.h` (no behavior change), so the
    distinction these per-transaction witnesses embody — a `test_mode` un-abort witness is NOT a
    renderer-neutral backend UI mode (doc 39 §5.1) — is now explicit in the code; it adds no capability.**

## Build (Windows)

Activate the VS DevShell, append `C:\dev\ccache` to PATH, configure with `-G Ninja
-DCMAKE_BUILD_TYPE=RelWithDebInfo` into **one** `out/build/win-rel-deb` dir (game + tests share the
`cataclysm-bn-tiles-common` OBJECT lib; a second dir exhausts the disk), then `cmake --build
.\out\build\win-rel-deb --target cataclysm-bn-tiles cata_test-tiles`. Format touched C++ first with
`C:\dev\astyle\bin\AStyle.exe --options=.astylerc -n <files>` (the CMake "astyle not found" warning is a
PATH gotcha, not unavailability). **Footprint (measured 2026-06-18):** the shared `win-rel-deb` dir is
**~7.6 GB** (one-time cold build); a routine **incremental** rebuild only recompiles the touched TUs and
relinks the exe — **~a couple hundred MB**, not GB. Exact commands + disk/ccache notes:
[00_WINDOWS_LOCAL_ENVIRONMENT.md](00_WINDOWS_LOCAL_ENVIRONMENT.md).
