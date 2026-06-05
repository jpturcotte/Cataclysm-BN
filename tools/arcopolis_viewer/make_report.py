#!/usr/bin/env python3
"""Arcopolis Spike 4 - offline session viewer / contract consumer.

Reads an Arcopolis backend export directory (a ``session.jsonl`` transcript plus
``NNN_<name>.json`` snapshot files, produced by the Bright Nights
``--arcopolis-run-script`` mode, Spike 3.1C) and renders ONE self-contained HTML
report visualizing the session sequence.

This is an *external consumer* of an already-defined file contract. It is
read-only and stdlib-only:

  * no third-party Python packages,
  * no web server,
  * no JavaScript,
  * no images or tilesets.

The report:

  * parses ``session.jsonl`` and validates that every line is JSON,
  * shows ``session_start`` / ``session_end``,
  * lays out a timeline of command / export / error events in file order,
  * loads each export's referenced snapshot and re-verifies that the export
    event's ``turn`` / ``pos_abs`` / ``moves`` match the snapshot,
  * draws a simple 2D text/CSS tile map per snapshot, centered on the avatar,
  * surfaces errors (bad lines, missing snapshots, mismatches, error events).

Usage::

    python make_report.py --session-dir <export_dir> --output <report.html>

Exit codes::

    0  report written; every line was valid JSON and every export matched its
       snapshot (a clean run).
    2  report STILL written, but at least one discrepancy was found: a malformed
       JSONL line, a missing / unreadable / invalid snapshot, a scalar mismatch,
       an ``error`` event, or a truncated session. Open the report and inspect.
    1  fatal: bad usage, a missing / unreadable ``session.jsonl``, or the report
       could not be written. No report is produced.

It changes no Bright Nights gameplay, no backend command, and no snapshot or
transcript schema. Any data a richer viewer would want but the current export
does not provide is documented as future export work in
``docs/arcopolis/12_SPIKE4_OFFLINE_SESSION_VIEWER.md`` - it is NOT invented here.
"""

import argparse
import html
import json
import os
import sys

TOOL_VERSION = "1.1.0"
EXPECTED_SCHEMA_VERSION = 1
SESSION_LOG_NAME = "session.jsonl"
# Defensive cap on the tile-window span we will render (the engine view is
# radius 12 = 25x25); a malformed snapshot with wild coordinates cannot blow up
# the render loops.
MAX_MAP_SPAN = 256

esc = html.escape


# --------------------------------------------------------------------------- #
# small helpers
# --------------------------------------------------------------------------- #
def dig(obj, dotted):
    """Return a nested value by dotted path, or ``None`` on any missing hop."""
    cur = obj
    for key in dotted.split("."):
        if not isinstance(cur, dict) or key not in cur:
            return None
        cur = cur[key]
    return cur


def fmt_scalar(value):
    """Render a JSON scalar/list compactly for display (None -> em dash)."""
    if value is None:
        return "—"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, list):
        return "[" + ", ".join(fmt_scalar(v) for v in value) + "]"
    return str(value)


def as_int_list(value):
    """Coerce a value to a list[int], or return ``None`` if it cannot be."""
    if not isinstance(value, list):
        return None
    try:
        return [int(v) for v in value]
    except (TypeError, ValueError):
        return None


def display_path(path, reveal):
    """Render a local path for the report.

    Redacted to a basename by default (AGENTS.md: diagnostic tooling must not
    embed machine-specific local paths in its output); ``--reveal-paths`` shows
    it verbatim.
    """
    if reveal or not path:
        return str(path)
    return os.path.basename(os.path.normpath(str(path))) or str(path)


# --------------------------------------------------------------------------- #
# loading + validation
# --------------------------------------------------------------------------- #
def load_session_log(session_dir):
    """Parse ``session.jsonl`` line by line.

    Returns a dict with ``start``, ``end``, ``events`` (every parsed object, in
    file order, each annotated with ``_line``), ``bad_lines`` (line number, raw
    snippet, parser message), and ``warnings``. Raises ``OSError`` if the file
    itself cannot be read (the caller turns that into a fatal exit).
    """
    path = os.path.join(session_dir, SESSION_LOG_NAME)
    start = None
    end = None
    events = []
    bad_lines = []
    warnings = []

    # utf-8-sig transparently strips a UTF-8 BOM if a tool (PowerShell, Notepad)
    # added one, while reading plain UTF-8 unchanged.
    with open(path, "r", encoding="utf-8-sig", errors="replace") as handle:
        for line_no, raw in enumerate(handle, start=1):
            stripped = raw.strip()
            if not stripped:
                continue
            try:
                obj = json.loads(stripped)
            except json.JSONDecodeError as err:
                bad_lines.append((line_no, stripped[:200], str(err)))
                continue
            if not isinstance(obj, dict):
                bad_lines.append((line_no, stripped[:200], "valid JSON but not an object"))
                continue
            obj["_line"] = line_no
            events.append(obj)
            event_type = obj.get("event")
            if event_type == "session_start":
                if start is None:
                    start = obj
                else:
                    warnings.append("multiple session_start events (line %d); using the first" % line_no)
            elif event_type == "session_end":
                if end is None:
                    end = obj
                else:
                    warnings.append("multiple session_end events (line %d); using the first" % line_no)

    return {
        "path": path,
        "start": start,
        "end": end,
        "events": events,
        "bad_lines": bad_lines,
        "warnings": warnings,
    }


def load_snapshot(session_dir, rel_path):
    """Load a referenced snapshot file defensively.

    Returns ``{rel, ok, error, data, missing_keys}``. Never raises: hard
    failures (path traversal, missing, unreadable, invalid JSON, non-object)
    are reported as ``ok=False`` with a human reason. A loaded object that is
    missing required keys stays ``ok=True`` (so the report still renders what it
    can) but records them in ``missing_keys``, which the caller counts as a
    discrepancy.
    """
    result = {"rel": rel_path, "ok": False, "error": None, "data": None, "missing_keys": []}

    if not isinstance(rel_path, str) or not rel_path:
        result["error"] = "export event has no usable 'path'"
        return result

    # Defense in depth: the producer only ever writes a bare relative filename
    # (e.g. "001_after_move1.json"); reject anything that resolves outside
    # session_dir. Resolving both sides to absolute paths and checking the
    # prefix also catches Windows drive-relative paths (e.g. "C:foo"), which
    # os.path.isabs() does not treat as absolute.
    abs_session_dir = os.path.abspath(session_dir)
    abspath = os.path.abspath(os.path.join(abs_session_dir, rel_path))
    if not abspath.startswith(abs_session_dir + os.sep):
        result["error"] = "refusing to load snapshot outside the session dir: %r" % rel_path
        return result

    if not os.path.isfile(abspath):
        result["error"] = "snapshot file not found: %s" % rel_path
        return result

    try:
        with open(abspath, "r", encoding="utf-8-sig", errors="replace") as handle:
            text = handle.read()
    except OSError as err:
        result["error"] = "could not read snapshot: %s" % err
        return result

    try:
        data = json.loads(text)
    except json.JSONDecodeError as err:
        result["error"] = "snapshot is not valid JSON: %s" % err
        return result

    if not isinstance(data, dict):
        result["error"] = "snapshot JSON is not an object"
        return result

    for required in ("backend.turn", "avatar.pos_abs", "avatar.moves", "avatar.pos_local", "tiles"):
        if dig(data, required) is None:
            result["missing_keys"].append(required)

    result["ok"] = True
    result["data"] = data
    return result


def verify_export_against_snapshot(export_ev, snap_data):
    """Re-verify the export event's scalars against the loaded snapshot.

    Core contract (drives PASS/FAIL): ``turn == backend.turn``,
    ``pos_abs == avatar.pos_abs``, ``moves == avatar.moves``. Bonus cross-checks
    against the optional ``session`` block strengthen the result and also count
    as discrepancies when they fail.
    """
    if snap_data is None:
        return {"overall": "N/A", "core": [], "bonus": []}

    def check(name, expected, actual):
        return {"name": name, "expected": expected, "actual": actual, "ok": expected == actual}

    core = [
        check("turn", export_ev.get("turn"), dig(snap_data, "backend.turn")),
        check("pos_abs", as_int_list(export_ev.get("pos_abs")), as_int_list(dig(snap_data, "avatar.pos_abs"))),
        check("moves", export_ev.get("moves"), dig(snap_data, "avatar.moves")),
    ]

    bonus = []
    session = snap_data.get("session")
    if isinstance(session, dict):
        bonus = [
            check("step_index", export_ev.get("step_index"), session.get("step_index")),
            check("export_index", export_ev.get("export_index"), session.get("export_index")),
            check("name", export_ev.get("name"), session.get("export_name")),
            check("final", export_ev.get("final"), session.get("final")),
        ]

    all_ok = all(item["ok"] for item in core) and all(item["ok"] for item in bonus)
    return {"overall": "PASS" if all_ok else "FAIL", "core": core, "bonus": bonus}


# --------------------------------------------------------------------------- #
# tile -> glyph classification
# --------------------------------------------------------------------------- #
# Each rule is (substrings, glyph, css_class, legend_label). Furniture is
# classified first (when furn != f_null), then terrain. Matching is by substring
# on the lower-cased id so unfamiliar ids still resolve to a sensible category;
# anything unmatched falls through to a documented "unknown" glyph. This is a
# schematic - the engine does not export a per-tile symbol/colour (see the doc's
# "future export work").
FURN_RULES = [
    (("door",), "+", "furn-door", "furniture door"),
    (("bench",), "n", "furn", "bench"),
    (("locker", "cupboard", "fridge", "crate", "wardrobe", "dresser", "bookcase", "rack"), "H", "furn", "storage furniture"),
    (("flower", "bluebell", "bush", "plant", "shrub", "sapling"), "*", "furn-plant", "plant / flower"),
    (("wreck", "rubble", "debris"), "%", "furn", "wreckage / rubble"),
]
FURN_FALLBACK = ("F", "furn", "furniture")

TER_RULES = [
    (("door",), "+", "door", "door"),
    (("window",), "=", "window", "window"),
    (("wall",), "#", "wall", "wall"),
    (("stairs_down", "ladder_down", "downstairs"), ">", "stairs", "stairs / ladder down"),
    (("stairs_up", "ladder_up", "upstairs"), "<", "stairs", "stairs / ladder up"),
    (("stairs", "ladder", "escalator"), "≡", "stairs", "stairs / ladder"),
    (("water", "pool", "sewage", "swamp"), "~", "water", "water"),
    (("console", "machinery", "remote", "terminal"), "&", "feature", "machinery / console"),
    (("pavement", "road", "asphalt", "sidewalk", "concrete"), ":", "pavement", "pavement / road"),
    (("grass", "underbrush"), ",", "grass", "grass"),
    (("dirt", "sand", "mud", "gravel"), ".", "dirt", "dirt / ground"),
    (("floor",), ".", "floor", "floor"),
    (("null", "t_null"), " ", "void", "empty / void"),
]
UNKNOWN_RULE = ("?", "unknown", "unknown terrain")


def glyph_for_tile(tile):
    """Map a tile object to ``(glyph, css_class, legend_label)``."""
    furn = str(tile.get("furn", "") or "").lower()
    if furn and furn != "f_null":
        for substrings, glyph, css, label in FURN_RULES:
            if any(token in furn for token in substrings):
                return glyph, css, label
        return FURN_FALLBACK

    ter = str(tile.get("ter", "") or "").lower()
    for substrings, glyph, css, label in TER_RULES:
        if any(token in ter for token in substrings):
            return glyph, css, label
    return UNKNOWN_RULE


# --------------------------------------------------------------------------- #
# map rendering (text + CSS, no JS, no images)
# --------------------------------------------------------------------------- #
def render_map_html(snap_data, open_default=False):
    """Render a snapshot's ``tiles`` window as a monospace HTML grid.

    Returns an HTML string. The grid is built from the actual tiles (clamp-safe:
    a window near the reality-bubble edge has fewer tiles and may be
    asymmetric). North (small y) is at the top because ``move_s`` increments y.
    The avatar cell is the tile whose (x, y) equals ``avatar.pos_local``.
    """
    tiles = dig(snap_data, "tiles")
    if not isinstance(tiles, list) or not tiles:
        return '<p class="nomap">No tiles in this snapshot (empty window or fully out of bounds).</p>'

    grid = {}
    skipped = 0
    for tile in tiles:
        if not isinstance(tile, dict):
            skipped += 1
            continue
        try:
            tx = int(tile["x"])
            ty = int(tile["y"])
        except (KeyError, TypeError, ValueError):
            skipped += 1
            continue
        grid[(tx, ty)] = tile

    if not grid:
        return '<p class="nomap">Snapshot has tiles but none carried usable coordinates.</p>'

    xs = [px for (px, _) in grid]
    ys = [py for (_, py) in grid]
    x0, x1 = min(xs), max(xs)
    y0, y1 = min(ys), max(ys)

    if (x1 - x0 + 1) > MAX_MAP_SPAN or (y1 - y0 + 1) > MAX_MAP_SPAN:
        return ('<p class="nomap">Tile window too large to render '
                "(%d&times;%d; cap %d) &mdash; likely a malformed snapshot.</p>"
                % (x1 - x0 + 1, y1 - y0 + 1, MAX_MAP_SPAN))

    avatar_local = as_int_list(dig(snap_data, "avatar.pos_local"))
    ax = avatar_local[0] if avatar_local and len(avatar_local) >= 2 else None
    ay = avatar_local[1] if avatar_local and len(avatar_local) >= 2 else None
    avatar_in_window = ax is not None and x0 <= ax <= x1 and y0 <= ay <= y1

    # Spike 6A: overlay nearby monsters (entities.monsters[]) on the same single-z window. Absent in
    # pre-Spike-6 snapshots -> dig() returns None -> no overlay (backward compatible). setdefault keeps
    # the first monster (lowest export index) when several share a cell; the per-snapshot list shows all.
    tile_z = next((t.get("z") for t in grid.values() if isinstance(t.get("z"), int)), None)
    monster_cells = {}
    monsters_here = dig(snap_data, "entities.monsters")
    if isinstance(monsters_here, list):
        for mon in monsters_here:
            if not isinstance(mon, dict):
                continue
            pl = as_int_list(mon.get("pos_local"))
            if not pl or len(pl) < 3 or (tile_z is not None and pl[2] != tile_z):
                continue
            monster_cells.setdefault((pl[0], pl[1]), mon)

    legend = {}
    rows_html = []
    for y in range(y0, y1 + 1):
        cells = []
        for x in range(x0, x1 + 1):
            tile = grid.get((x, y))
            if tile is None:
                cells.append('<span class="cell void" title="(%d,%d) outside window">&nbsp;</span>' % (x, y))
                continue
            glyph, css, label = glyph_for_tile(tile)
            legend[(css, glyph, label)] = True
            seen = tile.get("seen", True)
            classes = ["cell", css]
            # Prefer the explicit backend marker (Spike 5); fall back to the pos_local coordinate match
            # only for snapshots produced before is_avatar existed (key absent). A present-but-false
            # marker is trusted, not overridden by the coordinate guess.
            is_avatar = tile.get("is_avatar")
            if is_avatar is None:
                is_avatar = avatar_in_window and x == ax and y == ay
            else:
                is_avatar = bool(is_avatar)
            monster = None if is_avatar else monster_cells.get((x, y))
            if is_avatar:
                render_glyph = "@"
                classes.append("avatar")
            elif monster is not None:
                # Guard: a monster symbol may be empty, non-str, or multi-codepoint; take one char or "M".
                raw = monster.get("symbol")
                render_glyph = raw[0] if isinstance(raw, str) and raw else "M"
                classes.append("monster")
            else:
                render_glyph = glyph
            if not seen and not is_avatar and monster is None:
                classes.append("unseen")
            title = "(%d,%d) ter=%s furn=%s seen=%s" % (
                x, y, tile.get("ter", ""), tile.get("furn", ""), str(bool(seen)).lower(),
            )
            if monster is not None:
                title += " | monster=%s (%s) hp=%s/%s" % (
                    monster.get("type_id", "?"), monster.get("name", ""),
                    monster.get("hp", "?"), monster.get("hp_max", "?"),
                )
            content = "&nbsp;" if render_glyph == " " else esc(render_glyph)
            cells.append('<span class="%s" title="%s">%s</span>' % (" ".join(classes), esc(title), content))
        rows_html.append('<div class="maprow">%s</div>' % "".join(cells))

    if monster_cells:
        legend[("monster", "M", "monster")] = True

    width = x1 - x0 + 1
    height = y1 - y0 + 1
    centered = avatar_in_window and (ax - x0) == (x1 - ax) and (ay - y0) == (y1 - ay)

    caption_bits = ["%d&times;%d window, %d tiles" % (width, height, len(grid))]
    if avatar_in_window:
        caption_bits.append("avatar @ local (%d,%d)" % (ax, ay))
        caption_bits.append("centered" if centered else "clamped near bubble edge - not centered")
    elif ax is not None:
        caption_bits.append("avatar local (%d,%d) is outside this window - not marked" % (ax, ay))
    else:
        caption_bits.append("avatar pos_local unavailable - not marked")
    if skipped:
        caption_bits.append("%d malformed tile(s) skipped" % skipped)
    if monster_cells:
        caption_bits.append("%d monster cell(s)" % len(monster_cells))

    summary = "Tile map &mdash; %d&times;%d window (%d tiles)" % (width, height, len(grid))
    open_attr = " open" if open_default else ""
    return (
        '<details class="map"%s><summary>%s</summary>'
        '<p class="mapcaption">%s</p>'
        '<div class="mapgrid">%s</div>'
        "%s"
        "</details>"
    ) % (open_attr, summary, " &middot; ".join(caption_bits), "".join(rows_html), render_legend(legend))


def render_legend(legend_keys):
    """Render a small legend for the terrain/furniture categories present."""
    items = ['<span class="legend-item"><span class="cell floor avatar">@</span> avatar</span>']
    for css, glyph, label in sorted(legend_keys, key=lambda key: key[2]):
        shown = "&nbsp;" if glyph == " " else esc(glyph)
        items.append('<span class="legend-item"><span class="cell %s">%s</span> %s</span>' % (css, shown, esc(label)))
    items.append('<span class="legend-item"><span class="cell floor unseen">.</span> unseen (dimmed)</span>')
    return '<div class="legend">%s</div>' % "".join(items)


def verify_monsters_in_window(data):
    """Check that every exported monster sits on an exported tile (same x, y, z).

    Returns ``{"checked": int, "off_window": [index...], "note": str | None}``.
    The C++ exporter filters monsters with the SAME window predicate as ``tiles[]``,
    so a correct snapshot has ``off_window == []``; a non-empty list is a real
    contract violation. Backward compatible: a snapshot without ``entities.monsters``
    checks nothing. If ``tiles[]`` is missing/empty there is nothing to verify
    against, so nothing is flagged (a note is returned instead of false failures).
    """
    monsters = dig(data, "entities.monsters")
    if not isinstance(monsters, list) or not monsters:
        return {"checked": 0, "off_window": [], "note": None}
    tiles = dig(data, "tiles")
    if not isinstance(tiles, list) or not tiles:
        return {"checked": len(monsters), "off_window": [],
                "note": "no tiles[] to verify monster positions against"}
    tile_set = set()
    for tile in tiles:
        if not isinstance(tile, dict):
            continue
        try:
            tile_set.add((int(tile["x"]), int(tile["y"]), int(tile["z"])))
        except (KeyError, TypeError, ValueError):
            continue
    off_window = []
    for i, mon in enumerate(monsters):
        if not isinstance(mon, dict):
            continue
        pl = as_int_list(mon.get("pos_local"))
        if not pl or len(pl) < 3 or (pl[0], pl[1], pl[2]) not in tile_set:
            idx = mon.get("index")
            off_window.append(idx if idx is not None else i)
    return {"checked": len(monsters), "off_window": off_window, "note": None}


# --------------------------------------------------------------------------- #
# model assembly
# --------------------------------------------------------------------------- #
def build_model(session_dir):
    """Load the log, resolve every export's snapshot + match, and tally counts.

    Mutates each ``export`` event in place with ``_snapshot`` (load result) and
    ``_match`` (verification result) so the renderer can read them back in file
    order. Returns ``{log, counts, overall_pass}``.
    """
    log = load_session_log(session_dir)

    counts = {
        "events": len(log["events"]),
        "bad_lines": len(log["bad_lines"]),
        "commands": 0,
        "exports": 0,
        "error_events": 0,
        "passes": 0,
        "fails": 0,
        "missing_snapshots": 0,
        "incomplete_snapshots": 0,
        "monsters_off_window": 0,
    }

    for event in log["events"]:
        event_type = event.get("event")
        if event_type == "command":
            counts["commands"] += 1
        elif event_type == "error":
            counts["error_events"] += 1
        elif event_type == "export":
            counts["exports"] += 1
            snap = load_snapshot(session_dir, event.get("path"))
            match = verify_export_against_snapshot(event, snap["data"])
            event["_snapshot"] = snap
            event["_match"] = match
            monsters = verify_monsters_in_window(snap["data"])
            event["_monsters"] = monsters
            counts["monsters_off_window"] += len(monsters["off_window"])
            if not snap["ok"]:
                counts["missing_snapshots"] += 1
            elif snap["missing_keys"]:
                counts["incomplete_snapshots"] += 1
            if match["overall"] == "PASS":
                counts["passes"] += 1
            elif match["overall"] == "FAIL":
                counts["fails"] += 1

    end_status = dig(log["end"], "status")
    overall_pass = (
        counts["bad_lines"] == 0
        and counts["fails"] == 0
        and counts["missing_snapshots"] == 0
        and counts["incomplete_snapshots"] == 0
        and counts["error_events"] == 0
        and counts["monsters_off_window"] == 0
        and log["start"] is not None
        and log["end"] is not None
        and end_status != "error"
    )
    return {"log": log, "counts": counts, "overall_pass": overall_pass}


# --------------------------------------------------------------------------- #
# HTML rendering
# --------------------------------------------------------------------------- #
CSS = """
:root {
  --bg: #ffffff; --fg: #1b1b1f; --muted: #6b6b72; --card: #f5f5f7;
  --border: #d9d9e0; --accent: #3b6ea5;
  --pass: #1b7f3b; --fail: #b00020; --warn: #b06a00;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #16161a; --fg: #e6e6ea; --muted: #9a9aa3; --card: #1f1f25;
    --border: #33333d; --accent: #79b3ff;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; padding: 1.5rem; background: var(--bg); color: var(--fg);
  font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif; line-height: 1.5;
}
h1 { font-size: 1.5rem; margin: 0 0 .25rem; }
h2 { font-size: 1.15rem; margin: 1.75rem 0 .6rem; border-bottom: 1px solid var(--border); padding-bottom: .25rem; }
h3 { font-size: 1rem; margin: 0 0 .4rem; }
a { color: var(--accent); }
.sub { color: var(--muted); margin: 0 0 1rem; }
.card { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: .9rem 1.1rem; margin: .8rem 0; }
.grid2 { display: grid; grid-template-columns: max-content 1fr; gap: .15rem 1rem; }
.grid2 dt { color: var(--muted); }
.grid2 dd { margin: 0; }
table { border-collapse: collapse; margin: .4rem 0; font-size: .92rem; }
th, td { text-align: left; padding: .2rem .7rem .2rem 0; vertical-align: top; }
th { color: var(--muted); font-weight: 600; }
code, .mono { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; }
.badge { display: inline-block; padding: .05rem .5rem; border-radius: 999px; font-size: .8rem; font-weight: 700; color: #fff; }
.badge.pass { background: var(--pass); }
.badge.fail { background: var(--fail); }
.badge.na   { background: var(--muted); }
.badge.warn { background: var(--warn); }
.badge.kind { background: var(--accent); }
.big-badge { font-size: 1.1rem; padding: .2rem 1rem; }
.ok  { color: var(--pass); font-weight: 700; }
.no  { color: var(--fail); font-weight: 700; }
.timeline { border-left: 2px solid var(--border); margin-left: .5rem; padding-left: 1rem; }
.tl-item { margin: .5rem 0; }
.tl-step { color: var(--muted); font-size: .8rem; }
.cmd { background: var(--card); border: 1px solid var(--border); border-radius: 6px; padding: .35rem .6rem; }
.export-card { border: 1px solid var(--border); border-radius: 8px; padding: .7rem .9rem; margin: .5rem 0; background: var(--card); }
.export-card.fail { border-color: var(--fail); }
.export-head { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; margin-bottom: .4rem; }
.export-head .name { font-weight: 700; }
.error-callout { border-left: 4px solid var(--fail); background: rgba(176,0,32,.08); padding: .5rem .8rem; border-radius: 4px; margin: .5rem 0; }
.warn-callout  { border-left: 4px solid var(--warn); background: rgba(176,106,0,.08); padding: .5rem .8rem; border-radius: 4px; margin: .5rem 0; }
.raw { white-space: pre-wrap; word-break: break-all; font-size: .82rem; }

/* map */
details.map { margin-top: .5rem; }
details.map > summary { cursor: pointer; color: var(--accent); font-weight: 600; }
.mapcaption { color: var(--muted); font-size: .82rem; margin: .35rem 0; }
.mapgrid { background: #0d0d10; color: #cccccc; padding: .5rem; border-radius: 6px; overflow-x: auto;
           font-family: ui-monospace, SFMono-Regular, Consolas, monospace; line-height: 1; width: max-content; max-width: 100%; }
.maprow { white-space: nowrap; }
.cell { display: inline-block; width: 1ch; text-align: center; }
.cell.unseen { opacity: .32; }
.cell.avatar { color: #ffffff; background: #c0152f; outline: 1px solid #fff; font-weight: 700; }
.cell.wall { color: #c9c9c9; }
.cell.floor { color: #6f6f78; }
.cell.dirt { color: #b5895f; }
.cell.grass { color: #6fbf73; }
.cell.water { color: #4f93d6; }
.cell.door { color: #d9b15a; }
.cell.window { color: #79c0d6; }
.cell.pavement { color: #8a8a92; }
.cell.stairs { color: #e08a5a; }
.cell.feature { color: #c08fd6; }
.cell.furn, .cell.furn-door { color: #d9b15a; }
.cell.furn-plant { color: #6fbf73; }
.cell.void { color: #2a2a30; }
.cell.unknown { color: #ff5d6c; }
.cell.monster { color: #ff6b6b; font-weight: 700; }
.legend { display: flex; flex-wrap: wrap; gap: .25rem 1rem; margin-top: .5rem; font-size: .82rem;
          background: #0d0d10; color: #cccccc; padding: .5rem; border-radius: 6px; }
.legend-item { display: inline-flex; align-items: center; gap: .35rem; }
.legend .cell { background: #0d0d10; }
.legend .cell.avatar { background: #c0152f; }
footer { margin-top: 2rem; padding-top: .75rem; border-top: 1px solid var(--border); color: var(--muted); font-size: .82rem; }
"""


def render_session_card(log, reveal_paths=False):
    start = log["start"]
    end = log["end"]
    rows = []

    def add(term, value):
        rows.append("<dt>%s</dt><dd>%s</dd>" % (esc(term), value))

    if start is not None:
        add("world", esc(str(start.get("world", "—"))))
        if start.get("seed") is not None:
            add("seed", esc(str(start.get("seed"))))
        add("export_dir", "<span class='mono'>%s</span>" % esc(display_path(start.get("export_dir", "—"), reveal_paths)))
        add("game_version", esc(str(start.get("game_version", "—"))))
    else:
        rows.append("<dt>session_start</dt><dd><span class='no'>absent</span> (truncated transcript)</dd>")

    if end is not None:
        status = str(end.get("status", "—"))
        status_html = "<span class='badge %s'>%s</span>" % ("pass" if status == "ok" else "fail", esc(status))
        add("session_end", status_html)
        add("snapshots", esc(str(end.get("snapshots", "—"))))
        add("commands", esc(str(end.get("commands", "—"))))
        if end.get("final_turn") is not None:
            add("final_turn", esc(str(end.get("final_turn"))))
        if end.get("final_pos_abs") is not None:
            add("final_pos_abs", esc(fmt_scalar(end.get("final_pos_abs"))))
    else:
        rows.append("<dt>session_end</dt><dd><span class='no'>absent</span> (run did not end cleanly)</dd>")

    return '<section class="card"><h3>Session</h3><dl class="grid2">%s</dl></section>' % "".join(rows)


def render_validation_card(counts, overall_pass):
    badge = "<span class='badge big-badge %s'>%s</span>" % (
        "pass" if overall_pass else "fail",
        "PASS" if overall_pass else "DISCREPANCIES",
    )
    rows = [
        ("events parsed", counts["events"]),
        ("malformed JSONL lines", counts["bad_lines"]),
        ("command events", counts["commands"]),
        ("export events", counts["exports"]),
        ("exports matched (PASS)", counts["passes"]),
        ("exports mismatched (FAIL)", counts["fails"]),
        ("snapshots missing/unreadable", counts["missing_snapshots"]),
        ("snapshots missing required keys", counts["incomplete_snapshots"]),
        ("error events", counts["error_events"]),
        ("monsters off the tile window", counts["monsters_off_window"]),
    ]
    body = "".join(
        "<tr><td>%s</td><td class='mono'>%s</td></tr>" % (esc(label), value) for label, value in rows
    )
    return (
        '<section class="card"><h3>Validation %s</h3>'
        "<table>%s</table></section>"
    ) % (badge, body)


def render_errors_section(log, all_exports):
    blocks = []

    error_events = [event for event in log["events"] if event.get("event") == "error"]
    if error_events:
        items = []
        for event in error_events:
            step = event.get("step_index")
            step_txt = "" if step is None else " (step %s)" % esc(str(step))
            items.append(
                "<div class='error-callout'><strong>error: %s</strong>%s &mdash; %s "
                "<span class='tl-step'>exit_code=%s</span></div>"
                % (
                    esc(str(event.get("kind", "?"))),
                    step_txt,
                    esc(str(event.get("detail", ""))),
                    esc(str(event.get("exit_code", "—"))),
                )
            )
        blocks.append("<h3>Transcript error events</h3>" + "".join(items))

    if log["bad_lines"]:
        items = []
        for line_no, raw, message in log["bad_lines"]:
            items.append(
                "<div class='error-callout'><strong>line %d is not valid JSON</strong> &mdash; %s"
                "<div class='raw mono'>%s</div></div>" % (line_no, esc(message), esc(raw))
            )
        blocks.append("<h3>Malformed JSONL lines</h3>" + "".join(items))

    snapshot_problems = []
    for event in all_exports:
        snap = event.get("_snapshot") or {}
        match = event.get("_match") or {}
        if not snap.get("ok"):
            snapshot_problems.append(
                "<div class='error-callout'><strong>%s</strong> &mdash; %s</div>"
                % (esc(str(event.get("path", "?"))), esc(str(snap.get("error", "snapshot unavailable"))))
            )
            continue
        if match.get("overall") == "FAIL":
            failed = [c for c in (match.get("core", []) + match.get("bonus", [])) if not c["ok"]]
            detail = "; ".join(
                "%s expected %s got %s" % (esc(c["name"]), esc(fmt_scalar(c["expected"])), esc(fmt_scalar(c["actual"])))
                for c in failed
            )
            snapshot_problems.append(
                "<div class='error-callout'><strong>%s: scalar mismatch</strong> &mdash; %s</div>"
                % (esc(str(event.get("name", event.get("path", "?")))), detail)
            )
        if snap.get("missing_keys"):
            snapshot_problems.append(
                "<div class='error-callout'><strong>%s: missing required keys</strong> &mdash; %s "
                "(report cannot fully reconstruct this frame)</div>"
                % (esc(str(event.get("name", event.get("path", "?")))), esc(", ".join(snap["missing_keys"])))
            )
    if snapshot_problems:
        blocks.append("<h3>Snapshot / contract problems</h3>" + "".join(snapshot_problems))

    if log["warnings"]:
        items = "".join("<div class='warn-callout'>%s</div>" % esc(w) for w in log["warnings"])
        blocks.append("<h3>Warnings</h3>" + items)

    if not blocks:
        return ""
    return '<section class="card" style="border-color:var(--fail)"><h2>Issues</h2>%s</section>' % "".join(blocks)


def render_scalar_table(match):
    if match["overall"] == "N/A":
        return "<p class='sub'>Snapshot unavailable &mdash; scalars could not be verified.</p>"
    rows = []
    for group, checks in (("contract", match["core"]), ("session", match["bonus"])):
        for check in checks:
            mark = "<span class='ok'>match</span>" if check["ok"] else "<span class='no'>MISMATCH</span>"
            rows.append(
                "<tr><td>%s</td><td class='mono'>%s</td><td class='mono'>%s</td><td class='mono'>%s</td><td>%s</td></tr>"
                % (
                    esc(group),
                    esc(check["name"]),
                    esc(fmt_scalar(check["expected"])),
                    esc(fmt_scalar(check["actual"])),
                    mark,
                )
            )
    return (
        "<table><tr><th>group</th><th>field</th><th>transcript</th><th>snapshot</th><th></th></tr>%s</table>"
        % "".join(rows)
    )


def render_export_card(event, open_map=False):
    snap = event.get("_snapshot") or {}
    match = event.get("_match") or {"overall": "N/A", "core": [], "bonus": []}
    data = snap.get("data")

    overall = match["overall"]
    badge_cls = {"PASS": "pass", "FAIL": "fail", "N/A": "na"}.get(overall, "na")
    final_badge = " <span class='badge warn'>final</span>" if event.get("final") else ""
    step = event.get("step_index")
    step_txt = "final" if step is None else str(step)

    head = (
        "<div class='export-head'>"
        "<span class='name'>export #%s &mdash; %s</span>"
        "<span class='badge kind'>snapshot</span>"
        "<span class='badge %s'>%s</span>%s"
        "<span class='tl-step'>step %s &middot; <span class='mono'>%s</span></span>"
        "</div>"
    ) % (
        esc(str(event.get("export_index", "—"))),
        esc(str(event.get("name", "—"))),
        badge_cls,
        esc(overall),
        final_badge,
        esc(step_txt),
        esc(str(event.get("path", "—"))),
    )

    meta = (
        "<p class='sub'>turn <span class='mono'>%s</span> &middot; moves <span class='mono'>%s</span> "
        "&middot; pos_abs <span class='mono'>%s</span></p>"
    ) % (
        esc(fmt_scalar(event.get("turn"))),
        esc(fmt_scalar(event.get("moves"))),
        esc(fmt_scalar(event.get("pos_abs"))),
    )

    body = [head, meta, render_scalar_table(match)]

    if snap.get("ok") and data is not None:
        avatar = data.get("avatar") or {}
        body.append(
            "<p class='sub'>avatar <span class='mono'>%s</span> &middot; hp %s/%s &middot; "
            "pos_local <span class='mono'>%s</span></p>"
            % (
                esc(str(avatar.get("name", "—"))),
                esc(fmt_scalar(avatar.get("hp"))),
                esc(fmt_scalar(avatar.get("hp_max"))),
                esc(fmt_scalar(avatar.get("pos_local"))),
            )
        )
        messages = data.get("messages")
        if isinstance(messages, list) and messages:
            texts = [esc(str(m.get("text", ""))) for m in messages if isinstance(m, dict) and m.get("text")]
            if texts:
                body.append("<p class='sub'>messages: %s</p>" % " &middot; ".join(texts))
        entities = data.get("entities") or {}
        monsters = entities.get("monsters")
        if isinstance(monsters, list) and monsters:
            items = []
            for mon in monsters:
                if not isinstance(mon, dict):
                    continue
                symbol = mon.get("symbol")
                type_id = mon.get("type_id")
                items.append("%s %s @ %s (hp %s/%s)" % (
                    esc(str(symbol) if symbol is not None else ""),
                    esc(str(type_id) if type_id is not None else "?"),
                    esc(fmt_scalar(mon.get("pos_local"))),
                    esc(fmt_scalar(mon.get("hp"))),
                    esc(fmt_scalar(mon.get("hp_max"))),
                ))
            body.append("<p class='sub'>monsters (%d): %s</p>" % (len(monsters), " &middot; ".join(items)))
        mon_check = event.get("_monsters") or {}
        if mon_check.get("off_window"):
            body.append(
                "<div class='warn-callout'>monsters off the tile window: <span class='mono'>%s</span></div>"
                % esc(", ".join(str(idx) for idx in mon_check["off_window"]))
            )
        elif mon_check.get("note"):
            body.append("<div class='warn-callout'>%s</div>" % esc(mon_check["note"]))
        if snap.get("missing_keys"):
            body.append(
                "<div class='warn-callout'>snapshot missing expected keys: <span class='mono'>%s</span></div>"
                % esc(", ".join(snap["missing_keys"]))
            )
        body.append(render_map_html(data, open_default=open_map))
    else:
        body.append(
            "<div class='error-callout'>snapshot unavailable: %s</div>"
            % esc(str(snap.get("error", "unknown")))
        )

    card_cls = "export-card fail" if overall == "FAIL" or not snap.get("ok") else "export-card"
    return "<div class='%s'>%s</div>" % (card_cls, "".join(body))


def render_command_row(event):
    bits = ["<span class='badge kind'>command</span> <span class='mono'>%s</span>" % esc(str(event.get("command", "?")))]
    if event.get("direction"):
        bits.append("dir <span class='mono'>%s</span>" % esc(str(event.get("direction"))))
    if event.get("action_id"):
        bits.append("action <span class='mono'>%s</span>" % esc(str(event.get("action_id"))))
    bits.append("<span class='tl-step'>%s</span>" % esc(str(event.get("status", ""))))
    return "<div class='cmd'>%s</div>" % " &middot; ".join(bits)


def render_marker_row(event, label):
    return "<div class='tl-step'>&mdash; %s &mdash;</div>" % esc(label)


def render_unknown_row(event):
    dump = {k: v for k, v in event.items() if not k.startswith("_")}
    return "<div class='cmd'><span class='badge warn'>unknown event</span> <span class='raw mono'>%s</span></div>" % esc(
        json.dumps(dump, ensure_ascii=False)
    )


def render_timeline(log):
    items = []
    first_export_emitted = False
    for event in log["events"]:
        event_type = event.get("event")
        step = event.get("step_index")
        step_label = "" if step is None else "<span class='tl-step'>step %s</span> " % esc(str(step))

        if event_type == "export":
            inner = render_export_card(event, open_map=not first_export_emitted)
            first_export_emitted = True
        elif event_type == "command":
            inner = render_command_row(event)
        elif event_type == "error":
            inner = (
                "<div class='error-callout'><strong>error: %s</strong> &mdash; %s</div>"
                % (esc(str(event.get("kind", "?"))), esc(str(event.get("detail", ""))))
            )
        elif event_type == "session_start":
            inner = render_marker_row(event, "session start")
        elif event_type == "session_end":
            inner = render_marker_row(event, "session end (%s)" % str(event.get("status", "")))
        else:
            inner = render_unknown_row(event)

        items.append("<div class='tl-item'>%s%s</div>" % (step_label, inner))

    return '<section><h2>Timeline</h2><div class="timeline">%s</div></section>' % "".join(items)


def render_report_html(model, session_dir, reveal_paths=False):
    log = model["log"]
    counts = model["counts"]
    # key=str so a malformed transcript mixing JSON types (e.g. 1 and "1")
    # cannot raise TypeError mid-render; it stays on the discrepancy path.
    schema_versions = sorted(
        {event.get("schema_version") for event in log["events"] if event.get("schema_version") is not None},
        key=str,
    )
    schema_txt = ", ".join(str(v) for v in schema_versions) if schema_versions else "unknown"

    all_exports = [event for event in log["events"] if event.get("event") == "export"]
    errors_section = render_errors_section(log, all_exports)

    head = (
        "<!DOCTYPE html><html lang='en'><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width, initial-scale=1'>"
        "<title>Arcopolis Offline Session Report</title><style>%s</style></head><body>"
    ) % CSS

    header = (
        "<h1>Arcopolis Offline Session Report</h1>"
        "<p class='sub'>Generated by <code>make_report.py</code> v%s &middot; read-only, offline, no server &middot; "
        "schema_version %s</p>"
        "<p class='sub'>session-dir: <span class='mono'>%s</span></p>"
    ) % (esc(TOOL_VERSION), esc(schema_txt), esc(display_path(session_dir, reveal_paths)))

    cards = render_session_card(log, reveal_paths) + render_validation_card(counts, model["overall_pass"])

    footer = (
        "<footer>Arcopolis Spike 4 viewer. Consumes a Spike 3.1C export "
        "(<code>session.jsonl</code> + <code>NNN_&lt;name&gt;.json</code>). "
        "See <code>docs/arcopolis/12_SPIKE4_OFFLINE_SESSION_VIEWER.md</code>.</footer></body></html>"
    )

    return head + header + cards + errors_section + render_timeline(log) + footer


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        prog="make_report.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=(
            "Render an Arcopolis backend export directory (session.jsonl + NNN_<name>.json\n"
            "snapshots, Spike 3.1C) into one self-contained offline HTML report.\n"
            "Read-only, stdlib-only: no server, no JavaScript, no images, no dependencies."
        ),
        epilog=(
            "example:\n"
            "  python tools/arcopolis_viewer/make_report.py "
            "--session-dir <repo-root>/out/arco_3v1c --output <repo-root>/out/arco_3v1c_report.html"
        ),
    )
    parser.add_argument("--session-dir", required=True, metavar="PATH",
                        help="directory containing session.jsonl and the NNN_<name>.json snapshots")
    parser.add_argument("--output", required=True, metavar="PATH",
                        help="path to write the single self-contained .html report")
    parser.add_argument("--reveal-paths", action="store_true",
                        help="show full local paths in the report instead of basenames "
                             "(off by default per the AGENTS.md privacy rule)")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    session_dir = args.session_dir
    output = args.output

    if not os.path.isdir(session_dir):
        sys.stderr.write("fatal: --session-dir is not a directory: %s\n" % session_dir)
        return 1
    log_path = os.path.join(session_dir, SESSION_LOG_NAME)
    if not os.path.isfile(log_path):
        sys.stderr.write("fatal: %s not found in %s\n" % (SESSION_LOG_NAME, session_dir))
        return 1
    output_parent = os.path.dirname(os.path.abspath(output))
    if not os.path.isdir(output_parent):
        sys.stderr.write("fatal: output directory does not exist: %s\n" % output_parent)
        return 1

    try:
        model = build_model(session_dir)
    except OSError as err:
        sys.stderr.write("fatal: could not read %s: %s\n" % (SESSION_LOG_NAME, err))
        return 1

    html_text = render_report_html(model, session_dir, reveal_paths=args.reveal_paths)
    try:
        with open(output, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(html_text)
    except OSError as err:
        sys.stderr.write("fatal: could not write report: %s\n" % err)
        return 1

    counts = model["counts"]
    status = "OK" if model["overall_pass"] else "DISCREPANCIES"
    sys.stdout.write(
        "wrote %s  [%s]  exports=%d pass=%d fail=%d missing=%d incomplete=%d bad_lines=%d errors=%d "
        "monsters_off_window=%d\n"
        % (
            output, status, counts["exports"], counts["passes"], counts["fails"],
            counts["missing_snapshots"], counts["incomplete_snapshots"], counts["bad_lines"],
            counts["error_events"], counts["monsters_off_window"],
        )
    )
    return 0 if model["overall_pass"] else 2


if __name__ == "__main__":
    sys.exit(main())
