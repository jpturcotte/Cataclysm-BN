#!/usr/bin/env python3
"""Arcopolis Spike 26A - build the on-person dialogue-predicate witness fixture.

Creates the ``ArcopolisCarriedNestedTest`` world by CLONING the canonical ``ArcopolisBackpackTest``
world and save-editing FOUR witness items into known positions so the ``op:"query", kind:"has_item"``
regression can pin the on-person dialogue predicate (``condition.cpp`` ``set_has_items``:
``has_charges(id,count) || has_amount(id,count)``) WITHOUT drifting into ``crafting_inventory()`` reach
(Spike 26B's scope).

Why ArcopolisBackpackTest as the source world: it is the existing Spike 12A fixture whose avatar already
wears a ``backpack`` in ``player.worn`` (worn[6] verified via the .sav). The backpack item is the
container the visit_items recursion walks into (``visitable<Character>::visit_items`` iterates ``worn``
and calls ``visit_internal``, which recurses via ``contents.visit_contents`` on NEXT). Cloning it -- and
NOT regenerating it -- is the right hygiene: ``ArcopolisBackpackTest`` is GUI-created and not produced
by any committed script; this fixture inherits its committed save shape.

The four witness items (the four regression cases pin them in order):

  (1) ``CARRIED_NESTED`` — ``glass_shard``, placed inside the backpack's pocket via
      ``worn[backpack].contents = {"items": [{"typeid":"glass_shard", ...}]}``. The save format mirrors
      ``item_contents::serialize`` (``src/savegame_json.cpp`` ~:180), which emits a top-level object
      with an ``items`` array when contents is non-empty. The query ``op:"query", kind:"has_item",
      item:"glass_shard"`` must return ``has:true`` -- proves ``visit_internal`` recurses into the
      pocket. This is the load-bearing CONTAINER-RECURSION witness.

  (2) ``WIELDED`` — ``rock``, written into ``player.weapon`` (top-level field of the player object;
      serialized via ``Character::store``'s ``json.member("weapon", weapon)`` at
      ``savegame_json.cpp`` ~:894). The query for ``rock`` must return ``has:true`` -- proves the
      wielded source is visited.

  (3) ``ABSENT`` — ``hairpin``, NOT placed anywhere on the avatar. Query must return
      ``has:false``. The id is a stable BN itype_id known absent from the avatar entirely. NOT chosen
      from the existing ground pile -- the (c) discipline (plan §4) requires the id be unreachable
      from ``Character::visit_items`` on the fixture, not "off-person but visible".

  (4) ``GROUND`` — ``feather``, dropped on the AVATAR'S OWN TILE in the .map file. Query must return
      ``has:false`` -- pins anti-``crafting_inventory()`` scope. Spike 26B's broader predicate would
      flip this to ``has:true``; this case is the divergence signal that protects the labeling guard.

If a future BN sync renames or removes any of (glass_shard, rock, hairpin, feather),
swap the id here AND in ``spike26a_dialogue_predicate_regression.ps1``'s Gate name-match patterns.
Do NOT invent JSON.

This is a developer fixture tool: stdlib-only, read-only on ``ArcopolisBackpackTest``, only writes the
new world folder. Run it, then validate with ``docs/arcopolis/spike26a_dialogue_predicate_regression.ps1``.

Usage::

    python docs/arcopolis/make_carried_nested_fixture.py            # defaults
    python docs/arcopolis/make_carried_nested_fixture.py --force    # overwrite an existing dest world
"""

import argparse
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

# The four witness ids. See module docstring for the criteria each must satisfy and the swap procedure
# if any id ever stops meeting them. (verified 2026-06-23.)
CARRIED_NESTED = "glass_shard"
WIELDED = "rock"
GROUND = "feather"
# ABSENT is documented for symmetry but not placed in the fixture; the regression queries it directly.
ABSENT = "hairpin"


def load_sav(world_dir):
    """Return ``(sav_path, prefix_bytes, data)`` for a world's main .sav (one-line ``# version N``
    prefix then JSON; the prefix bytes are preserved verbatim on write)."""
    matches = sorted(glob.glob(os.path.join(world_dir, "*.sav")))
    if not matches:
        raise SystemExit("fatal: no .sav file in %s" % world_dir)
    with open(matches[0], "rb") as f:
        raw = f.read()
    nl = raw.find(b"\n")
    if nl == -1 or not raw.lstrip().startswith(b"#"):
        return matches[0], b"", json.loads(raw.decode("utf-8"))
    return matches[0], raw[: nl + 1], json.loads(raw[nl + 1:].decode("utf-8"))


def write_sav(sav_path, prefix_bytes, data):
    """Rewrite a .sav file preserving the ``# version N`` prefix line verbatim."""
    payload = json.dumps(data).encode("utf-8")
    with open(sav_path, "wb") as f:
        f.write(prefix_bytes + payload)


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


def stack_at_index(submap, wx, wy):
    """Return the index into submap['items'] where the (wx,wy) pile's stack list lives, or None.
    submap['items'] is a flat array of [wx, wy, [stack], wx, wy, [stack], ...] triples."""
    items = submap.get("items", [])
    for i in range(0, len(items) - 2, 3):
        if items[i] == wx and items[i + 1] == wy:
            return i + 2
    return None


def fresh_item(typeid, turn):
    """Return a minimal item JSON object the engine's item::deserialize will load cleanly. The engine
    allows_omitted_members on most item fields; the prototype supplies type-specific defaults. Mirrors
    the minimal shape observed in the canonical fixture's player.inv (typeid + bday + owner). Stale-only
    fields are intentionally omitted -- ``item::deserialize`` resolves them from the prototype.

    WHY no template-based approach (vs the sibling generators' ``copy.deepcopy(template_item)``): the
    sibling fixture generators (``make_capacity_fixture.py``, ``make_vehicle_fixture.py``) inject items
    onto an EXISTING ground pile and deep-copy one of the pile's items as the template -- carrying every
    serialized field the engine wrote, then overriding ``typeid``. That pattern guarantees the engine's
    item::deserialize sees a fully-formed item under any future field migration. Spike 26A's fixture
    instead places items in THREE DIFFERENT NEW slots (worn-container pocket, wielded weapon, fresh
    ground pile on the avatar's own tile) where no template item exists at any of them in the source
    save. Building from scratch is the only path; if a future BN sync adds a required item field that
    ``allow_omitted_members`` does NOT cover, this helper -- and only this helper -- needs the field
    added. A shared utility across generators is not introduced here because no existing caller would
    benefit (every other generator has a template available).
    """
    return {
        "typeid": typeid,
        "bday": turn,
        "owner": "your_followers",
        "last_rot_check": 0,
        "melee_damage_bonus": [],
        "ranged_damage_bonus": [],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Build the ArcopolisCarriedNestedTest dialogue-predicate witness fixture (Spike 26A).")
    parser.add_argument("--fixture-root", default=_default_fixture_root(),
                        help="userdir holding save/<world> (default: the AGENTS.md fixture root)")
    parser.add_argument("--source-world", default="ArcopolisBackpackTest",
                        help="world to clone (read-only; GUI-created, not regenerated)")
    parser.add_argument("--dest-world", default="ArcopolisCarriedNestedTest", help="world to create")
    parser.add_argument("--force", action="store_true", help="overwrite an existing dest world")
    args = parser.parse_args(argv)

    save_root = os.path.join(args.fixture_root, "save")
    src = os.path.join(save_root, args.source_world)
    dst = os.path.join(save_root, args.dest_world)
    if not os.path.isdir(src):
        raise SystemExit("fatal: source world not found: %s" % src)

    # Read-only validate the source world has the worn backpack at the expected index (worn[6]) before
    # cloning. A drift here fails LOUD instead of silently producing a witness that misses the nesting case.
    src_sav_path, _, src_data = load_sav(src)
    src_worn = src_data.get("player", {}).get("worn", [])
    if not src_worn:
        raise SystemExit("fatal: source world has no worn items (%s)" % src_sav_path)
    backpack_idx = next((i for i, w in enumerate(src_worn) if w.get("typeid") == "backpack"), None)
    if backpack_idx is None:
        raise SystemExit("fatal: source world's avatar has no worn 'backpack' (worn typeids: %s)"
                         % [w.get("typeid") for w in src_worn])

    ax, ay, az = src_data["player"]["abs_pos"]
    turn = src_data["turn"]
    # Witness tile for the GROUND case = the avatar's OWN tile (delta 0,0,0). The query's
    # crafting_inventory-scope divergence is sharpest on the avatar's own tile: a frontend could see
    # the item under the avatar yet observe has:false -- the dialogue predicate does not reach it.
    tx, ty, tz = ax, ay, az
    sx, sy = tx // SEEX, ty // SEEY
    wx, wy = tx - sx * SEEX, ty - sy * SEEY
    mpath = map_file_path(sx, sy, tz)
    print("avatar abs_pos : %s (turn %d)" % ([ax, ay, az], turn))
    print("worn backpack  : worn[%d] = %s" % (backpack_idx, src_worn[backpack_idx].get("typeid")))
    print("ground tile    : abs %s -> submap (%d,%d,%d) within (%d,%d)" % (
        [tx, ty, tz], sx, sy, tz, wx, wy))
    print("map file       : %s" % mpath)
    print("witness ids    : nested=%s wielded=%s ground=%s absent=%s" % (
        CARRIED_NESTED, WIELDED, GROUND, ABSENT))

    # Validate the ground tile has NO existing items at avatar's position; cloning into a dirty tile would
    # add the witness to an existing pile (which is harmless to the query but obscures the witness scope).
    src_db = os.path.join(src, "map.sqlite3")
    _, src_submaps = read_submap_file(src_db, mpath)
    if src_submaps is None:
        raise SystemExit("fatal: map file row not found: %s (is the avatar tile in the saved bubble?)" % mpath)
    src_submap = next((s for s in src_submaps if s.get("coordinates") == [sx, sy, tz]), None)
    if src_submap is None:
        raise SystemExit("fatal: submap (%d,%d,%d) not present in %s" % (sx, sy, tz, mpath))
    existing_idx = stack_at_index(src_submap, wx, wy)
    if existing_idx is not None and src_submap["items"][existing_idx]:
        print("note: avatar tile already holds %d ground item(s) -- the ground witness will join them" %
              len(src_submap["items"][existing_idx]))

    if os.path.exists(dst):
        if not args.force:
            raise SystemExit("fatal: %s already exists (use --force to overwrite)" % dst)
        shutil.rmtree(dst)
    shutil.copytree(src, dst)

    # --- Edit the .sav: nest the CARRIED_NESTED item inside the backpack pocket, wield the WIELDED item. ---
    dst_sav_path, dst_prefix, dst_data = load_sav(dst)
    dst_worn = dst_data["player"]["worn"]
    backpack = dst_worn[backpack_idx]
    # Mirror item_contents::serialize (src/savegame_json.cpp ~:180): a non-empty contents serializes as
    # {"items": [...]}, and item_contents::deserialize reads back "items" -- this is the format the
    # engine's loader expects. Single nested item is sufficient for the (a) witness; depth > 1 is
    # explicitly out of scope per the plan.
    backpack["contents"] = {
        "items": [fresh_item(CARRIED_NESTED, turn)]
    }
    # Wield WIELDED: Character::store at savegame_json.cpp ~:894 writes "weapon" as a top-level field
    # when primary_weapon().is_null() is false; the loader installs it as the wielded item.
    dst_data["player"]["weapon"] = fresh_item(WIELDED, turn)
    write_sav(dst_sav_path, dst_prefix, dst_data)

    # --- Edit the .map: drop the GROUND item onto the avatar's tile. ---
    dst_db = os.path.join(dst, "map.sqlite3")
    compressed, dst_submaps = read_submap_file(dst_db, mpath)
    dst_submap = next((s for s in dst_submaps if s.get("coordinates") == [sx, sy, tz]), None)
    ground_item = fresh_item(GROUND, turn)
    idx = stack_at_index(dst_submap, wx, wy)
    if idx is None:
        # No existing pile at the avatar tile: append a fresh triple [wx, wy, [item]].
        dst_submap.setdefault("items", []).extend([wx, wy, [ground_item]])
    else:
        dst_submap["items"][idx].append(ground_item)
    write_submap_file(dst_db, mpath, dst_submaps, compressed)

    print("created world  : %s" % dst)
    print("nested item    : %s inside worn[%d]=backpack pocket" % (CARRIED_NESTED, backpack_idx))
    print("wielded item   : %s as player.weapon" % WIELDED)
    print("ground item    : %s on avatar tile within-submap (%d,%d)" % (GROUND, wx, wy))
    print("next           : validate with docs/arcopolis/spike26a_dialogue_predicate_regression.ps1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
