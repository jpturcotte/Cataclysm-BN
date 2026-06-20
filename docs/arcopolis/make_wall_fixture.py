#!/usr/bin/env python3
"""Arcopolis Spike 21 - build the genuine terrain-block (blocked_no_op) witness fixture.

Creates the ``ArcopolisWallTest`` world by CLONING the canonical ``ArcopolisTest`` world and replacing the
terrain of ONE clean floor tile one tile EAST of the avatar with an impassable wall (``t_wall``).

WHY this exists (Spike 21):
  Before Spike 21 the only ``blocked_no_op`` witness was ``move_n`` into the shelter NPC Edwardo. But that
  path is NOT a faithful blocked movement -- it reaches ``game::npc_menu``'s unarmed ``uilist::query``, which
  the backend now FAILS LOUD on (``unexpected_prompt``, see docs/arcopolis/43). To keep the client harness's
  ``blocked_no_op`` classification covered by a REAL runtime witness, this fixture
  provides a GENUINE terrain block: moving EAST into the wall runs the real ``avatar_action::move`` ->
  ``g->walk_move`` leaf, which returns false for the impassable destination and (for a sighted, same-z move)
  spends NO moves, shows NO message, opens NO prompt/uilist, and does NOT tick the world
  (src/avatar_action.cpp "Regular Move" + "Invalid move" tail). That is exactly ``blocked_no_op``.

WHY ``t_wall`` / this tile:
  * ``t_wall`` (data/json/furniture_and_terrain/terrain-walls.json) has ``move_cost: 0`` and the ``WALL``
    flag, so it is impassable. A plain move into it is rejected with no prompt (auto-bash needs the explicit
    smash command; auto-mine needs AUTO_MINING + a DIG_TOOL the stock shelter avatar does not carry). Its id
    contains "wall", so the client harness's destination analysis reads it as a wall-family tile. (NOTE: the
    harness withholds ``blocked_by=["terrain"]`` here -- that branch needs ``dest.seen=true`` and a headless
    run never populates LOS, so every tile exports ``seen=false``; the gate asserts the ``blocked_no_op``
    outcome + the ``t_wall`` destination, not the seen-gated attribution. See docs/arcopolis/43 §6/§10.)
  * The EAST tile (offset +1,0,0) is plain ``t_floor`` with NO furniture and NO items in ``ArcopolisTest``
    (this tool ABORTS otherwise) -- the same verified-clean tile ``make_furniture_fixture.py`` uses, and away
    from the NPC (north) and the south ground-item pile other gates rely on.

The regression (the terrain ``blocked_no_op`` gate in ``docs/arcopolis/client_harness_regression.ps1``)
drives ``harness.py run --commands move_e --world ArcopolisWallTest`` and asserts the harness classifies
``blocked_no_op`` with ``turn_delta 0``, ``pos_abs_delta 0,0,0``, ``destination.ter == t_wall``, exit 0.

If a future BN sync renames/removes ``t_wall`` or makes a plain move into it prompt (a "really walk into..."
query), pick another impassable, non-prompting wall/rock terrain whose id contains "wall"/"rock" and update
``WALL_TER`` here AND the gate (the gate is self-checking: a non-no-op move fails it). DO NOT invent JSON.

WHY save-injection (same rationale as make_furniture_fixture.py / make_vehicle_fixture.py):
  * Scriptable, reproducible, needs NO interactive client and NO build -- one ``python`` invocation.
  * NOT "faking engine state": terrain is a normal submap field; this authors an INITIAL world condition (a
    wall on a floor tile), exactly what a mapgen/build would leave. Nothing engine-internal is mutated at
    runtime.

WHERE the terrain lives:
  * Submap terrain lives in the ``.map`` (``map.sqlite3``) ``terrain`` field as an RLE array of id strings
    and ``[id, count]`` runs, indexed ROW-MAJOR (y outer, x inner: index = y*SEEX + x). This tool decodes it, sets the one
    witness tile to ``WALL_TER``, re-encodes the full 144-tile RLE (the form the loader accepts), and
    rewrites the zlib-compressed row. ``ArcopolisTest`` stays untouched.

This is a developer fixture tool: stdlib-only, read-only on ``ArcopolisTest``, only writes the new world
folder. Run it, then validate with ``docs/arcopolis/client_harness_regression.ps1``.

Usage::

    python docs/arcopolis/make_wall_fixture.py            # defaults
    python docs/arcopolis/make_wall_fixture.py --force    # overwrite an existing dest world
"""

import argparse
import glob
import json
import os
import shutil
import sqlite3
import zlib

# The approved external fixture root (AGENTS.md fixture section); kept as the default so the command is
# copy-pasteable. Override with --fixture-root for a different layout.
DEFAULT_FIXTURE_ROOT = r"C:\dev\arcopolis-fixtures\arcopolis_user"
SEEX = SEEY = 12  # submap side length

# The witness wall id. See module docstring for the criteria it must satisfy and the swap procedure if this
# id ever stops meeting them. (data/json/furniture_and_terrain/terrain-walls.json, verified 2026-06-20:
# move_cost 0, WALL flag, id contains "wall".)
WALL_TER = "t_wall"
# The witness tile must be plain passable floor before the swap so the wall is the only difference from the
# clone. (Any of the avatar's neighbours are floor in ArcopolisTest; EAST is the verified-clean one.)
EXPECTED_TER = "t_floor"


def load_sav(world_dir):
    """Return the parsed JSON object of a world's main .sav (one-line ``# version N`` prefix then JSON)."""
    matches = sorted(glob.glob(os.path.join(world_dir, "*.sav")))
    if not matches:
        raise SystemExit("fatal: no .sav file in %s" % world_dir)
    with open(matches[0], "rb") as f:
        raw = f.read()
    nl = raw.find(b"\n")
    if nl == -1 or not raw.lstrip().startswith(b"#"):
        return json.loads(raw.decode("utf-8"))
    return json.loads(raw[nl + 1:].decode("utf-8"))


def map_file_path(sx, sy, z):
    """The map.sqlite3 ``files.path`` holding the 2x2 submap block that contains submap (sx,sy,z).
    BN groups 4 submaps per .map file at fx=sx//2, fy=sy//2: maps/<fx//32>.<fy//32>.<z>/<fx>.<fy>.<z>.map.
    (Same helper as the other fixture scripts; kept duplicated so each fixture is standalone.)"""
    fx, fy = sx // 2, sy // 2
    return "maps/%d.%d.%d/%d.%d.%d.map" % (fx // 32, fy // 32, z, fx, fy, z)


def read_submap_file(db, path):
    """Return ``(was_compressed, submap_list)`` for a .map row, or ``(None, None)`` if absent."""
    con = sqlite3.connect(db)
    try:
        row = con.execute("SELECT data FROM files WHERE path=?", (path,)).fetchone()
    finally:
        con.close()
    if not row:
        return None, None
    blob = row[0]
    try:
        text = zlib.decompress(blob)
        compressed = True
    except zlib.error:
        text = bytes(blob)
        compressed = False
    return compressed, json.loads(text.decode("utf-8"))


def write_submap_file(db, path, obj, compressed):
    """Rewrite a .map row with the modified submap list, matching the original compression."""
    payload = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    if compressed:
        payload = zlib.compress(payload)
    con = sqlite3.connect(db)
    try:
        con.execute("UPDATE files SET data=? WHERE path=?", (sqlite3.Binary(payload), path))
        con.commit()
    finally:
        con.close()


def decode_terrain(arr):
    """Decode the submap ``terrain`` RLE into a flat list of 144 ids. The flat order is ROW-MAJOR
    (y outer, x inner): index = y*SEEX + x -- verified empirically against the loaded snapshot (a tile
    written at index wy*SEEX+wx appears at within-submap (wx,wy)). Each element is a string (one tile) or a
    ``[id, count]`` run. NOTE: make_furniture_fixture.py's copy of this docstring claims x-major; that is a
    latent error there, harmless only because its terrain CHECK lands on another t_floor tile."""
    flat = []
    for e in arr:
        if isinstance(e, list):
            flat += [e[0]] * e[1]
        else:
            flat.append(e)
    return flat


def encode_terrain(flat):
    """Re-encode a flat list of terrain ids into the submap RLE the loader accepts: a run of length 1 is a
    bare id string; a run of length N>1 is ``[id, N]`` (the inverse of decode_terrain; the loader decodes
    both forms, so this round-trips exactly)."""
    out = []
    i = 0
    n = len(flat)
    while i < n:
        j = i
        while j < n and flat[j] == flat[i]:
            j += 1
        run = j - i
        out.append(flat[i] if run == 1 else [flat[i], run])
        i = j
    return out


def items_count_at(submap, wx, wy):
    """Number of ground items at within-submap (wx,wy). submap['items'] is a flat
    ``[wx, wy, [stack], ...]`` array (verified by the other fixtures)."""
    items = submap.get("items", [])
    for i in range(0, len(items) - 2, 3):
        if items[i] == wx and items[i + 1] == wy:
            return len(items[i + 2])
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Build the ArcopolisWallTest terrain-block (blocked_no_op) witness fixture.")
    parser.add_argument("--fixture-root", default=DEFAULT_FIXTURE_ROOT,
                        help="userdir holding save/<world> (default: the AGENTS.md fixture root)")
    parser.add_argument("--source-world", default="ArcopolisTest", help="world to clone (read-only)")
    parser.add_argument("--dest-world", default="ArcopolisWallTest", help="world to create")
    parser.add_argument("--offset", default="1,0,0",
                        help="witness-tile offset from the avatar as dx,dy,dz. DEFAULT 1,0,0 is the clean "
                             "floor tile one EAST of the avatar -- the tile a `move direction=move_e` "
                             "targets. Its terrain is replaced with the wall.")
    parser.add_argument("--force", action="store_true", help="overwrite an existing dest world")
    args = parser.parse_args(argv)

    save_root = os.path.join(args.fixture_root, "save")
    src = os.path.join(save_root, args.source_world)
    dst = os.path.join(save_root, args.dest_world)
    if not os.path.isdir(src):
        raise SystemExit("fatal: source world not found: %s" % src)
    try:
        dx, dy, dz = (int(v) for v in args.offset.split(","))
    except ValueError:
        raise SystemExit("fatal: --offset must be dx,dy,dz integers, e.g. 1,0,0")

    # Avatar abs_pos (read-only) -> the witness tile and its submap.
    data = load_sav(src)
    ax, ay, az = data["player"]["abs_pos"]
    tx, ty, tz = ax + dx, ay + dy, az + dz
    sx, sy = tx // SEEX, ty // SEEY
    wx, wy = tx - sx * SEEX, ty - sy * SEEY
    path = map_file_path(sx, sy, tz)
    print("avatar abs_pos : %s" % [ax, ay, az])
    print("witness tile   : abs %s -> submap (%d,%d,%d) within (%d,%d)" % ([tx, ty, tz], sx, sy, tz, wx, wy))
    print("map file       : %s" % path)
    print("witness wall   : %s" % WALL_TER)

    # Read the source submap (read-only) and ASSERT the witness tile is a clean floor tile BEFORE cloning,
    # so a stale offset/world drift fails loud instead of producing a broken witness.
    src_db = os.path.join(src, "map.sqlite3")
    _, src_submaps = read_submap_file(src_db, path)
    if src_submaps is None:
        raise SystemExit("fatal: map file row not found: %s (is the witness tile in the saved bubble?)" % path)
    src_submap = next((s for s in src_submaps if s.get("coordinates") == [sx, sy, tz]), None)
    if src_submap is None:
        raise SystemExit("fatal: submap (%d,%d,%d) not present in %s" % (sx, sy, tz, path))
    flat = decode_terrain(src_submap["terrain"])
    if len(flat) != SEEX * SEEY:
        raise SystemExit("fatal: decoded terrain has %d tiles, expected %d" % (len(flat), SEEX * SEEY))
    idx = wy * SEEX + wx  # ROW-MAJOR (y outer, x inner): within-submap (wx,wy) -> flat index wy*SEEX+wx
    if flat[idx] != EXPECTED_TER:
        raise SystemExit("fatal: witness tile terrain is '%s', expected '%s' -- pick a clean floor offset"
                         % (flat[idx], EXPECTED_TER))
    existing_furn = [e for e in src_submap.get("furniture", []) if e[0] == wx and e[1] == wy]
    if existing_furn:
        raise SystemExit("fatal: witness tile already has furniture %s -- pick a clean offset" % existing_furn)
    nitems = items_count_at(src_submap, wx, wy)
    if nitems:
        raise SystemExit("fatal: witness tile already has %d ground item(s) -- pick a clean offset" % nitems)

    if os.path.exists(dst):
        if not args.force:
            raise SystemExit("fatal: %s already exists (use --force to overwrite)" % dst)
        shutil.rmtree(dst)
    shutil.copytree(src, dst)

    db = os.path.join(dst, "map.sqlite3")
    compressed, submaps = read_submap_file(db, path)
    submap = next((s for s in submaps if s.get("coordinates") == [sx, sy, tz]), None)
    if submap is None:
        raise SystemExit("fatal: submap (%d,%d,%d) not found in the cloned map" % (sx, sy, tz))
    flat = decode_terrain(submap["terrain"])
    flat[idx] = WALL_TER
    submap["terrain"] = encode_terrain(flat)
    write_submap_file(db, path, submaps, compressed)

    # Read-back sanity: confirm the witness tile now decodes to the wall and the tile count is intact.
    _, verify_submaps = read_submap_file(db, path)
    verify_submap = next((s for s in verify_submaps if s.get("coordinates") == [sx, sy, tz]), None)
    if verify_submap is None:
        raise SystemExit("fatal: read-back verification failed (submap not found)")
    verify_flat = decode_terrain(verify_submap["terrain"])
    if len(verify_flat) != SEEX * SEEY or verify_flat[idx] != WALL_TER:
        raise SystemExit("fatal: read-back verification failed (tiles=%d, witness='%s')"
                         % (len(verify_flat), verify_flat[idx] if idx < len(verify_flat) else "?"))

    print("created world  : %s" % dst)
    print("placed wall    : %s at within-submap (%d,%d) (was %s)" % (WALL_TER, wx, wy, EXPECTED_TER))
    print("next           : validate with docs/arcopolis/client_harness_regression.ps1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
