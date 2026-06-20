#!/usr/bin/env python3
"""Arcopolis Spike 12A follow-up - build the vehicle-cargo + ground-items witness fixture.

Creates the ``ArcopolisVehicleCargoTest`` world by CLONING the canonical ``ArcopolisTest`` world and
injecting a single-tile cargo vehicle ON the tile that already holds the deterministic ground-item pile
(one tile south of where the avatar stands after one ``move_s``). That tile then has BOTH vehicle cargo
AND ground items, which is exactly the condition ``pickup::pick_up`` checks before opening the
``uilist( "Get items from where?" )`` submenu (src/pickup.cpp:1264-1275, the ``veh_has_items &&
map_has_items`` branch). The Spike 12A prompt/menu transaction does not drive that submenu, so the
follow-up makes a live ``pickup`` toward this tile FAIL LOUD (``unsupported_command``) instead of
silently auto-cancelling and reporting success. See
``docs/arcopolis/31_SPIKE12A_FOLLOWUP_FAIL_LOUD.md``.

WHY save-injection instead of the graphical debug "spawn vehicle":
  * It is scriptable, reproducible, and needs NO interactive client and NO build -- the whole fixture is
    one ``python`` invocation, exactly like ``make_monster_fixture.py``.
  * It is NOT "faking engine state": the engine deserializes the injected object into a real vehicle (it
    resolves the prototype + part types and rebuilds the derived structures in ``vehicle::refresh`` on
    load). This only authors an INITIAL world condition, like the GUI debug spawn would.

HOW it stays valid (no engine vehicle exists in ``ArcopolisTest`` to deep-copy, unlike the monster tool):
  * The vehicle is an EXACT structural replica of the stock ``folding_wagon`` prototype
    (data/json/vehicles/carts.json) -- a real single-tile cart whose one mount (0,0) stacks
    ``folding_frame`` (structure, INITIAL_PART), ``wheel_caster`` (wheel), and ``basketlg_folding``
    (the CARGO basket). All three are real part ids; ``vehicle_part::deserialize`` spawns each part's
    own base item from ``id.obj().item`` when ``base`` is omitted (src/savegame_json.cpp:3035-3040), so
    no item is hand-authored for the parts.
  * The CARGO item is a DEEP COPY of a real engine-written ground item already in the pile (so it carries
    every field the engine serialized), placed in the basket part's ``items`` list -- the same list
    ``vehicle::get_items`` reads (src/pickup.cpp:1266).
  * Only the save fields the loader actually reads are written; ``vehicle::deserialize`` and
    ``vehicle_part::deserialize`` both ``allow_omitted_members()`` and ``data.read`` with defaults
    (src/savegame_json.cpp:3236-3442, :2968-3118), and ``read_saved_vehicle_parts`` SKIPS (warns, never
    aborts) an unreadable part (:3212-3229).

Vehicles live in the submap ``.map`` (``map.sqlite3``), NOT the ``.sav`` (unlike active monsters): on
world load the engine reads each submap's ``vehicles`` array into the active map. So this tool edits the
submap that contains the witness tile, appends one vehicle to its ``vehicles`` list, and rewrites the
zlib-compressed row. ``ArcopolisTest`` stays untouched (read-only).

This is a developer fixture tool: stdlib-only, read-only on ``ArcopolisTest``, and it only writes the new
world folder. Run it, then validate with ``docs/arcopolis/prompt_menu_regression.ps1`` (the P1 gate).

Usage::

    python docs/arcopolis/make_vehicle_fixture.py            # defaults (pile tile, folding_wagon)
    python docs/arcopolis/make_vehicle_fixture.py --force    # overwrite an existing dest world
"""

import argparse
import copy
import glob
import json
import os
import shutil
import sqlite3
import zlib

# Resolve the fixture root with the same precedence as the *_regression.ps1 scripts:
# ARCO_FIXTURE_ROOT env override > repo-local committed pack (docs/arcopolis/fixtures/arcopolis_user)
# > optional external dev fallback (C:\dev\arcopolis-fixtures, an AGENTS.md-approved non-sensitive path).
# Pass --fixture-root to override explicitly. See docs/arcopolis/fixtures/README.md.
def _default_fixture_root() -> str:
    env = os.environ.get("ARCO_FIXTURE_ROOT")
    if env:
        return env
    repo_local = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "arcopolis_user")
    if os.path.isdir(repo_local):
        return repo_local
    external = r"C:\dev\arcopolis-fixtures\arcopolis_user"
    if os.path.isdir(external):
        return external
    return repo_local  # canonical target; the existing not-found checks report it clearly
SEEX = SEEY = 12  # submap side length


def load_sav(world_dir):
    """Return ``(sav_path, prefix_bytes, data)`` for a world's main .sav (one-line ``# version N`` prefix
    then the JSON object; the prefix bytes are preserved verbatim on write)."""
    matches = sorted(glob.glob(os.path.join(world_dir, "*.sav")))
    if not matches:
        raise SystemExit("fatal: no .sav file in %s" % world_dir)
    with open(matches[0], "rb") as f:
        raw = f.read()
    nl = raw.find(b"\n")
    if nl == -1 or not raw.lstrip().startswith(b"#"):
        return matches[0], b"", json.loads(raw.decode("utf-8"))
    return matches[0], raw[: nl + 1], json.loads(raw[nl + 1:].decode("utf-8"))


def map_file_path(sx, sy, z):
    """The map.sqlite3 ``files.path`` holding the 2x2 submap block that contains submap (sx,sy,z).
    BN groups 4 submaps per .map file at fx=sx//2, fy=sy//2: maps/<fx//32>.<fy//32>.<z>/<fx>.<fy>.<z>.map."""
    fx, fy = sx // 2, sy // 2
    return "maps/%d.%d.%d/%d.%d.%d.map" % (fx // 32, fy // 32, z, fx, fy, z)


def read_submap_file(db, path):
    """Return ``(was_compressed, submap_list)`` for a .map row, or ``(None, None)`` if absent. The row is
    a JSON LIST of (up to four) submap objects; the blob is zlib-compressed in this save format."""
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
    obj = json.loads(text.decode("utf-8"))
    return compressed, obj


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


def stack_at(submap, wx, wy):
    """The ground-item stack list at within-submap (wx,wy), or None. The submap ``items`` field is a flat
    array of [wx, wy, [stack], wx, wy, [stack], ...] triples (verified against the fixture)."""
    items = submap.get("items", [])
    for i in range(0, len(items) - 2, 3):
        if items[i] == wx and items[i + 1] == wy:
            return items[i + 2]
    return None


def build_vehicle(posx, posy, cargo_item, turn):
    """A faithful single-tile ``folding_wagon`` replica at within-submap (posx,posy) whose basket holds
    ``cargo_item`` (a deep copy of a real ground item). Only loader-read fields are written; everything
    else defaults via vehicle::deserialize / vehicle_part::deserialize (allow_omitted_members)."""
    def part(part_id, items=None):
        p = {"id": part_id, "mount_dx": 0, "mount_dy": 0, "carry": []}
        p["items"] = items if items is not None else []
        return p

    return {
        "type": "folding_wagon",
        "posx": posx,
        "posy": posy,
        "faceDir": 0,
        "moveDir": 0,
        "turn_dir": 0,
        "velocity": 0,
        "cruise_velocity": 0,
        "name": "Arcopolis cargo cart",
        "owner": "",
        "old_owner": "",
        "last_update_turn": turn,
        # Exact folding_wagon stack at mount (0,0): structure, wheel, then the CARGO basket with the item.
        "parts": [
            part("folding_frame"),
            part("wheel_caster"),
            part("basketlg_folding", [cargo_item]),
        ],
        "tags": [],
        "labels": [],
        "zones": [],
        "pivot": [0, 0],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Build the ArcopolisVehicleCargoTest vehicle-cargo + ground-items witness fixture.")
    parser.add_argument("--fixture-root", default=_default_fixture_root(),
                        help="userdir holding save/<world> (default: the AGENTS.md fixture root)")
    parser.add_argument("--source-world", default="ArcopolisTest", help="world to clone (read-only)")
    parser.add_argument("--dest-world", default="ArcopolisVehicleCargoTest", help="world to create")
    parser.add_argument("--offset", default="0,2,0",
                        help="witness-tile offset from the avatar as dx,dy,dz. DEFAULT 0,2,0 is the "
                             "ground-item pile one south of the post-move_s avatar -- the tile a "
                             "`pickup direction=move_s` (after `move_s`) targets. The vehicle is placed "
                             "ON this tile so it has BOTH vehicle cargo and ground items.")
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
        raise SystemExit("fatal: --offset must be dx,dy,dz integers, e.g. 0,2,0")

    # Avatar abs_pos + turn (read-only) -> the witness tile and its submap.
    _, _, data = load_sav(src)
    turn = data["turn"]
    ax, ay, az = data["player"]["abs_pos"]
    tx, ty, tz = ax + dx, ay + dy, az + dz
    sx, sy = tx // SEEX, ty // SEEY
    wx, wy = tx - sx * SEEX, ty - sy * SEEY
    path = map_file_path(sx, sy, tz)
    print("avatar abs_pos : %s (turn %d)" % ([ax, ay, az], turn))
    print("witness tile   : abs %s -> submap (%d,%d,%d) within (%d,%d)" % ([tx, ty, tz], sx, sy, tz, wx, wy))
    print("map file       : %s" % path)

    if os.path.exists(dst):
        if not args.force:
            raise SystemExit("fatal: %s already exists (use --force to overwrite)" % dst)
        shutil.rmtree(dst)
    shutil.copytree(src, dst)

    db = os.path.join(dst, "map.sqlite3")
    compressed, submaps = read_submap_file(db, path)
    if submaps is None:
        raise SystemExit("fatal: map file row not found: %s (is the witness tile in the saved bubble?)" % path)
    submap = next((s for s in submaps if s.get("coordinates") == [sx, sy, tz]), None)
    if submap is None:
        raise SystemExit("fatal: submap (%d,%d,%d) not present in %s" % (sx, sy, tz, path))

    pile = stack_at(submap, wx, wy)
    if not pile:
        raise SystemExit("fatal: no ground-item pile at within-submap (%d,%d) -- the witness needs BOTH "
                         "vehicle cargo and ground items on the same tile (pick an offset over the pile)."
                         % (wx, wy))
    if submap.get("vehicles"):
        raise SystemExit("fatal: submap (%d,%d,%d) already has a vehicle; refusing to stack one." % (sx, sy, tz))

    # Deep-copy a real engine-written ground item into the cargo so it carries every serialized field.
    cargo_item = copy.deepcopy(pile[0])
    vehicle = build_vehicle(wx, wy, cargo_item, turn)
    submap.setdefault("vehicles", []).append(vehicle)
    write_submap_file(db, path, submaps, compressed)

    print("created world  : %s" % dst)
    print("vehicle        : folding_wagon at submap pos (%d,%d) with 1 CARGO item '%s'"
          % (wx, wy, cargo_item.get("typeid", "?")))
    print("ground pile    : %d item(s) on the same tile (unchanged)" % len(pile))
    print("next           : validate with docs/arcopolis/prompt_menu_regression.ps1 (the P1 gate)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
