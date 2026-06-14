# Spike 10C — Optional frontend tileset rendering

**Status: implemented & validated (2026-06-11).** The Spike 10A/10B browser prototype gains an
**optional tileset rendering mode**: the bridge re-serves the in-repo `gfx/UltimateCataclysm`
tileset (`tile_config.json` + exactly the spritesheets it references), and the browser parses the
config and paints map cells as sprite layers instead of glyphs, with a visible
**[Glyph] / [Tileset]** toggle. Zero engine/C++ changes, zero snapshot/protocol changes, zero
state-document changes; no new libraries anywhere (Python stdlib bridge, plain HTML/CSS/JS).

Terminology this doc is careful about: the **backend snapshot is the only authority**. Glyphs are
a frontend interpretation of that snapshot, and so are sprites — glyph mode is the **safe visual
fallback**, never "authoritative". Tileset mode is a render skin over the same consumed data.

## Why 10C

10A/10B proved a mouse-first browser client over the live protocol, but as pure text. The project
goal is a _graphical_ frontend, so the next falsifiable question was: **can the existing browser
prototype render real BN tileset art — from the repo's own tileset files, without any engine-side
rendering contract — while every proven affordance (clicks, inspection, diffing) keeps working?**

```
browser (static HTML/CSS/JS)        <- 10C: parses tile_config.json, paints sprites
  -> prototype_server.py            <- 10C: + /tileset/ asset whitelist (serving only)
    -> stdin/stdout JSON Lines live protocol (Spike 9B)     unchanged
      -> game::handle_action() input seam                   unchanged
  <- read-only snapshots NNN_<name>.json + session.jsonl    unchanged
  <- gfx/UltimateCataclysm assets, re-served verbatim       new, read-only
```

The tileset pipeline is **rendering metadata, not game state**: the bridge serves the asset files
verbatim and never interprets sprite meaning; the browser resolves snapshot ids (`ter`, `furn`,
`type_id`) against the tileset on its own. `/api/state` is byte-identical to 10B — tileset
availability deliberately lives on a separate `/tileset/info` endpoint so the state document stays
the unreshaped snapshot contract every consumer re-derives.

## What it proves / what it deliberately does not

Proves:

1. A BN tileset shipped in this repo can be parsed **in browser JavaScript** (no npm, no
   bundler, no canvas/WebGL) far enough to render recognizable terrain, furniture, items and
   monsters from the ids the snapshot already carries.
2. The engine's sprite-index scheme can be replicated faithfully at the index-resolution level
   (global indices over concatenated sheets, capacities from real image dimensions — see the
   citation audit below), validated against known ids (`t_door_c`/`t_door_o` render as a closed
   and an open wooden door).
3. The bridge can serve tileset assets **safely**: an exact-name whitelist derived from
   `tile_config.json`, path containment, no client-controlled path arithmetic, and a fail-safe
   that keeps the server and the glyph UI fully usable when the tileset is missing or broken.
4. Every 10A/10B affordance survives the new skin: adjacent-click movement, Shift-click
   inspection, d-pad, Wait/Export/Quit, tooltips, the tile inspector, changed-cell highlights and
   the before→after diff panel all work identically in both modes, and toggling modes cannot
   move the 10B diff baseline (the toggle re-renders pure consumers only). (**Update (Spike 11B):**
   adjacent-click movement + the d-pad are now 8-way, and a Move/Examine mode adds examine targeting;
   the tileset skin is unaffected — same pure-consumer re-render. See
   [29_SPIKE11B_GUI_EQUIVALENT_PLANAR_MOVE_EXAMINE.md](29_SPIKE11B_GUI_EQUIVALENT_PLANAR_MOVE_EXAMINE.md).)
5. Per-cell fallback works: an id with no usable sprite renders as its existing glyph **on top
   of** whatever sprites did resolve (`evac_pamphlet` — absent from UltimateCataclysm — is the
   fixture's natural witness).

Deliberately NOT proven (out of scope):

- fidelity to BN's native tiles renderer (see "Unsupported tile_config features" — no multitile
  connections, rotation selection, variation weights, animation, lighting/tint, overhang…);
- the engine's `looks_like` fallback chains (game-data JSON, not tile_config — unresolved ids
  glyph-fall-back instead);
- avatar/NPC sprite identity (the export carries no avatar sex/equipment and no NPC `type_id`,
  so `@` and `N` stay glyph overlays by design);
- progressive/partial tileset loading, caching, or any rendering performance work.

## Files

| Path                                               | Change                                             |
| -------------------------------------------------- | -------------------------------------------------- |
| `tools/arcopolis_frontend/prototype_server.py`     | `--tileset-dir`/`--disable-tileset`, `/tileset/*`  |
| `tools/arcopolis_frontend/static/index.html`       | [Glyph]/[Tileset] buttons + status line            |
| `tools/arcopolis_frontend/static/style.css`        | scoped `.tileset-mode` rules, sprite layers, rings |
| `tools/arcopolis_frontend/static/app.js`           | `loadTileset`/`setRenderMode`/`renderSpriteCell`   |
| `docs/arcopolis/frontend_prototype_regression.ps1` | Gate 2c + Gate 15 (17 gates total)                 |

## How to run (Windows, PowerShell)

```powershell
# one-time per worktree: copy the canonical fixture (AGENTS.md, "Arcopolis test world fixture")
Copy-Item C:\dev\arcopolis-fixtures\arcopolis_user .\arcopolis_user -Recurse -Force

python tools\arcopolis_frontend\prototype_server.py `
    --exe <built cataclysm-bn-tiles.exe> `
    --userdir .\arcopolis_user `
    --world ArcopolisTest `
    --tileset-dir .\gfx\UltimateCataclysm
# open http://127.0.0.1:8765/ , press Start, then click [Tileset]
```

`--tileset-dir` defaults to `.\gfx\UltimateCataclysm`, so from the repo root the flag is
optional. The page always starts in **glyph mode** (the safe default); the **[Tileset]** button
enables itself once the config and **all** referenced spritesheets finish loading, and the status
line walks through `loading tileset… → tileset loaded: UltimateCataclysm` (or
`tileset unavailable: <short reason>` / `glyph only — <reason>`). `--disable-tileset` forces
glyph-only serving.

## The sprite-index interpretation (answered from the engine code)

`tile_config.json` tile entries name sprites by integer (`"t_door_c": { "fg": 3239 }`). The
load-bearing question — _what does 3239 mean?_ — was answered from BN's own loader, then
cross-checked against the UltimateCataclysm data. **In a main tileset, fg/bg integers are GLOBAL
0-based sprite indices over the concatenation of every `tiles-new` sheet, in file order, each
sheet's capacity computed from its actual image dimensions.**

Citation audit (all verified in this checkout):

| Claim                                                                                    | Implementing line(s)                                          |
| ---------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| Main-tileset load starts at `offset = 0`; no per-sheet rebase of JSON values             | `src/cata_tiles.cpp:2237`                                     |
| `sprite_id_offset` is only ever set for **mod** tilesets (`= 0` initializer otherwise)   | `src/cata_tiles.cpp:2243`, `src/cata_tiles.h:535`             |
| Per-sheet capacity = `(imgW / spriteW) * (imgH / spriteH)` from the **loaded image**     | `src/cata_tiles.cpp:1910` (`size = expected_tilecount` :1962) |
| Sheets concatenate in `tiles-new` order                                                  | `offset += size`, `src/cata_tiles.cpp:2378`                   |
| Within a sheet, sprites are row-major, left→right, top→bottom                            | index math `src/cata_tiles.cpp:1130-1132`                     |
| Indices outside `[0, total)` are erased after ALL sheets load (entry then has no sprite) | `src/cata_tiles.cpp:2592-2593`, called from :2285-2305        |
| fg/bg forms: int; int array (rotations, **first = north/unrotated**); `{weight, sprite}` | `src/cata_tiles.cpp:2868-2926`; rotation semantics :4722-4728 |
| Duplicate ids: last definition wins (`tile_ids[id] = …`)                                 | `src/cata_tiles.cpp:427-431`                                  |
| Engine fallback for unmapped ids is the `looks_like` chain, then ASCII                   | `find_tile_looks_like`, `src/cata_tiles.cpp:4252`             |
| `sprite_width`/`sprite_height` default to `tile_info` width/height; offsets default 0    | `src/cata_tiles.cpp:2337-2341`                                |

Empirical cross-check against `gfx/UltimateCataclysm/tile_config.json`: every per-sheet `"//"`
range comment reproduces exactly from cumulative actual-PNG capacities (e.g. `small.png`
320×1380 at 20×20 → 1104 sprites, so `normal.png` starts at 1104 — its comment says "range 1104
to 4543", and 512×6880 at 32×32 is 3440 sprites: 1104+3440−1 = 4543 ✓). Worked example:
`t_door_c` fg 3239 → 3239−1104 = local 2135 in `normal.png` → column 7, row 133. The comments'
"range 1 to …" prose is 1-based only because the composed tileset never references sprite 0; the
engine indexing itself is 0-based. One data subtlety the renderer must honor: a sheet's `tiles`
entries may reference sprite indices that live in **other** sheets, so index→sheet resolution
always goes through the global table, never the entry's containing sheet.

## Supported tile_config features (v0)

- `tile_info[0]` `width`/`height` (the cell box; 32×32 here — `pixelscale` 1 assumed/ignored).
- `tiles-new` sheets with `sprite_width`/`sprite_height` (default: tile size) and
  `sprite_offset_x`/`sprite_offset_y` (default 0), applied as the sprite's position inside its
  cell.
- Tile entries with `id` as a string or an array of strings (each registered).
- `fg`/`bg` resolved to **one** sprite each: plain int as-is; an array of ints (rotations) → the
  first entry (the unrotated/north sprite per the engine's rotation table); a weighted-object
  array → the first object's `sprite` (first entry again if that sprite is itself a rotation
  array). `bg` draws under `fg`.
- Range validation mirroring the engine's post-load erase: out-of-range indices are dropped and
  the id falls back to the glyph.

## Unsupported tile_config features (explicit, deferred)

`multitile`/`additional_tiles` (the base entry's fg/bg is used; connection variants are ignored),
rotation **selection** (always the first/north sprite), variation **weights** (always the first
variant — deterministic, unlike the engine's seeded pick), `animated`, the `ascii` fallback
sheets, the tileset's own `"unknown"` tile (the glyph is the fallback instead), `looks_like`
chains, lighting/tinting/memory dimming, sprite **overhang** (a sprite larger than its tile clips
to the cell box — tall/large/giant sheet art shows its in-cell portion), vehicles, fields,
`transparency`/`pixelscale` per sheet, and `state-modifiers`/warp features. Two frontend
heuristics are documented rather than solved: the "top" ground item = the **last** entry of the
tile's exported stack, and the rendered monster = the **first** in entities order — the snapshot
defines no stacking order.

## How a cell renders in tileset mode

`renderSpriteCell` keeps the 10A/10B cell div (same classes, dataset, tooltip, diff classes,
click handling) and replaces its text with absolutely-positioned `.sprite-layer` spans, bottom →
top: terrain bg/fg → furniture bg/fg → top item bg/fg → monster bg/fg. Then **one** optional
`.cell-glyph` overlay: the existing `cellGlyph()` precedence picks the cell's representative
glyph, which is shown only if its referent did **not** render as a sprite — so the avatar `@` and
NPC `N` always overlay (no sprite identity exists for them), an unresolved monster/item shows
`M`/`i` over the terrain art, and a fully resolved tile shows no text at all. Unseen-tile dimming
and `:hover`/`.inspected` outlines work unchanged.

**10B diff-highlight compatibility** needed one real fix: the 10B rings are _inset box-shadows on
the cell_, which paint **under** positioned children — an opaque sprite would hide them. In
tileset mode the same five `changed-*` classes therefore also draw the ring on a `::after`
overlay (`pointer-events: none`, same source-order precedence), which is generated as the cell's
last child and paints **above** the sprite layers. Glyph mode keeps the original mechanism
byte-identically. Door readability in tileset mode comes from the real door sprites (`+`/`'`
glyph split still rules glyph mode), and the exact ids stay in the tooltip, the inspector, and
the before→after diff rows.

The inspector gains a debug affordance whenever a tileset is loaded (in both modes): `ter
sprite` / `furn sprite` / `entity sprite` rows showing `#<global index> (<sheet file>)` or
`unresolved → glyph`.

## Server-side containment

`/tileset/<name>` resolves **only** by exact lookup in a whitelist built once at startup:
`tile_config.json` plus each `tiles-new` `file` value that is a flat basename, exists, and stays
under `--tileset-dir` (commonpath check). The name is percent-decoded **once** (browsers encode
specials in sheet filenames, and the frontend encodes them explicitly), then names containing a
separator are rejected before the lookup — an encoded `..%2F…` decodes into the separator
reject. Files on disk but not referenced by the config (e.g. `tileset.txt`) are 404s. `/tileset/info`
always answers `{enabled, name, reason, files}` — with no local paths in any browser-visible
field. Every response keeps `Cache-Control: no-store` (prototype debuggability; the ~2.4 MB of
sheets re-fetch per page load on loopback, which is fine and not worth caching politics yet).

## Regression

[`frontend_prototype_regression.ps1`](frontend_prototype_regression.ps1) grows from 15 to **17
gates**; gates 1–14 are unchanged:

- **Gate 2c** (after 2b): `/tileset/info` reports the enabled UltimateCataclysm tileset;
  `tile_config.json` serves as JSON with `tile_info` + `tiles-new` + `no-store`; sheet PNGs
  **derived from the served config** (`small.png`/`normal.png` when referenced, else the first
  sheet) serve as `image/png` with a non-empty body (tolerantly: no Content-Length assert);
  unwhitelisted and traversal-shaped names 404; the served assets carry the tileset hooks
  (`loadTileset` / `setRenderMode` / `renderSpriteCell` / `mode-tileset` / `tileset-status` /
  `tileset-mode`). Server/static/API level only — sprite rendering is browser-side JS, covered
  by the manual smoke below, never by HTTP asserts.
- **Gate 15** (after 14): a second short-lived server started with `--disable-tileset` still
  serves the UI, `/tileset/info` answers `enabled:false`, `tile_config.json` 404s, and it shuts
  down cleanly — the fail-safe is a tested contract, not a hope.

The main server now starts with `--tileset-dir`; that is safe for gates 1–14 because tileset
failures only disable `/tileset/` serving (the regression header documents the coupling).

## Validation (2026-06-11, real backend, zero C++ changes)

- `frontend_prototype_regression.ps1` — **all 17 gates passed, exit 0**.
- `live_protocol_regression.ps1` — **ok, exit 0** (no collateral).
- `client_harness_regression.ps1` — **ok, exit 0** (no collateral).
- `[arcopolis]` C++ unit tests — **293 assertions in 53 test cases passed, exit 0** (collateral
  confirmation only; this spike changes no C++). Note: the suite must run with the **built
  checkout's root as working directory** — since upstream's `--gpu-backend` work it probes
  SDL_GPU at startup and needs the shadercross-compiled blobs under `data/shaders/`, which exist
  only where a build ran; from a never-built worktree it exits 1 before reaching any test.
- Manual browser smoke: see below.
- Post-review hardening (PR #29 bot review, all four comments addressed — one with a modified
  remedy): decode-once asset serving, strictly-positive tile/sprite dimension validation
  (invalid dims now **fail the load to glyph mode** instead of corrupting the index table under
  a `ready` status), and quoted/percent-encoded sprite URLs. Frontend regression re-run after
  the changes: **all 17 gates passed, exit 0**.

## Manual browser smoke (required by the spike, performed against a real backend)

Performed 2026-06-11 against a real `--arcopolis-live` backend (nothing committed); two sessions:
`ArcopolisTest` for the main pass and `ArcopolisNearMonsterTest` for the monster witness.

- **Tileset load:** on page load the browser parsed the served config — 17 sheets, **total
  capacity 12640** (8544 sprites through `fillergiant.png` + the ascii-only `fallback.png`'s
  4096; every per-sheet start matched the config's range comments), 7234 ids registered; status
  `tileset loaded: UltimateCataclysm`, [Tileset] enabled, default mode glyph.
- **Glyph mode first:** Start → 625 cells; `move_n → blocked_no_op` naming Edwardo Stovall (the
  canonical blocker, unchanged).
- **Tileset mode:** 685 sprite layers painted from 4 sheets; only **8 glyph overlays** survived
  (`@`, `N`, one `+`, four `f`, one `i`) — 617/625 cells fully sprite-rendered, walls/windows/
  benches/lockers/doors recognizable.
- **Click movement on cells (tileset mode):** clicking the adjacent south cell → `moved
  [0,1,0]`; the diff flagged **exactly 8 tiles** (avatar-trail entities ×2 + 6 `seen` flips),
  every ringed cell carrying sprite layers — the 10B pattern, now over art.
- **Rings never block clicks:** `elementFromPoint` at a `changed-entities`-ringed cell's center
  returns the cell itself, and clicking that ringed adjacent cell issued a real `move_n → moved`.
- **Shift-click inspection:** inspected Edwardo's tile without moving; the inspector showed
  `t_floor`, the new debug row `ter sprite #3342 (normal.png)` (t_floor's multitile base fg),
  the NPC line, and a `seen false → true` diff row.
- **Fallback witness:** the lone `balloon` (no UltimateCataclysm entry) rendered as an `i`
  glyph overlay on its floor sprite; resolved stack-tops (`bag_zipper`, `mirror`, `box_small`)
  rendered as sprites with no overlay. `evac_pamphlet` is confirmed absent from the id map, but
  in this fixture it never sits at the top of a stack under the "top item = last stack entry"
  heuristic, so the live unresolved-item witness was `balloon` (same code path).
- **Door test (tileset mode):** walked to a real `t_door_c`. En route, two unplanned witnesses:
  a faithful engine no-op (`move_e` into a `t_door_b` tile answered `blocked_no_op`; the
  heuristic explanation correctly admitted "no blocker is visible in the snapshot" — there is
  still no passability flag) and an **organic reality-bubble rebase** (`pos_local` y 83 → 95,
  one submap) absorbed cleanly — the diff stayed 8 genuine tiles, not 625. The bump-open:
  `move_e` into the door → `acted_in_place`, turn_delta 1, diff `1 tile changed — terrain 1`,
  tooltip `changed: ter t_door_c → t_door_o`, cell classes `g-door-open changed-terrain` — and
  the rendered layer's `background-position` flipped to **(−288px, −4256px), exactly the
  predicted column 9 / row 133 of fg 3241** in `normal.png`. The sprite-index interpretation is
  thereby confirmed pixel-exactly in a live browser (fg 3239 = column 7 before the bump).
- **Weighted-first rule, live:** an inspected `t_grass` tile reported `#3429 (normal.png)` —
  the first of its four weighted variants, as documented.
- **Wait / Export:** `wait → waited` (turn advanced, highlights cleared to "no tile changes");
  `export → no_command` (turn_delta 0).
- **Back to glyph:** zero `.sprite-layer` nodes, columns back to `1.25em`, the opened door
  rendered `'` with `g-door-open` (the 10B glyph split intact), Shift-click inspection fine —
  the sprite debug rows report in both modes.
- **Quit:** phase `ended`, backend exit 0, `NNN_final.json` recorded, Start re-enabled.
- **Monster witness (`ArcopolisNearMonsterTest`):** `mon_fungal_wall` exported at one tile; its
  cell rendered a terrain layer plus a **64×64 `large.png` layer at offset (−16, −32) with
  background-position (−448, −256) — exactly fg 7303 → column 7, row 4** — clipped to the cell
  (the documented no-overhang v0) with no `M` overlay; the cell dimmed as `unseen`
  (out-of-LOS authoritative export, as in 10A). Clean quit, exit 0.
- **Zero browser console messages** (errors, warnings or logs) across both sessions.
- Tooling note, **root-caused after the fact** (instrumented with capture-phase event logging):
  part of the smoke was driven as synthetic bubbling `MouseEvent`s because the preview harness's
  clicks stopped landing after a viewport resize. The instrumentation showed why: the harness
  synthesizes a fully **trusted** pointer sequence, but when the emulated viewport is larger
  than the preview panel it fails to compensate for the panel's scale-to-fit display transform —
  every click lands at `target_center × (emulatedW / naturalW)` (measured: a uniform ×2.33701 on
  both axes at a 980px emulation over a 419.34px panel, delivered onto `<html>`). At the panel's
  **natural** size the same clicks land pixel-exactly. After the diagnosis, the load-bearing
  claims were re-verified with **real trusted pointer clicks at natural size**: a cell click in
  tileset mode hit its exact cell and produced `move_s → moved [0,1,0]`, and a far-cell click
  inspected the precise cell clicked. The app — including its deliberate one-in-flight
  click-drop rule — behaved correctly under every delivered event; the earlier "swallowed"
  clicks were all mis-scaled deliveries that genuinely hit nothing interactive.

## Known limitations

- **Not** a faithful reproduction of BN's renderer — see the unsupported-features list; walls and
  floors render their unconnected base sprite, weighted terrains always show their first variant,
  and oversized art clips to its cell.
- All-or-nothing loading: the [Tileset] button stays disabled until **all** referenced sheets
  load (one missing sheet would shift every later sheet's index range, so partial tables are
  refused outright); progressive loading is deferred.
- The avatar tile's `.is-avatar` background tint sits under opaque terrain sprites in tileset
  mode; the always-on `@` overlay is what marks the avatar there.
- Unseen-tile dimming applies to the whole cell (sprites included) — parity with glyph mode, not
  a lighting model.
- The browser still consumes snapshots; there is no engine-side rendering contract. Everything
  the diff/inspector say comes from the same exported fields as 10B (no per-tile symbol/colour,
  no stable entity ids, `messages[].type` still blank).
- One render skin per page: the mode toggle is per-browser-tab state and resets on reload (the
  tileset reloads automatically; the mode defaults back to glyph).

## Next likely follow-up decisions

1. **Multitile + rotation support** (the single biggest visual gap: connected walls/floors) —
   needs the subtile selection logic, not new data.
2. **`looks_like` resolution** — requires reading game-data JSON (a different contract surface
   than tile_config; decide deliberately whether the frontend should consume it).
3. **Overhang rendering** for tall/large sprites (paint order = row order would mirror the
   engine; clipping was the v0 simplification).
4. Sprite identity for the avatar/NPCs would need new export fields (deferred backlog), not
   frontend work.
5. If sprites become the default skin, revisit `no-store` for sheet PNGs and progressive
   loading.
