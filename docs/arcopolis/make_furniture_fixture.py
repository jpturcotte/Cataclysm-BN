#!/usr/bin/env python3
"""Arcopolis Spike 15 - build the backend-driven query_popup (query_yn) witness fixture.

Creates the ``ArcopolisDeployedFurnitureTest`` world by CLONING the canonical ``ArcopolisTest`` world and
injecting ONE deployed furniture (``f_floor_mattress``) onto a CLEAN floor tile one tile EAST of the avatar.

WHY this furniture / this tile:
  * ``f_floor_mattress`` (data/json/furniture_and_terrain/furniture-sleep.json) has
    ``examine_action: "deployed_furniture"`` and ``deployed_item: "mattress"``. Examining it runs
    ``iexamine::deployed_furniture`` (src/iexamine.cpp), whose FIRST and ONLY prompt is
    ``query_yn("Take down the %s?")`` -- the Spike 15 witness query_popup ("YESNO" input_context). On YES,
    ``take_down_deployed_furniture`` (src/map_utils.cpp) removes the furniture and drops a real ``mattress``
    item (proven side-effect-only by tests/deployed_furniture_test.cpp); on NO nothing changes. The avatar
    never moves.
  * The EAST tile (offset +1,0,0) is plain ``t_floor`` with NO existing furniture and NO existing items
    (verified by this tool, which ABORTS otherwise) -- so the examine reaches the furniture cleanly, the NO
    path leaves the tile untouched, and the YES path's only follow-on is the dropped mattress (which the
    examine pickup tail auto-cancels via the existing nested-input guard). EAST is deliberately away from
    the NPC (north, a creature -- not submap furniture) and the south ground-item pile used by other gates.

The regression (``docs/arcopolis/query_popup_regression.ps1``) drives ``examine direction=move_e`` against
this tile; the backend exposes the take-down query_yn as a ``prompt`` (kind="query_popup") and drives the
real ``input_context("YESNO")`` loop at level 4.

If a future BN sync renames or deprecates ``f_floor_mattress`` (or removes its ``deployed_furniture``
examine action / ``deployed_item``), choose another real BN furniture with ``examine_action:
"deployed_furniture"`` + a valid ``deployed_item`` and update ``WITNESS_FURN`` here AND the Gate text-match
patterns in ``query_popup_regression.ps1``. DO NOT invent JSON.

WHY save-injection (same rationale as ``make_capacity_fixture.py`` / ``make_vehicle_fixture.py``):
  * Scriptable, reproducible, needs NO interactive client and NO build -- one ``python`` invocation.
  * NOT "faking engine state": furniture is a normal submap field; this authors an INITIAL world
    condition (a deployed mattress on a floor tile), exactly what a player who dropped one would leave.
    Nothing engine-internal is mutated at runtime.

WHERE the furniture lives:
  * Submap furniture lives in the ``.map`` (``map.sqlite3``) ``furniture`` field, a sparse array of
    ``[wx, wy, "f_id"]`` entries (src/savegame_json.cpp save ~:4417, load ~:4644). This tool appends one
    entry at the witness tile, then rewrites the zlib-compressed row. ``ArcopolisTest`` stays untouched.

This is a developer fixture tool: stdlib-only, read-only on ``ArcopolisTest``, only writes the new world
folder. Run it, then validate with ``docs/arcopolis/query_popup_regression.ps1``.

Usage::

    python docs/arcopolis/make_furniture_fixture.py            # defaults
    python docs/arcopolis/make_furniture_fixture.py --force    # overwrite an existing dest world
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

# The witness furniture id. See module docstring for the criteria it must satisfy and the swap procedure if
# this id ever stops meeting them. (data/json/furniture_and_terrain/furniture-sleep.json, verified 2026-06-16.)
WITNESS_FURN = "f_floor_mattress"
# The witness tile must be plain passable floor so the take-down drop has somewhere to land and nothing
# else is examinable/pickable there. (Any of t_floor's neighbours of the avatar are floor in ArcopolisTest.)
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
    """Decode the submap ``terrain`` RLE into a flat list of 144 ids, indexed row-major: index = y*SEEX + x
    (y outer, x inner). The engine loader (src/savegame_json.cpp) writes ter[sm_ms.x()][sm_ms.y()] while
    iterating submap_tiles() (src/coordinates.h), which spans the submap with a point_range whose operator++
    (src/map_iterator.h) advances x first (inner), y on wrap (outer) -- so RLE element N is the tile at
    x = N % SEEX, y = N // SEEX. Each element is a string (one tile) or a ``[id, count]`` run."""
    flat = []
    for e in arr:
        if isinstance(e, list):
            flat += [e[0]] * e[1]
        else:
            flat.append(e)
    return flat


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
        description="Build the ArcopolisDeployedFurnitureTest query_popup (query_yn) witness fixture.")
    parser.add_argument("--fixture-root", default=DEFAULT_FIXTURE_ROOT,
                        help="userdir holding save/<world> (default: the AGENTS.md fixture root)")
    parser.add_argument("--source-world", default="ArcopolisTest", help="world to clone (read-only)")
    parser.add_argument("--dest-world", default="ArcopolisDeployedFurnitureTest", help="world to create")
    parser.add_argument("--offset", default="1,0,0",
                        help="witness-tile offset from the avatar as dx,dy,dz. DEFAULT 1,0,0 is the clean "
                             "floor tile one EAST of the avatar -- the tile an `examine direction=move_e` "
                             "targets. The deployed furniture is placed there.")
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
    print("witness furn   : %s" % WITNESS_FURN)

    # Read the source submap (read-only) and ASSERT the witness tile is a clean floor tile BEFORE cloning,
    # so a stale offset/world drift fails loud instead of producing a broken witness.
    src_db = os.path.join(src, "map.sqlite3")
    _, src_submaps = read_submap_file(src_db, path)
    if src_submaps is None:
        raise SystemExit("fatal: map file row not found: %s (is the witness tile in the saved bubble?)" % path)
    src_submap = next((s for s in src_submaps if s.get("coordinates") == [sx, sy, tz]), None)
    if src_submap is None:
        raise SystemExit("fatal: submap (%d,%d,%d) not present in %s" % (sx, sy, tz, path))
    ter = decode_terrain(src_submap["terrain"])[wy * SEEX + wx]
    if ter != EXPECTED_TER:
        raise SystemExit("fatal: witness tile terrain is '%s', expected '%s' -- pick a clean floor offset"
                         % (ter, EXPECTED_TER))
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
    submap.setdefault("furniture", []).append([wx, wy, WITNESS_FURN])
    write_submap_file(db, path, submaps, compressed)

    print("created world  : %s" % dst)
    print("placed furn    : %s at within-submap (%d,%d) on %s" % (WITNESS_FURN, wx, wy, ter))
    print("next           : validate with docs/arcopolis/query_popup_regression.ps1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
