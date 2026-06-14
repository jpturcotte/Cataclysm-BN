/* Arcopolis Spike 10A prototype frontend.
 *
 * Plain self-contained JavaScript: fetches the bridge's single state document
 * (GET /api/state and the identical document every successful POST returns),
 * renders the radius-12 snapshot window as a glyph grid, and sends move/wait/
 * export/quit commands. The browser is an honest consumer of the bridge API -
 * it never invents simulation state; everything rendered comes verbatim from
 * the backend snapshot the bridge re-serves.
 *
 * Glyph precedence (re-derived from the harness concept, not imported):
 * avatar '@' > NPC 'N' > monster 'M' > item 'i' > terrain family.
 *
 * Spike 10B adds frontend-side snapshot diffing: whenever the snapshot
 * identity changes, the previous snapshot's cell bundles are compared to the
 * new ones, changed cells get highlighted, the inspector shows before/after
 * detail, and a summary panel reports counts. Pure observability over the
 * snapshots the bridge re-serves - nothing here invents or mutates state.
 *
 * Spike 10C adds an OPTIONAL tileset rendering mode: the page parses the
 * bridge-served tile_config.json + spritesheets and paints cells as sprite
 * layers instead of glyphs. The backend snapshot stays the only authority;
 * the glyph renderer remains the SAFE VISUAL FALLBACK (glyphs are a frontend
 * interpretation too), used per-cell whenever an id has no usable sprite and
 * wholesale whenever the tileset is absent or fails to load.
 *
 * Spike 11B makes the planar move/examine surface GUI-equivalent: the click
 * map and d-pad cover all EIGHT adjacent tiles (the four cardinals plus the
 * four diagonals), and a Move/Examine mode selector lets the user send the
 * backend's `examine` verb in any of those 8 directions plus `here` (the
 * avatar's own tile). The direction sent is always the backend command token
 * (move_n .. move_sw / here), never a frontend-computed target mutation; the
 * backend remains the only authority over what the command does.
 */
"use strict";

let doc = null;            // the last rendered state document
let renderedSerial = -1;   // state_serial guard: never render an older doc
let inFlight = false;      // one in-flight POST at a time (mirrors the bridge)
let inspectKey = null;     // "x,y" of the inspected tile, or null
let lastCells = null;      // cell bundles of the CURRENT snapshot (updateDiff owns it)
let diffState = emptyDiffState(); // diff of the current snapshot vs the previous one
let renderMode = "glyph";  // "glyph" | "tileset" - glyph is the safe default
let tileset = emptyTilesetState(); // optional sprite-skin state (Spike 10C)
let actionMode = "move";   // "move" | "examine" - what a direction/click sends (Spike 11B)

const MAX_MAP_SPAN = 64;   // defensive render cap (the window is 25x25 today)
// The EIGHT planar adjacency deltas -> the backend command direction token (the
// four cardinals plus the four diagonals; same set the engine's planar move and
// examine choosers offer). Screen convention: y grows SOUTH, x grows EAST, so
// move_n is (0,-1) and move_ne is (+1,-1). Used for both click-to-move and
// click-to-examine; the avatar's own tile (delta 0,0) is "here" (examine only).
const DIRECTION_FOR_DELTA = {
    "0,-1": "move_n",
    "1,-1": "move_ne",
    "1,0": "move_e",
    "1,1": "move_se",
    "0,1": "move_s",
    "-1,1": "move_sw",
    "-1,0": "move_w",
    "-1,-1": "move_nw",
};

const $ = (id) => document.getElementById(id);

/* ---------------------------------------------------------------- fetch -- */

async function api(path, options) {
    let resp;
    try {
        resp = await fetch(path, options);
    } catch (err) {
        throw { code: "unreachable", message: String(err) };
    }
    let body = null;
    try {
        body = await resp.json();
    } catch (err) {
        throw { code: "bad_response", message: `non-JSON response (HTTP ${resp.status})` };
    }
    if (!resp.ok) {
        const error = (body && body.error) || {};
        throw {
            code: error.code || `http_${resp.status}`,
            message: error.message || `HTTP ${resp.status}`,
        };
    }
    return body;
}

async function refresh() {
    try {
        render(await api("/api/state"));
        setConnected(true);
    } catch (err) {
        setConnected(false);
    }
}

async function post(path, body) {
    if (inFlight) return;
    inFlight = true;
    renderButtons();
    try {
        const result = await api(path, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: body === undefined ? "{}" : JSON.stringify(body),
        });
        render(result);
        setConnected(true);
        clearError();
    } catch (err) {
        showError(err);
        await refresh(); // the failure may have changed state (e.g. phase dead)
    } finally {
        inFlight = false;
        renderButtons();
    }
}

/* --------------------------------------------------------------- render -- */

function render(newDoc) {
    if (!newDoc || typeof newDoc.state_serial !== "number") return;
    if (newDoc.state_serial <= renderedSerial) return; // stale poll vs newer POST
    renderedSerial = newDoc.state_serial;
    doc = newDoc;
    updateDiff(newDoc);
    renderStatus();
    renderGrid();
    renderAvatar();
    renderOutcome();
    renderDiffSummary();
    renderInspector();
    renderMessages();
    renderButtons();
}

function canAct() {
    return !!doc && doc.phase === "ready" && !doc.busy && !inFlight;
}

function renderStatus() {
    const phase = $("status-phase");
    phase.textContent = doc.phase;
    phase.className = `pill phase-${doc.phase}`;
    $("status-world").textContent = doc.session ? `world: ${doc.session.world}` : "";
    $("status-turn").textContent =
        doc.backend && typeof doc.backend.turn === "number" ? `turn: ${doc.backend.turn}` : "";
    $("status-session").textContent = doc.session
        ? `${doc.session.dir_name}${doc.backend ? " / " + doc.backend.snapshot : ""}`
        : "";
    $("status-busy").classList.toggle("hidden", !doc.busy);
}

function buildCells(map) {
    const cells = new Map();
    for (const tile of map.tiles || []) {
        if (!tile || typeof tile.x !== "number" || typeof tile.y !== "number") continue;
        cells.set(`${tile.x},${tile.y}`, {
            tile,
            npcs: [],
            monsters: [],
            items: [],
            isAvatar: !!tile.is_avatar,
        });
    }
    const entities = map.entities || {};
    for (const group of ["npcs", "monsters", "items"]) {
        for (const entity of entities[group] || []) {
            const pos = entity && entity.pos_local;
            if (!Array.isArray(pos)) continue;
            const cell = cells.get(`${pos[0]},${pos[1]}`);
            if (cell) cell[group].push(entity);
        }
    }
    return cells;
}

/* -------------------------------------------------------- snapshot diff -- */

function emptyDiffState() {
    return {
        snapKey: null,    // session dir + snapshot filename of the diffed snapshot
        dirName: null,
        origin: null,     // [pos_abs - pos_local] x/y: the bubble origin in squares
        z: null,          // avatar z (the export window is single-z)
        changes: null,    // Map "x,y" -> change record; null = no baseline to compare
        counts: null,     // { tiles, terrain, furniture, seen, entities }
        producedBy: null, // "move_s → moved": the op/outcome that produced the diff
        vsSnapshot: null, // the previous snapshot's filename
    };
}

/* Deterministic entity-occupancy view of one cell. `sig` is the comparison
 * key; `text` is what the inspector/tooltip shows. The export carries no
 * stable entity ids, so names/type_ids are the identity - a same-named pair
 * swapping tiles between snapshots is invisible (documented limitation). */
function entityOccupancy(cell) {
    const npcs = cell.npcs.map((npc) => String(npc.name || "?")).sort();
    const monsters = cell.monsters
        .map((mon) => `${mon.name || "?"} (${mon.type_id || "?"})`).sort();
    const itemCounts = new Map();
    for (const item of cell.items) {
        const label = `${item.name || "?"} (${item.type_id || "?"})`;
        const count = item.count_by_charges && typeof item.charges === "number"
            ? item.charges : 1;
        itemCounts.set(label, (itemCounts.get(label) || 0) + count);
    }
    const items = [...itemCounts.keys()].sort().map((label) =>
        itemCounts.get(label) === 1 ? label : `${label} ×${itemCounts.get(label)}`);
    const parts = [];
    if (cell.isAvatar) parts.push("avatar");
    if (npcs.length) parts.push(`npc: ${npcs.join(", ")}`);
    if (monsters.length) parts.push(`monster: ${monsters.join(", ")}`);
    if (items.length) parts.push(`items: ${items.join(", ")}`);
    return {
        sig: JSON.stringify({ a: !!cell.isAvatar, n: npcs, m: monsters, i: items }),
        text: parts.length ? parts.join("; ") : "(empty)",
    };
}

/* Pure diff of two buildCells() maps. originDelta maps CURRENT local coords
 * into the PREVIOUS snapshot's frame (see updateDiff), so a reality-bubble
 * rebase between snapshots does not flag every tile. Tiles with no
 * counterpart in prev (window edge / rebase stripe) are skipped, not
 * flagged. Change records carry display-ready before/after values so the
 * previous cells can be dropped right after this returns. */
function computeSnapshotDiff(prevCells, curCells, originDelta) {
    const changes = new Map();
    const counts = { tiles: 0, terrain: 0, furniture: 0, seen: 0, entities: 0 };
    for (const [key, cur] of curCells) {
        const [x, y] = key.split(",").map(Number);
        const prev = prevCells.get(`${x + originDelta[0]},${y + originDelta[1]}`);
        if (!prev) continue;
        const record = { ter: null, furn: null, seen: null, entities: null };
        const terPair = [String(prev.tile.ter || ""), String(cur.tile.ter || "")];
        if (terPair[0] !== terPair[1]) { record.ter = terPair; counts.terrain++; }
        const furnPair = [String(prev.tile.furn || ""), String(cur.tile.furn || "")];
        if (furnPair[0] !== furnPair[1]) { record.furn = furnPair; counts.furniture++; }
        const seenPair = [prev.tile.seen !== false, cur.tile.seen !== false];
        if (seenPair[0] !== seenPair[1]) { record.seen = seenPair; counts.seen++; }
        const occBefore = entityOccupancy(prev);
        const occAfter = entityOccupancy(cur);
        if (occBefore.sig !== occAfter.sig) {
            record.entities = [occBefore.text, occAfter.text];
            counts.entities++;
        }
        if (record.ter || record.furn || record.seen || record.entities) {
            changes.set(key, record);
            counts.tiles++;
        }
    }
    return { changes, counts };
}

/* "move_s → moved" / "examine here → examined" from the state doc's
 * last_result (null when absent). */
function describeProducer(lastResult) {
    if (!lastResult) return null;
    const request = lastResult.request || {};
    let what = lastResult.op;
    if (lastResult.op === "command") {
        // examine carries a direction too, but reads clearest with the verb
        // ("examine move_n"); a bare move keeps its direction token alone.
        if (request.command === "examine") {
            what = `examine ${request.direction || "?"}`;
        } else {
            what = request.direction || request.command || what;
        }
    }
    const outcome = lastResult.outcome ? lastResult.outcome.outcome : null;
    return outcome ? `${what} → ${outcome}` : String(what);
}

/* The ONLY place lastCells and the diff baseline move. Keyed on the snapshot
 * IDENTITY (session dir + snapshot filename), NOT state_serial: the serial
 * also bumps on busy-flag swaps and recoverable rejections, where the
 * snapshot - and so the diff - must stay put. The dir prefix matters too:
 * every session's first snapshot is NNN_start.json (same name, new world
 * state). Same-snapKey renders and click-driven repaints (which never call
 * this) cannot rebuild cells or shift the baseline, by construction. */
function updateDiff(newDoc) {
    const backend = newDoc.backend;
    if (!backend || !backend.snapshot || !newDoc.map || !Array.isArray(newDoc.map.tiles)) {
        lastCells = null;
        diffState = emptyDiffState();
        return;
    }
    const dirName = newDoc.session ? newDoc.session.dir_name : null;
    const snapKey = `${dirName}/${backend.snapshot}`;
    if (diffState.snapKey === snapKey) return;
    const prevCells = lastCells;
    const prevState = diffState;
    lastCells = buildCells(newDoc.map);
    const avatar = newDoc.avatar || {};
    const posAbs = Array.isArray(avatar.pos_abs) ? avatar.pos_abs : null;
    const posLocal = Array.isArray(avatar.pos_local) ? avatar.pos_local : null;
    const next = emptyDiffState();
    next.snapKey = snapKey;
    next.dirName = dirName;
    next.origin = posAbs && posLocal
        ? [posAbs[0] - posLocal[0], posAbs[1] - posLocal[1]] : null;
    next.z = posLocal ? posLocal[2] : null;
    // Baseline (changes stays null) unless this is the SAME session on the
    // same z-level (nothing can change z today - defensive) and both
    // snapshots carry the avatar fields the origin correction needs.
    if (prevCells && prevState.dirName !== null && prevState.dirName === dirName
        && prevState.z !== null && prevState.z === next.z
        && prevState.origin !== null && next.origin !== null) {
        const originDelta = [next.origin[0] - prevState.origin[0],
                             next.origin[1] - prevState.origin[1]];
        const result = computeSnapshotDiff(prevCells, lastCells, originDelta);
        next.changes = result.changes;
        next.counts = result.counts;
        next.producedBy = describeProducer(newDoc.last_result);
        next.vsSnapshot = prevState.snapKey.split("/").pop();
    }
    diffState = next;
}

/* Exact-ids tooltip for one rendered cell (+ a change suffix when diffed). */
function cellTitle(cell, x, y, record) {
    const parts = [`${x},${y}`, `ter ${cell.tile.ter || "?"}`,
                   `furn ${cell.tile.furn || "f_null"}`];
    if (record) {
        const changed = [];
        if (record.ter) changed.push(`ter ${record.ter[0]} → ${record.ter[1]}`);
        if (record.furn) changed.push(`furn ${record.furn[0]} → ${record.furn[1]}`);
        if (record.seen) changed.push(`seen ${record.seen[0]} → ${record.seen[1]}`);
        if (record.entities) {
            changed.push(`entities ${record.entities[0]} → ${record.entities[1]}`);
        }
        parts.push(`changed: ${changed.join("; ")}`);
    }
    return parts.join(" · ");
}

/* Door ids, split open vs closed (Spike 10B). A bare "door" substring
 * over-matches: "indoor"/"outdoor" contain it (f_indoor_plant,
 * t_water_pool_outdoors used to render "+"). Open = an `_o` token
 * (t_door_o, t_door_metal_o_peep), a `_b` token (broken = a permanently
 * open hole; `_bar`/`_boarded` do NOT match - the token needs `_` or
 * end-of-id after it), "open", or "frame" (an empty doorway). Heuristic
 * only - the exact id is in the cell tooltip and the inspector. */
function doorGlyph(id) {
    if (!id.includes("door") || id.includes("indoor") || id.includes("outdoor")) {
        return null;
    }
    if (/_[ob]($|_)/.test(id) || id.includes("open") || id.includes("frame")) {
        return ["'", "door-open"];
    }
    return ["+", "door"];
}

/* Heuristic terrain families from the ter/furn id strings - the snapshot has
 * no per-tile symbol/colour yet (a documented contract gap). */
function terrainGlyph(tile) {
    const furn = String(tile.furn || "");
    if (furn && furn !== "f_null") {
        const furnDoor = doorGlyph(furn);
        if (furnDoor) return furnDoor;
        return ["f", "furniture"];
    }
    const ter = String(tile.ter || "");
    if (ter === "" || ter === "t_null") return [" ", "void"];
    const terDoor = doorGlyph(ter);
    if (terDoor) return terDoor;
    if (ter.includes("window")) return ["=", "window"];
    if (ter.includes("wall") || ter.includes("rock")) return ["#", "wall"];
    if (ter.includes("stairs_up") || ter.includes("ladder_up")) return ["<", "stairs"];
    if (ter.includes("stairs") || ter.includes("ladder")) return [">", "stairs"];
    if (ter.includes("water") || ter.includes("sewage") || ter.includes("swamp")
        || ter.includes("pool")) return ["~", "water"];
    if (ter.includes("grass") || ter.includes("underbrush")) return [",", "grass"];
    if (ter.includes("floor") || ter.includes("pavement") || ter.includes("road")
        || ter.includes("sidewalk") || ter.includes("concrete") || ter.includes("asphalt")
        || ter.includes("dirt") || ter.includes("sand") || ter.includes("gravel")) {
        return [".", "floor"];
    }
    return ["?", "unknown"];
}

function cellGlyph(cell) {
    if (cell.isAvatar) return ["@", "avatar"];
    if (cell.npcs.length) return ["N", "npc"];
    if (cell.monsters.length) return ["M", "monster"];
    if (cell.items.length) return ["i", "item"];
    return terrainGlyph(cell.tile);
}

/* --------------------------------------- tileset rendering (Spike 10C) -- */
/* An OPTIONAL sprite skin over the SAME consumed snapshots. The backend
 * snapshot stays the only authority; the glyph renderer above remains the
 * safe visual fallback (glyphs are a frontend interpretation too).
 *
 * Sprite-index interpretation mirrors the engine's tileset loader (the
 * implementing lines are cited in docs/arcopolis/
 * 24_SPIKE10C_FRONTEND_TILESET_RENDERING.md): fg/bg integers in a MAIN
 * tileset's tile_config.json are GLOBAL 0-based sprite indices over the
 * concatenation of every "tiles-new" sheet, each sheet's capacity derived
 * from its ACTUAL image dimensions (floor(w/spriteW) * floor(h/spriteH)),
 * sheets in file order, sprites row-major left-to-right top-to-bottom.
 * Entries may reference sprites in OTHER sheets, so index->sheet resolution
 * always goes through the global table.
 *
 * v0 renders ONE sprite per fg/bg: a plain int as-is; an array of ints
 * (rotations) -> the first entry (the unrotated/north sprite); a weighted
 * object array -> the first object's sprite (again first entry when that is
 * itself a rotation array). multitile additional_tiles, rotation selection,
 * variation weights, animation and the engine's looks_like fallback chain
 * are all out of scope: anything unresolved falls back to the glyph. */

function emptyTilesetState() {
    return {
        status: "none",   // none | loading | ready | error
        reason: null,
        name: null,
        tileW: 32,        // tile_info width/height: the cell box in pixels
        tileH: 32,
        total: 0,         // grand total sprite count across all sheets
        sheets: [],       // {file, spriteW, spriteH, offX, offY, start, count, cols}
        ids: null,        // Map id -> {fg: int|null, bg: int|null} (global indices)
    };
}

function tilesetActive() {
    return renderMode === "tileset" && tileset.status === "ready";
}

function asIndex(value) {
    return Number.isInteger(value) && value >= 0 ? value : null;
}

/* One sprite index from a tile_config fg/bg value (the v0 simplifications
 * from the section comment). Returns a non-negative int or null. */
function resolveSpriteIndex(value) {
    if (Number.isInteger(value)) return asIndex(value);
    if (Array.isArray(value) && value.length) {
        const first = value[0];
        if (Number.isInteger(first)) return asIndex(first);     // rotation array
        if (first && typeof first === "object") {               // weighted variations
            const sprite = first.sprite;
            if (Number.isInteger(sprite)) return asIndex(sprite);
            if (Array.isArray(sprite) && Number.isInteger(sprite[0])) {
                return asIndex(sprite[0]);                      // weighted rotations
            }
        }
    }
    return null;
}

/* Mirrors the engine's post-load range erase: indices outside [0, total)
 * are dropped, so the entry falls back to the glyph. */
function validIndex(idx) {
    return idx !== null && idx >= 0 && idx < tileset.total ? idx : null;
}

function loadImage(url) {
    return new Promise((resolve, reject) => {
        const img = new Image();
        img.onload = () => resolve(img);
        img.onerror = () => reject(new Error(`image failed to load: ${url}`));
        img.src = url;
    });
}

async function loadTileset() {
    tileset = emptyTilesetState();
    tileset.status = "loading";
    renderTilesetStatus();
    try {
        const info = await api("/tileset/info");
        if (!info || info.enabled !== true) {
            tileset.status = "none";
            tileset.reason = (info && info.reason) || "no tileset configured";
            return;
        }
        tileset.name = typeof info.name === "string" && info.name ? info.name : "tileset";
        const config = await api("/tileset/tile_config.json");
        const tileInfo = Array.isArray(config.tile_info) ? config.tile_info[0] : null;
        const sheetsRaw = config["tiles-new"];
        if (!tileInfo || !Number.isInteger(tileInfo.width) || tileInfo.width <= 0
            || !Number.isInteger(tileInfo.height) || tileInfo.height <= 0
            || !Array.isArray(sheetsRaw) || !sheetsRaw.length) {
            throw new Error("tile_config.json lacks the tile_info/tiles-new shape");
        }
        tileset.tileW = tileInfo.width;
        tileset.tileH = tileInfo.height;
        // ALL-OR-NOTHING image load: every sheet's start index depends on the
        // ACTUAL dimensions of every sheet before it (exactly like the engine
        // loader), so one missing sheet invalidates the whole table. UX cost,
        // accepted for the spike: the Tileset button stays disabled until all
        // sheets finish loading; progressive loading is deferred.
        const images = await Promise.all(
            sheetsRaw.map((sheet) => loadImage(`/tileset/${encodeURIComponent(sheet.file)}`)));
        let offset = 0;
        sheetsRaw.forEach((sheetDef, i) => {
            const img = images[i];
            // A present-but-invalid sprite dimension would corrupt the WHOLE
            // index table (cols = floor(w/0) = Infinity shifts every later
            // sheet's start), so it fails the load outright: the fail-safe
            // contract is "tileset unavailable -> glyph", never
            // silently-wrong sprites under a "ready" status.
            for (const key of ["sprite_width", "sprite_height"]) {
                if (key in sheetDef
                    && (!Number.isInteger(sheetDef[key]) || sheetDef[key] <= 0)) {
                    throw new Error(`sheet ${sheetDef.file}: invalid ${key}`);
                }
            }
            const spriteW = Number.isInteger(sheetDef.sprite_width)
                ? sheetDef.sprite_width : tileset.tileW;
            const spriteH = Number.isInteger(sheetDef.sprite_height)
                ? sheetDef.sprite_height : tileset.tileH;
            const cols = Math.floor(img.naturalWidth / spriteW);
            const count = cols * Math.floor(img.naturalHeight / spriteH);
            tileset.sheets.push({
                file: String(sheetDef.file),
                spriteW,
                spriteH,
                offX: Number.isInteger(sheetDef.sprite_offset_x) ? sheetDef.sprite_offset_x : 0,
                offY: Number.isInteger(sheetDef.sprite_offset_y) ? sheetDef.sprite_offset_y : 0,
                start: offset,
                count,
                cols,
            });
            offset += count;
        });
        tileset.total = offset;
        // Register ids only AFTER the full capacity table exists: fg/bg are
        // global indices that may point into other sheets, so range
        // validation needs the grand total. additional_tiles are skipped
        // (the engine registers those under suffixed ids - out of scope).
        // Duplicate ids: last one wins, like the engine's map assignment.
        const ids = new Map();
        for (const sheetDef of sheetsRaw) {
            for (const entry of sheetDef.tiles || []) {
                if (!entry || typeof entry !== "object") continue;
                const fg = validIndex(resolveSpriteIndex(entry.fg));
                const bg = validIndex(resolveSpriteIndex(entry.bg));
                if (fg === null && bg === null) continue;
                const entryIds = Array.isArray(entry.id) ? entry.id : [entry.id];
                for (const id of entryIds) {
                    if (typeof id === "string" && id) ids.set(id, { fg, bg });
                }
            }
        }
        tileset.ids = ids;
        tileset.status = "ready";
    } catch (err) {
        tileset.status = "error";
        tileset.reason = String((err && err.message) || err);
    } finally {
        if (renderMode === "tileset" && tileset.status !== "ready") {
            renderMode = "glyph"; // fail safe: never leave a dead mode active
        }
        renderTilesetStatus();
        renderGrid();
        renderInspector();
    }
}

function setRenderMode(mode) {
    if (mode === "tileset" && tileset.status !== "ready") mode = "glyph";
    if (mode !== renderMode) {
        renderMode = mode;
        // Pure consumers only: a view toggle re-renders but can never touch
        // updateDiff, so the 10B diff baseline stays put by construction.
        renderGrid();
        renderInspector();
    }
    renderTilesetStatus();
}

/* The footer status line + the mode buttons (view toggles - deliberately
 * NOT gated on canAct(): switching the skin is always allowed). */
function renderTilesetStatus() {
    const texts = {
        none: `glyph only — ${tileset.reason || "no tileset configured"}`,
        loading: "loading tileset…",
        ready: `tileset loaded: ${tileset.name}`,
        error: `tileset unavailable: ${tileset.reason || "load failed"}`,
    };
    const status = $("tileset-status");
    status.textContent = texts[tileset.status] || "";
    status.classList.toggle("tileset-warn", tileset.status === "error");
    $("mode-tileset").disabled = tileset.status !== "ready";
    $("mode-glyph").classList.toggle("mode-active", renderMode === "glyph");
    $("mode-tileset").classList.toggle("mode-active", renderMode === "tileset");
}

function tilesetEntry(id) {
    if (!tileset.ids || !id) return null;
    return tileset.ids.get(String(id)) || null;
}

/* Global sprite index -> its sheet + pixel position, mirroring the engine's
 * row-major bookkeeping. A linear scan over ~17 sheets is fine here. */
function spriteLocation(idx) {
    for (const sheet of tileset.sheets) {
        if (idx >= sheet.start && idx < sheet.start + sheet.count) {
            const local = idx - sheet.start;
            return {
                sheet,
                px: (local % sheet.cols) * sheet.spriteW,
                py: Math.floor(local / sheet.cols) * sheet.spriteH,
            };
        }
    }
    return null;
}

/* Inspector debug: where an id resolved ("#3239 (normal.png)") or why the
 * cell will glyph-fallback for it. */
function spriteDebugLabel(id) {
    const entry = tilesetEntry(id);
    const idx = entry === null ? null : (entry.fg !== null ? entry.fg : entry.bg);
    const loc = idx === null ? null : spriteLocation(idx);
    if (!loc) return "unresolved → glyph";
    return `#${idx} (${loc.sheet.file})`;
}

/* Paint one cell as sprite layers plus, when something has no sprite, the
 * glyph overlay. Layer order bottom->top: terrain bg/fg, furniture bg/fg,
 * top ground item bg/fg, first monster bg/fg. "Top item" = the LAST entry
 * of the exported tile stack and "first monster" = entities order - both
 * are frontend heuristics; the snapshot defines no stacking order. The
 * avatar always stays a glyph (the export carries no avatar sprite
 * identity) and NPCs stay 'N' (no npc type_id in the export). Sprites
 * larger than the cell clip to it (no overhang in v0). */
function renderSpriteCell(div, cell) {
    div.textContent = "";
    const addLayers = (id) => {
        const entry = tilesetEntry(id);
        if (!entry) return false;
        let drawn = false;
        for (const key of ["bg", "fg"]) {
            const loc = entry[key] === null ? null : spriteLocation(entry[key]);
            if (!loc) continue;
            const span = document.createElement("span");
            span.className = "sprite-layer";
            span.style.left = `${loc.sheet.offX}px`;
            span.style.top = `${loc.sheet.offY}px`;
            span.style.width = `${loc.sheet.spriteW}px`;
            span.style.height = `${loc.sheet.spriteH}px`;
            span.style.backgroundImage = `url("/tileset/${encodeURIComponent(loc.sheet.file)}")`;
            span.style.backgroundPosition = `${-loc.px}px ${-loc.py}px`;
            div.appendChild(span);
            drawn = true;
        }
        return drawn;
    };

    const terDrawn = addLayers(cell.tile.ter);
    const furnId = String(cell.tile.furn || "");
    const hasFurn = furnId !== "" && furnId !== "f_null";
    const furnDrawn = hasFurn ? addLayers(furnId) : false;
    const topItem = cell.items.length ? cell.items[cell.items.length - 1] : null;
    const itemDrawn = topItem ? addLayers(topItem.type_id) : false;
    const monster = cell.monsters.length ? cell.monsters[0] : null;
    const monsterDrawn = monster ? addLayers(monster.type_id) : false;

    // ONE glyph overlay: the existing glyph logic picks the cell's
    // representative glyph, and it is shown unless its referent just
    // rendered as a sprite. With furniture present, terrainGlyph's verdict
    // is always furniture-derived, so the furn layer decides suppression.
    const [glyph, family] = cellGlyph(cell);
    let show;
    if (family === "avatar" || family === "npc") show = true;
    else if (family === "monster") show = !monsterDrawn;
    else if (family === "item") show = !itemDrawn;
    else if (hasFurn) show = !furnDrawn;
    else show = !terDrawn;
    if (show && glyph !== " ") {
        const overlay = document.createElement("span");
        overlay.className = `cell-glyph g-${family}`;
        overlay.textContent = glyph;
        div.appendChild(overlay);
    }
}

function renderGrid() {
    const grid = $("grid");
    grid.innerHTML = "";
    grid.style.gridTemplateColumns = "";
    const tilesetOn = tilesetActive();
    grid.classList.toggle("tileset-mode", tilesetOn);
    // Cells are built ONLY by updateDiff, so a click-driven repaint can never
    // rebuild them or shift the diff baseline; this is a pure consumer.
    const cells = lastCells;
    if (!cells || !cells.size) {
        grid.appendChild(placeholder("No snapshot yet — press Start."));
        return;
    }
    let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
    for (const key of cells.keys()) {
        const [x, y] = key.split(",").map(Number);
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
    }
    if (maxX - minX + 1 > MAX_MAP_SPAN || maxY - minY + 1 > MAX_MAP_SPAN) {
        grid.appendChild(placeholder("snapshot window too large to render"));
        return;
    }
    grid.style.gridTemplateColumns =
        `repeat(${maxX - minX + 1}, ${tilesetOn ? tileset.tileW + "px" : "1.25em"})`;
    if (tilesetOn) {
        // The cell box tracks tile_info (32x32 for UltimateCataclysm).
        grid.style.setProperty("--tile-w", `${tileset.tileW}px`);
        grid.style.setProperty("--tile-h", `${tileset.tileH}px`);
    }
    for (let y = minY; y <= maxY; y++) {
        for (let x = minX; x <= maxX; x++) {
            const cell = cells.get(`${x},${y}`);
            const div = document.createElement("div");
            div.dataset.x = x;
            div.dataset.y = y;
            if (!cell) {
                div.className = "cell g-void";
                div.textContent = " ";
            } else {
                const [glyph, family] = cellGlyph(cell);
                div.textContent = glyph === " " ? " " : glyph;
                div.className = `cell g-${family}`;
                if (cell.tile.seen === false) div.classList.add("unseen");
                if (cell.isAvatar) div.classList.add("is-avatar");
                const record = diffState.changes ? diffState.changes.get(`${x},${y}`) : null;
                div.title = cellTitle(cell, x, y, record);
                if (record) {
                    div.classList.add("changed-tile");
                    if (record.ter) div.classList.add("changed-terrain");
                    if (record.furn) div.classList.add("changed-furniture");
                    if (record.seen) div.classList.add("changed-seen");
                    if (record.entities) div.classList.add("changed-entities");
                }
            }
            // Tileset mode repaints the cell as sprite layers + an optional
            // glyph overlay; glyph mode keeps the text node above untouched.
            if (tilesetOn && cell) renderSpriteCell(div, cell);
            if (inspectKey === `${x},${y}`) div.classList.add("inspected");
            grid.appendChild(div);
        }
    }
}

function renderAvatar() {
    const stats = $("avatar-stats");
    stats.innerHTML = "";
    const avatar = doc.avatar;
    if (!avatar) {
        stats.appendChild(placeholder("no session", "dd"));
        return;
    }
    const rows = [
        ["name", avatar.name],
        ["hp", `${avatar.hp} / ${avatar.hp_max}`],
        ["stamina", avatar.stamina],
        ["moves", avatar.moves],
        ["pain", avatar.pain],
        ["pos_abs", Array.isArray(avatar.pos_abs) ? avatar.pos_abs.join(", ") : "?"],
        ["pos_local", Array.isArray(avatar.pos_local) ? avatar.pos_local.join(", ") : "?"],
    ];
    for (const [label, value] of rows) {
        const dt = document.createElement("dt");
        dt.textContent = label;
        const dd = document.createElement("dd");
        dd.textContent = value === undefined || value === null ? "?" : String(value);
        stats.append(dt, dd);
    }
}

function renderOutcome() {
    const badge = $("outcome-badge");
    const text = $("outcome-text");
    const raw = $("raw-response");
    const last = doc.last_result;
    if (!last) {
        badge.textContent = "—";
        badge.className = "badge o-none";
        text.textContent = "";
        raw.textContent = "";
        return;
    }
    const outcome = last.outcome;
    if (outcome) {
        badge.textContent = outcome.outcome;
        badge.className = `badge o-${outcome.outcome}`;
        text.textContent = outcome.explanation || "";
    } else {
        badge.textContent = last.op;
        badge.className = "badge o-none";
        text.textContent = last.op === "start"
            ? "session started; initial snapshot loaded"
            : "";
    }
    raw.textContent = last.response ? JSON.stringify(last.response, null, 2) : "(no response)";
}

/* The compact change-summary panel: counts + what produced the diff. */
function renderDiffSummary() {
    const box = $("diff-summary");
    box.innerHTML = "";
    if (!diffState.snapKey) {
        box.appendChild(placeholder("no snapshot yet"));
        return;
    }
    if (!diffState.changes) {
        box.appendChild(placeholder("first snapshot — no baseline to compare"));
        return;
    }
    const counts = diffState.counts;
    const head = document.createElement("p");
    head.className = "diff-headline";
    head.textContent = counts.tiles
        ? `${counts.tiles} tile${counts.tiles === 1 ? "" : "s"} changed`
        : "no tile changes vs previous snapshot";
    box.appendChild(head);
    if (counts.tiles) {
        const detail = document.createElement("p");
        detail.className = "diff-counts";
        detail.textContent = `terrain ${counts.terrain} · furniture ${counts.furniture}`
            + ` · seen ${counts.seen} · entities ${counts.entities}`;
        box.appendChild(detail);
    }
    const bits = [];
    if (diffState.producedBy) bits.push(`after ${diffState.producedBy}`);
    if (diffState.vsSnapshot) bits.push(`vs ${diffState.vsSnapshot}`);
    if (bits.length) {
        const meta = document.createElement("p");
        meta.className = "diff-meta";
        meta.textContent = bits.join(" · ");
        box.appendChild(meta);
    }
}

function entityLine(group, entity) {
    if (group === "npcs") {
        const flags = [];
        if (entity.is_enemy) flags.push("enemy");
        if (entity.is_player_ally) flags.push("ally");
        if (entity.is_following) flags.push("following");
        if (entity.is_stationary) flags.push("stationary");
        if (entity.hallucination) flags.push("hallucination");
        return `${entity.name}${flags.length ? " — " + flags.join(", ") : ""}`;
    }
    if (group === "monsters") {
        const halluc = entity.hallucination ? ", hallucination" : "";
        return `${entity.name} (${entity.type_id}) hp ${entity.hp}/${entity.hp_max}${halluc}`;
    }
    const charges = entity.count_by_charges ? ` ×${entity.charges}` : "";
    return `${entity.name} (${entity.type_id})${charges}`;
}

function renderInspector() {
    const box = $("inspector");
    box.innerHTML = "";
    if (!inspectKey || !lastCells) {
        box.appendChild(placeholder("click a tile"));
        return;
    }
    const cell = lastCells.get(inspectKey);
    if (!cell) {
        box.appendChild(placeholder(`(${inspectKey}) is outside the export window`));
        return;
    }
    const [x, y] = inspectKey.split(",").map(Number);
    const avatar = doc.avatar || {};
    const av = Array.isArray(avatar.pos_local) ? avatar.pos_local : null;
    const dl = document.createElement("dl");
    const rows = [
        ["tile", `${x}, ${y}`],
        ["terrain", cell.tile.ter || "?"],
        ["furniture", cell.tile.furn || "(none)"],
        ["seen", String(cell.tile.seen !== false)],
    ];
    if (cell.isAvatar) {
        rows.push(["avatar", "here"]);
        // The avatar's own tile is examinable via the "here" token (the engine
        // chooser's self/pause path); it is never a move target.
        rows.push(["examine via", "here"]);
    } else if (av) {
        const dx = x - av[0];
        const dy = y - av[1];
        rows.push(["distance", String(Math.max(Math.abs(dx), Math.abs(dy)))]);
        // Any of the 8 adjacent tiles is reachable by both verbs through the
        // same direction token (cardinals and diagonals alike).
        const direction = DIRECTION_FOR_DELTA[`${dx},${dy}`];
        if (direction) rows.push(["move/examine via", direction]);
    }
    // Spike 10C debug affordance: how each aspect resolves against the
    // loaded tileset (reported in glyph mode too - resolution is a property
    // of the tileset, not of the active skin).
    if (tileset.status === "ready") {
        rows.push(["ter sprite", spriteDebugLabel(cell.tile.ter)]);
        const furnId = String(cell.tile.furn || "");
        if (furnId && furnId !== "f_null") {
            rows.push(["furn sprite", spriteDebugLabel(furnId)]);
        }
        const topEntity = cell.monsters.length ? cell.monsters[0]
            : cell.items.length ? cell.items[cell.items.length - 1] : null;
        if (topEntity) rows.push(["entity sprite", spriteDebugLabel(topEntity.type_id)]);
    }
    for (const [label, value] of rows) {
        const dt = document.createElement("dt");
        dt.textContent = label;
        const dd = document.createElement("dd");
        dd.textContent = value;
        dl.append(dt, dd);
    }
    box.appendChild(dl);
    for (const group of ["npcs", "monsters", "items"]) {
        if (!cell[group].length) continue;
        const heading = document.createElement("dt");
        heading.textContent = group;
        box.appendChild(heading);
        const list = document.createElement("ul");
        for (const entity of cell[group]) {
            const li = document.createElement("li");
            li.textContent = entityLine(group, entity);
            list.appendChild(li);
        }
        box.appendChild(list);
    }
    renderInspectorDiff(box);
}

/* The "changed since previous snapshot" block under the inspected tile. */
function renderInspectorDiff(box) {
    const heading = document.createElement("dt");
    heading.textContent = "changed since previous snapshot";
    box.appendChild(heading);
    if (!diffState.changes) {
        box.appendChild(placeholder("(no previous snapshot)", "div"));
        return;
    }
    const record = diffState.changes.get(inspectKey);
    if (!record) {
        box.appendChild(placeholder("no changes detected", "div"));
        return;
    }
    const dl = document.createElement("dl");
    const rows = [
        ["terrain", record.ter],
        ["furniture", record.furn],
        ["seen", record.seen],
        ["entities", record.entities],
    ];
    for (const [label, pair] of rows) {
        const dt = document.createElement("dt");
        dt.textContent = label;
        const dd = document.createElement("dd");
        if (pair) {
            dd.textContent = `${pair[0]} → ${pair[1]}`;
            dd.classList.add("diff-changed");
        } else {
            dd.textContent = "no change";
        }
        dl.append(dt, dd);
    }
    box.appendChild(dl);
}

function renderMessages() {
    const list = $("messages");
    list.innerHTML = "";
    const messages = doc.messages || [];
    // Newest first; the snapshot carries a small recent-messages window.
    for (const message of messages.slice(-15).reverse()) {
        const li = document.createElement("li");
        li.textContent = message && message.text ? message.text : String(message);
        list.appendChild(li);
    }
    if (!messages.length) list.appendChild(placeholder("no messages", "li"));
}

/* ----------------------------------------------- action mode (Spike 11B) -- */
/* "move" vs "examine": which verb a direction button or an adjacent-tile click
 * sends. A pure UI selector - it changes nothing about the backend contract,
 * only which command token the same gesture produces. Default is move. */

const MAP_HINTS = {
    move: "Move mode: click any adjacent tile to move (8-way). Examine mode: "
        + "click any adjacent tile, or the avatar tile for here. Shift-click "
        + "inspects without acting.",
    examine: "Examine mode: click any adjacent tile to examine it, or the "
        + "avatar tile for here. Switch to Move mode to step. Shift-click "
        + "inspects without acting.",
};

function setActionMode(mode) {
    if (mode !== "move" && mode !== "examine") return;
    actionMode = mode;
    renderActionMode();
    renderButtons(); // the "here" center button is only active in examine mode
}

/* The mode buttons' active state + the map hint. Always safe to call (a view
 * selector, never gated on canAct). */
function renderActionMode() {
    $("mode-move").classList.toggle("mode-active", actionMode === "move");
    $("mode-examine").classList.toggle("mode-active", actionMode === "examine");
    $("map-hint").textContent = MAP_HINTS[actionMode] || MAP_HINTS.move;
}

/* Send the current action verb for one direction token (a d-pad button or an
 * adjacent-tile click). "here" is examine-only (the avatar's own tile). */
function sendDirection(direction) {
    if (!direction || !canAct()) return;
    if (actionMode === "examine") {
        post("/api/command", { command: "examine", direction });
    } else if (direction !== "here") {
        post("/api/command", { command: "move", direction });
    }
    // move + "here" is intentionally a no-op (the center button is disabled in
    // move mode); Wait stays the separate explicit control.
}

function renderButtons() {
    const phase = doc ? doc.phase : "idle";
    $("btn-start").disabled = inFlight || !["idle", "ended", "dead"].includes(phase);
    const actable = canAct();
    for (const button of document.querySelectorAll(".btn-dir")) {
        // In move mode the center "here" button does nothing (Wait is separate);
        // in examine mode every direction incl. "here" is active.
        const hereOnly = button.dataset.direction === "here";
        button.disabled = !actable || (hereOnly && actionMode === "move");
    }
    $("btn-wait").disabled = !actable;
    $("btn-export").disabled = !actable;
    $("btn-quit").disabled = !actable;
}

/* ----------------------------------------------------------- chrome bits -- */

function placeholder(message, tag) {
    const node = document.createElement(tag || "span");
    node.className = "placeholder";
    node.textContent = message;
    return node;
}

function setConnected(ok) {
    $("status-conn").classList.toggle("hidden", ok);
}

function showError(err) {
    $("error-text").textContent = `${err.code}: ${err.message}`;
    $("error-banner").classList.remove("hidden");
}

function clearError() {
    $("error-banner").classList.add("hidden");
}

/* ------------------------------------------------------------------ init -- */

function init() {
    $("btn-start").addEventListener("click", () => post("/api/start"));
    $("btn-wait").addEventListener("click", () => post("/api/wait"));
    $("btn-export").addEventListener("click", () => post("/api/export"));
    $("btn-quit").addEventListener("click", () => post("/api/quit"));
    // The 3x3 d-pad: every direction button sends the CURRENT action verb
    // (move or examine) for its data-direction token; "here" is the center.
    for (const button of document.querySelectorAll(".btn-dir")) {
        button.addEventListener("click", () => sendDirection(button.dataset.direction));
    }
    $("error-dismiss").addEventListener("click", clearError);
    $("mode-glyph").addEventListener("click", () => setRenderMode("glyph"));
    $("mode-tileset").addEventListener("click", () => setRenderMode("tileset"));
    $("mode-move").addEventListener("click", () => setActionMode("move"));
    $("mode-examine").addEventListener("click", () => setActionMode("examine"));

    // Click an adjacent tile to act on it with the current mode's verb (move:
    // step onto any of the 8 neighbors; examine: examine any neighbor, or the
    // avatar tile for here). Click anything non-adjacent - or Shift-click
    // anywhere, so adjacent tiles stay inspectable - to inspect read-only.
    $("grid").addEventListener("click", (event) => {
        const target = event.target.closest(".cell");
        if (!target || !doc) return;
        const x = Number(target.dataset.x);
        const y = Number(target.dataset.y);
        const avatar = doc.avatar;
        if (avatar && Array.isArray(avatar.pos_local) && !event.shiftKey && canAct()) {
            const dx = x - avatar.pos_local[0];
            const dy = y - avatar.pos_local[1];
            if (dx === 0 && dy === 0) {
                // The avatar's own tile: examine here (examine mode only); in
                // move mode it is never a move target, so it falls through to
                // inspect below.
                if (actionMode === "examine") {
                    post("/api/command", { command: "examine", direction: "here" });
                    return;
                }
            } else {
                const direction = DIRECTION_FOR_DELTA[`${dx},${dy}`];
                if (direction) {
                    sendDirection(direction);
                    return;
                }
            }
        }
        inspectKey = `${x},${y}`;
        renderGrid();
        renderInspector();
    });

    renderActionMode(); // set the initial hint + active mode button
    loadTileset(); // async; the UI stays glyph-only until (and unless) it succeeds
    refresh();
    setInterval(refresh, 1000); // freshness fallback; POSTs render immediately
}

document.addEventListener("DOMContentLoaded", init);
