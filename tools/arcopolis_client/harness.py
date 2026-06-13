#!/usr/bin/env python3
"""Arcopolis Spike 9A - external player-loop harness / contract consumer.

Proves that the Arcopolis snapshot contract (Spikes 0-8A: terrain + monsters +
NPCs + ground items, plus the ``session.jsonl`` transcript) is already enough
for an EXTERNAL frontend loop: build a usable local game view, choose a
command, run it through the backend, and explain the result.

Like the Spike 4 viewer (``tools/arcopolis_viewer/make_report.py``) this is an
*external consumer* of an already-defined file contract, deliberately
share-nothing with it (each consumer independently re-derives the contract -
that independence is the point). It is stdlib-only:

  * no third-party Python packages,
  * no web server,
  * no JavaScript (the HTML view is static; hover tooltips only),
  * no images or tilesets.

Subcommands::

    view     load one snapshot, build per-tile cell bundles keyed by pos_local
             (tile + avatar? + npcs[] + monsters[] + items[]), and write ONE
             self-contained HTML page: local map + a tile inspector for a
             selected tile (--at X,Y; defaults to the avatar tile).
    explain  pair consecutive exports from session.jsonl, re-verify each
             export's scalars against its snapshot, diff messages, analyze the
             commanded destination tile in the BEFORE snapshot, and classify
             every command outcome (moved / blocked_no_op / acted_in_place /
             waited / ...). ``--json`` emits a machine-readable document.
    run      compose a script from a command list (wait / move_n / move_s /
             move_e / move_w ONLY - the backend's current vocabulary), invoke
             the backend exe once, then explain the produced session. The
             backend never saves the world after --arcopolis-run-script, so one
             scripted run per session IS the faithful player loop today;
             interactive continuation across runs is impossible by design.
    live     drive ONE persistent --arcopolis-live backend process over its
             stdin/stdout JSON Lines protocol (Spike 9B): read the ready
             event, send export/command requests ONE AT A TIME (each next
             request only after the previous response), verify each referenced
             snapshot exists, quit cleanly, then explain the produced session.
             Every backend stdout line MUST parse as JSON - the live protocol's
             stdout-purity guarantee is verified, not assumed.

Exit codes (same convention as the Spike 4 viewer)::

    0  clean: every transcript line parsed, every export matched its snapshot,
       no error events, session start+end present. Outcome labels such as
       blocked_no_op are DATA, never failures.
    2  contract discrepancies: malformed JSONL lines, missing / unreadable /
       invalid / incomplete snapshots, scalar mismatches, error events, a
       truncated session, or off-window entities.
    1  fatal: bad usage, missing session.jsonl (explain), unwritable output;
       for run: bad command token, missing exe/world, launch failure, timeout,
       or a nonzero backend exit (surfaced with its meaning).

It changes no Bright Nights gameplay, no backend command, and no snapshot or
transcript schema. Anything a richer loop would want but the current export
does not provide (passability flags, NPC interaction commands, a live
protocol) is documented as future work in
``docs/arcopolis/20_SPIKE9A_CLIENT_HARNESS.md`` - it is NOT invented here.
"""

import argparse
import html
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time

TOOL_NAME = "arcopolis_client_harness"
TOOL_VERSION = "1.1.0"
EXPECTED_SCHEMA_VERSION = 1
SESSION_LOG_NAME = "session.jsonl"
# Defensive cap on the tile-window span we will render (the engine view is
# radius 12 = 25x25); a malformed snapshot with wild coordinates cannot blow up
# the render loops. Same cap as the Spike 4 viewer.
MAX_MAP_SPAN = 256

# The harness's run/live MOVEMENT vocabulary: "wait" -> ACTION_PAUSE and "move" +
# any of the EIGHT planar directions (the four cardinals plus the four diagonals --
# all dispatched through the same avatar_action::move body). This is INTENTIONALLY
# wait + planar-move only: it is NOT the backend's complete vocabulary, which since
# Spike 11A also includes "examine" (src/arcopolis_command.cpp, command_to_action).
# examine is a prompted/nested-input interaction driven by its own regression path
# (docs/arcopolis/examine_live_driver.py + examine_regression.ps1), not through this
# movement-oriented harness. run/live whitelist EXACTLY these tokens and reject
# anything else BEFORE launching a subprocess, so a harness-vocabulary mistake can
# never be confused with a backend command failure (backend exit 6).
COMMAND_TOKENS = ("wait",
                  "move_n", "move_s", "move_e", "move_w",
                  "move_ne", "move_nw", "move_se", "move_sw")

# Local/absolute coordinate frames share orientation: y grows SOUTH (move_s is
# +y), x grows EAST. Deltas are (dx, dy) on the same z-level. Diagonals combine
# the two axes (move_ne = +x,-y; move_sw = -x,+y), matching the engine's
# get_direction mapping the backend mirrors.
DIRECTION_DELTAS = {
    "move_n": (0, -1),
    "move_s": (0, 1),
    "move_e": (1, 0),
    "move_w": (-1, 0),
    "move_ne": (1, -1),
    "move_nw": (-1, -1),
    "move_se": (1, 1),
    "move_sw": (-1, 1),
}
DELTA_DIRECTIONS = {v: k for k, v in DIRECTION_DELTAS.items()}

# Backend exit codes (src/arcopolis_command.cpp, exit_code_for).
BACKEND_EXIT_MEANINGS = {
    0: "ok",
    2: "missing_file",
    3: "unreadable_file",
    4: "invalid_json",
    5: "bad_schema",
    6: "unsupported_command",
    7: "apply_failed",
    8: "safe_mode_blocked",
    9: "export_failed",
    10: "backend_stalled",
    11: "game_over",
}

# Closed outcome enum (documented in docs/arcopolis/20_SPIKE9A_CLIENT_HARNESS.md).
OUTCOMES = (
    "moved", "blocked_no_op", "acted_in_place", "waited", "no_command",
    "multi_command", "displaced", "unknown", "unverifiable",
)

esc = html.escape


# --------------------------------------------------------------------------- #
# small helpers (idioms adapted from tools/arcopolis_viewer/make_report.py
# lines 67-107; re-derived here on purpose - the consumers stay independent)
# --------------------------------------------------------------------------- #
def dig(obj, dotted):
    """Return a nested value by dotted path, or ``None`` on any missing hop."""
    cur = obj
    for key in dotted.split("."):
        if not isinstance(cur, dict) or key not in cur:
            return None
        cur = cur[key]
    return cur


def as_int_list(value):
    """Coerce a value to a list[int], or return ``None`` if it cannot be."""
    if not isinstance(value, list):
        return None
    try:
        return [int(v) for v in value]
    except (TypeError, ValueError):
        return None


def fmt_pos(value):
    """Render a coordinate list compactly (``[85,84,0]``), or ``?``."""
    ints = as_int_list(value)
    if ints is None:
        return "?"
    return "[" + ",".join(str(v) for v in ints) + "]"


def ascii_safe(text):
    """Force text to plain ASCII for console output (cp1252-safe on Windows)."""
    return str(text).encode("ascii", "replace").decode("ascii")


def display_path(path, reveal):
    """Render a local path: basename by default, verbatim with --reveal-paths.

    AGENTS.md privacy rule: diagnostic tooling must not embed machine-specific
    local paths in its output by default (same idiom as the Spike 4 viewer).
    """
    if reveal or not path:
        return str(path)
    return os.path.basename(os.path.normpath(str(path))) or str(path)


def emit(text=""):
    """Print one ASCII-sanitized line to stdout."""
    sys.stdout.write(ascii_safe(text) + "\n")


def warn(text):
    """Print one ASCII-sanitized warning line to stderr."""
    sys.stderr.write(ascii_safe(text) + "\n")


# --------------------------------------------------------------------------- #
# loading + contract verification (contract re-derived from
# docs/arcopolis/ARCOPOLIS_STATE.md; same checks the Spike 4 viewer performs,
# make_report.py lines 113-255)
# --------------------------------------------------------------------------- #
def load_session_log(session_dir):
    """Parse ``session.jsonl`` line by line.

    Returns ``{path, start, end, events, bad_lines, warnings}``. Raises
    ``OSError`` if the file itself cannot be read (caller turns that into a
    fatal exit). ``utf-8-sig`` transparently strips a UTF-8 BOM if a tool
    (PowerShell, Notepad) added one.
    """
    path = os.path.join(session_dir, SESSION_LOG_NAME)
    start = None
    end = None
    events = []
    bad_lines = []
    warnings = []

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

    Returns ``{rel, ok, error, data, missing_keys}``; never raises. A loaded
    object missing required keys stays ``ok=True`` (render what we can) but the
    caller counts ``missing_keys`` as a discrepancy.
    """
    result = {"rel": rel_path, "ok": False, "error": None, "data": None, "missing_keys": []}

    if not isinstance(rel_path, str) or not rel_path:
        result["error"] = "no usable snapshot path"
        return result

    # The producer only ever writes a bare relative filename; reject anything
    # resolving outside session_dir (also catches Windows drive-relative paths).
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
    """Re-verify an export event's scalars against its loaded snapshot.

    Core contract: ``turn == backend.turn``, ``pos_abs == avatar.pos_abs``,
    ``moves == avatar.moves``; bonus checks against the optional ``session``
    block. Returns ``{"ok": bool, "failed": [check names]}``.
    """
    if snap_data is None:
        return {"ok": False, "failed": ["snapshot unavailable"]}

    failed = []
    if export_ev.get("turn") != dig(snap_data, "backend.turn"):
        failed.append("turn")
    if as_int_list(export_ev.get("pos_abs")) != as_int_list(dig(snap_data, "avatar.pos_abs")):
        failed.append("pos_abs")
    if export_ev.get("moves") != dig(snap_data, "avatar.moves"):
        failed.append("moves")

    session = snap_data.get("session")
    if isinstance(session, dict):
        for ev_key, snap_key in (("step_index", "step_index"), ("export_index", "export_index"),
                                 ("name", "export_name"), ("final", "final")):
            if export_ev.get(ev_key) != session.get(snap_key):
                failed.append(ev_key)

    return {"ok": not failed, "failed": failed}


def list_snapshot_files(session_dir):
    """All ``NNN_<name>.json`` snapshots in the dir, ordered by numeric prefix.

    This is the transcript-free fallback used by ``view`` (the same NNN_
    selection idiom the regression scripts use), so a bare directory of
    snapshots is still viewable.
    """
    found = []
    for name in os.listdir(session_dir):
        match = re.match(r"^(\d+)_.*\.json$", name)
        if match and os.path.isfile(os.path.join(session_dir, name)):
            found.append((int(match.group(1)), name))
    found.sort()
    return [name for _, name in found]


def select_snapshot_name(files, selector):
    """Resolve a --snapshot selector to one filename.

    Accepted: ``latest`` (default, highest NNN) | ``final`` | a bare export
    index (``0`` / ``003``) | an export name (``after_move_n``) | an exact
    filename. Returns ``(name, error, warnings)``.
    """
    warnings = []
    if not files:
        return None, "no NNN_<name>.json snapshots in the session dir", warnings
    sel = (selector or "latest").strip()
    if sel == "latest":
        return files[-1], None, warnings
    if sel == "final":
        finals = [f for f in files if re.fullmatch(r"\d+_final\.json", f)]
        if finals:
            return finals[-1], None, warnings
        return None, "no NNN_final.json snapshot present", warnings
    if re.fullmatch(r"\d+", sel):
        idx = int(sel)
        for name in files:
            if int(name.split("_", 1)[0]) == idx:
                return name, None, warnings
        return None, "no snapshot with export index %d" % idx, warnings
    if sel in files:
        return sel, None, warnings
    matches = [f for f in files if re.fullmatch(r"\d+_%s\.json" % re.escape(sel), f)]
    if matches:
        if len(matches) > 1:
            warnings.append("selector %r matches %d snapshots; using the first (%s)"
                            % (sel, len(matches), matches[0]))
        return matches[0], None, warnings
    return None, "no snapshot matches selector %r" % sel, warnings


# --------------------------------------------------------------------------- #
# the cell-bundle model (feature 2: everything on a tile, keyed by pos_local)
# --------------------------------------------------------------------------- #
def build_cells(snap):
    """Bundle a snapshot into ``{(x, y, z): cell}`` keyed by ``pos_local``.

    Each cell is ``{"tile": {...}, "is_avatar": bool, "npcs": [], "monsters":
    [], "items": []}`` - the per-tile world model a frontend would consume.
    Tolerant of pre-Spike-5/6A/7A/8A snapshots (no ``is_avatar`` marker, no
    ``entities.*`` blocks). Returns ``(cells, info)`` where ``info`` carries
    ``avatar_key``, ``skipped_tiles`` and the per-kind ``off_window`` counts
    (an exported entity NOT on an exported tile breaks the window-equivalence
    invariant - a contract violation, counted by the caller).
    """
    cells = {}
    skipped = 0
    tiles = dig(snap, "tiles")
    for tile in tiles if isinstance(tiles, list) else []:
        if not isinstance(tile, dict):
            skipped += 1
            continue
        try:
            key = (int(tile["x"]), int(tile["y"]), int(tile["z"]))
        except (KeyError, TypeError, ValueError):
            skipped += 1
            continue
        cells[key] = {"tile": tile, "is_avatar": False, "npcs": [], "monsters": [], "items": []}

    # Prefer the explicit Spike 5 marker; fall back to the pos_local coordinate
    # match only when the key is absent (pre-Spike-5 snapshots). A present-but-
    # false marker is trusted, not overridden (viewer idiom).
    avatar_local = as_int_list(dig(snap, "avatar.pos_local"))
    avatar_key = tuple(avatar_local[:3]) if avatar_local and len(avatar_local) >= 3 else None
    found_avatar_key = None
    for key, cell in cells.items():
        marker = cell["tile"].get("is_avatar")
        is_avatar = bool(marker) if marker is not None else (key == avatar_key)
        cell["is_avatar"] = is_avatar
        if is_avatar and found_avatar_key is None:
            found_avatar_key = key

    off_window = {"npcs": 0, "monsters": 0, "items": 0}
    for kind in ("npcs", "monsters", "items"):
        entries = dig(snap, "entities." + kind)
        for obj in entries if isinstance(entries, list) else []:
            if not isinstance(obj, dict):
                off_window[kind] += 1
                continue
            pos = as_int_list(obj.get("pos_local"))
            key = tuple(pos[:3]) if pos and len(pos) >= 3 else None
            if key in cells:
                cells[key][kind].append(obj)
            else:
                off_window[kind] += 1

    return cells, {
        "avatar_key": found_avatar_key,
        "skipped_tiles": skipped,
        "off_window": off_window,
    }


def entity_counts(snap):
    """Sizes of the ``entities.*`` lists, counting a wrong-typed block as 0.

    A malformed block (``entities.items`` as a dict/string) would make a bare
    ``len()`` crash or report a misleading size - degrade exactly like an
    absent block instead, the same tolerance ``build_cells`` applies.
    """
    counts = {}
    for kind in ("npcs", "monsters", "items"):
        entries = dig(snap, "entities." + kind)
        counts[kind] = len(entries) if isinstance(entries, list) else 0
    return counts


# --------------------------------------------------------------------------- #
# tile -> glyph / family classification (substring families adapted from the
# Spike 4 viewer, make_report.py lines 267-307, reduced to ASCII-only glyphs;
# the engine exports no per-tile symbol/colour or passability flag, so this is
# a heuristic schematic and is documented as such)
# --------------------------------------------------------------------------- #
FURN_FAMILY_RULES = [
    (("door",), "+", "door"),
]
FURN_FALLBACK = ("f", "furniture")

TER_FAMILY_RULES = [
    (("door",), "+", "door"),
    (("window",), "=", "window"),
    (("wall", "rock"), "#", "wall"),
    (("stairs_down", "ladder_down", "downstairs"), ">", "stairs"),
    (("stairs_up", "ladder_up", "upstairs"), "<", "stairs"),
    (("stairs", "ladder", "escalator"), ">", "stairs"),
    (("water", "pool", "sewage", "swamp"), "~", "water"),
    (("pavement", "road", "asphalt", "sidewalk", "concrete"), ".", "floor"),
    (("grass", "underbrush"), ",", "grass"),
    (("dirt", "sand", "mud", "gravel"), ".", "floor"),
    (("floor",), ".", "floor"),
    (("null",), " ", "void"),
]
UNKNOWN_FAMILY = ("?", "unknown")

# Families a blocked move is HEURISTICALLY attributed to when no creature
# occupies the destination. The contract has no passability flag (deferred), so
# the harness reports this as a guess, never as engine truth.
BLOCKING_FAMILIES = ("wall", "window")


def terrain_family(tile):
    """Map a tile to ``(glyph, family)`` - furniture first, then terrain."""
    furn = str(tile.get("furn", "") or "").lower()
    if furn and furn != "f_null":
        for substrings, glyph, family in FURN_FAMILY_RULES:
            if any(token in furn for token in substrings):
                return glyph, family
        return FURN_FALLBACK

    ter = str(tile.get("ter", "") or "").lower()
    for substrings, glyph, family in TER_FAMILY_RULES:
        if any(token in ter for token in substrings):
            return glyph, family
    return UNKNOWN_FAMILY


def cell_glyph(cell):
    """Overlay precedence avatar > NPC > monster > item > terrain.

    Fixed ASCII letters (engine ``symbol`` fields may be multi-byte): ``@``
    avatar, ``N`` npc, ``M`` monster, ``i`` item.
    """
    if cell["is_avatar"]:
        return "@", "avatar"
    if cell["npcs"]:
        return "N", "npc"
    if cell["monsters"]:
        return "M", "monster"
    if cell["items"]:
        return "i", "item"
    glyph, family = terrain_family(cell["tile"])
    return glyph, family


# --------------------------------------------------------------------------- #
# explain pipeline: pair exports, diff messages, analyze the destination,
# classify the outcome
# --------------------------------------------------------------------------- #
def pair_exports(events):
    """Walk the transcript in file order into export pairs.

    Returns ``(pairs, preamble_commands)`` where each pair is ``{"before":
    export_ev, "after": export_ev, "commands": [...], "errors": [...]}`` with
    the command / error events that sit strictly between the two exports.
    Commands before the first export (none today - run_script always exports
    eagerly when asked) are returned separately as session-level context.
    """
    pairs = []
    preamble_commands = []
    last_export = None
    commands = []
    errors = []
    for ev in events:
        kind = ev.get("event")
        if kind == "export":
            if last_export is not None:
                pairs.append({"before": last_export, "after": ev,
                              "commands": commands, "errors": errors})
            elif commands:
                preamble_commands.extend(commands)
            last_export = ev
            commands = []
            errors = []
        elif kind == "command":
            commands.append(ev)
        elif kind == "error":
            errors.append(ev)
    if last_export is None:
        preamble_commands.extend(commands)
    return pairs, preamble_commands


def diff_messages(before_snap, after_snap):
    """New messages across a pair, from the snapshots' ``messages[]`` text.

    The export is a sliding window of the most recent <=10 messages in
    chronological (oldest-first) order - Messages::recent_messages takes the
    deque tail in original order (src/messages.cpp:250-262). The new suffix is
    everything after the LARGEST k with ``before[-k:] == after[:k]``. k == 0
    with both windows non-empty means the window rotated entirely (>= 10 new
    messages) OR no overlap exists; we then report all after-messages as
    possibly new rather than fabricating precision. Duplicate texts make the
    max-k overlap deliberately UNDER-report (conservative).
    """
    def texts(snap):
        msgs = dig(snap, "messages")
        if not isinstance(msgs, list):
            return []
        return [m.get("text", "") for m in msgs if isinstance(m, dict)]

    if before_snap is None or after_snap is None:
        return [], "messages unavailable (snapshot missing)"

    before = texts(before_snap)
    after = texts(after_snap)
    if not after:
        return [], None
    for k in range(min(len(before), len(after)), 0, -1):
        if before[-k:] == after[:k]:
            return after[k:], None
    if before:
        return after, "no overlap with the previous message window (rotated or >=10 new); all listed as possibly new"
    return after, None


def entity_summary(obj, kind):
    """Compact JSON-able copy of an exported entity (v0 fields, verbatim)."""
    if kind == "npcs":
        keys = ("index", "name", "pos_local", "pos_abs", "is_enemy", "is_following",
                "is_player_ally", "is_stationary", "hallucination")
    elif kind == "monsters":
        keys = ("index", "type_id", "name", "symbol", "pos_local", "pos_abs",
                "hp", "hp_max", "moves", "hallucination")
    else:
        keys = ("index", "type_id", "name", "symbol", "pos_local", "pos_abs",
                "charges", "count_by_charges")
    return {k: obj.get(k) for k in keys if k in obj}


def analyze_destination(before_snap, delta):
    """Describe the commanded destination tile, from the BEFORE snapshot.

    Destination = ``avatar.pos_local + (dx, dy)`` on the same z, looked up in
    the cell bundles. Returns ``(dest_dict_or_None, note_or_None)``; ``None``
    when the avatar position is unknown or the destination lies outside the
    exported window (bubble-clamped).
    """
    if before_snap is None:
        return None, "destination analysis unavailable (before snapshot missing)"
    avatar_local = as_int_list(dig(before_snap, "avatar.pos_local"))
    if not avatar_local or len(avatar_local) < 3:
        return None, "destination analysis unavailable (avatar.pos_local missing)"
    key = (avatar_local[0] + delta[0], avatar_local[1] + delta[1], avatar_local[2])
    cells, _ = build_cells(before_snap)
    cell = cells.get(key)
    if cell is None:
        return None, "destination %s is outside the exported window (bubble-clamped)" % fmt_pos(list(key))
    glyph, family = terrain_family(cell["tile"])
    dest = {
        "pos_local": list(key),
        "ter": cell["tile"].get("ter"),
        "furn": cell["tile"].get("furn"),
        "terrain_family": family,
        "seen": bool(cell["tile"].get("seen", True)),
        "npcs": [entity_summary(o, "npcs") for o in cell["npcs"]],
        "monsters": [entity_summary(o, "monsters") for o in cell["monsters"]],
        "items": [entity_summary(o, "items") for o in cell["items"]],
    }
    return dest, None


def npc_adjectives(npc):
    """Human adjectives for an exported NPC's v0 relationship flags."""
    bits = []
    bits.append("hostile" if npc.get("is_enemy") else
                ("allied" if npc.get("is_player_ally") else "neutral"))
    if npc.get("is_following"):
        bits.append("following")
    if npc.get("is_stationary"):
        bits.append("stationary")
    if npc.get("hallucination"):
        bits.append("hallucination")
    return ", ".join(bits)


def classify_pair(pair, before_snap, after_snap):
    """Apply the Spike 9A outcome decision table to one export pair.

    Classification keys on the EVENT scalars (verified equal to the snapshots)
    and on ``pos_abs`` - NEVER ``pos_local``, which is reality-bubble-relative
    and can stay constant across a real move when the bubble shifts.
    ``moves_delta`` is reported but never classified (the after snapshot sits
    at the next input rest, where Creature::process_turn may have refilled
    moves - the movement_regression.ps1 idiom).
    """
    before_ev = pair["before"]
    after_ev = pair["after"]
    commands = pair["commands"]
    notes = []

    bturn, aturn = before_ev.get("turn"), after_ev.get("turn")
    bpos = as_int_list(before_ev.get("pos_abs"))
    apos = as_int_list(after_ev.get("pos_abs"))
    bmoves, amoves = before_ev.get("moves"), after_ev.get("moves")

    turn_delta = (aturn - bturn) if isinstance(aturn, int) and isinstance(bturn, int) else None
    moves_delta = (amoves - bmoves) if isinstance(amoves, int) and isinstance(bmoves, int) else None
    pos_delta = None
    if bpos and apos and len(bpos) == len(apos) == 3:
        pos_delta = [apos[i] - bpos[i] for i in range(3)]

    result = {
        "turn_delta": turn_delta,
        "moves_delta": moves_delta,
        "pos_abs_delta": pos_delta,
        "expected_delta": None,
        "outcome": "unknown",
        "blocked_by": [],
        "destination": None,
        "new_messages": [],
        "notes": notes,
        "explanation": "",
    }

    new_msgs, msg_note = diff_messages(before_snap, after_snap)
    result["new_messages"] = new_msgs
    if msg_note:
        notes.append(msg_note)

    if before_snap is None or after_snap is None or turn_delta is None or pos_delta is None:
        result["outcome"] = "unverifiable"
        notes.append("a snapshot or its scalars are unavailable; outcome cannot be classified")
        result["explanation"] = "This pair cannot be verified: a snapshot is missing or malformed."
        return result

    moved_flag = pos_delta != [0, 0, 0]
    cmd_names = ", ".join(c.get("direction") or c.get("command", "?") for c in commands)

    if not commands:
        result["outcome"] = "no_command"
        if moved_flag or turn_delta != 0:
            notes.append("state changed without a command - investigate (clean-park should leave it untouched)")
            result["explanation"] = ("No command sits between these exports, yet the state changed "
                                     "(turn %+d, pos_abs %s)." % (turn_delta, fmt_pos(pos_delta)))
        else:
            result["explanation"] = "No command between these exports; the state is unchanged."
        return result

    if len(commands) > 1:
        result["outcome"] = "multi_command"
        notes.append("per-command destination analysis requires exactly one command per export pair")
        result["explanation"] = ("Commands [%s] ran between these exports; net effect: turn %+d, "
                                 "pos_abs %s." % (cmd_names, turn_delta, fmt_pos(pos_delta)))
        return result

    cmd = commands[0]
    verb = cmd.get("command")
    direction = cmd.get("direction")

    if verb == "wait":
        if not moved_flag and turn_delta >= 1:
            result["outcome"] = "waited"
            result["explanation"] = ("wait kept the avatar in place while the turn advanced by %d "
                                     "(the world ticked)." % turn_delta)
        elif not moved_flag and turn_delta == 0:
            # Faithful lifecycle case, not an anomaly: the engine's bootstrap
            # turn right after load consumes the wait WITHOUT advancing the
            # calendar (do_turn skips calendar::turn += 1 while game::new_game
            # is set - src/game.cpp:1890-1898). Current seam-timed sessions
            # read the NEXT do_turn's clock and so show +1; the zero-advance
            # shape appears in pre-seam recorded sessions and stays legal.
            result["outcome"] = "waited"
            notes.append("wait consumed at bootstrap/input-rest without calendar turn advance "
                         "(legal: the bootstrap turn after load skips the calendar tick)")
            result["explanation"] = ("wait kept the avatar in place without advancing the turn "
                                     "(a faithful zero-advance wait, e.g. the engine's bootstrap "
                                     "turn right after load).")
        elif not moved_flag:
            result["outcome"] = "unknown"
            notes.append("wait went backward in turn (%d) - unexpected" % turn_delta)
            result["explanation"] = ("wait left the position unchanged but the turn went backward "
                                     "(%d) - unexpected." % turn_delta)
        else:
            result["outcome"] = "unknown"
            notes.append("wait changed the avatar position (unexpected)")
            result["explanation"] = "wait moved the avatar by %s - unexpected." % fmt_pos(pos_delta)
        return result

    if verb == "move" and direction in DIRECTION_DELTAS:
        delta = DIRECTION_DELTAS[direction]
        result["expected_delta"] = list(delta)
        dest, dest_note = analyze_destination(before_snap, delta)
        result["destination"] = dest
        if dest_note:
            notes.append(dest_note)
        if dest is not None and not dest["seen"]:
            notes.append("destination not seen by the player - contents listed are the authoritative "
                         "export, not player knowledge")

        if pos_delta == [delta[0], delta[1], 0]:
            result["outcome"] = "moved"
            if turn_delta == 0:
                notes.append("turn did not advance - the avatar had moves remaining "
                             "(multiple actions per turn are legal)")
            result["explanation"] = ("%s moved the avatar by (%d,%d) to pos_abs %s; the turn advanced "
                                     "by %d." % (direction, delta[0], delta[1], fmt_pos(apos), turn_delta))
            return result

        if not moved_flag and turn_delta == 0:
            result["outcome"] = "blocked_no_op"
            if dest is None:
                result["blocked_by"] = ["unknown"]
                result["explanation"] = ("%s did not move the avatar and the turn did not advance; the "
                                         "destination is outside the exported window, so the blocker is "
                                         "unknown." % direction)
            elif dest["npcs"]:
                result["blocked_by"] = ["npc"]
                npc = dest["npcs"][0]
                notes.append("faithful no-op: the NPC-interaction menu auto-cancels in test_mode; no AP "
                             "spent, world not ticked (clean-park) - see docs/arcopolis/15 and 18")
                result["explanation"] = ("%s did not move the avatar and the turn did not advance: NPC %s "
                                         "(%s) occupies the destination tile %s."
                                         % (direction, npc.get("name", "?"), npc_adjectives(npc),
                                            fmt_pos(dest["pos_local"])))
            elif dest["monsters"]:
                result["blocked_by"] = ["monster"]
                mon = dest["monsters"][0]
                notes.append("a hostile bump normally attacks (the turn would advance) - a 0-AP block "
                             "suggests a prompt/cancel path")
                result["explanation"] = ("%s did not move the avatar and the turn did not advance: monster "
                                         "%s (%s) occupies the destination tile %s."
                                         % (direction, mon.get("name", "?"), mon.get("type_id", "?"),
                                            fmt_pos(dest["pos_local"])))
            elif dest["terrain_family"] in BLOCKING_FAMILIES and dest["seen"]:
                result["blocked_by"] = ["terrain"]
                notes.append("terrain looks impassable (heuristic: id family '%s' - the contract has no "
                             "passability flag)" % dest["terrain_family"])
                result["explanation"] = ("%s did not move the avatar and the turn did not advance: the "
                                         "destination %s is %s (family '%s', heuristically impassable)."
                                         % (direction, fmt_pos(dest["pos_local"]), dest["ter"],
                                            dest["terrain_family"]))
            else:
                notes.append("no obvious blocker exported (v0 carries no vehicles, fields, or "
                             "furniture passability)")
                result["explanation"] = ("%s did not move the avatar and the turn did not advance; the "
                                         "destination %s (%s) shows no exported blocker."
                                         % (direction, fmt_pos(dest["pos_local"]),
                                            dest["ter"] if dest else "?"))
            return result

        if not moved_flag and turn_delta >= 1:
            result["outcome"] = "acted_in_place"
            hint = ""
            if dest is not None and dest["terrain_family"] == "door":
                hint = " (the destination is a door - likely opened it)"
            elif dest is not None and (dest["npcs"] or dest["monsters"]):
                hint = " (a creature occupies the destination - likely a bump-attack)"
            result["explanation"] = ("%s did not move the avatar but the turn advanced by %d - AP was "
                                     "spent in place%s." % (direction, turn_delta, hint))
            return result

        result["outcome"] = "displaced"
        notes.append("position changed but not by the commanded direction (push/swap/displacement?)")
        result["explanation"] = ("%s changed pos_abs by %s, not the commanded (%d,%d)."
                                 % (direction, fmt_pos(pos_delta), delta[0], delta[1]))
        return result

    result["outcome"] = "unknown"
    notes.append("unrecognized command verb/direction in the transcript: %r / %r" % (verb, direction))
    result["explanation"] = ("Command %r is outside the harness vocabulary; net effect: turn %+d, "
                             "pos_abs %s." % (verb, turn_delta, fmt_pos(pos_delta)))
    return result


def build_explain_model(session_dir):
    """Load + verify a whole session and classify every export pair.

    Returns the full ``--json`` document (also the human renderer's input).
    Raises ``OSError`` if ``session.jsonl`` itself cannot be read.
    """
    log = load_session_log(session_dir)
    events = log["events"]

    schema_mismatches = 0
    for ev in events:
        if ev.get("schema_version") != EXPECTED_SCHEMA_VERSION:
            schema_mismatches += 1

    export_events = [ev for ev in events if ev.get("event") == "export"]
    error_events = [ev for ev in events if ev.get("event") == "error"]

    snapshots = {}  # id(event) -> load_snapshot result
    export_mismatches = 0
    missing_snapshots = 0
    incomplete_snapshots = 0
    entities_off_window = 0
    for ev in export_events:
        snap = load_snapshot(session_dir, ev.get("path"))
        snapshots[id(ev)] = snap
        if not snap["ok"]:
            missing_snapshots += 1
            continue
        if snap["missing_keys"]:
            incomplete_snapshots += 1
        if snap["data"].get("schema_version") != EXPECTED_SCHEMA_VERSION:
            schema_mismatches += 1
        if not verify_export_against_snapshot(ev, snap["data"])["ok"]:
            export_mismatches += 1
        _, info = build_cells(snap["data"])
        entities_off_window += sum(info["off_window"].values())

    raw_pairs, preamble_commands = pair_exports(events)
    pairs = []
    for index, pair in enumerate(raw_pairs):
        before_snap = snapshots[id(pair["before"])]
        after_snap = snapshots[id(pair["after"])]
        classified = classify_pair(pair,
                                   before_snap["data"] if before_snap["ok"] else None,
                                   after_snap["data"] if after_snap["ok"] else None)

        def export_side(ev, snap):
            return {
                "name": ev.get("name"),
                "export_index": ev.get("export_index"),
                "file": ev.get("path"),
                "turn": ev.get("turn"),
                "pos_local": as_int_list(dig(snap["data"], "avatar.pos_local")) if snap["ok"] else None,
                "pos_abs": as_int_list(ev.get("pos_abs")),
                "moves": ev.get("moves"),
            }

        entry = {
            "pair_index": index,
            "before": export_side(pair["before"], before_snap),
            "after": export_side(pair["after"], after_snap),
            "commands": [{"step_index": c.get("step_index"), "command": c.get("command"),
                          "direction": c.get("direction"), "action_id": c.get("action_id")}
                         for c in pair["commands"]],
            "errors": [{"step_index": e.get("step_index"), "kind": e.get("kind"),
                        "detail": e.get("detail"), "exit_code": e.get("exit_code")}
                       for e in pair["errors"]],
        }
        entry.update(classified)
        pairs.append(entry)

    warnings = list(log["warnings"])
    if preamble_commands:
        warnings.append("%d command(s) recorded before the first export - no before-state to explain "
                        "them against" % len(preamble_commands))

    start = log["start"] or {}
    end = log["end"]
    truncated = log["start"] is None or end is None
    contract_ok = (
        not log["bad_lines"] and export_mismatches == 0 and missing_snapshots == 0
        and incomplete_snapshots == 0 and not error_events and not truncated
        and schema_mismatches == 0 and entities_off_window == 0
        and (end or {}).get("status") == "ok"
    )

    return {
        "schema_version": EXPECTED_SCHEMA_VERSION,
        "tool": TOOL_NAME,
        "tool_version": TOOL_VERSION,
        "session": {
            "world": start.get("world"),
            "seed": start.get("seed"),
            "game_version": start.get("game_version"),
            "end_status": (end or {}).get("status"),
            "snapshots": (end or {}).get("snapshots"),
            "commands": (end or {}).get("commands"),
        },
        "contract_check": {
            "ok": contract_ok,
            "bad_lines": len(log["bad_lines"]),
            "export_mismatches": export_mismatches,
            "missing_snapshots": missing_snapshots,
            "incomplete_snapshots": incomplete_snapshots,
            "error_events": len(error_events),
            "schema_mismatches": schema_mismatches,
            "entities_off_window": entities_off_window,
            "truncated": truncated,
        },
        "pairs": pairs,
        "summary": {
            "pairs": len(pairs),
            "outcome_sequence": [p["outcome"] for p in pairs],
        },
        "warnings": warnings,
    }


# --------------------------------------------------------------------------- #
# rendering: explain (human text) and view (static HTML)
# --------------------------------------------------------------------------- #
def render_explain_text(model, only_pair=None):
    """Human-readable explain output (one block per export pair)."""
    session = model["session"]
    emit("session: world=%s seed=%s end_status=%s snapshots=%s commands=%s"
         % (session["world"], session["seed"], session["end_status"],
            session["snapshots"], session["commands"]))
    for note in model["warnings"]:
        emit("note: %s" % note)
    emit("")

    for pair in model["pairs"]:
        if only_pair is not None and pair["pair_index"] != only_pair:
            continue
        before, after = pair["before"], pair["after"]
        cmds = ", ".join((c.get("direction") or c.get("command") or "?") for c in pair["commands"]) or "(none)"
        emit("pair %d: %s -> %s   command(s): %s"
             % (pair["pair_index"], before["name"], after["name"], cmds))
        emit("  turn    %s -> %s  (%s)" % (before["turn"], after["turn"],
                                           "%+d" % pair["turn_delta"] if pair["turn_delta"] is not None else "?"))
        emit("  pos_abs %s -> %s  (delta %s, expected %s)"
             % (fmt_pos(before["pos_abs"]), fmt_pos(after["pos_abs"]),
                fmt_pos(pair["pos_abs_delta"]), fmt_pos(pair["expected_delta"])))
        emit("  moves   %s -> %s  (%s; reported only, never classified)"
             % (before["moves"], after["moves"],
                "%+d" % pair["moves_delta"] if pair["moves_delta"] is not None else "?"))
        emit("  OUTCOME: %s%s" % (pair["outcome"],
                                  ("  blocked_by=" + ",".join(pair["blocked_by"])) if pair["blocked_by"] else ""))
        emit("  %s" % pair["explanation"])
        dest = pair["destination"]
        if dest is not None:
            emit("  destination %s: ter=%s furn=%s family=%s seen=%s npcs=%d monsters=%d items=%d"
                 % (fmt_pos(dest["pos_local"]), dest["ter"], dest["furn"], dest["terrain_family"],
                    str(dest["seen"]).lower(), len(dest["npcs"]), len(dest["monsters"]), len(dest["items"])))
            for npc in dest["npcs"]:
                emit("    npc: %s (%s)" % (npc.get("name", "?"), npc_adjectives(npc)))
            for mon in dest["monsters"]:
                emit("    monster: %s (%s) hp=%s/%s" % (mon.get("name", "?"), mon.get("type_id", "?"),
                                                        mon.get("hp", "?"), mon.get("hp_max", "?")))
            for item in dest["items"][:5]:
                emit("    item: %s (%s)" % (item.get("name", "?"), item.get("type_id", "?")))
            if len(dest["items"]) > 5:
                emit("    ... and %d more item(s)" % (len(dest["items"]) - 5))
        if pair["new_messages"]:
            for msg in pair["new_messages"]:
                emit("  new message: %s" % msg)
        else:
            emit("  new messages: none")
        for note in pair["notes"]:
            emit("  note: %s" % note)
        for err in pair["errors"]:
            emit("  error event: kind=%s detail=%s exit_code=%s"
                 % (err.get("kind"), err.get("detail"), err.get("exit_code")))
        emit("")

    check = model["contract_check"]
    emit("explained pairs=%d outcomes=%s contract=%s bad_lines=%d mismatches=%d missing=%d "
         "incomplete=%d errors=%d schema=%d off_window=%d%s"
         % (model["summary"]["pairs"], ",".join(model["summary"]["outcome_sequence"]) or "-",
            "OK" if check["ok"] else "DISCREPANCIES", check["bad_lines"], check["export_mismatches"],
            check["missing_snapshots"], check["incomplete_snapshots"], check["error_events"],
            check["schema_mismatches"], check["entities_off_window"],
            " truncated" if check["truncated"] else ""))


VIEW_CSS = """
body { font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif; line-height: 1.5;
       margin: 1.5rem auto; max-width: 1100px; padding: 0 1rem; background: #16161a; color: #e8e8ee; }
h1 { font-size: 1.25rem; } h2 { font-size: 1.05rem; margin-top: 1.5rem; }
code, .mono { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; }
table.kv { border-collapse: collapse; }
table.kv td { padding: .1rem .6rem .1rem 0; vertical-align: top; }
table.kv td:first-child { color: #9a9aa6; white-space: nowrap; }
.mapwrap { display: flex; gap: 1.5rem; flex-wrap: wrap; align-items: flex-start; }
.mapgrid { background: #0d0d10; color: #cccccc; padding: .5rem; border-radius: 6px; overflow-x: auto;
           font-family: ui-monospace, SFMono-Regular, Consolas, monospace; line-height: 1;
           width: max-content; max-width: 100%; }
.maprow { white-space: nowrap; }
.ylabel { display: inline-block; width: 4ch; color: #5a5a64; text-align: right; padding-right: 1ch; }
.cell { display: inline-block; width: 1ch; text-align: center; }
.cell.unseen { opacity: .32; }
.cell.avatar { color: #ffffff; background: #c0152f; outline: 1px solid #fff; font-weight: 700; }
.cell.wall { color: #c9c9c9; } .cell.floor { color: #6f6f78; } .cell.grass { color: #6fbf73; }
.cell.water { color: #4f93d6; } .cell.door { color: #d9b15a; } .cell.window { color: #79c0d6; }
.cell.stairs { color: #e08a5a; } .cell.furniture { color: #d9b15a; } .cell.void { color: #2a2a30; }
.cell.unknown { color: #ff5d6c; }
.cell.monster { color: #ff6b6b; font-weight: 700; } .cell.npc { color: #ffd166; font-weight: 700; }
.cell.item { color: #4fd6c0; font-weight: 700; }
.cell.inspected { outline: 1px dashed #ffd166; }
.legend { margin-top: .6rem; color: #9a9aa6; font-size: .85rem; }
.legend .cell { background: #0d0d10; } .legend .cell.avatar { background: #c0152f; }
.legend-item { margin-right: .9rem; white-space: nowrap; display: inline-block; }
.inspector { background: #1d1d24; border-radius: 6px; padding: .75rem 1rem; min-width: 22rem; }
.inspector ul { margin: .25rem 0 .5rem 1.1rem; padding: 0; }
.muted { color: #9a9aa6; } .hint { color: #ffd166; }
footer { margin-top: 2rem; color: #71717c; font-size: .8rem; }
"""


def render_view_html(snap, snap_name, session_dir, at_key, reveal):
    """Render ONE static self-contained HTML page: local map + tile inspector.

    Zero JavaScript; hover tooltips only (the same interactivity level as the
    Spike 4 viewer - this stays a report, not a mouse UI). Colour palette and
    grid CSS adapted from make_report.py lines 774-801.
    """
    cells, info = build_cells(snap)
    # Wrong-typed snapshot blocks must degrade like absent ones, not crash the
    # renderer (an ``avatar``/``session`` that is not a dict has no ``.get``).
    avatar = dig(snap, "avatar")
    if not isinstance(avatar, dict):
        avatar = {}
    counts = entity_counts(snap)

    # --- header table -------------------------------------------------------
    session = snap.get("session")
    if not isinstance(session, dict):
        session = {}
    header_rows = [
        ("session dir", display_path(session_dir, reveal)),
        ("snapshot", snap_name),
        ("export", "index=%s step=%s name=%s final=%s" % (session.get("export_index"),
                                                          session.get("step_index"),
                                                          session.get("export_name"),
                                                          session.get("final"))),
        ("backend turn", dig(snap, "backend.turn")),
        ("avatar", "%s  pos_local=%s  pos_abs=%s" % (avatar.get("name"),
                                                     fmt_pos(avatar.get("pos_local")),
                                                     fmt_pos(avatar.get("pos_abs")))),
        ("vitals", "hp=%s/%s stamina=%s moves=%s" % (avatar.get("hp"), avatar.get("hp_max"),
                                                     avatar.get("stamina"), avatar.get("moves"))),
        ("in window", "%d tiles, %d npcs, %d monsters, %d items"
         % (len(cells), counts["npcs"], counts["monsters"], counts["items"])),
    ]
    header_html = "<table class='kv'>%s</table>" % "".join(
        "<tr><td>%s</td><td class='mono'>%s</td></tr>" % (esc(str(k)), esc(str(v)))
        for k, v in header_rows)

    # --- map grid ------------------------------------------------------------
    if not cells:
        map_html = "<p class='muted'>No tiles in this snapshot.</p>"
        legend_html = ""
    else:
        xs = [k[0] for k in cells]
        ys = [k[1] for k in cells]
        x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
        if (x1 - x0 + 1) > MAX_MAP_SPAN or (y1 - y0 + 1) > MAX_MAP_SPAN:
            map_html = ("<p class='muted'>Tile window too large to render (%dx%d; cap %d) - likely a "
                        "malformed snapshot.</p>" % (x1 - x0 + 1, y1 - y0 + 1, MAX_MAP_SPAN))
            legend_html = ""
        else:
            tile_z = next(iter(cells))[2]
            legend = {}
            rows = []
            for y in range(y0, y1 + 1):
                row = ["<span class='ylabel'>%d</span>" % y]
                for x in range(x0, x1 + 1):
                    cell = cells.get((x, y, tile_z))
                    if cell is None:
                        row.append("<span class='cell void' title='(%d,%d) outside window'>&nbsp;</span>"
                                   % (x, y))
                        continue
                    glyph, css = cell_glyph(cell)
                    tglyph, tfamily = terrain_family(cell["tile"])
                    legend[(tfamily, tglyph)] = True
                    classes = ["cell", css]
                    seen = bool(cell["tile"].get("seen", True))
                    if not seen and not cell["is_avatar"]:
                        classes.append("unseen")
                    if (x, y, tile_z) == at_key:
                        classes.append("inspected")
                    title = "(%d,%d) ter=%s furn=%s seen=%s" % (
                        x, y, cell["tile"].get("ter", ""), cell["tile"].get("furn", ""),
                        str(seen).lower())
                    for npc in cell["npcs"]:
                        title += " | npc=%s (%s)" % (npc.get("name", "?"), npc_adjectives(npc))
                    for mon in cell["monsters"]:
                        title += " | monster=%s (%s) hp=%s/%s" % (mon.get("type_id", "?"),
                                                                  mon.get("name", ""),
                                                                  mon.get("hp", "?"), mon.get("hp_max", "?"))
                    if cell["items"]:
                        first = cell["items"][0]
                        title += " | items=%d (first: %s)" % (len(cell["items"]),
                                                              first.get("name") or first.get("type_id") or "?")
                    content = "&nbsp;" if glyph == " " else esc(glyph)
                    row.append("<span class='%s' title='%s'>%s</span>"
                               % (" ".join(classes), esc(title), content))
                rows.append("<div class='maprow'>%s</div>" % "".join(row))
            map_html = "<div class='mapgrid'>%s</div>" % "".join(rows)

            legend_items = ["<span class='legend-item'><span class='cell floor avatar'>@</span> avatar</span>",
                            "<span class='legend-item'><span class='cell npc'>N</span> npc</span>",
                            "<span class='legend-item'><span class='cell monster'>M</span> monster</span>",
                            "<span class='legend-item'><span class='cell item'>i</span> item (ground)</span>"]
            for family, glyph in sorted(legend):
                shown = "&nbsp;" if glyph == " " else esc(glyph)
                legend_items.append("<span class='legend-item'><span class='cell %s'>%s</span> %s</span>"
                                    % (esc(family), shown, esc(family)))
            legend_items.append("<span class='legend-item'><span class='cell floor unseen'>.</span> "
                                "unseen (dimmed)</span>")
            legend_html = "<div class='legend'>%s</div>" % "".join(legend_items)

    # --- tile inspector ------------------------------------------------------
    inspector_bits = ["<h2>Tile inspector - local %s</h2>" % esc(fmt_pos(list(at_key)))]
    cell = cells.get(at_key)
    if cell is None:
        inspector_bits.append("<p class='muted'>This tile is outside the exported window.</p>")
    else:
        tile = cell["tile"]
        _, family = terrain_family(tile)
        rows = [
            ("terrain", tile.get("ter")),
            ("furniture", tile.get("furn")),
            ("family", "%s (heuristic - no passability flag in the contract)" % family),
            ("seen", str(bool(tile.get("seen", True))).lower()),
            ("avatar here", str(cell["is_avatar"]).lower()),
        ]
        avatar_key = info["avatar_key"]
        if avatar_key is not None and at_key != avatar_key:
            cheb = max(abs(at_key[0] - avatar_key[0]), abs(at_key[1] - avatar_key[1]))
            rows.append(("distance from avatar", "%d (Chebyshev)" % cheb))
            step = (at_key[0] - avatar_key[0], at_key[1] - avatar_key[1])
            if step in DELTA_DIRECTIONS and at_key[2] == avatar_key[2]:
                rows.append(("reachable from avatar via", DELTA_DIRECTIONS[step]))
        inspector_bits.append("<table class='kv'>%s</table>" % "".join(
            "<tr><td>%s</td><td class='mono'>%s</td></tr>" % (esc(str(k)), esc(str(v)))
            for k, v in rows))
        if avatar_key is not None and at_key != avatar_key:
            step = (at_key[0] - avatar_key[0], at_key[1] - avatar_key[1])
            if step in DELTA_DIRECTIONS and at_key[2] == avatar_key[2]:
                inspector_bits.append("<p class='hint'>One command away: <code>%s</code></p>"
                                      % esc(DELTA_DIRECTIONS[step]))

        for kind, label in (("npcs", "NPCs"), ("monsters", "Monsters"), ("items", "Items")):
            entries = cell[kind]
            inspector_bits.append("<h2>%s on this tile (%d)</h2>" % (label, len(entries)))
            if not entries:
                inspector_bits.append("<p class='muted'>none</p>")
                continue
            lis = []
            for obj in entries:
                summary = entity_summary(obj, kind)
                if kind == "npcs":
                    text = "%s - %s" % (summary.get("name", "?"), npc_adjectives(summary))
                elif kind == "monsters":
                    text = "%s (%s) hp=%s/%s moves=%s halluc=%s" % (
                        summary.get("name", "?"), summary.get("type_id", "?"), summary.get("hp", "?"),
                        summary.get("hp_max", "?"), summary.get("moves", "?"),
                        str(bool(summary.get("hallucination"))).lower())
                else:
                    text = "%s (%s) charges=%s count_by_charges=%s" % (
                        summary.get("name", "?"), summary.get("type_id", "?"),
                        summary.get("charges", "?"),
                        str(bool(summary.get("count_by_charges"))).lower())
                lis.append("<li class='mono'>%s</li>" % esc(text))
            inspector_bits.append("<ul>%s</ul>" % "".join(lis))
    inspector_html = "<div class='inspector'>%s</div>" % "".join(inspector_bits)

    return (
        "<!DOCTYPE html><html lang='en'><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width, initial-scale=1'>"
        "<title>Arcopolis Client Harness - local view</title><style>%s</style></head><body>"
        "<h1>Arcopolis client harness - local view</h1>%s"
        "<h2>Local map</h2><div class='mapwrap'><div>%s%s</div>%s</div>"
        "<footer>%s v%s - Spike 9A external player-loop harness. Static page, zero JavaScript; "
        "hover a cell for its bundle. Generated from %s.</footer>"
        "</body></html>"
        % (VIEW_CSS, header_html, map_html, legend_html, inspector_html,
           esc(TOOL_NAME), esc(TOOL_VERSION), esc(snap_name))
    )


# --------------------------------------------------------------------------- #
# run mode (cleanly separable: only cmd_run and compose_script; deleting them
# plus the argparse block removes the mode without touching anything else)
# --------------------------------------------------------------------------- #
def compose_script(tokens):
    """Build the backend script JSON for a list of validated command tokens.

    Shape consumed by --arcopolis-run-script (src/arcopolis_script.cpp,
    parse_script): an export "start" first, then per command a command step
    plus an export named ``after_NN_<token>``. The engine appends its own
    final-on-exit snapshot afterward.
    """
    steps = [{"op": "export", "name": "start"}]
    for index, token in enumerate(tokens):
        if token == "wait":
            steps.append({"op": "command", "command": "wait"})
        else:
            steps.append({"op": "command", "command": "move", "direction": token})
        steps.append({"op": "export", "name": "after_%02d_%s" % (index, token)})
    return {"schema_version": EXPECTED_SCHEMA_VERSION, "steps": steps}


def cmd_run(args):
    """choose commands -> run the backend once -> explain the produced session."""
    tokens = [t.strip() for t in (args.commands or "").split(",") if t.strip()]
    if not tokens:
        warn("fatal: --commands is empty (expected a comma list of: %s)" % ", ".join(COMMAND_TOKENS))
        return 1
    bad = [t for t in tokens if t not in COMMAND_TOKENS]
    if bad:
        warn("fatal: unsupported command token(s): %s" % ", ".join(repr(t) for t in bad))
        warn("       the backend vocabulary is exactly: %s" % ", ".join(COMMAND_TOKENS))
        warn("       (rejected before any subprocess launch - this is a harness-side check)")
        return 1

    if not os.path.isfile(args.exe):
        warn("fatal: backend exe not found: %s" % display_path(args.exe, args.reveal_paths))
        return 1
    world_save = os.path.join(args.userdir, "save", args.world)
    if not os.path.isdir(world_save):
        warn("fatal: world %r not found under the sandbox userdir (expected %s)"
             % (args.world, os.path.join(display_path(args.userdir, args.reveal_paths), "save", args.world)))
        warn("       copy the canonical fixture userdir first (see docs/arcopolis/"
             "client_harness_regression.ps1 / AGENTS.md fixture section)")
        return 1

    out_dir = args.out
    if os.path.isdir(out_dir) and os.listdir(out_dir) and not args.force:
        warn("fatal: --out %s exists and is not empty (pass --force to reuse; the harness never "
             "silently deletes)" % display_path(out_dir, args.reveal_paths))
        return 1
    os.makedirs(out_dir, exist_ok=True)

    script_path = os.path.join(out_dir, "script.json")
    with open(script_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(compose_script(tokens), handle, indent=2)
        handle.write("\n")

    argv = [args.exe,
            "--world", args.world,
            "--arcopolis-run-script", script_path,
            "--arcopolis-export-dir", out_dir,
            "--userdir", args.userdir]
    if args.seed is not None:
        argv += ["--seed", args.seed]

    if not args.json:
        emit("run: %s  world=%s  commands=%s" % (display_path(args.exe, args.reveal_paths),
                                                 args.world, ",".join(tokens)))
    started = time.monotonic()
    stdout_path = os.path.join(out_dir, "backend_stdout.txt")
    stderr_path = os.path.join(out_dir, "backend_stderr.txt")
    try:
        with open(stdout_path, "w", encoding="utf-8") as out_handle, \
                open(stderr_path, "w", encoding="utf-8") as err_handle:
            proc = subprocess.run(argv, stdout=out_handle, stderr=err_handle, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        warn("fatal: backend did not finish within %ds (killed); see %s"
             % (args.timeout, display_path(stderr_path, args.reveal_paths)))
        return 1
    except OSError as err:
        warn("fatal: could not launch the backend: %s" % err)
        return 1
    duration = round(time.monotonic() - started, 1)

    run_block = {
        "exit_code": proc.returncode,
        "exit_meaning": BACKEND_EXIT_MEANINGS.get(proc.returncode, "unknown"),
        "script_file": os.path.basename(script_path),
        "commands": tokens,
        "duration_s": duration,
    }

    if proc.returncode != 0:
        if args.json:
            doc = {"schema_version": EXPECTED_SCHEMA_VERSION, "tool": TOOL_NAME,
                   "tool_version": TOOL_VERSION, "run": run_block}
            sys.stdout.write(json.dumps(doc, indent=2) + "\n")
        warn("fatal: backend exited %d (%s) after %.1fs; see %s"
             % (proc.returncode, run_block["exit_meaning"], duration,
                display_path(stderr_path, args.reveal_paths)))
        return 1

    try:
        model = build_explain_model(out_dir)
    except OSError as err:
        warn("fatal: backend exited 0 but %s is unreadable: %s" % (SESSION_LOG_NAME, err))
        return 1
    model["run"] = run_block

    if args.json:
        sys.stdout.write(json.dumps(model, indent=2) + "\n")
    else:
        emit("run: backend exit %d (%s) in %.1fs" % (proc.returncode, run_block["exit_meaning"], duration))
        emit("")
        render_explain_text(model)
    return 0 if model["contract_check"]["ok"] else 2


# --------------------------------------------------------------------------- #
# live mode (Spike 9B: drive the persistent --arcopolis-live stdin/stdout
# JSONL protocol; cleanly separable like run mode - cmd_live + LiveSession +
# the argparse block remove the mode without touching anything else)
# --------------------------------------------------------------------------- #
LIVE_PROTOCOL_VERSION = 1


class LiveProtocolError(Exception):
    """Fatal live-protocol failure: non-JSON stdout, timeout, early backend exit,
    a broken pipe, or a response that violates the probe's invariants."""


class LiveSession:
    """One stdin/stdout JSON Lines protocol session against a live backend.

    A single daemon reader thread pushes raw stdout lines into a queue and a
    sentinel on EOF - ``readline`` on a Windows pipe cannot be interrupted, so
    the main thread must never block on it directly. ``recv`` pops with a
    deadline and also notices early process death (e.g. a world-load failure
    exits before ``ready``). Every received line is teed verbatim to
    ``protocol.jsonl`` and MUST parse as a JSON object: stdout is the protocol
    stream, and one non-JSON line is a hard purity violation, never skipped.
    """

    _EOF = object()

    def __init__(self, proc, tee_path):
        self.proc = proc
        self.lines = queue.Queue()
        self.tee = open(tee_path, "w", encoding="utf-8", newline="\n")
        reader = threading.Thread(target=self._pump_stdout, daemon=True)
        reader.start()

    def _pump_stdout(self):
        try:
            for raw in self.proc.stdout:
                self.lines.put(raw)
        except (OSError, ValueError):
            pass  # pipe torn down mid-read (kill/exit); the sentinel below still lands
        self.lines.put(self._EOF)

    def close(self):
        try:
            self.tee.close()
        except OSError:
            pass

    def send(self, obj):
        """Write one request line + flush. subprocess wraps stdin in a buffered
        text layer, so the explicit flush is what actually delivers the line."""
        try:
            self.proc.stdin.write(json.dumps(obj) + "\n")
            self.proc.stdin.flush()
        except OSError as err:
            raise LiveProtocolError("could not send a request (backend gone? exit=%s): %s"
                                    % (self.proc.poll(), err))

    def recv(self, deadline, expect):
        """Return the next protocol object, enforcing the deadline and purity."""
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise LiveProtocolError("timed out waiting for %s" % expect)
            try:
                raw = self.lines.get(timeout=min(remaining, 0.5))
            except queue.Empty:
                if self.proc.poll() is not None and self.lines.empty():
                    raise LiveProtocolError("backend exited (code %s) before %s"
                                            % (self.proc.returncode, expect))
                continue
            if raw is self._EOF:
                raise LiveProtocolError("backend closed stdout (exit %s) before %s"
                                        % (self.proc.poll(), expect))
            stripped = raw.strip()
            self.tee.write(stripped + "\n")
            self.tee.flush()
            if not stripped:
                continue
            try:
                obj = json.loads(stripped)
            except json.JSONDecodeError as err:
                raise LiveProtocolError("non-JSON line on the protocol stdout (purity "
                                        "violation): %r (%s)" % (stripped[:200], err))
            if not isinstance(obj, dict):
                raise LiveProtocolError("protocol stdout line is JSON but not an object: %r"
                                        % stripped[:200])
            return obj


def live_expect_ok(resp, op, out_dir, expect):
    """Assert a success response for `op` and that its snapshot file exists."""
    if resp.get("type") != "response" or resp.get("ok") is not True or resp.get("op") != op:
        raise LiveProtocolError("expected an ok %s response for %s, got: %s"
                                % (op, expect, json.dumps(resp)[:300]))
    snapshot = resp.get("snapshot")
    if not isinstance(snapshot, str) or not snapshot:
        raise LiveProtocolError("ok %s response for %s carries no snapshot filename: %s"
                                % (op, expect, json.dumps(resp)[:300]))
    if not os.path.isfile(os.path.join(out_dir, snapshot)):
        raise LiveProtocolError("response for %s references %s, but the file does not exist"
                                % (expect, snapshot))


def cmd_live(args):
    """ready -> export -> one command per response -> quit -> explain."""
    tokens = [t.strip() for t in (args.commands or "").split(",") if t.strip()]
    if not tokens:
        warn("fatal: --commands is empty (expected a comma list of: %s)" % ", ".join(COMMAND_TOKENS))
        return 1
    bad = [t for t in tokens if t not in COMMAND_TOKENS]
    if bad:
        warn("fatal: unsupported command token(s): %s" % ", ".join(repr(t) for t in bad))
        warn("       the backend vocabulary is exactly: %s" % ", ".join(COMMAND_TOKENS))
        warn("       (rejected before any subprocess launch - this is a harness-side check)")
        return 1

    if not os.path.isfile(args.exe):
        warn("fatal: backend exe not found: %s" % display_path(args.exe, args.reveal_paths))
        return 1
    world_save = os.path.join(args.userdir, "save", args.world)
    if not os.path.isdir(world_save):
        warn("fatal: world %r not found under the sandbox userdir (expected %s)"
             % (args.world, os.path.join(display_path(args.userdir, args.reveal_paths), "save", args.world)))
        warn("       copy the canonical fixture userdir first (see docs/arcopolis/"
             "live_protocol_regression.ps1 / AGENTS.md fixture section)")
        return 1

    out_dir = args.out
    if os.path.isdir(out_dir) and os.listdir(out_dir) and not args.force:
        warn("fatal: --out %s exists and is not empty (pass --force to reuse; the harness never "
             "silently deletes)" % display_path(out_dir, args.reveal_paths))
        return 1
    os.makedirs(out_dir, exist_ok=True)

    argv = [args.exe,
            "--world", args.world,
            "--arcopolis-live",
            "--arcopolis-export-dir", out_dir,
            "--userdir", args.userdir]
    if args.seed is not None:
        argv += ["--seed", args.seed]

    if not args.json:
        emit("live: %s  world=%s  commands=%s%s"
             % (display_path(args.exe, args.reveal_paths), args.world, ",".join(tokens),
                "  (+negative probe)" if args.negative_probe else ""))

    started = time.monotonic()
    deadline = started + args.timeout
    stderr_path = os.path.join(out_dir, "backend_stderr.txt")
    stderr_handle = open(stderr_path, "w", encoding="utf-8")
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=stderr_handle, text=True, encoding="utf-8",
                                errors="replace")
    except OSError as err:
        stderr_handle.close()
        warn("fatal: could not launch the backend: %s" % err)
        return 1

    session = LiveSession(proc, os.path.join(out_dir, "protocol.jsonl"))
    ready_seen = False
    protocol_version = None
    responses = []
    negative_probe = None
    next_id = 1

    def send_and_recv(req, expect):
        session.send(req)
        resp = session.recv(deadline, expect)
        responses.append(resp)
        return resp

    try:
        # 1. The ready event (written only after the world loaded + transcript opened).
        ready = session.recv(deadline, "the ready event")
        if ready.get("type") != "ready" or ready.get("ok") is not True:
            raise LiveProtocolError("first protocol line is not an ok ready event: %s"
                                    % json.dumps(ready)[:300])
        protocol_version = ready.get("protocol_version")
        if protocol_version != LIVE_PROTOCOL_VERSION:
            raise LiveProtocolError("backend speaks protocol_version %r (expected %d)"
                                    % (protocol_version, LIVE_PROTOCOL_VERSION))
        ready_seen = True

        # 2. Export the starting state; every later request goes out only AFTER the
        # previous response arrived - the inspect -> decide -> send loop, serialized.
        resp = send_and_recv({"id": next_id, "op": "export", "name": "start"},
                             "the start export response")
        live_expect_ok(resp, "export", out_dir, "export start")
        next_id += 1

        # 3. One command per response (run-mode export naming, duplicate-safe).
        for index, token in enumerate(tokens):
            req = {"id": next_id, "op": "command", "name": "after_%02d_%s" % (index, token)}
            if token == "wait":
                req.update(command="wait")
            else:
                req.update(command="move", direction=token)
            resp = send_and_recv(req, "the %s response" % token)
            live_expect_ok(resp, "command", out_dir, token)
            next_id += 1

        # 4. Optional negative probe: a vocabulary-rejected command must produce ok=false
        # WITHOUT ending the session; a recovery wait must then succeed (Spike 9B's
        # recoverable-error gate).
        if args.negative_probe:
            resp = send_and_recv({"id": next_id, "op": "command", "command": "move",
                                  "direction": "move_up", "name": "probe_bad"},
                                 "the negative-probe error response")
            next_id += 1
            error = resp.get("error") if isinstance(resp.get("error"), dict) else {}
            negative_probe = {
                "sent": True,
                "ok": resp.get("ok"),
                "error_code": error.get("code"),
                "error_message": error.get("message"),
                "recovered": False,
            }
            if resp.get("ok") is not False or error.get("code") != "unsupported_command":
                raise LiveProtocolError("negative probe expected ok=false with error.code="
                                        "unsupported_command, got: %s" % json.dumps(resp)[:300])
            if proc.poll() is not None:
                raise LiveProtocolError("backend died after a recoverable bad request "
                                        "(exit %s) - recoverability violated" % proc.returncode)
            resp = send_and_recv({"id": next_id, "op": "command", "command": "wait",
                                  "name": "after_probe_wait"},
                                 "the post-probe recovery wait response")
            live_expect_ok(resp, "command", out_dir, "the recovery wait")
            negative_probe["recovered"] = True
            next_id += 1

        # 5. Quit; the backend writes its final snapshot + session_end after this response.
        resp = send_and_recv({"id": next_id, "op": "quit"}, "the quit response")
        if resp.get("ok") is not True or resp.get("op") != "quit" \
                or resp.get("status") != "session_end":
            raise LiveProtocolError("expected an ok quit/session_end response, got: %s"
                                    % json.dumps(resp)[:300])

        try:
            proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=max(1.0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            raise LiveProtocolError("backend did not exit after quit (killed)")
    except LiveProtocolError as err:
        proc.kill()
        proc.wait()
        session.close()
        stderr_handle.close()
        warn("fatal: %s" % err)
        warn("       protocol transcript: %s; backend stderr: %s"
             % (display_path(os.path.join(out_dir, "protocol.jsonl"), args.reveal_paths),
                display_path(stderr_path, args.reveal_paths)))
        return 1
    finally:
        session.close()
        stderr_handle.close()

    duration = round(time.monotonic() - started, 1)
    live_block = {
        "protocol_version": protocol_version,
        "ready_seen": ready_seen,
        "responses": responses,
        "process_exit_code": proc.returncode,
        "duration_s": duration,
    }
    if negative_probe is not None:
        live_block["negative_probe"] = negative_probe

    if proc.returncode != 0:
        warn("fatal: backend exited %d (%s) after the live session; see %s"
             % (proc.returncode, BACKEND_EXIT_MEANINGS.get(proc.returncode, "unknown"),
                display_path(stderr_path, args.reveal_paths)))
        if args.json:
            doc = {"schema_version": EXPECTED_SCHEMA_VERSION, "tool": TOOL_NAME,
                   "tool_version": TOOL_VERSION, "live": live_block}
            sys.stdout.write(json.dumps(doc, indent=2) + "\n")
        return 1

    try:
        model = build_explain_model(out_dir)
    except OSError as err:
        warn("fatal: backend exited 0 but %s is unreadable: %s" % (SESSION_LOG_NAME, err))
        return 1
    model["live"] = live_block

    if args.json:
        sys.stdout.write(json.dumps(model, indent=2) + "\n")
    else:
        emit("live: ready protocol_version=%s; %d response(s); backend exit %d in %.1fs"
             % (protocol_version, len(responses), proc.returncode, duration))
        emit("")
        render_explain_text(model)
    return 0 if model["contract_check"]["ok"] else 2


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def cmd_view(args):
    if not os.path.isdir(args.session_dir):
        warn("fatal: --session-dir is not a directory: %s" % display_path(args.session_dir, args.reveal_paths))
        return 1
    files = list_snapshot_files(args.session_dir)
    name, error, sel_warnings = select_snapshot_name(files, args.snapshot)
    for note in sel_warnings:
        warn("note: %s" % note)
    if error:
        warn("fatal: %s" % error)
        return 1
    snap = load_snapshot(args.session_dir, name)
    if not snap["ok"]:
        warn("fatal: %s" % snap["error"])
        return 1

    avatar_local = as_int_list(dig(snap["data"], "avatar.pos_local"))
    if args.at:
        match = re.fullmatch(r"\s*(-?\d+)\s*,\s*(-?\d+)\s*", args.at)
        if not match:
            warn("fatal: --at expects 'X,Y' local coordinates (got %r)" % args.at)
            return 1
        z = avatar_local[2] if avatar_local and len(avatar_local) >= 3 else 0
        at_key = (int(match.group(1)), int(match.group(2)), z)
    elif avatar_local and len(avatar_local) >= 3:
        at_key = tuple(avatar_local[:3])
    else:
        warn("fatal: snapshot has no avatar.pos_local and no --at was given")
        return 1

    page = render_view_html(snap["data"], name, args.session_dir, at_key, args.reveal_paths)
    try:
        with open(args.output, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(page)
    except OSError as err:
        warn("fatal: could not write %s: %s" % (display_path(args.output, args.reveal_paths), err))
        return 1

    counts = entity_counts(snap["data"])
    cells, _ = build_cells(snap["data"])
    inspected = cells.get(at_key)
    emit("view ok snapshot=%s turn=%s avatar=%s npcs=%d monsters=%d items=%d inspect=%s "
         "inspect_npcs=%d inspect_items=%d wrote=%s"
         % (name, dig(snap["data"], "backend.turn"), fmt_pos(avatar_local),
            counts["npcs"], counts["monsters"], counts["items"], fmt_pos(list(at_key)),
            len(inspected["npcs"]) if inspected else 0,
            len(inspected["items"]) if inspected else 0,
            display_path(args.output, args.reveal_paths)))
    if snap["missing_keys"]:
        warn("note: snapshot is missing required keys: %s" % ", ".join(snap["missing_keys"]))
        return 2
    return 0


def cmd_explain(args):
    if not os.path.isdir(args.session_dir):
        warn("fatal: --session-dir is not a directory: %s" % display_path(args.session_dir, args.reveal_paths))
        return 1
    if not os.path.isfile(os.path.join(args.session_dir, SESSION_LOG_NAME)):
        warn("fatal: %s not found in %s" % (SESSION_LOG_NAME, display_path(args.session_dir, args.reveal_paths)))
        return 1
    try:
        model = build_explain_model(args.session_dir)
    except OSError as err:
        warn("fatal: could not read %s: %s" % (SESSION_LOG_NAME, err))
        return 1

    if args.json:
        # stdout carries ONLY the JSON document (warnings go to stderr) so a
        # redirected stdout always parses.
        for note in model["warnings"]:
            warn("note: %s" % note)
        sys.stdout.write(json.dumps(model, indent=2) + "\n")
    else:
        render_explain_text(model, only_pair=args.pair)
    return 0 if model["contract_check"]["ok"] else 2


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        prog="harness.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=(
            "Arcopolis Spike 9A - external player-loop harness / contract consumer.\n"
            "Builds a frontend-style local view from backend snapshots, drives one\n"
            "scripted backend run, and explains every command's outcome.\n"
            "Read-only toward the contract, stdlib-only, zero JavaScript."
        ),
        epilog=(
            "examples:\n"
            "  python tools/arcopolis_client/harness.py view --session-dir <dir> --output view.html --at 85,84\n"
            "  python tools/arcopolis_client/harness.py explain --session-dir <dir> --json\n"
            "  python tools/arcopolis_client/harness.py run --exe <cataclysm-bn-tiles.exe> --out <dir> \\\n"
            "         --userdir .\\arcopolis_user --commands move_n,move_s,wait --json\n"
            "  python tools/arcopolis_client/harness.py live --exe <cataclysm-bn-tiles.exe> --out <dir> \\\n"
            "         --userdir .\\arcopolis_user --commands move_n,move_s,wait --json"
        ),
    )
    sub = parser.add_subparsers(dest="subcommand", required=True)

    view = sub.add_parser("view", help="render one snapshot as a static HTML map + tile inspector")
    view.add_argument("--session-dir", required=True, metavar="PATH",
                      help="directory containing NNN_<name>.json snapshots (session.jsonl not required)")
    view.add_argument("--output", required=True, metavar="PATH",
                      help="path to write the single self-contained .html page")
    view.add_argument("--snapshot", default="latest", metavar="SEL",
                      help="latest (default) | final | export index | export name | filename")
    view.add_argument("--at", metavar="X,Y",
                      help="local coordinates of the tile to inspect (default: the avatar tile)")
    view.add_argument("--reveal-paths", action="store_true",
                      help="show full local paths instead of basenames (AGENTS.md privacy rule)")

    explain = sub.add_parser("explain", help="classify every command outcome across the session")
    explain.add_argument("--session-dir", required=True, metavar="PATH",
                         help="directory containing session.jsonl and the NNN_<name>.json snapshots")
    explain.add_argument("--json", action="store_true",
                         help="emit the machine-readable JSON document on stdout (nothing else)")
    explain.add_argument("--pair", type=int, metavar="N",
                         help="human output only: show just this pair index")
    explain.add_argument("--reveal-paths", action="store_true",
                         help="show full local paths instead of basenames")

    run = sub.add_parser("run", help="compose a script, run the backend once, explain the session")
    run.add_argument("--exe", required=True, metavar="PATH",
                     help="path to cataclysm-bn-tiles.exe (a Spike 8A+ build)")
    run.add_argument("--out", required=True, metavar="DIR",
                     help="export dir for this session (refused if non-empty unless --force)")
    run.add_argument("--commands", required=True, metavar="LIST",
                     help="comma list of: %s" % ", ".join(COMMAND_TOKENS))
    run.add_argument("--world", default="ArcopolisTest", metavar="NAME",
                     help="world name under <userdir>/save (default: ArcopolisTest)")
    run.add_argument("--userdir", default=os.path.join(".", "arcopolis_user"), metavar="DIR",
                     help="sandbox userdir holding save/<world> (default: .\\arcopolis_user; ALWAYS "
                          "passed to the backend so a run can never touch the real user directory)")
    run.add_argument("--seed", metavar="S", help="forwarded to the backend --seed")
    run.add_argument("--timeout", type=int, default=120, metavar="SECONDS",
                     help="kill the backend after this many seconds (default: 120)")
    run.add_argument("--force", action="store_true",
                     help="allow writing into an existing non-empty --out dir")
    run.add_argument("--json", action="store_true",
                     help="emit the machine-readable JSON document (with a 'run' block) on stdout")
    run.add_argument("--reveal-paths", action="store_true",
                     help="show full local paths instead of basenames")

    live = sub.add_parser("live", help="drive one persistent --arcopolis-live backend over its "
                                       "stdin/stdout JSONL protocol, then explain the session")
    live.add_argument("--exe", required=True, metavar="PATH",
                      help="path to cataclysm-bn-tiles.exe (a Spike 9B+ build)")
    live.add_argument("--out", required=True, metavar="DIR",
                      help="export dir for this session (refused if non-empty unless --force)")
    live.add_argument("--commands", required=True, metavar="LIST",
                      help="comma list of: %s (sent one at a time, each only after the previous "
                           "response)" % ", ".join(COMMAND_TOKENS))
    live.add_argument("--world", default="ArcopolisTest", metavar="NAME",
                      help="world name under <userdir>/save (default: ArcopolisTest)")
    live.add_argument("--userdir", default=os.path.join(".", "arcopolis_user"), metavar="DIR",
                      help="sandbox userdir holding save/<world> (default: .\\arcopolis_user; ALWAYS "
                           "passed to the backend so a session can never touch the real user directory)")
    live.add_argument("--seed", metavar="S", help="forwarded to the backend --seed")
    live.add_argument("--timeout", type=int, default=120, metavar="SECONDS",
                      help="overall protocol deadline incl. world load; the backend is killed past "
                           "it (default: 120)")
    live.add_argument("--negative-probe", action="store_true",
                      help="after the scripted commands, send an unsupported move_up (expect a "
                           "recoverable ok=false), then a recovery wait, before quitting")
    live.add_argument("--force", action="store_true",
                      help="allow writing into an existing non-empty --out dir")
    live.add_argument("--json", action="store_true",
                      help="emit the machine-readable JSON document (with a 'live' block) on stdout")
    live.add_argument("--reveal-paths", action="store_true",
                      help="show full local paths instead of basenames")

    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if args.subcommand == "view":
        return cmd_view(args)
    if args.subcommand == "explain":
        return cmd_explain(args)
    if args.subcommand == "run":
        return cmd_run(args)
    if args.subcommand == "live":
        return cmd_live(args)
    return 1


if __name__ == "__main__":
    sys.exit(main())
