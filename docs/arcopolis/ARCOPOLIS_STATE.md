# Arcopolis backend — current state (truth as of Spike 12A, 2026-06-14)

A single-page checkpoint of what the Arcopolis backend **is today**, so you don't have to
reconstruct it from the per-spike history. The numbered `NN_SPIKE*.md` docs are the chronological
record (including a **failed** Spike 3); **this page is the current truth.** When they disagree, this
page wins — or fix it.

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

**`pickup` + `direction` → `ACTION_PICKUP` (Spike 12A, LIVE mode only)** — a GUI-equivalent prompt/menu
transaction (doc 25's "Option C" for one prompt class). The "Pickup where?" chooser is answered like
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
both gate. After `CONFIRM`, the activity may raise a **secondary** capacity/wield/spill prompt
(`handle_problematic_pickup` `uilist`); **driving it is not implemented (a tracked defect)**, so the guard
force-cancels it and the activity halts on that item — not fidelity, a not-yet-built path. The transaction
does not fake the part it cannot do: a multi-select deposits only what the avatar can carry. The regression
witnesses both halves: **rejected items** (the over-capacity item left on the ground, never logged as picked
up) on the default `ArcopolisTest` avatar, and **carry-both** (both selected items leave) on a **3rd fixture
`ArcopolisBackpackTest`** whose avatar wears a backpack. `NEW_PICKUP_MENU=true` **fails loud**
(`unsupported_command`); script/one-shot modes have no answer channel so a pickup there auto-cancels via the
guard. The new inventory_selector, per-unit quantities, driving the secondary capacity/wield/spill prompts,
and every other menu class stay backlog. See
[30_SPIKE12A_PROMPT_MENU_TRANSACTION.md](30_SPIKE12A_PROMPT_MENU_TRANSACTION.md).

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

## Capabilities by spike

| Spike | What                                                                                                                                                                                         | State                                   |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| 0     | headless load + one-shot snapshot                                                                                                                                                            | ✅                                      |
| 1     | `wait` command (bootstrap turn)                                                                                                                                                              | ✅                                      |
| 2     | persistent `--arcopolis-run-script` + `--arcopolis-export-dir` (T→T→T+1)                                                                                                                     | ✅                                      |
| 3     | movement via `command → do_turn`                                                                                                                                                             | ❌ failed (turn inversion) — superseded |
| 3.1A  | input-seam architecture (the fix)                                                                                                                                                            | ✅                                      |
| 3.1B  | clean-park hardening + final-on-exit snapshot                                                                                                                                                | ✅                                      |
| 3.1C  | `session.jsonl` transcript                                                                                                                                                                   | ✅                                      |
| 4     | offline viewer / contract consumer (Python → HTML)                                                                                                                                           | ✅                                      |
| 5     | `is_avatar` marker + `seed` in `session_start`                                                                                                                                               | ✅                                      |
| 6A    | nearby monster export (`entities.monsters[]`)                                                                                                                                                | ✅                                      |
| 6B    | monster witness fixture (`ArcopolisNearMonsterTest`) + monster regression                                                                                                                    | ✅ validated (vs 6A build)              |
| 7A    | nearby NPC export (`entities.npcs[]`) + NPC blocker regression                                                                                                                               | ✅                                      |
| 8A    | nearby ground-item export (`entities.items[]`) + item regression                                                                                                                             | ✅                                      |
| 9A    | external player-loop harness (cell bundles, HTML view/inspect, outcome explain, one-shot run; `tools/arcopolis_client`)                                                                      | ✅                                      |
| 9B    | minimal persistent live protocol over stdin/stdout JSONL (`--arcopolis-live`, one request at a time, same seam)                                                                              | ✅                                      |
| 10A   | browser frontend prototype: stdlib HTTP bridge + plain HTML/JS driving `--arcopolis-live` (`tools/arcopolis_frontend/`)                                                                      | ✅                                      |
| 10B   | frontend-side snapshot diff: changed-tile highlights, before→after inspector, change summary, open/closed door glyphs                                                                        | ✅                                      |
| 10C   | optional frontend tileset rendering: bridge re-serves `gfx/UltimateCataclysm`, browser paints sprites, glyph fallback                                                                        | ✅                                      |
| 11A   | directed `examine` via a one-shot nested-input answer + auto-cancel guard at `input_context::handle_input`                                                                                   | ✅                                      |
| 11B   | 8-way planar move + 8-way-plus-`here` examine in the **browser frontend + bridge** (backend was already 8-way: #34 move, #31 examine)                                                        | ✅                                      |
| 12A   | GUI-equivalent `pickup` prompt/menu transaction (live mode): the real `"PICKUP"` menu exposed as a `prompt` + selected by registered actions through the engine's own loop (level 4); doc 30 | ✅                                      |

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
branch, the pluggable `prompt_source` hook and `backend_resolve_pickup_choice`) ·
`arcopolis_live.{h,cpp}` (Spike 9B: the JSONL protocol parser/formatters +
the blocking stdin pump + `run_live`; Spike 12A adds the `prompt`/`prompt_answer` wire format + parser,
the live `prompt_source`, and the `NEW_PICKUP_MENU=true` fail-loud) · `arcopolis_session_log.{h,cpp}`
(transcript; Spike 12A adds the five `prompt_*` events). Flags wired in
`src/main.cpp`; the seam branch lives at `src/handle_action.cpp`, the clean-park at `src/game.cpp`,
and the Spike 11A nested-input hook at the top of `input_context::handle_input` in `src/input.cpp`
(the third engine touch point — and a third recurring upstream-rebase collision surface). **Spike 12A
adds a fourth gated engine touch:** a session-gated pre-loop block in `pick_up_from_items`
(`src/pickup.cpp`) that exposes the real menu choices and arms the registered-action queue, leaving the
`"PICKUP"` menu loop itself UNMODIFIED.
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
regressions (need a loaded world, so not in CI):
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
recoverable rejection with the prompt left open, and `NEW_PICKUP_MENU=true` fails loud. Two further gates
cover multi-select: **rejected items** — a `choices:[0,6]` pick of an over-capacity item + a carriable one
carries only what fits and leaves the rejected item on the ground, never logged as picked up (driving the
in-activity capacity prompt is a tracked defect; the guard force-cancels it), on the default avatar — and
**carry-both** — a `choices:[5,6]` pick deposits BOTH
items (7 → 5) on the backpack avatar (`ArcopolisBackpackTest`, a copy of `ArcopolisTest` whose avatar wears
a backpack so two items fit). See
[30_SPIKE12A_PROMPT_MENU_TRANSACTION.md](30_SPIKE12A_PROMPT_MENU_TRANSACTION.md).
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

## Build (Windows)

Activate the VS DevShell, append `C:\dev\ccache` to PATH, configure with `-G Ninja
-DCMAKE_BUILD_TYPE=RelWithDebInfo` into **one** `out/build/win-rel-deb` dir (game + tests share the
`cataclysm-bn-tiles-common` OBJECT lib; a second dir exhausts the disk), then `cmake --build
.\out\build\win-rel-deb --target cataclysm-bn-tiles cata_test-tiles`. Exact commands +
disk/ccache notes: [00_WINDOWS_LOCAL_ENVIRONMENT.md](00_WINDOWS_LOCAL_ENVIRONMENT.md).
