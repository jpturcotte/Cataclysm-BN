#!/usr/bin/env python3
"""Arcopolis Spike 10A: local browser-frontend prototype bridge.

One small HTTP server that owns ONE persistent `--arcopolis-live` Cataclysm-BN
backend child process and exposes it to a plain HTML/CSS/JS browser page over a
tiny JSON HTTP API:

    browser (static/index.html + app.js)
      -> this bridge (HTTP, loopback)
        -> stdin/stdout JSON Lines live protocol (Spike 9B)
          -> the engine's real game::handle_action() input seam
            -> game::do_turn() owns turns and the world tick
      <- read-only snapshots (NNN_<name>.json) + session.jsonl transcript

The bridge is a *protocol client and file consumer only*: it never mutates game
state, never bypasses the live protocol, and never reshapes the snapshot
contract (snapshot slices are re-served verbatim to the browser). Like the
Spike 4 viewer and the Spike 9A client harness, it is an external consumer that
deliberately shares no code with them (each consumer independently re-derives
the contract - that independence is the point) and is stdlib-only: no third
party packages, no websockets, no sockets/pipes to the backend.

Protocol facts this file relies on (verified against src/arcopolis_live.{h,cpp}
and docs/arcopolis/21_SPIKE9B_LIVE_PROTOCOL.md):
  * backend stdout carries ONLY protocol JSON lines, flushed per line; stderr
    is diagnostics. One request in flight at a time (strictly serial).
  * ready:    {"type":"ready","protocol_version":1,"ok":true,"world":...}
  * success:  {"type":"response","id",...,"ok":true,"op","snapshot":
              "NNN_<name>.json","export_index","turn"} - the snapshot file is
              flushed BEFORE the response, so it is resolved from this field,
              never by globbing (single exception: the final-on-exit snapshot's
              label is contractually "final").
  * quit:     {"type":"response",...,"ok":true,"op":"quit","status":
              "session_end"}; the final snapshot + session_end transcript are
              written AFTER this response; then the process exits 0. stdin EOF
              is the same clean path without a response line.
  * errors:   {"type":"response",...,"ok":false,["op",]"error":{"code",
              "message"}}. Recoverable codes (session continues):
              malformed_json, bad_request, unsupported_command. Fatal codes
              (process exits right after responding): export_failed(exit 9),
              backend_stalled(exit 10), game_over(exit 11).
  * a command response is DEFERRED to the next input-rest instant, so the
    response's snapshot is the post-command state.

Spike 10C adds OPTIONAL tileset asset serving: with --tileset-dir pointing at a
BN tileset (default .\\gfx\\UltimateCataclysm), the bridge re-serves that dir's
tile_config.json plus exactly the spritesheet files it references, under
/tileset/. The bridge stays an asset file server here - it never parses sprite
meaning (the browser does), and tileset availability is frontend/RENDERING
metadata, deliberately NOT part of /api/state: the state document remains the
unreshaped snapshot contract every consumer re-derives. Any tileset problem
disables /tileset/ serving with a warning and the server still starts - the UI
falls back to glyph rendering (the backend snapshot is the only authority;
glyphs are a frontend interpretation too).

HTTP API (one state-document shape everywhere; see docs/arcopolis/
22_SPIKE10A_FRONTEND_PROTOTYPE.md for the full contract):
  GET  /                      static UI (whitelisted files only)
  GET  /static/app.js
  GET  /static/style.css
  GET  /tileset/info          tileset serving status {enabled, name, reason,
                              files}; always answers, even when disabled
  GET  /tileset/<file>        tile_config.json or a spritesheet PNG it
                              references (exact-name whitelist; 404 otherwise)
  GET  /api/state             cached state document; never touches the backend
  POST /api/start             spawn backend -> ready -> initial "start" export
  POST /api/command           {"command":"wait"}, {"command":"move",
                              "direction":"move_n"} (any of the 8 planar
                              directions), or {"command":"examine",
                              "direction":"move_n"|...|"here"}; shape-validated
                              only - vocabulary is deliberately left to the
                              backend (an unsupported direction must surface the
                              authoritative unsupported_command rejection)
  POST /api/wait              alias for {"command":"wait"}
  POST /api/export            refresh snapshot (outcome: no_command)
  POST /api/quit              quit ladder: quit request -> EOF -> wait -> kill
  POST /api/shutdown          quit a live backend, then stop this server

Run (PowerShell, from the repo root; copy the fixture first per AGENTS.md):
  python tools/arcopolis_frontend/prototype_server.py --exe <built-exe> `
      --userdir .\\arcopolis_user --world ArcopolisTest
then open http://127.0.0.1:8765/ in a browser.

This is a prototype, not a final UI architecture: polling instead of push, one
session at a time, loopback only (no auth), and session directories accumulate
under --out-root by design (never silently deleted).
"""

import argparse
import atexit
import http.server
import json
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time
import traceback
import urllib.parse

TOOL_NAME = "arcopolis_frontend_prototype"
TOOL_VERSION = "0.2.0"

# The only live-protocol version this bridge speaks (asserted against `ready`).
LIVE_PROTOCOL_VERSION = 1
# The only snapshot schema this bridge accepts.
EXPECTED_SCHEMA_VERSION = 1

# Recoverable protocol rejections: the backend answers ok:false and the session
# keeps accepting requests (src/arcopolis_live.h, live_error_code).
RECOVERABLE_ERROR_CODES = {"malformed_json", "bad_request", "unsupported_command"}

# Backend process exit codes for the live mode (doc 21; arcopolis_live.h).
BACKEND_EXIT_MEANINGS = {
    0: "ok",
    1: "startup_error",
    9: "export_failed",
    10: "backend_stalled",
    11: "game_over",
}

# Planar moves: direction ident -> expected (dx, dy) in pos_abs space. The eight
# adjacent tiles a BN GUI player can step (four cardinals + four diagonals) - the
# same planar set the backend's move verb dispatches through avatar_action::move.
# Snapshot y grows southward, x grows eastward, so move_n is (0, -1), move_s is
# (0, 1), and move_ne is (1, -1). Vertical (move_up/down) is a SEPARATE engine
# primitive (game::vertical_move) and is deliberately absent here - the bridge
# passes it through and lets the backend surface the authoritative rejection.
DIRECTION_DELTAS = {
    "move_n": (0, -1),
    "move_ne": (1, -1),
    "move_e": (1, 0),
    "move_se": (1, 1),
    "move_s": (0, 1),
    "move_sw": (-1, 1),
    "move_w": (-1, 0),
    "move_nw": (-1, -1),
}

# Static file whitelist: URL path -> (filename under static/, content type).
# Routing by exact dict lookup means there is no path arithmetic to traverse.
STATIC_ROUTES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/static/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/static/style.css": ("style.css", "text/css; charset=utf-8"),
}

API_GET_ROUTES = {"/api/state"}
API_POST_ROUTES = {
    "/api/start", "/api/export", "/api/command", "/api/wait", "/api/quit", "/api/shutdown",
}

STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

# Tileset asset serving (Spike 10C). /tileset/<name> resolves by EXACT lookup
# in a whitelist built once at startup from tile_config.json's "tiles-new"
# file inventory - no path arithmetic ever touches client input.
TILESET_CONFIG_NAME = "tile_config.json"
TILESET_INFO_ROUTE = "/tileset/info"
TILESET_PREFIX = "/tileset/"


def warn(message):
    """Diagnostics go to stderr (stdout is not protocol here, but stay tidy)."""
    print(f"{TOOL_NAME}: {message}", file=sys.stderr, flush=True)


def dig(obj, *keys):
    """Nested dict lookup returning None instead of raising."""
    cur = obj
    for key in keys:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(key)
    return cur


def as_int_list(value, length):
    """Return value as a list of `length` ints, or None if it is not one."""
    if not isinstance(value, list) or len(value) != length:
        return None
    out = []
    for item in value:
        if isinstance(item, bool) or not isinstance(item, int):
            return None
        out.append(item)
    return out


def safe_token(text):
    """Reduce arbitrary client text to the backend's export-name alphabet
    ([A-Za-z0-9_.-]) so bridge-built labels are valid by construction."""
    token = re.sub(r"[^A-Za-z0-9_.-]", "_", str(text or ""))[:24]
    return token or "cmd"


def build_tileset_state(tileset_dir, disabled):
    """Build the /tileset/ serving state once at startup: an exact-name
    whitelist {name: (abspath, content_type)} of tile_config.json plus the
    spritesheet files its "tiles-new" entries reference, and the /tileset/info
    document. The shape check is deliberately shallow (a file inventory): the
    bridge re-serves tileset ASSETS, it never interprets sprite meaning - that
    is the browser's job, just as snapshot meaning belongs to the backend.

    Fail-safe by contract: ANY problem returns enabled:false with a short
    reason (no local paths - the info doc is browser-visible) and the server
    still starts; the UI then stays in glyph mode, the safe visual fallback."""
    info = {"enabled": False, "name": None, "reason": None, "files": 0}
    routes = {}
    if disabled:
        info["reason"] = "disabled by --disable-tileset"
        return routes, info
    base = os.path.abspath(tileset_dir)
    config_path = os.path.join(base, TILESET_CONFIG_NAME)
    if not os.path.isdir(base):
        info["reason"] = "tileset dir not found"
        warn(f"tileset: dir not found: {base}")
        return routes, info
    if not os.path.isfile(config_path):
        info["reason"] = f"{TILESET_CONFIG_NAME} not found in the tileset dir"
        warn(f"tileset: missing {config_path}")
        return routes, info
    try:
        with open(config_path, encoding="utf-8-sig") as handle:
            config = json.load(handle)
    except (OSError, json.JSONDecodeError, UnicodeDecodeError) as err:
        info["reason"] = f"{TILESET_CONFIG_NAME} is unreadable or not valid JSON"
        warn(f"tileset: cannot load {config_path}: {err}")
        return routes, info
    if not isinstance(config, dict) or not isinstance(config.get("tile_info"), list) \
            or not isinstance(config.get("tiles-new"), list):
        info["reason"] = f"{TILESET_CONFIG_NAME} lacks the tile_info/tiles-new shape"
        warn(f"tileset: {config_path} is not a tiles-new tileset config")
        return routes, info
    routes[TILESET_CONFIG_NAME] = (config_path, "application/json; charset=utf-8")
    for sheet in config["tiles-new"]:
        name = sheet.get("file") if isinstance(sheet, dict) else None
        # Flat basenames only: anything else cannot be a sibling spritesheet.
        if not isinstance(name, str) or not name or name in (".", "..") \
                or name != os.path.basename(name):
            warn(f"tileset: skipping non-basename tiles-new file entry: {name!r}")
            continue
        path = os.path.abspath(os.path.join(base, name))
        try:
            contained = os.path.commonpath([base, path]) == base
        except ValueError:  # different drives on Windows -> cannot be inside base
            contained = False
        if not contained or not os.path.isfile(path):
            warn(f"tileset: skipping missing/escaping sheet file: {name!r}")
            continue
        # BN tileset sheets are PNGs; the whitelist serves them as such.
        routes[name] = (path, "image/png")
    info["enabled"] = True
    info["name"] = os.path.basename(base)
    info["files"] = len(routes)
    return routes, info


class BackendError(Exception):
    """Fatal bridge<->backend failure (timeout, death, purity violation,
    invalid snapshot). `code` feeds the HTTP error envelope."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def load_snapshot(session_dir, rel_name):
    """Load + shape-check the snapshot file named by a backend response.

    Only the response-provided filename is used (the contract flushes the file
    before the response). The joined path must stay inside session_dir."""
    base = os.path.abspath(session_dir)
    path = os.path.abspath(os.path.join(base, rel_name))
    try:
        contained = os.path.commonpath([base, path]) == base
    except ValueError:  # e.g. different drives on Windows -> cannot be inside session_dir
        contained = False
    if not contained:
        raise BackendError("protocol_violation",
                           f"response snapshot name escapes the session dir: {rel_name!r}")
    try:
        with open(path, encoding="utf-8-sig") as handle:
            snap = json.load(handle)
    except OSError as err:
        raise BackendError("snapshot_invalid", f"cannot read snapshot {rel_name}: {err}")
    except json.JSONDecodeError as err:
        raise BackendError("snapshot_invalid", f"snapshot {rel_name} is not valid JSON: {err}")
    if not isinstance(snap, dict):
        raise BackendError("snapshot_invalid", f"snapshot {rel_name} is not a JSON object")
    if snap.get("schema_version") != EXPECTED_SCHEMA_VERSION:
        raise BackendError("snapshot_invalid",
                           f"snapshot {rel_name} has schema_version "
                           f"{snap.get('schema_version')!r} (expected {EXPECTED_SCHEMA_VERSION})")
    problems = []
    if not isinstance(dig(snap, "backend", "turn"), int):
        problems.append("backend.turn")
    if as_int_list(dig(snap, "avatar", "pos_abs"), 3) is None:
        problems.append("avatar.pos_abs")
    if as_int_list(dig(snap, "avatar", "pos_local"), 3) is None:
        problems.append("avatar.pos_local")
    if not isinstance(dig(snap, "avatar", "moves"), int):
        problems.append("avatar.moves")
    if not isinstance(snap.get("tiles"), list):
        problems.append("tiles")
    if problems:
        raise BackendError("snapshot_invalid",
                           f"snapshot {rel_name} is missing/mistyped: {', '.join(problems)}")
    return snap


def summarize(snap):
    """The scalars outcome classification compares (load_snapshot validated)."""
    return {
        "turn": dig(snap, "backend", "turn"),
        "pos_abs": as_int_list(dig(snap, "avatar", "pos_abs"), 3),
        "moves": dig(snap, "avatar", "moves"),
    }


def find_final_snapshot(session_dir):
    """The single allowed glob: the final-on-exit snapshot's label is
    contractually "final" and the quit response carries no filename."""
    best = None
    best_index = -1
    try:
        names = os.listdir(session_dir)
    except OSError:
        return None
    for name in names:
        match = re.fullmatch(r"(\d+)_final\.json", name)
        if match and int(match.group(1)) > best_index:
            best_index = int(match.group(1))
            best = name
    return best


def destination_cell(snap, delta):
    """The BEFORE-snapshot cell one step from the avatar: tile + entities
    sharing that pos_local. None when the tile is outside the export window."""
    avatar = as_int_list(dig(snap, "avatar", "pos_local"), 3)
    if avatar is None:
        return None
    dest = (avatar[0] + delta[0], avatar[1] + delta[1], avatar[2])
    tile = None
    for candidate in snap.get("tiles") or []:
        if isinstance(candidate, dict) and \
                (candidate.get("x"), candidate.get("y"), candidate.get("z")) == dest:
            tile = candidate
            break
    if tile is None:
        return None
    cell = {"tile": tile, "npcs": [], "monsters": [], "items": []}
    for group in ("npcs", "monsters", "items"):
        for entity in dig(snap, "entities", group) or []:
            pos = as_int_list(dig(entity, "pos_local"), 3) if isinstance(entity, dict) else None
            if pos is not None and tuple(pos) == dest:
                cell[group].append(entity)
    return cell


def blocking_terrain_family(tile):
    """Heuristic only - the snapshot carries no passability flag, so this is a
    best-effort guess from the ter/furn id strings, never engine truth."""
    ids = " ".join(str(tile.get(key) or "") for key in ("ter", "furn"))
    if "window" in ids:
        return "window"
    if "wall" in ids or "rock" in ids:
        return "wall"
    return None


def outcome_for_rejection(code, message):
    """An ok:false backend response surfaced as outcome data (not transport)."""
    return {
        "outcome": "error",
        "turn_delta": None,
        "pos_abs_delta": None,
        "moves_delta": None,
        "expected_delta": None,
        "blocked_by": [],
        "blocker_name": None,
        "explanation": f"the backend rejected the request: {code}: {message}",
        "error": {"code": code, "message": message},
    }


def classify_outcome(verb, direction, before, after, before_snap):
    """Basic outcome explanation, re-derived from the Spike 9A concept: keyed
    on the avatar pos_abs delta + calendar turn delta + the command verb.
    pos_local is bubble-relative and moves are refilled at turn processing, so
    neither is ever classified on (moves_delta is reported only)."""
    out = {
        "outcome": "unknown",
        "turn_delta": None,
        "pos_abs_delta": None,
        "moves_delta": None,
        "expected_delta": None,
        "blocked_by": [],
        "blocker_name": None,
        "explanation": "",
        "error": None,
    }
    if before is None or after is None:
        out["outcome"] = "unverifiable"
        out["explanation"] = "missing a before/after snapshot summary to compare"
        return out
    turn_delta = after["turn"] - before["turn"]
    pos_delta = [a - b for a, b in zip(after["pos_abs"], before["pos_abs"])]
    out["turn_delta"] = turn_delta
    out["pos_abs_delta"] = pos_delta
    out["moves_delta"] = after["moves"] - before["moves"]
    moved = any(pos_delta)

    if verb is None:
        out["outcome"] = "no_command"
        out["explanation"] = "snapshot refreshed; no command was issued"
        if moved or turn_delta != 0:
            out["explanation"] += (f" (state changed anyway: turn_delta={turn_delta}, "
                                   f"pos_abs_delta={pos_delta})")
        return out

    if verb == "wait":
        if not moved and turn_delta >= 1:
            out["outcome"] = "waited"
            out["explanation"] = f"wait ended the turn; the calendar advanced {turn_delta} turn(s)"
        elif not moved and turn_delta == 0:
            # The engine's bootstrap turn after a load processes the world at
            # the loaded turn without advancing the calendar - still a wait.
            out["outcome"] = "waited"
            out["explanation"] = ("wait ran the engine's bootstrap turn: the world was processed "
                                  "at the loaded turn without advancing the calendar")
        else:
            out["outcome"] = "unknown"
            out["explanation"] = (f"wait produced an unexpected state change "
                                  f"(turn_delta={turn_delta}, pos_abs_delta={pos_delta})")
        return out

    if verb == "move" and direction in DIRECTION_DELTAS:
        dx, dy = DIRECTION_DELTAS[direction]
        expected = [dx, dy, 0]
        out["expected_delta"] = expected
        if pos_delta == expected:
            out["outcome"] = "moved"
            out["explanation"] = (f"{direction} moved the avatar by ({dx},{dy}); "
                                  f"{turn_delta} turn(s) passed")
        elif not moved and turn_delta == 0:
            out["outcome"] = "blocked_no_op"
            cell = destination_cell(before_snap, (dx, dy)) if before_snap else None
            if cell is None:
                out["explanation"] = (f"{direction} did not move the avatar and no turn passed; "
                                      "the destination tile is outside the export window")
            elif cell["npcs"]:
                out["blocked_by"] = ["npc"]
                out["blocker_name"] = dig(cell["npcs"][0], "name")
                out["explanation"] = (f"{direction} did not move the avatar and no turn passed; "
                                      f"the destination tile holds NPC '{out['blocker_name']}'")
            elif cell["monsters"]:
                out["blocked_by"] = ["monster"]
                out["blocker_name"] = dig(cell["monsters"][0], "name")
                out["explanation"] = (f"{direction} did not move the avatar and no turn passed; "
                                      f"the destination tile holds monster '{out['blocker_name']}'")
            else:
                family = blocking_terrain_family(cell["tile"])
                if family is not None:
                    out["blocked_by"] = ["terrain"]
                    out["blocker_name"] = str(cell["tile"].get("ter") or "")
                    out["explanation"] = (f"{direction} did not move the avatar and no turn "
                                          f"passed; the destination terrain looks like a "
                                          f"{family} (heuristic - the snapshot has no "
                                          f"passability flag)")
                else:
                    out["explanation"] = (f"{direction} did not move the avatar and no turn "
                                          "passed; no blocker is visible in the snapshot")
        elif not moved and turn_delta >= 1:
            out["outcome"] = "acted_in_place"
            out["explanation"] = (f"{direction} did not move the avatar but {turn_delta} turn(s) "
                                  "passed (the move spent the turn on something else, e.g. "
                                  "opening a door)")
        else:
            out["outcome"] = "displaced"
            out["explanation"] = (f"{direction} ended with pos_abs_delta={pos_delta}, not the "
                                  f"expected {expected}")
        return out

    if verb == "examine":
        # Examine is a prompted/nested-input interaction whose target EFFECTS
        # (messages, menus the backend auto-cancels) live in the engine, not in
        # the scalar deltas the bridge can see. So the bridge makes only the
        # honest position claim: the command completed through the backend input
        # path and (faithfully) did not move the avatar. We REPORT turn/moves
        # deltas but do not interpret them as a target result - examine does not
        # invent semantics here. A position change would be unexpected (examine
        # should never move the avatar), so it is flagged as displaced.
        if not moved:
            out["outcome"] = "examined"
            out["explanation"] = (
                f"examine {direction} completed through the backend input path; "
                "inspect the messages panel / transcript for engine effects "
                f"(turn_delta={turn_delta}, moves_delta={out['moves_delta']})")
        else:
            out["outcome"] = "displaced"
            out["explanation"] = (
                f"examine {direction} completed but the avatar position changed "
                f"unexpectedly (pos_abs_delta={pos_delta}); examine should not move "
                "the avatar")
        return out

    out["outcome"] = "unknown"
    out["explanation"] = (f"no classification rule for verb={verb!r} direction={direction!r} "
                          f"(turn_delta={turn_delta}, pos_abs_delta={pos_delta})")
    return out


# --------------------------------------------------------------------------- #
# BackendSession: exactly one --arcopolis-live child process
# --------------------------------------------------------------------------- #
class BackendSession:
    """One live-protocol session. All methods run under the bridge op lock
    (documented invariant), so the class needs no internal locking. A daemon
    reader thread pumps stdout lines into a queue plus an EOF sentinel -
    readline on a Windows pipe cannot be interrupted, so the serving thread
    never blocks on the pipe directly. Every received line is teed verbatim to
    protocol.jsonl and MUST parse as a JSON object (stdout is the protocol
    stream; one non-JSON line is a hard purity violation, never skipped)."""

    _EOF = object()

    def __init__(self, exe, world, userdir, session_dir, seed, response_timeout):
        self.exe = exe
        self.world = world
        self.userdir = userdir
        self.session_dir = session_dir
        self.seed = seed
        self.response_timeout = response_timeout
        self.proc = None
        self.lines = queue.Queue()
        self.tee = None
        self.stderr_handle = None
        self.next_id = 0
        self.world_echo = None
        self.cur_snapshot = None
        self.cur_snapshot_name = None
        self.cur_summary = None
        self.last_export_index = None

    @property
    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    @property
    def exit_code(self):
        return None if self.proc is None else self.proc.poll()

    def spawn(self):
        """Launch the backend, verify `ready`, and load an initial snapshot."""
        cmd = [self.exe, "--world", self.world,
               "--arcopolis-live", "--arcopolis-export-dir", self.session_dir,
               "--userdir", self.userdir]
        if self.seed:
            cmd += ["--seed", self.seed]
        self.tee = open(os.path.join(self.session_dir, "protocol.jsonl"),
                        "w", encoding="utf-8", newline="\n")
        # stderr goes to a file, never a pipe: an unread pipe would fill and
        # deadlock the child. stdout stays a pipe and is drained by the pump.
        self.stderr_handle = open(os.path.join(self.session_dir, "backend_stderr.txt"),
                                  "w", encoding="utf-8")
        try:
            self.proc = subprocess.Popen(
                cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=self.stderr_handle, text=True, encoding="utf-8", errors="replace")
        except OSError as err:
            raise BackendError("spawn_failed", f"could not launch the backend: {err}")
        threading.Thread(target=self._pump_stdout, daemon=True).start()
        ready = self._recv(time.monotonic() + self.response_timeout, "the ready event")
        if ready.get("type") != "ready" or ready.get("ok") is not True:
            raise BackendError("protocol_violation",
                               f"expected the ready event, got: {json.dumps(ready)[:300]}")
        if ready.get("protocol_version") != LIVE_PROTOCOL_VERSION:
            raise BackendError("protocol_violation",
                               f"backend speaks live protocol "
                               f"{ready.get('protocol_version')!r}, this bridge speaks "
                               f"{LIVE_PROTOCOL_VERSION}")
        self.world_echo = ready.get("world")
        # An immediate export so the UI has a map before any command is sent.
        response = self.request({"op": "export", "name": "start"})
        if response.get("ok") is not True:
            raise BackendError("protocol_violation",
                               f"the initial export was rejected: {json.dumps(response)[:300]}")
        self._absorb_success(response)
        return response

    def _pump_stdout(self):
        try:
            for raw in self.proc.stdout:
                self.lines.put(raw)
        except (OSError, ValueError):
            pass  # pipe torn down mid-read (kill/exit); the sentinel still lands
        self.lines.put(self._EOF)

    def _send(self, obj):
        """One request line + flush (subprocess buffers stdin in a text layer;
        the explicit flush is what actually delivers the line)."""
        try:
            self.proc.stdin.write(json.dumps(obj) + "\n")
            self.proc.stdin.flush()
        except OSError as err:
            raise BackendError("backend_dead",
                               f"could not send a request (backend exit={self.proc.poll()}): {err}")

    def _recv(self, deadline, expect):
        """Next protocol object, enforcing the deadline and stdout purity."""
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BackendError("timeout", f"timed out waiting for {expect}")
            try:
                raw = self.lines.get(timeout=min(remaining, 0.5))
            except queue.Empty:
                if self.proc.poll() is not None and self.lines.empty():
                    code = self.proc.returncode
                    meaning = BACKEND_EXIT_MEANINGS.get(code, "unknown")
                    raise BackendError("backend_dead",
                                       f"backend exited (code {code}: {meaning}) before {expect}")
                continue
            if raw is self._EOF:
                raise BackendError("backend_dead",
                                   f"backend closed stdout (exit {self.proc.poll()}) "
                                   f"before {expect}")
            stripped = raw.strip()
            # Local ref + swallowed teardown errors: the no-lock emergency
            # branches (op_shutdown/emergency_stop after a lock timeout) may
            # close the tee while a wedged recv is mid-loop; the tee is an
            # audit trail only and must never turn that into a new failure.
            tee = self.tee
            if tee is not None:
                try:
                    tee.write(stripped + "\n")
                    tee.flush()
                except (OSError, ValueError):
                    pass
            if not stripped:
                continue
            try:
                obj = json.loads(stripped)
            except json.JSONDecodeError as err:
                raise BackendError("protocol_violation",
                                   f"non-JSON line on the protocol stdout (purity violation): "
                                   f"{stripped[:200]!r} ({err})")
            if not isinstance(obj, dict):
                raise BackendError("protocol_violation",
                                   f"protocol stdout line is JSON but not an object: "
                                   f"{stripped[:200]!r}")
            return obj

    def request(self, req):
        """Send one request and block for its response. The protocol is
        strictly serial; the id check is defensive. A timeout here poisons the
        serial stream (a late response would desync every later id), so the
        caller's only recovery is kill + mark the session dead - never retry."""
        self.next_id += 1
        payload = {"id": self.next_id}
        payload.update(req)
        self._send(payload)
        deadline = time.monotonic() + self.response_timeout
        response = self._recv(deadline, f"the response to {req.get('op')!r}")
        if response.get("type") != "response":
            raise BackendError("protocol_violation",
                               f"expected a response object, got: {json.dumps(response)[:300]}")
        if response.get("id") != self.next_id:
            raise BackendError("protocol_violation",
                               f"response id {response.get('id')!r} does not match request id "
                               f"{self.next_id}")
        return response

    def _absorb_success(self, response):
        """Load the snapshot an ok:true export/command response names."""
        name = response.get("snapshot")
        if not isinstance(name, str) or not name:
            raise BackendError("protocol_violation",
                               f"ok response carries no snapshot filename: "
                               f"{json.dumps(response)[:300]}")
        snap = load_snapshot(self.session_dir, name)
        self.cur_snapshot = snap
        self.cur_snapshot_name = name
        self.cur_summary = summarize(snap)
        if isinstance(response.get("export_index"), int):
            self.last_export_index = response["export_index"]

    def do_export(self, label):
        response = self.request({"op": "export", "name": label})
        if response.get("ok") is True:
            self._absorb_success(response)
        return response

    def do_command(self, verb, direction, label):
        req = {"op": "command", "command": verb, "name": label}
        if direction is not None:
            req["direction"] = direction
        response = self.request(req)
        if response.get("ok") is True:
            self._absorb_success(response)
        return response

    def quit_clean(self, timeout):
        """The quit/EOF/kill ladder. Returns {clean, exit_code, exit_meaning,
        final_snapshot, quit_response}. The final snapshot is located only
        after the process exits - it is written after the quit response."""
        result = {"clean": False, "exit_code": None, "exit_meaning": None,
                  "final_snapshot": None, "quit_response": None}
        acked = False
        if self.alive:
            try:
                response = self.request({"op": "quit"})
                result["quit_response"] = response
                acked = (response.get("ok") is True
                         and response.get("status") == "session_end")
            except BackendError:
                acked = False
        # EOF is the same documented clean path; harmless after a quit ack.
        if self.proc is not None:
            try:
                self.proc.stdin.close()
            except OSError:
                pass
            try:
                self.proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self._kill()
            result["exit_code"] = self.proc.returncode
            result["exit_meaning"] = BACKEND_EXIT_MEANINGS.get(self.proc.returncode, "unknown")
        if result["exit_code"] == 0:
            result["final_snapshot"] = find_final_snapshot(self.session_dir)
            result["clean"] = acked and result["final_snapshot"] is not None
        self.close()
        return result

    def reap(self, timeout):
        """After a FATAL ok:false response the backend exits on its own."""
        if self.proc is None:
            return None
        try:
            self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self._kill()
        self.close()
        return self.proc.returncode

    def _kill(self):
        if self.proc is None:
            return
        try:
            self.proc.kill()
            self.proc.wait(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            pass

    def kill(self):
        self._kill()
        self.close()

    def close(self):
        """Close bridge-held file handles (idempotent; the process may live)."""
        for attr in ("tee", "stderr_handle"):
            handle = getattr(self, attr)
            if handle is not None:
                try:
                    handle.close()
                except OSError:
                    pass
                setattr(self, attr, None)


# --------------------------------------------------------------------------- #
# Bridge: the shared application object behind the HTTP handler
# --------------------------------------------------------------------------- #
class Bridge:
    """Serializes every backend-touching operation behind a non-blocking op
    lock (busy -> HTTP 409: the live protocol allows one request in flight)
    and publishes an immutable-by-convention cached state document that
    GET /api/state returns without ever touching the backend or the op lock."""

    def __init__(self, config):
        self.config = config
        self.op_lock = threading.Lock()
        self.state_lock = threading.Lock()
        self.session = None
        self.session_meta = None
        self.phase = "idle"  # idle -> starting -> ready -> ended | dead
        self.busy_op = None
        self.command_seq = 0
        self.last_result = None
        self.last_error = None
        self.state_serial = 0
        self.state_doc = None
        self._stopped = False
        self.next_session_index = self._scan_session_index()
        self._swap_doc()

    # ----- state document ----------------------------------------------- #
    def _scan_session_index(self):
        highest = 0
        try:
            names = os.listdir(self.config["out_root"])
        except OSError:
            names = []
        for name in names:
            match = re.fullmatch(r"session_(\d+)", name)
            if match:
                highest = max(highest, int(match.group(1)))
        return highest + 1

    def _build_doc(self):
        doc = {
            "ok": True,
            "server": {"tool": TOOL_NAME, "version": TOOL_VERSION,
                       "protocol_version": LIVE_PROTOCOL_VERSION,
                       "schema_version": EXPECTED_SCHEMA_VERSION},
            "state_serial": self.state_serial,
            "phase": self.phase,
            "busy": self.busy_op is not None,
            "busy_op": self.busy_op,
            "session": dict(self.session_meta) if self.session_meta else None,
            "backend": None,
            "avatar": None,
            "map": None,
            "messages": [],
            "last_result": self.last_result,
            "last_error": self.last_error,
        }
        session = self.session
        if session is not None and session.cur_snapshot is not None:
            snap = session.cur_snapshot
            doc["backend"] = {
                "turn": dig(snap, "backend", "turn"),
                "export_index": session.last_export_index,
                "snapshot": session.cur_snapshot_name,
            }
            # Verbatim snapshot slices: the bridge re-serves the contract, it
            # never reshapes it (the browser is an honest consumer too).
            doc["avatar"] = snap.get("avatar")
            doc["map"] = {
                "bounds": snap.get("map_bounds"),
                "tiles": snap.get("tiles"),
                "entities": snap.get("entities") or {"monsters": [], "npcs": [], "items": []},
            }
            doc["messages"] = snap.get("messages") or []
        return doc

    def _swap_doc(self):
        with self.state_lock:
            self.state_serial += 1
            self.state_doc = self._build_doc()

    def get_state_doc(self):
        with self.state_lock:
            return self.state_doc

    @staticmethod
    def error_doc(code, message):
        return {"ok": False, "error": {"code": code, "message": message}}

    # ----- operation plumbing -------------------------------------------- #
    def _run_op(self, name, fn):
        """Acquire the op lock without blocking, run fn() -> (status,
        error_doc|None), rebuild the cache, and return the freshest state doc
        for success responses (one document shape everywhere)."""
        if not self.op_lock.acquire(blocking=False):
            return 409, self.error_doc("busy",
                                       f"another operation ({self.busy_op}) is in progress")
        final_doc = None
        try:
            self.busy_op = name
            self._swap_doc()
            try:
                status, err_doc = fn()
            except BackendError as err:
                # Defensive: ops are expected to map BackendError themselves.
                self._mark_dead(err)
                status, err_doc = 502, self.error_doc(err.code, str(err))
        finally:
            self.busy_op = None
            self._swap_doc()
            final_doc = self.get_state_doc()
            self.op_lock.release()
        return status, (err_doc if err_doc is not None else final_doc)

    def _mark_dead(self, err):
        if self.session is not None:
            self.session.kill()
            if self.session_meta is not None:
                self.session_meta["exit_code"] = self.session.exit_code
                self.session_meta["exit_meaning"] = BACKEND_EXIT_MEANINGS.get(
                    self.session.exit_code, "unknown")
        self.phase = "dead"
        self.last_error = {"code": err.code, "message": str(err)}

    # ----- operations ----------------------------------------------------- #
    def op_start(self):
        def fn():
            if self.session is not None and self.session.alive:
                return 409, self.error_doc("session_already_running",
                                           "a live backend session is already running; "
                                           "quit it first")
            if self.session is not None:
                self.session.close()
            index = self.next_session_index
            dir_name = f"session_{index:03d}"
            session_dir = os.path.join(self.config["out_root"], dir_name)
            try:
                os.makedirs(session_dir, exist_ok=True)
            except OSError as err:
                return 502, self.error_doc("spawn_failed",
                                           f"cannot create the session dir: {err}")
            self.next_session_index = index + 1
            self.phase = "starting"
            self.command_seq = 0
            self.session_meta = {
                "index": index, "dir_name": dir_name,
                "world": self.config["world"], "seed": self.config["seed"],
                "exit_code": None, "exit_meaning": None, "final_snapshot": None,
            }
            session = BackendSession(
                exe=self.config["exe"], world=self.config["world"],
                userdir=self.config["userdir"], session_dir=session_dir,
                seed=self.config["seed"],
                response_timeout=self.config["response_timeout"])
            self.session = session
            try:
                response = session.spawn()
            except BackendError as err:
                self._mark_dead(err)
                return 502, self.error_doc(err.code, str(err))
            self.phase = "ready"
            self.last_error = None
            # No before-state exists for the first export: outcome is null.
            self.last_result = {"op": "start", "request": {"op": "start"},
                                "response": response, "outcome": None}
            return 200, None

        return self._run_op("start", fn)

    def _op_backend_step(self, op_name, request_doc, runner, verb, direction):
        """Shared body of command/wait/export: run one backend request, then
        classify the outcome from the before/after snapshot summaries."""
        def fn():
            session = self.session
            if session is None or not session.alive or self.phase != "ready":
                return 409, self.error_doc("no_session",
                                           f"no live backend session (phase: {self.phase})")
            # Label numbering happens HERE - under the op lock, after the
            # preconditions: incremented outside it, a 409-rejected concurrent
            # request would skip (or, unsynchronized, duplicate) a number.
            # Labels are cosmetic (the backend's NNN prefix is authoritative),
            # but gapless reads better in a session dir listing.
            self.command_seq += 1
            before_summary = session.cur_summary
            before_snap = session.cur_snapshot
            try:
                response = runner(session, self.command_seq)
            except BackendError as err:
                self._mark_dead(err)
                return 502, self.error_doc(err.code, str(err))
            if response.get("ok") is True:
                outcome = classify_outcome(verb, direction, before_summary,
                                           session.cur_summary, before_snap)
                self.last_result = {"op": op_name, "request": request_doc,
                                    "response": response, "outcome": outcome}
                self.last_error = None
                return 200, None
            code = dig(response, "error", "code") or "unknown"
            message = dig(response, "error", "message") or ""
            outcome = outcome_for_rejection(code, message)
            self.last_result = {"op": op_name, "request": request_doc,
                                "response": response, "outcome": outcome}
            if code in RECOVERABLE_ERROR_CODES:
                # The session keeps accepting requests; the rejection is data.
                return 200, None
            # Fatal: the backend exits right after this response.
            exit_code = session.reap(timeout=10)
            self.session_meta["exit_code"] = exit_code
            self.session_meta["exit_meaning"] = BACKEND_EXIT_MEANINGS.get(exit_code, "unknown")
            self.phase = "dead"
            self.last_error = {"code": "backend_fatal", "message": f"{code}: {message}"}
            return 502, self.error_doc("backend_fatal", f"{code}: {message}")

        return self._run_op(op_name, fn)

    def op_command(self, verb, direction):
        token = safe_token(direction if direction is not None else verb)
        request_doc = {"command": verb}
        if direction is not None:
            request_doc["direction"] = direction
        return self._op_backend_step(
            "command", request_doc,
            lambda session, seq: session.do_command(verb, direction, f"after_{seq:02d}_{token}"),
            verb, direction)

    def op_export(self):
        return self._op_backend_step(
            "export", {"op": "export"},
            lambda session, seq: session.do_export(f"export_{seq:02d}"),
            None, None)

    def op_quit(self):
        def fn():
            session = self.session
            if session is None or self.phase not in ("ready", "starting"):
                return 409, self.error_doc("no_session",
                                           f"no live backend session to quit "
                                           f"(phase: {self.phase})")
            result = session.quit_clean(timeout=self.config["response_timeout"])
            self.session_meta["exit_code"] = result["exit_code"]
            self.session_meta["exit_meaning"] = result["exit_meaning"]
            self.session_meta["final_snapshot"] = result["final_snapshot"]
            self.last_result = {"op": "quit", "request": {"op": "quit"},
                                "response": result["quit_response"], "outcome": None}
            if result["clean"]:
                self.phase = "ended"
                self.last_error = None
                return 200, None
            self.phase = "dead"
            self.last_error = {"code": "backend_dead",
                               "message": f"quit did not end cleanly "
                                          f"(exit_code={result['exit_code']})"}
            return 502, self.error_doc(self.last_error["code"], self.last_error["message"])

        return self._run_op("quit", fn)

    def op_shutdown(self):
        """Quit a live backend (waiting out an in-flight op), flag shutdown.
        The HTTP handler stops the listener AFTER writing the response."""
        got = self.op_lock.acquire(timeout=10)
        try:
            if got:
                self.busy_op = "shutdown"
                self._swap_doc()
                if self.session is not None and self.session.alive:
                    result = self.session.quit_clean(timeout=10)
                    if self.session_meta is not None:
                        self.session_meta["exit_code"] = result["exit_code"]
                        self.session_meta["exit_meaning"] = result["exit_meaning"]
                        self.session_meta["final_snapshot"] = result["final_snapshot"]
                    self.phase = "ended" if result["clean"] else "dead"
            elif self.session is not None:
                # An op is wedged; last resort so no orphan outlives the server.
                self.session.kill()
                self.phase = "dead"
        finally:
            if got:
                self.busy_op = None
                self._swap_doc()
                self.op_lock.release()
        self._stopped = True
        return 200, {"ok": True, "shutting_down": True}

    def emergency_stop(self):
        """atexit / signal ladder: never leave an orphan backend behind."""
        if self._stopped:
            return
        self._stopped = True
        got = self.op_lock.acquire(timeout=2)
        try:
            session = self.session
            if session is not None and session.alive:
                if got:
                    session.quit_clean(timeout=5)
                else:
                    session.kill()
        finally:
            if got:
                self.op_lock.release()


# --------------------------------------------------------------------------- #
# HTTP layer
# --------------------------------------------------------------------------- #
class Handler(http.server.BaseHTTPRequestHandler):
    server_version = f"ArcopolisFrontendPrototype/{TOOL_VERSION}"
    protocol_version = "HTTP/1.1"  # keep-alive; every response sets Content-Length

    @property
    def bridge(self):
        return self.server.bridge

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def _dispatch(self, method):
        try:
            path = urllib.parse.urlsplit(self.path).path
            if method == "GET":
                self._handle_get(path)
            else:
                self._handle_post(path)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass  # the browser went away mid-response; nothing to answer
        except Exception:  # one handler bug must not hang the socket
            warn("unhandled handler error:\n" + traceback.format_exc())
            try:
                self._send_json(500, Bridge.error_doc(
                    "server_error", "unhandled bridge error; see the server log"))
            except OSError:
                pass

    def _handle_get(self, path):
        if path in STATIC_ROUTES:
            self._serve_static(path)
        elif path == "/api/state":
            self._send_json(200, self.bridge.get_state_doc())
        elif path == TILESET_INFO_ROUTE:
            # Always answers (also when disabled): the UI's status line needs
            # to distinguish "not configured" from "fetch failed".
            self._send_json(200, self.server.tileset_info)
        elif path.startswith(TILESET_PREFIX):
            self._serve_tileset(path)
        elif path in API_POST_ROUTES:
            self._send_json(405, Bridge.error_doc("method_not_allowed", f"POST {path}"),
                            extra_headers=[("Allow", "POST")])
        else:
            self._send_json(404, Bridge.error_doc("not_found", path))

    def _handle_post(self, path):
        # Drain the request body up front for EVERY endpoint: with HTTP/1.1
        # keep-alive, unread body bytes would be parsed as the NEXT request's
        # request line, poisoning the connection with a spurious 400.
        raw, body_err = self._read_body()
        if body_err is not None:
            self.close_connection = True  # cannot know where the body ends
            self._send_json(400, Bridge.error_doc("bad_request", body_err))
            return
        if path == "/api/start":
            status, doc = self.bridge.op_start()
        elif path == "/api/export":
            status, doc = self.bridge.op_export()
        elif path == "/api/wait":
            status, doc = self.bridge.op_command("wait", None)
        elif path == "/api/command":
            body, err = self._parse_json_body(raw)
            if err is not None:
                self._send_json(400, Bridge.error_doc("bad_request", err))
                return
            verb = body.get("command")
            direction = body.get("direction")
            # Shape/type checks only: vocabulary (verbs/directions) is
            # deliberately left to the backend so its authoritative
            # unsupported_command rejection is what surfaces (e.g. move_up).
            if not isinstance(verb, str) or not verb:
                self._send_json(400, Bridge.error_doc(
                    "bad_request", "body requires a non-empty string 'command'"))
                return
            if direction is not None and not isinstance(direction, str):
                self._send_json(400, Bridge.error_doc(
                    "bad_request", "'direction' must be a string when present"))
                return
            status, doc = self.bridge.op_command(verb, direction)
        elif path == "/api/quit":
            status, doc = self.bridge.op_quit()
        elif path == "/api/shutdown":
            status, doc = self.bridge.op_shutdown()
            self._send_json(status, doc)
            # Stop the listener only after the response bytes are written, and
            # never from this handler thread directly: shutdown() blocks until
            # serve_forever() exits, so calling it inline would deadlock.
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        elif path in STATIC_ROUTES or path in API_GET_ROUTES \
                or path == TILESET_INFO_ROUTE or path.startswith(TILESET_PREFIX):
            self._send_json(405, Bridge.error_doc("method_not_allowed", f"GET {path}"),
                            extra_headers=[("Allow", "GET")])
            return
        else:
            self._send_json(404, Bridge.error_doc("not_found", path))
            return
        self._send_json(status, doc)

    def _read_body(self):
        """Read exactly Content-Length bytes (the body MUST always be consumed
        before responding - see _handle_post)."""
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return None, "invalid Content-Length"
        raw = self.rfile.read(length) if length > 0 else b""
        return raw, None

    @staticmethod
    def _parse_json_body(raw):
        if not raw:
            return None, "a JSON object body is required"
        try:
            body = json.loads(raw.decode("utf-8", errors="replace"))
        except json.JSONDecodeError as err:
            return None, f"body is not valid JSON: {err}"
        if not isinstance(body, dict):
            return None, "body must be a JSON object"
        return body, None

    def _serve_static(self, path):
        filename, content_type = STATIC_ROUTES[path]
        file_path = os.path.join(STATIC_DIR, filename)
        try:
            with open(file_path, "rb") as handle:
                payload = handle.read()
        except OSError:
            self._send_json(404, Bridge.error_doc("not_found", f"static file {filename}"))
            return
        self._send_bytes(200, content_type, payload)

    def _serve_tileset(self, path):
        """One whitelisted tileset asset. The name after /tileset/ is
        percent-decoded ONCE (browsers encode specials in sheet filenames and
        the frontend encodes them explicitly), then resolved by EXACT dict
        lookup only - whitelist keys are flat basenames, so a decoded name
        carrying a separator (e.g. an encoded ..%2F traversal) can never
        match; the explicit separator reject in front is belt and braces and
        a clearer refusal."""
        name = urllib.parse.unquote(path[len(TILESET_PREFIX):])
        routes = self.server.tileset_routes
        if "/" in name or "\\" in name or name not in routes:
            self._send_json(404, Bridge.error_doc("not_found", path))
            return
        file_path, content_type = routes[name]
        try:
            with open(file_path, "rb") as handle:
                payload = handle.read()
        except OSError:
            self._send_json(404, Bridge.error_doc("not_found", f"tileset file {name}"))
            return
        self._send_bytes(200, content_type, payload)

    def _send_json(self, status, doc, extra_headers=None):
        payload = json.dumps(doc, separators=(",", ":")).encode("utf-8")
        self._send_bytes(status, "application/json; charset=utf-8", payload,
                         extra_headers=extra_headers)

    def _send_bytes(self, status, content_type, payload, extra_headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        # no-store everywhere: a stale cached app.js would silently test old UI.
        self.send_header("Cache-Control", "no-store")
        for name, value in extra_headers or []:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):  # noqa: A002 (stdlib signature)
        sys.stderr.write(f"{self.address_string()} - {format % args}\n")


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="prototype_server.py",
        description="Arcopolis Spike 10A browser-frontend prototype bridge "
                    "(stdlib-only; drives one --arcopolis-live backend).",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument("--exe",
                        default=os.path.join(".", "out", "build", "win-rel-deb", "src",
                                             "cataclysm-bn-tiles.exe"),
                        help="path to the built cataclysm-bn-tiles executable")
    parser.add_argument("--userdir", default=os.path.join(".", "arcopolis_user"),
                        help="userdir holding the prepared world (copy the fixture "
                             "first; see AGENTS.md)")
    parser.add_argument("--world", default="ArcopolisTest",
                        help="world name inside the userdir's save/")
    parser.add_argument("--out-root", default=os.path.join(".", "out", "arco_frontend"),
                        help="directory that receives one session_NNN dir per /api/start")
    parser.add_argument("--host", default="127.0.0.1",
                        help="bind address (loopback only - the bridge has no auth)")
    parser.add_argument("--port", type=int, default=8765, help="HTTP port")
    parser.add_argument("--seed", default=None,
                        help="optional --seed string forwarded to the backend")
    parser.add_argument("--response-timeout", type=float, default=60.0,
                        help="seconds to wait for ready and for each protocol response")
    parser.add_argument("--tileset-dir",
                        default=os.path.join(".", "gfx", "UltimateCataclysm"),
                        help="BN tileset dir whose tile_config.json + referenced "
                             "spritesheets are re-served under /tileset/ (optional "
                             "rendering mode; if unusable the UI stays glyph-only)")
    parser.add_argument("--disable-tileset", action="store_true",
                        help="never serve /tileset/ assets, even if --tileset-dir exists")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])
    out_root = os.path.abspath(args.out_root)
    try:
        os.makedirs(out_root, exist_ok=True)
    except OSError as err:
        warn(f"fatal: cannot create --out-root {out_root}: {err}")
        return 1
    if not os.path.isfile(args.exe):
        warn(f"note: --exe not found yet ({args.exe}); /api/start will fail until it exists")
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        warn(f"WARNING: binding {args.host}: this prototype has no authentication; "
             "anyone who can reach the port controls the backend")

    bridge = Bridge({
        "exe": args.exe,
        "userdir": args.userdir,
        "world": args.world,
        "out_root": out_root,
        "seed": args.seed,
        "response_timeout": args.response_timeout,
    })

    # Tileset serving is strictly optional: a failure here only disables
    # /tileset/ (the UI stays glyph-only) - the server must still start.
    tileset_routes, tileset_info = build_tileset_state(args.tileset_dir, args.disable_tileset)
    if tileset_info["enabled"]:
        warn(f"tileset serving enabled: {tileset_info['name']} "
             f"({tileset_info['files']} whitelisted files)")
    else:
        warn(f"tileset serving disabled: {tileset_info['reason']} (UI stays glyph-only)")

    try:
        httpd = http.server.ThreadingHTTPServer((args.host, args.port), Handler)
    except OSError as err:
        warn(f"fatal: cannot bind {args.host}:{args.port}: {err}")
        return 1
    httpd.daemon_threads = True  # a wedged handler must not block process exit
    httpd.bridge = bridge
    httpd.tileset_routes = tileset_routes
    httpd.tileset_info = tileset_info

    atexit.register(bridge.emergency_stop)

    def request_shutdown(signum, frame):  # noqa: ARG001 (stdlib signature)
        # shutdown() blocks until serve_forever() exits - never call it on the
        # signal-handling (main) thread directly.
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    for sig_name in ("SIGINT", "SIGTERM", "SIGBREAK"):
        sig = getattr(signal, sig_name, None)
        if sig is not None:
            try:
                signal.signal(sig, request_shutdown)
            except (OSError, ValueError):
                pass

    warn(f"serving http://{args.host}:{args.port}/ "
         f"(world={args.world}, out_root={out_root})")
    warn("POST /api/start to launch the backend; Ctrl+C or POST /api/shutdown to stop")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    httpd.server_close()
    bridge.emergency_stop()
    warn("server stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
