#!/usr/bin/env python3
"""Arcopolis Spike 14 - build the secondary capacity/wield/spill `uilist` multi-entry witness fixture.

Creates the ``ArcopolisCapacityTest`` world by CLONING the canonical ``ArcopolisTest`` world and injecting
ONE bulky armor item onto the existing 7-item ground pile one tile south of the post-``move_s`` avatar.
The injected item is an exact ``jacket_leather`` (data/json/items/armor/coats.json: ARMOR, 4500 ml volume,
1450 g, OUTER + torso/arms): is_armor() == true (so the engine's handle_problematic_pickup adds a WEAR
entry, src/pickup.cpp:193-195), it does NOT conflict with the ArcopolisTest avatar's basic clothing (so
WEAR is `enabled:true`), its 4500 ml exceeds the default avatar's tiny volume capacity (so
handle_problematic_pickup is REACHED at all, src/pickup.cpp:350-358), and it is neither a bucket nor a
container with children (so SPILL/EMPTY are NOT added, keeping the uilist at exactly **WEAR + WIELD = 2
entries** -- the multi-entry navigation witness Spike 14 needs to prove `[DOWN, CONFIRM]` selection of
WIELD or `[CONFIRM]` selection of WEAR through the real `input_context("UILIST")` loop).

If a future BN sync renames or deprecates ``jacket_leather``, or it stops meeting these criteria for any
reason, choose another real BN ARMOR item with the same shape (>capacity volume, can_wear succeeds, not a
bucket, no children) and document the swap here AND in
``docs/arcopolis/34_SPIKE14_SECONDARY_PICKUP_UILIST.md``. DO NOT invent JSON.

WHY save-injection (same rationale as ``make_vehicle_fixture.py``):
  * Scriptable, reproducible, needs NO interactive client and NO build -- one ``python`` invocation.
  * NOT "faking engine state": the injected item carries every field the engine serialized for a real
    pile item (deep-copied from one of the existing 7 ground items), with only ``typeid`` overridden to
    ``jacket_leather``. The engine's ``item::deserialize`` then uses the prototype for type-specific
    fields. This authors an INITIAL world condition; nothing engine-internal is mutated at runtime.

WHERE the item lives:
  * Ground items live in the submap ``.map`` (``map.sqlite3``) ``items`` field, a flat
    ``[wx, wy, [stack], wx, wy, [stack], ...]`` array (verified by ``stack_at`` in the vehicle fixture).
  * This tool appends the new item to the existing pile's stack list at the witness tile, then rewrites
    the zlib-compressed row. ``ArcopolisTest`` stays untouched (read-only).

This is a developer fixture tool: stdlib-only, read-only on ``ArcopolisTest``, only writes the new world
folder. Run it, then validate with ``docs/arcopolis/prompt_menu_regression.ps1`` (Gate J).

Usage::

    python docs/arcopolis/make_capacity_fixture.py            # defaults
    python docs/arcopolis/make_capacity_fixture.py --force    # overwrite an existing dest world
"""

import argparse
import copy
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

# The witness item id. See module docstring for the criteria it must satisfy and the swap procedure if
# this id ever stops meeting them. (data/json/items/armor/coats.json, verified 2026-06-16.)
WITNESS_TYPEID = "jacket_leather"


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
    BN groups 4 submaps per .map file at fx=sx//2, fy=sy//2: maps/<fx//32>.<fy//32>.<z>/<fx>.<fy>.<z>.map.
    (Same helper as make_vehicle_fixture.py; kept duplicated so each fixture script is standalone.)"""
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


def stack_at_index(submap, wx, wy):
    """Return the index into submap['items'] where the (wx,wy) pile's stack list lives, or None.
    submap['items'] is a flat array of [wx, wy, [stack], wx, wy, [stack], ...] triples. Returning the
    index (rather than the list) lets the caller mutate the stack in place via items[idx]."""
    items = submap.get("items", [])
    for i in range(0, len(items) - 2, 3):
        if items[i] == wx and items[i + 1] == wy:
            return i + 2
    return None


def build_witness_item(template, turn):
    """Return a deep copy of ``template`` with typeid swapped to the witness id. Mirrors the vehicle
    fixture's deep-copy approach: every serialized field (bday/damaged/owner/etc) carries through, so the
    engine's item::deserialize sees a fully-formed item; only typeid is replaced, which causes the engine
    to resolve the jacket_leather prototype for type-specific fields. count_by_charges/charges fields (if
    any on the template) are reset so a stack-count item does not become a non-charge armor with a stale
    charges value."""
    item = copy.deepcopy(template)
    item["typeid"] = WITNESS_TYPEID
    # Reset fields that are meaningful only for the template's type and would be stale on an armor item.
    # The engine's loader allow_omitted_members for these; explicit reset keeps the JSON tidy and avoids
    # any chance of the deserializer keying off a leftover charges/poison/etc tag the prototype does not use.
    for stale in ("charges", "poison", "frequency", "active", "components"):
        item.pop(stale, None)
    # bday is fine to keep (real engine items have it); but if the template was older, refresh it to the
    # current turn so the item is "fresh" on the witness tile and not pre-rotted.
    if "bday" in item:
        item["bday"] = turn
    return item


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Build the ArcopolisCapacityTest secondary-capacity multi-entry witness fixture.")
    parser.add_argument("--fixture-root", default=DEFAULT_FIXTURE_ROOT,
                        help="userdir holding save/<world> (default: the AGENTS.md fixture root)")
    parser.add_argument("--source-world", default="ArcopolisTest", help="world to clone (read-only)")
    parser.add_argument("--dest-world", default="ArcopolisCapacityTest", help="world to create")
    parser.add_argument("--offset", default="0,2,0",
                        help="witness-tile offset from the avatar as dx,dy,dz. DEFAULT 0,2,0 is the "
                             "ground-item pile one south of the post-move_s avatar -- the tile a "
                             "`pickup direction=move_s` (after `move_s`) targets. The new armor item "
                             "is appended onto that pile.")
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
    print("witness item   : %s" % WITNESS_TYPEID)

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

    idx = stack_at_index(submap, wx, wy)
    if idx is None:
        raise SystemExit("fatal: no ground-item pile at within-submap (%d,%d) -- the witness needs an "
                         "existing pile to append to (pick an offset over the pile)." % (wx, wy))
    pile = submap["items"][idx]
    if not pile:
        raise SystemExit("fatal: pile at within-submap (%d,%d) is empty; "
                         "no template item to deep-copy." % (wx, wy))

    # Deep-copy a real engine-written ground item as the template (so the new item carries every field the
    # engine serialized), override typeid -> jacket_leather, append to the stack.
    item = build_witness_item(pile[0], turn)
    pile.append(item)
    write_submap_file(db, path, submaps, compressed)

    print("created world  : %s" % dst)
    print("appended item  : %s onto pile at within-submap (%d,%d) (template typeid '%s')"
          % (WITNESS_TYPEID, wx, wy, pile[0].get("typeid", "?")))
    print("pile size      : %d -> %d items" % (len(pile) - 1, len(pile)))
    print("next           : validate with docs/arcopolis/prompt_menu_regression.ps1 (Gate J)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
