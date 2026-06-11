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
 */
"use strict";

let doc = null;            // the last rendered state document
let renderedSerial = -1;   // state_serial guard: never render an older doc
let inFlight = false;      // one in-flight POST at a time (mirrors the bridge)
let inspectKey = null;     // "x,y" of the inspected tile, or null
let lastCells = null;      // Map "x,y" -> cell bundle from the last render

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
    renderStatus();
    renderGrid();
    renderAvatar();
    renderOutcome();
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

/* Heuristic terrain families from the ter/furn id strings - the snapshot has
 * no per-tile symbol/colour yet (a documented contract gap). */
function terrainGlyph(tile) {
    const furn = String(tile.furn || "");
    if (furn && furn !== "f_null") {
        if (furn.includes("door")) return ["+", "door"];
        return ["f", "furniture"];
    }
    const ter = String(tile.ter || "");
    if (ter === "" || ter === "t_null") return [" ", "void"];
    if (ter.includes("door")) return ["+", "door"];
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
    if (!doc.map || !Array.isArray(doc.map.tiles) || !doc.map.tiles.length) {
        lastCells = null;
        grid.appendChild(placeholder("No snapshot yet — press Start."));
        return;
    }
    const cells = buildCells(doc.map);
    lastCells = cells;
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
