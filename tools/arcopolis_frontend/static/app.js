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
 */
"use strict";

let doc = null;            // the last rendered state document
let renderedSerial = -1;   // state_serial guard: never render an older doc
let inFlight = false;      // one in-flight POST at a time (mirrors the bridge)
let inspectKey = null;     // "x,y" of the inspected tile, or null
let lastCells = null;      // cell bundles of the CURRENT snapshot (updateDiff owns it)
let diffState = emptyDiffState(); // diff of the current snapshot vs the previous one

const MAX_MAP_SPAN = 64;   // defensive render cap (the window is 25x25 today)
const DIRECTION_FOR_DELTA = {
    "0,-1": "move_n",
    "0,1": "move_s",
    "1,0": "move_e",
    "-1,0": "move_w",
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

/* "move_s → moved" from the state doc's last_result (null when absent). */
function describeProducer(lastResult) {
    if (!lastResult) return null;
    const request = lastResult.request || {};
    let what = lastResult.op;
    if (lastResult.op === "command") what = request.direction || request.command || what;
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

function renderGrid() {
    const grid = $("grid");
    grid.innerHTML = "";
    grid.style.gridTemplateColumns = "";
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
    grid.style.gridTemplateColumns = `repeat(${maxX - minX + 1}, 1.25em)`;
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
    } else if (av) {
        const dx = x - av[0];
        const dy = y - av[1];
        rows.push(["distance", String(Math.max(Math.abs(dx), Math.abs(dy)))]);
        const direction = DIRECTION_FOR_DELTA[`${dx},${dy}`];
        if (direction) rows.push(["reachable via", direction]);
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

function renderButtons() {
    const phase = doc ? doc.phase : "idle";
    $("btn-start").disabled = inFlight || !["idle", "ended", "dead"].includes(phase);
    const actable = canAct();
    for (const button of document.querySelectorAll(".btn-move")) button.disabled = !actable;
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
    for (const button of document.querySelectorAll(".btn-move")) {
        button.addEventListener("click", () =>
            post("/api/command", { command: "move", direction: button.dataset.direction }));
    }
    $("error-dismiss").addEventListener("click", clearError);

    // Click an adjacent cardinal tile to move; click anything else (or
    // Shift-click anywhere, so adjacent tiles stay inspectable) to inspect.
    $("grid").addEventListener("click", (event) => {
        const target = event.target.closest(".cell");
        if (!target || !doc) return;
        const x = Number(target.dataset.x);
        const y = Number(target.dataset.y);
        const avatar = doc.avatar;
        if (avatar && Array.isArray(avatar.pos_local) && !event.shiftKey && canAct()) {
            const delta = `${x - avatar.pos_local[0]},${y - avatar.pos_local[1]}`;
            const direction = DIRECTION_FOR_DELTA[delta];
            if (direction) {
                post("/api/command", { command: "move", direction });
                return;
            }
        }
        inspectKey = `${x},${y}`;
        renderGrid();
        renderInspector();
    });

    refresh();
    setInterval(refresh, 1000); // freshness fallback; POSTs render immediately
}

document.addEventListener("DOMContentLoaded", init);
