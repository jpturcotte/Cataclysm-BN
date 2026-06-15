# Spike 11B — GUI-equivalent planar move/examine in the browser frontend + bridge

## Status

**Implemented & validated (2026-06-14).** The browser prototype (`tools/arcopolis_frontend/`) now
drives the **complete planar move/examine surface** the backend and the BN GUI already expose:
click-to-move and a 3×3 d-pad reach all **eight** adjacent tiles, and a Move/Examine mode selector
sends the backend `examine` verb in any of the **eight planar directions plus `here`** (the avatar's
own tile). The bridge classifies diagonal moves and reports a non-misleading `examined` outcome.
Frontend + Python bridge only — **zero engine/C++ changes**, zero snapshot/protocol/schema changes.

**The "GUI-equivalent" claim is bounded to the planar move + examine-targeting surfaces only.** It is
**NOT** a claim about vertical movement, prompt/menu protocols, pickup/talk/computer interaction, or a
full right-click context menu — those remain unimplemented (see _What remains not implemented_). The
claim is exactly: every planar tile a GUI player can step to, the browser can step to; every planar
examine target a GUI player can select (8 neighbors + self), the browser can select — and the verb
reaches the real `game::handle_action()` seam unchanged.

## Why this exists

`GUI behavior == engine behavior == the behavior` (AGENTS.md). The backend reached that bar for the
planar surface in two earlier PRs — `move` became 8-way in
[#34](https://github.com/jpturcotte/Cataclysm-BN/pull/34) and directed `examine` became 8-way + `here`
in [#31](https://github.com/jpturcotte/Cataclysm-BN/pull/31) (Spike 11A,
[26_SPIKE11A_DIRECTED_EXAMINE.md](26_SPIKE11A_DIRECTED_EXAMINE.md)). The browser frontend and the HTTP
bridge did **not** follow: they exposed only N/S/E/W click + N/S/E/W buttons and had no examine UI at
all, and the bridge's outcome classifier knew only four cardinal move deltas. The GUI-equivalence
audit ([28_GUI_EQUIVALENCE_AUDIT.md](28_GUI_EQUIVALENCE_AUDIT.md)) classified the frontend
click-to-move as a **violation (subset)** — a primitive presented (click-to-move) that under-delivered
(only 4 of 8 directions) — and named this spike as the fix. This spike closes that gap.

## The discrepancy fixed

| Surface                       | Backend (already)                           | Frontend/bridge before         | Frontend/bridge after (this spike)                                                      |
| ----------------------------- | ------------------------------------------- | ------------------------------ | --------------------------------------------------------------------------------------- |
| planar move                   | 8-way (`move_n/s/e/w` + `move_ne/nw/se/sw`) | N/S/E/W click + 4-button d-pad | 8-way click-to-move + 3×3 d-pad                                                         |
| examine                       | 8 planar + `here`                           | **no examine UI**              | Move/Examine mode → examine 8 planar + `here`                                           |
| bridge move classification    | n/a                                         | 4 cardinal deltas only         | 8 planar deltas (diagonals classify moved / blocked_no_op / acted_in_place / displaced) |
| bridge examine classification | n/a                                         | none (→ "unknown")             | honest `examined` (pos-unchanged) / `displaced` (unexpected move)                       |

## What was implemented

Frontend (`static/`):

- **`app.js`** — `DIRECTION_FOR_DELTA` widened to all 8 adjacency deltas; an `actionMode`
  (`"move"`/`"examine"`) layer with `setActionMode()` + `sendDirection()`; the grid click handler
  branches on mode (move: step any of the 8 neighbors; examine: examine any neighbor, or the avatar
  tile for `here`); `renderButtons()` gates the d-pad on `canAct()` and disables the center `here`
  button in move mode; the inspector reports diagonal direction tokens, adds `examine via: here` for
  the avatar tile and `move/examine via: <token>` for any adjacent tile; `describeProducer()` reads
  examine as `examine <dir>`. The direction sent is always the **backend command token**
  (`move_n`…`move_sw` / `here`), never a frontend-computed target mutation.
- **`index.html`** — the 4-button d-pad replaced by a true **3×3** control (NW N NE / W · E / SW S
  SE) whose buttons carry `data-direction` backend tokens and whose center is
  `data-direction="here"`; a **Move/Examine** mode cluster; an honest, mode-aware map hint (no longer
  "N/S/E/W").
- **`style.css`** — 3×3 d-pad + center-button styling, the `#action-mode-cluster`, and an
  `.o-examined` outcome badge.

Bridge (`prototype_server.py`):

- `DIRECTION_DELTAS` widened to the 8 planar directions (diagonal expected deltas `move_ne [1,-1]`,
  `move_se [1,1]`, `move_sw [-1,1]`, `move_nw [-1,-1]`); the existing `classify_outcome` move branch
  is generic over the table, so diagonals classify with no other change and **no faked passability**
  (the blocker explanation stays an explicit heuristic).
- A new `examine` branch in `classify_outcome`: ok:true + avatar unmoved → `examined`
  ("examine completed through the backend input path; inspect messages/transcript for engine
  effects"); a position change → `displaced`. It reports `turn_delta`/`moves_delta` without
  overinterpreting them, and does **not** invent target semantics. Recoverable `ok:false` examine
  rejections continue to surface as `outcome:"error"` through the existing rejection path; a backend
  hang/death stays a fatal transport error exactly as before.

The bridge's request path was already verb-agnostic (shape-validated only), so examine needed only
classification, not a new endpoint.

## Backend command surface — before / after

**Unchanged by this spike** (recorded so the boundary is explicit). The backend already accepted, at
`game::handle_action()` via `src/arcopolis_command.cpp`:

- `wait` → `ACTION_PAUSE`.
- `move` + any of the 8 planar directions → `ACTION_MOVE_*` (all through the shared
  `avatar_action::move` body).
- `examine` + any of the 8 planar directions or `here` → `ACTION_EXAMINE`, the direction served as
  the one-shot nested-input answer if the engine's chooser asks (Spike 11A).

Vertical (`move_up`/`move_down`) is rejected by the backend as a separate `game::vertical_move`
primitive — unchanged here.

## Browser behavior — before / after

- **Before:** clicking an adjacent **cardinal** tile or an N/S/E/W button sent a `move`; diagonals
  were unreachable from the UI; there was no way to examine from the browser at all.
- **After:** Move mode — clicking any of the 8 adjacent tiles, or any of the 8 d-pad direction
  buttons, sends the matching `move`; the avatar tile and the center button never move (Wait stays a
  separate button). Examine mode — clicking any of the 8 adjacent tiles examines it, clicking the
  avatar tile or the center button examines `here`, and the 8 d-pad buttons examine in their
  direction. Shift-click remains a read-only inspect in both modes. The current mode is shown
  unambiguously (active button + mode-specific hint). Glyph/Tileset rendering is unchanged and
  independent of the action mode.

## What "GUI-equivalent" means here

It means parity on the **planar move and examine-targeting** surfaces, and nothing wider:

- Every planar tile a GUI player can **step** to (8 neighbors) is reachable by click and by d-pad.
- Every planar **examine target** a GUI player can select (8 neighbors + self) is selectable, and the
  selection is the backend's own direction token delivered to the real input seam — not a
  frontend-computed target.

It is explicitly **not** a claim that the browser reproduces every GUI mouse/key affordance.

## What remains not implemented

Stated plainly so nothing reads as "equivalent" that is not:

- **Vertical movement** (`move_up`/`move_down`) — the separate `game::vertical_move` primitive
  (stairs/ropes/climb); a different engine command, not a planar step. Not in this spike.
- **Generic prompt/menu protocol** (doc 25 Option C) — examine reaches menu targets (NPC, vehicle,
  computer, pickup) but the menus auto-cancel; _acting_ on them is deferred.
- **pickup / talk / computer interaction UI** — no command and no UI.
- **Full right-click context menu** — not implemented; Shift-click is a read-only inspector, not a
  context menu.

## Validation

Run from the worktree root with `-Exe` pointing at the built game binary.

- **`frontend_prototype_regression.ps1` — all 18 gates passed, exit 0.** Includes the new **Gate 2d**
  (served UI carries the 8 direction buttons + `here` + Move/Examine controls + the 8 delta mappings +
  the examine dispatch; the hint no longer says "N/S/E/W"; `.o-examined` styled) and the expanded
  **Gate 13** on a fresh `session_002` from spawn: `examine move_n` → `examined`, `examine here` →
  `examined`, `examine move_up` → recoverable `error` with the session still ready, and the diagonal
  `move_se` → `moved` `pos_abs_delta [1,1,0]` `turn_delta >= 1` as a **hard fixture assertion (no
  silent fallback to another diagonal)**.
- **`examine_regression.ps1` — ok, exit 0** (backend directed-examine, incl. the diagonal `move_sw`
  serve, unchanged).
- **`movement_regression.ps1` — ok, exit 0** (cardinal `move_s`, diagonal `move_se` `(+1,+1)`, and the
  documented `move_n`-into-NPC no-op).
- **`live_protocol_regression.ps1` — ok, exit 0.**
- **`client_harness_regression.ps1` — ok, exit 0** (incl. the run-mode diagonal `move_se` classified
  `moved (1,1,0)`).
- **`[arcopolis]` C++ unit suite — all passed (73 test cases / 501 assertions, exit 0).** Collateral
  confirmation only; this spike changes **zero C++**. (Must be run with the **built checkout root** as
  the working directory so SDL_GPU finds the compiled `data/shaders/` blobs; a worktree cwd without
  compiled shaders aborts at SDL_GPU device creation before any test runs.)
- **Manual browser smoke** (Claude Preview MCP driving the real DOM at `http://localhost:8771/`
  against a live `ArcopolisTest` backend; nothing committed) — **all checks passed, zero console
  errors/logs**:
  - Start → phase `ready`, avatar rendered, 625 cells, Move mode default.
  - Move mode: SE d-pad button → moved `(+1,+1)` with diff highlighting (12 changed tiles); clicking
    the NW adjacent cell → moved `(-1,-1)` (click-to-move on a diagonal tile).
  - Examine mode: toggle updates the hint and enables the center `here` button; `examine move_n`
    (toward the NPC) → `examined` (no move, no hang, messages render); the center `here` button →
    `examined`; clicking an adjacent cell → `examined`.
  - Shift-click an adjacent tile → inspector populated (showed the NPC + the `move/examine via move_n`
    row), no command fired, avatar unmoved.
  - Glyph↔Tileset toggle → sprite layers drawn (`tileset loaded: UltimateCataclysm`) and back; the
    d-pad and the active examine mode survived the toggle.
  - Quit → phase `ended`.

## Risks / follow-ups

- The `examined` outcome is a **bridge classification** (ok:true + avatar unmoved), deliberately not
  interpreting the engine's target effects (messages/menus); the messages panel + raw response remain
  the place to read what the engine actually did. Stated as such, never as a richer claim.
- The d-pad/click path sends a command per gesture (one in flight at a time, like every other
  control); no batching or path-walking — out of scope.
- Next planar-surface follow-ups remain the backend's, not the frontend's: vertical move, and a
  prompt-aware protocol to _act_ on examine's menu targets (doc 25 Option C). The frontend will follow
  those once the backend exposes them, the same way it followed #31/#34 here.

## Citation audit

| Claim                                                                                 | Implementing line(s)                                                                                                                                 |
| ------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Backend resolves all 8 planar move directions through the shared move body            | `src/arcopolis_command.cpp` `is_supported_move_direction` / `command_to_action` (`look_up_action`)                                                   |
| Backend examine accepts 8 planar + `here` (vertical excluded, `allow_vertical=false`) | `src/arcopolis_command.cpp` `target_direction_answers` (was `examine_direction_answers`, renamed Spike 12A); `src/game.cpp` `game::examine`          |
| Frontend 8-way click + d-pad + mode dispatch                                          | `tools/arcopolis_frontend/static/app.js` (`DIRECTION_FOR_DELTA`, `sendDirection`, grid click handler), `static/index.html` (3×3 d-pad, mode cluster) |
| Bridge 8-way move deltas + examine outcome rule                                       | `tools/arcopolis_frontend/prototype_server.py` (`DIRECTION_DELTAS`, `classify_outcome`)                                                              |
| Regression proves a diagonal move + examine through the HTTP bridge                   | `docs/arcopolis/frontend_prototype_regression.ps1` Gate 2d + Gate 13                                                                                 |
