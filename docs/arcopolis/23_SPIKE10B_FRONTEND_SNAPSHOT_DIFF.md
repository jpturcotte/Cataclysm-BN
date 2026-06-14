# Spike 10B — Frontend snapshot diff / terrain change visibility

**Status: implemented & validated (2026-06-11).** The Spike 10A browser prototype now shows _what
changed_ between consecutive snapshots: changed cells are highlighted, the tile inspector shows
before → after detail, a summary panel reports counts, and door glyphs distinguish open from
closed. **Frontend-side only**: zero engine/C++ changes, zero snapshot/protocol/bridge changes —
`prototype_server.py` is untouched; everything lives in `static/app.js` / `style.css` /
`index.html`.

## Why 10B

After 10A, a door/terrain mutation test was unreadable from the browser: open and closed doors
shared the `+` glyph, and confirming "did that command actually change the tile?" meant diffing raw
`NNN_<name>.json` files by hand. 10B answers, from the UI alone: did the tile change after the last
command, which nearby tiles changed, and what exactly changed on the selected tile.

```
browser (static HTML/CSS/JS)          <- 10B lives ONLY here
  -> prototype_server.py (stdlib HTTP bridge, loopback)     unchanged
    -> stdin/stdout JSON Lines live protocol (Spike 9B)     unchanged
      -> game::handle_action() input seam                   unchanged
  <- read-only snapshots NNN_<name>.json + session.jsonl    unchanged
```

It compares **consecutive exported snapshots**, not live engine internals: the diff is an honest
view of what the backend chose to export, and can never explain a cause the snapshot does not
carry.

## How the diff is computed (`static/app.js`)

- **Trigger — snapshot identity, not `state_serial`.** The bridge bumps `state_serial` on every
  cached-doc rebuild, including busy-flag toggles and recoverable rejections, where the snapshot is
  unchanged. The diff is keyed on `snapKey = session.dir_name + "/" + backend.snapshot` instead —
  exactly the bridge's "a new snapshot was absorbed" signal. The dir prefix matters: every
  session's first snapshot is `NNN_start.json` (same name, new world state).
- **One owner for the baseline.** `updateDiff()` is the only code that rebuilds the cell bundles
  and moves the previous/current pair; `renderGrid()`/`renderInspector()` are pure consumers.
  Same-snapKey renders (1 s polls, busy flips) and click-driven repaints cannot shift the baseline
  by construction.
- **Tile key: `pos_local` with an origin-delta correction.** Cells are keyed `"x,y"` in bubble
  coordinates. When the engine shifts the reality bubble (`map::shift`), every `pos_local` rebases
  and a naive key match would flag all 625 tiles. Each snapshot's bubble origin is
  `avatar.pos_abs − avatar.pos_local` (same map-square frame, fields already exported), so the
  previous cell for current `(x, y)` is looked up at `(x, y) + (originCur − originPrev)` — zero
  for ordinary steps, one submap on a rebase. Tiles with no counterpart in the previous window
  (edges, the rebase stripe) are skipped, not flagged.
- **Per-tile comparison** (`computeSnapshotDiff`, pure): `ter` / `furn` string inequality, `seen`
  normalized as `!== false`, and an **entity-occupancy signature** — avatar presence, sorted NPC
  names, sorted monster `name (type_id)`, sorted ground-item `name (type_id)` with per-label count
  aggregation (`count_by_charges` → charges). Occupancy, not state: an hp or NPC-flag change on
  the same occupant does not flag the tile.
- **Baseline resets** (diff shows "first snapshot — no baseline to compare"): first snapshot of a
  session, a session change, a z change (defensive — no vertical commands exist), or missing
  avatar position fields.
- **Persistence:** highlights stay until the next snapshot replaces the diff. A wait/export that
  changes nothing yields "no tile changes vs previous snapshot" and clears them; rejected commands
  and polls leave them alone.

## UI affordances

| Where          | What                                                                                                                                      |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| map cells      | inset ring per changed tile — `.changed-tile` + specific `.changed-seen`/`.changed-furniture`/`.changed-terrain`/`.changed-entities`      |
| map cells      | `title` tooltip on every tile: `x,y · ter <id> · furn <id>` + a `changed: …` suffix when diffed                                           |
| map cells      | door glyphs split: `+` closed vs `'` open (`_o` token), broken (`_b` token), `open`, or `frame`; `indoor`/`outdoor` ids excluded          |
| Changes panel  | `N tiles changed · terrain/furniture/seen/entities counts · after <command → outcome> · vs <previous snapshot>`                           |
| tile inspector | a "changed since previous snapshot" block: per-aspect `before → after` or `no change`; `no changes detected` when the tile did not change |

The door split also fixes a 10A glyph bug: `f_indoor_plant` / `t_water_pool_outdoors` matched the
bare `"door"` substring and rendered `+`.

Highlight precedence when one tile changed in several ways (box-shadow does not stack — CSS source
order decides): entities > terrain > furniture > seen. Changed unseen cells dim to 0.65 instead of
0.35 so seen-flag diffs stay visible.

## Testing a door/terrain change from the browser

1. Copy the fixture and start the bridge (see doc 22), open the page, press **Start**.
2. Closed doors render `+`, open/broken ones `'`; hover any cell for its exact `ter`/`furn` ids.
3. Walk next to a closed door and **click the door tile** (an adjacent click is a real `move` into
   it — any of the 8 neighbors since Spike 11B; bump-open works diagonally too). The engine spends
   the turn opening it: outcome `acted_in_place`.
4. Read the result without opening any JSON: the Changes panel reports `1 tile changed — terrain
   1`, the door cell flips `+` → `'` inside a terrain ring, its tooltip ends `changed: ter
   t_door_c → t_door_o`, and Shift-clicking it shows `terrain: t_door_c → t_door_o` with `no
   change` on the other aspects.
5. Press **Export / Refresh**: "no tile changes vs previous snapshot" and the highlights clear —
   the change belonged to the command, not to noise.

## Regression

[`frontend_prototype_regression.ps1`](frontend_prototype_regression.ps1) gains **Gate 2b** (15
gates total): the **served** `app.js` must carry `computeSnapshotDiff` and the `changed-tile`
class, the served `style.css` must style `.changed-tile` and `.g-door-open`, and the served page
must carry the `diff-summary` panel. Static-content asserts only — diff behavior is browser-side
JS, and the regression deliberately stays free of browser automation (there is also no JS
unit-test pattern or Node dependency in the repo to lean on); behavior is covered by the manual
browser validation below. Gates 1–14 are unchanged.

## Validation (2026-06-11, real backend, zero C++ changes)

- `frontend_prototype_regression.ps1` — **all 15 gates passed, exit 0**.
- `live_protocol_regression.ps1` — **ok, exit 0** (no collateral).
- `client_harness_regression.ps1` — **ok, exit 0** (no collateral).
- `[arcopolis]` C++ unit tests — **293 assertions in 53 test cases passed, exit 0** (collateral
  confirmation only; this spike changes no C++).
- Manual browser smoke (performed against a real backend on `ArcopolisTest`; nothing committed):
  - Start → baseline: 625 cells, zero highlights, "first snapshot — no baseline to compare".
  - `move_s → moved`: exactly 8 tiles flagged — the avatar trail (`entities: avatar → (empty)` /
    `(empty) → avatar`) plus 6 FOV `seen` flips; summary counts matched the cells.
  - An incidental bump-open was caught organically: `move_e → acted_in_place`, `1 tile changed —
    terrain 1` (`t_window_no_curtains → t_window_no_curtains_open`).
  - A **reality-bubble rebase happened mid-walk** (bubble origin shifted one submap north): the
    diff stayed clean — 8 genuine changes, not 625 false ones — live proof of the origin-delta
    correction.
  - Door test exactly as scripted above on a real `t_door_c`: `acted_in_place`, `1 tile changed —
    terrain 1`, glyph `+` → `'`, tooltip `changed: ter t_door_c → t_door_o`, inspector
    `terrain: t_door_c → t_door_o`, others `no change`.
  - `wait → waited` and `export → no_command` both reported "no tile changes" and cleared the
    highlights; a far-tile plain click inspected without moving or disturbing the diff;
    Shift-click, d-pad, adjacent-click movement and Quit (phase `ended`, Start re-enabled) all
    behaved; **zero console errors/warnings** for the whole session.

## Known limitations

- Not animation: one previous ↔ current snapshot pair, replaced wholesale on each new snapshot.
- Window-only: tiles (and their entities) entering the radius-12 export window — including the
  stripe a bubble rebase reveals — have no baseline and are not flagged.
- It cannot explain hidden engine causes; it reports _that_ an exported field changed, and only
  for fields the snapshot already carries (no fields/vehicles, no per-entity hp/flag deltas —
  occupancy only).
- No stable entity ids are exported, so identity is names/type_ids: two same-named entities
  swapping tiles between snapshots is invisible.
- `producedBy` names the op that produced the **current** snapshot; if another client advanced the
  backend several snapshots between this page's renders, the diff spans them all — the `vs
  NNN_<name>.json` suffix is what keeps the panel honest.
- A browser reload drops the baseline (the next snapshot starts fresh); a z change resets it
  (defensive — no vertical commands exist yet).
- Pre-existing 10A wart, unchanged: restarting the **server** resets `state_serial`, and an
  already-open page ignores the new docs until reloaded.
- Door open/closed remains an id heuristic (per-tile symbol/colour export stays deferred backlog
  #1); the exact ids in tooltips/inspector are the compensation. It does not add
  examine/open/close/pickup/talk commands — bump-open is the only terrain mutation reachable
  today.

## Next likely follow-up decisions

1. The first **interaction commands** (open/close/examine/pickup) would make the diff view a real
   test harness for terrain mutations instead of relying on bump-open side effects.
2. **Per-tile symbol/colour export** (deferred backlog #1) retires the glyph and door heuristics.
3. **Stable entity ids** in the export would upgrade occupancy diffing to identity-true entity
   tracking.
4. If a future client wants event-level "what changed" pushed from the backend, that is a
   **protocol delta/event stream** decision (deferred with the rest of the live-protocol v0 list)
   — snapshot diffing in the client is the cheap stopgap that needed no contract change.
