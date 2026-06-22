#!/usr/bin/env python3
"""Arcopolis Spike 23 - build the deterministic aligned two-floor stair witness fixture.

Creates the ``ArcopolisStairsTest`` world by CLONING the canonical ``ArcopolisTest`` world and
writing a MATCHED stair pair into the avatar's column WITHOUT moving the avatar:

  * z=0  (the avatar's OWN tile)         : ``t_floor``           -> ``t_stairs_down`` (flag GOES_DOWN)
  * z=-1 (directly below, same x,y)      : ``t_linoleum_white``  -> ``t_stairs_up``   (flag GOES_UP)

This is a FIXTURE-ONLY spike. It does NOT add any Arcopolis ``move_up`` / ``move_down`` command
support and proves NO vertical movement. The NEXT spike (Spike 24) is the ``move_down`` backend-input
witness that drives THIS fixture. The avatar starts standing ON ``t_stairs_down``, so the intended
first witness is a single ``move_down``; ``move_up`` is a later follow-up (a sibling fixture or the
resulting lower-floor position) and is deliberately NOT presented as equally ready here.

WHY a matched aligned pair (the load-bearing determinism requirement, docs/arcopolis/47 section 4):
  * ``game::vertical_move`` (src/game.cpp) -> ``find_stairs`` has a deterministic FAST PATH: descending
    one z returns the tile DIRECTLY BELOW at the same (x,y) iff it carries ``TFLAG_GOES_UP``
    (src/game.cpp:14840-14846). Hitting it pins the destination and raises NO prompt.
  * If the fast path MISSES, ``find_or_make_stairs`` FABRICATES a stair and raises up to four
    lava/deep-water/no-return ``query_yn`` confirms (src/game.cpp:14911-14939); and ``find_stairs``
    raises a "push past?" ``query_yn`` if a CREATURE occupies the chosen tile (src/game.cpp:14885-14887).
    Under Arcopolis any of those is an unexpected prompt -> fail loud, never a clean witness.
  * So the fixture asserts: (1) the avatar's current tile becomes the GOES_DOWN stair; (2) the
    counterpart GOES_UP stair sits directly below at the same (x,y); (3) no creature on either tile.
    All three => no climb diversion, no fabrication, no query_yn, deterministic descend.

WHY these terrain ids / these tiles:
  * ``t_stairs_down`` / ``t_stairs_up``
    (data/json/furniture_and_terrain/terrain-zlevel-transitions.json:119,142) are the stock BN stair
    pair: ``move_cost 2`` (passable), flags ``GOES_DOWN`` / ``GOES_UP``, and NONE of the prompt-raising
    flags (no DEEP_WATER, no lava) -- so traversal hits the clean fast path.
  * The avatar's own z=0 tile is plain ``t_floor`` (no furniture, no items, no spawns -- this tool
    ABORTS otherwise), and the tile directly below at z=-1 is ``t_linoleum_white`` (a finished
    basement floor in ArcopolisTest's already-saved bubble). Both submaps ALREADY EXIST in the saved
    ``map.sqlite3``, so this needs only two terrain edits -- NO submap synthesis/injection.

WHY NOT move the avatar onto an existing stair instead:
  * BN's loader recomputes the reality-bubble origin from ``player.abs_pos`` (src/savegame.cpp:350-352);
    shifting ``abs_pos`` across a submap boundary moves the bubble origin and fires mapgen on the new
    edge submaps (src/map.cpp:8725-8744) -- non-deterministic. So this tool leaves ``abs_pos`` UNTOUCHED
    and instead mutates terrain under the stationary avatar. The fixture's load-time determinism profile
    is therefore byte-identical to ``ArcopolisTest`` except for the two edited terrain cells.

NPC-topology limit (read this before reusing for a moved-avatar fixture):
  * This tool asserts no MONSTER on either stair tile (``active_monsters[*].pos_abs`` scan) and
    ``stair_monsters == []``. It does NOT scan NPCs, because NPCs live in the overmap files, not the
    ``.sav``. That is sufficient HERE only because the topology guarantees it: the z=0 stair is the
    avatar's own tile (never occupied by the shelter NPC Edwardo, who sits one tile NORTH per
    docs/arcopolis/TEST_FIXTURES.md), and the z=-1 stair is in a basement no NPC visits. A later spike
    that MOVES the avatar or changes NPC placement must add an overmap-NPC scan.

WHY save-injection (same rationale as make_wall_fixture.py / make_furniture_fixture.py):
  * Scriptable, reproducible, needs NO interactive client and NO build -- one ``python`` invocation.
  * NOT "faking engine state": terrain is a normal submap field; this authors an INITIAL world
    condition (a matched stair pair), exactly what a mapgen/build would leave. Nothing engine-internal
    is mutated at runtime.

WHERE the terrain lives:
  * Submap terrain lives in the ``.map`` (``map.sqlite3``) ``terrain`` field as an RLE array of id
    strings and ``[id, count]`` runs, indexed ROW-MAJOR (y outer, x inner: index = y*SEEX + x). This
    tool decodes it, sets the one witness tile per z-level, re-encodes the full 144-tile RLE, and
    rewrites the zlib-compressed row. ``ArcopolisTest`` stays untouched.

If a future BN sync renames/removes ``t_stairs_down`` / ``t_stairs_up`` (or drops their GOES_DOWN /
GOES_UP flags), or changes the avatar tile's ``t_floor`` / the basement ``t_linoleum_white``, this tool
FAILS LOUD at its precondition asserts. Pick another stock GOES_DOWN/GOES_UP stair pair and update the
constants below AND docs/arcopolis/stairs_fixture_regression.ps1. DO NOT invent JSON.

External-editor inspiration note (Checkpoint 3.5, INSPIRATION ONLY -- not evidence of native BN
behavior): public CDDA save/map editors were reviewed for ideas only. ``teplinsky-maxim/cdda-save-editor``
preserves the save's JSON structure on edit and reports z-aware ``[x,y,z]`` coordinates -- both already
embodied here (structure-preserving ``json``; z-aware coordinate printing). We deliberately use
deterministic repo-local REGENERATION (this generator IS the reproducible source) rather than committing
transient timestamped backups, per docs/arcopolis/fixtures/README.md ("do not commit backups").
``olanti-p/cata-mapgen-editor`` (ID validation; on maintenance hold) and the historical
``TinyWolfGirl/Cataclysm-DDA-Map-Editor`` informed nothing beyond confirming map-editor attempts exist.
No external code is vendored and no technique was adopted beyond the existing ``make_*_fixture.py``
precedent.

This is a developer fixture tool: stdlib-only, read-only on ``ArcopolisTest``, only writes the new world
folder. Run it, then validate with ``docs/arcopolis/stairs_fixture_regression.ps1``.

Usage::

    python docs/arcopolis/make_stairs_fixture.py             # build/refresh ArcopolisStairsTest
    python docs/arcopolis/make_stairs_fixture.py --force      # overwrite an existing dest world
    python docs/arcopolis/make_stairs_fixture.py --check-only # assert preconditions (+ read-back if dest
                                                              # exists) WITHOUT writing -- used by the gate
"""

import argparse
import glob
import json
import os
import shutil
import sqlite3
import sys
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

# The witness stair pair. See module docstring for the criteria they must satisfy and the swap procedure
# if these ids ever stop meeting them. (terrain-zlevel-transitions.json:119,142, verified 2026-06-22:
# move_cost 2, GOES_DOWN / GOES_UP, no prompt-raising flags.)
STAIRS_DOWN_TER = "t_stairs_down"   # written at z=0 (the avatar's own tile)
STAIRS_UP_TER = "t_stairs_up"       # written at z=-1 (directly below, same x,y)
# The witness tiles must be these plain passable floors BEFORE the swap, so the stairs are the only
# difference from the clone (and a future BN floor rename fails loud here rather than producing a broken
# witness).
EXPECTED_TER_Z0 = "t_floor"           # avatar's own z=0 tile in ArcopolisTest
EXPECTED_TER_ZM1 = "t_linoleum_white"  # the basement tile directly below it (z=-1)


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
    (y outer, x inner): index = y*SEEX + x -- verified empirically against the loaded snapshot and the
    engine loader (see make_wall_fixture.py / make_furniture_fixture.py). Each element is a string (one
    tile) or a ``[id, count]`` run."""
    flat = []
    for e in arr:
        if isinstance(e, list):
            flat += [e[0]] * e[1]
        else:
            flat.append(e)
    return flat


def encode_terrain(flat):
    """Re-encode a flat list of terrain ids into the submap RLE the loader accepts: a run of length 1 is
    a bare id string; a run of length N>1 is ``[id, N]`` (the inverse of decode_terrain; the loader
    decodes both forms, so this round-trips exactly)."""
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


def submap_of(tx, ty, tz):
    """Return ``(sx, sy, wx, wy)`` for an absolute map-square (tx,ty,tz): the containing submap and the
    within-submap offset."""
    sx, sy = tx // SEEX, ty // SEEY
    return sx, sy, tx - sx * SEEX, ty - sy * SEEY


def get_clean_floor_submap(db, tx, ty, tz, expected_ter, label):
    """Read the submap holding (tx,ty,tz) and assert the witness tile is a clean ``expected_ter`` floor
    (right terrain, no furniture, no items). Returns ``(path, compressed, submaps, submap, wx, wy)`` for
    the caller to edit/read-back. Fails loud on any drift."""
    sx, sy, wx, wy = submap_of(tx, ty, tz)
    path = map_file_path(sx, sy, tz)
    compressed, submaps = read_submap_file(db, path)
    if submaps is None:
        raise SystemExit("fatal: %s map file row not found: %s (is the tile in the saved bubble?)"
                         % (label, path))
    submap = next((s for s in submaps if s.get("coordinates") == [sx, sy, tz]), None)
    if submap is None:
        raise SystemExit("fatal: %s submap (%d,%d,%d) not present in %s" % (label, sx, sy, tz, path))
    flat = decode_terrain(submap["terrain"])
    if len(flat) != SEEX * SEEY:
        raise SystemExit("fatal: %s decoded terrain has %d tiles, expected %d"
                         % (label, len(flat), SEEX * SEEY))
    idx = wy * SEEX + wx  # ROW-MAJOR (y outer, x inner): within-submap (wx,wy) -> flat index wy*SEEX+wx
    if flat[idx] != expected_ter:
        raise SystemExit("fatal: %s tile terrain is '%s', expected '%s' -- world drift; see the swap "
                         "procedure in this tool's docstring" % (label, flat[idx], expected_ter))
    existing_furn = [e for e in submap.get("furniture", []) if e[0] == wx and e[1] == wy]
    if existing_furn:
        raise SystemExit("fatal: %s tile already has furniture %s -- not a clean stair tile"
                         % (label, existing_furn))
    nitems = items_count_at(submap, wx, wy)
    if nitems:
        raise SystemExit("fatal: %s tile already has %d ground item(s) -- not a clean stair tile"
                         % (label, nitems))
    return path, compressed, submaps, submap, wx, wy


def assert_no_creature(data, tiles):
    """Assert no engine creature sits on any tile in ``tiles`` (each ``[x,y,z]``). Scans the in-bubble
    ``active_monsters[*].pos_abs`` and asserts the ``stair_monsters`` channel (the one find_stairs's
    push-past prompt would populate) is empty. NPCs are NOT scanned -- see the NPC-topology limit in the
    module docstring; the fixture topology guarantees no NPC on either stair tile."""
    for m in data.get("active_monsters", []):
        if list(m.get("pos_abs", [])) in tiles:
            raise SystemExit("fatal: a monster occupies a stair tile (pos_abs %s) -- find_stairs would "
                             "raise a push-past query_yn; pick a clear column" % m.get("pos_abs"))
    if data.get("stair_monsters"):
        raise SystemExit("fatal: stair_monsters is non-empty (%d) -- a creature is mid-stair-transit; "
                         "the fixture column must be clear" % len(data.get("stair_monsters")))


def verify_world(world_dir):
    """Read-back: assert the produced world carries the matched stair pair (t_stairs_down at the avatar's
    z=0 tile, t_stairs_up directly below at z=-1), each in an intact 144-tile submap. Used after the write
    and standalone by ``--check-only`` when the dest world exists. Raises SystemExit on any mismatch."""
    data = load_sav(world_dir)
    ax, ay, az = data["player"]["abs_pos"]
    db = os.path.join(world_dir, "map.sqlite3")
    for (tx, ty, tz, want, label) in (
        (ax, ay, az, STAIRS_DOWN_TER, "z=0 down-stair"),
        (ax, ay, az - 1, STAIRS_UP_TER, "z=-1 up-stair"),
    ):
        sx, sy, wx, wy = submap_of(tx, ty, tz)
        path = map_file_path(sx, sy, tz)
        _, submaps = read_submap_file(db, path)
        submap = next((s for s in submaps if s.get("coordinates") == [sx, sy, tz]), None) if submaps else None
        if submap is None:
            raise SystemExit("fatal: read-back failed -- %s submap (%d,%d,%d) not found" % (label, sx, sy, tz))
        flat = decode_terrain(submap["terrain"])
        if len(flat) != SEEX * SEEY or flat[wy * SEEX + wx] != want:
            raise SystemExit("fatal: read-back failed -- %s is '%s' (expected '%s'), tiles=%d"
                             % (label, flat[wy * SEEX + wx] if wy * SEEX + wx < len(flat) else "?", want,
                                len(flat)))
    # Read-back also re-asserts the no-creature invariant on the DEST itself (not only the source), so a
    # committed/regenerated world that drifted to carry a monster or a mid-transit stair_monster on either
    # stair tile FAILS the read-back / regression gate rather than passing on terrain alone.
    assert_no_creature(data, [[ax, ay, az], [ax, ay, az - 1]])
    print("read-back ok   : %s @ %s (z=0) + %s @ (%d,%d,%d) (z=-1)"
          % (STAIRS_DOWN_TER, [ax, ay, az], STAIRS_UP_TER, ax, ay, az - 1))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Build the ArcopolisStairsTest aligned two-floor stair witness fixture (Spike 23).")
    parser.add_argument("--fixture-root", default=_default_fixture_root(),
                        help="userdir holding save/<world> (default: the AGENTS.md fixture root)")
    parser.add_argument("--source-world", default="ArcopolisTest", help="world to clone (read-only)")
    parser.add_argument("--dest-world", default="ArcopolisStairsTest", help="world to create")
    parser.add_argument("--check-only", action="store_true",
                        help="assert source preconditions (and read-back the dest if it exists) WITHOUT "
                             "writing -- used by the regression gate")
    parser.add_argument("--force", action="store_true", help="overwrite an existing dest world")
    args = parser.parse_args(argv)

    save_root = os.path.join(args.fixture_root, "save")
    src = os.path.join(save_root, args.source_world)
    dst = os.path.join(save_root, args.dest_world)
    if not os.path.isdir(src):
        raise SystemExit("fatal: source world not found: save/%s" % args.source_world)
    # Refuse to overwrite the source world: a --dest-world equal to --source-world would rmtree the source
    # below (under --force) and then fail the copytree, destroying the canonical base world.
    if os.path.abspath(src) == os.path.abspath(dst):
        raise SystemExit("fatal: --dest-world must differ from --source-world (refusing to overwrite the "
                         "source world '%s')" % args.source_world)

    # Avatar abs_pos (read-only). The avatar's own tile becomes the down-stair; the tile directly below
    # becomes the up-stair. The avatar is NEVER moved (see the docstring's bubble-origin rationale).
    data = load_sav(src)
    ax, ay, az = data["player"]["abs_pos"]
    down_tile = [ax, ay, az]
    up_tile = [ax, ay, az - 1]
    print("source world   : save/%s" % args.source_world)  # fixture-root-relative (AGENTS.md:273 no-local-paths)
    print("avatar abs_pos : %s (unchanged -- stairs are written under the stationary avatar)" % [ax, ay, az])
    print("down-stair tile: abs %s -> %s" % (down_tile, STAIRS_DOWN_TER))
    print("up-stair tile  : abs %s -> %s" % (up_tile, STAIRS_UP_TER))

    # Preconditions on the SOURCE (read-only): both tiles are clean floors, both submaps exist, no
    # creature on either tile. Fail loud on drift BEFORE cloning so a stale offset/world never produces a
    # broken witness.
    src_db = os.path.join(src, "map.sqlite3")
    if not os.path.exists(src_db):
        # Guard before any sqlite3.connect(): a missing source db would otherwise be implicitly CREATED as
        # an empty file in the read-only source world, then fail with an opaque "no such table" error.
        raise SystemExit("fatal: source map database not found: save/%s/map.sqlite3" % args.source_world)
    get_clean_floor_submap(src_db, ax, ay, az, EXPECTED_TER_Z0, "z=0 down-stair")
    get_clean_floor_submap(src_db, ax, ay, az - 1, EXPECTED_TER_ZM1, "z=-1 up-stair")
    assert_no_creature(data, [down_tile, up_tile])
    print("preconditions  : ok (both tiles clean floors in existing submaps; no creature on either)")

    if args.check_only:
        if os.path.isdir(dst):
            verify_world(dst)
            print("check-only     : preconditions + dest read-back both pass")
        else:
            print("check-only     : preconditions pass (dest world does not exist yet; nothing to read back)")
        return 0

    if os.path.exists(dst):
        if not args.force:
            raise SystemExit("fatal: %s already exists (use --force to overwrite)" % dst)
        shutil.rmtree(dst)
    shutil.copytree(src, dst)

    # Apply the two terrain edits on the CLONED map.sqlite3.
    dst_db = os.path.join(dst, "map.sqlite3")
    for (tx, ty, tz, expected, want, label) in (
        (ax, ay, az, EXPECTED_TER_Z0, STAIRS_DOWN_TER, "z=0 down-stair"),
        (ax, ay, az - 1, EXPECTED_TER_ZM1, STAIRS_UP_TER, "z=-1 up-stair"),
    ):
        path, compressed, submaps, submap, wx, wy = get_clean_floor_submap(dst_db, tx, ty, tz, expected, label)
        flat = decode_terrain(submap["terrain"])
        flat[wy * SEEX + wx] = want
        submap["terrain"] = encode_terrain(flat)
        write_submap_file(dst_db, path, submaps, compressed)
        print("placed stair   : %s at submap (%d,%d,%d) within (%d,%d) (was %s)"
              % (want, *submap_of(tx, ty, tz)[:2], tz, wx, wy, expected))

    # Read-back sanity on the produced world.
    verify_world(dst)

    print("created world  : save/%s" % args.dest_world)  # fixture-root-relative (AGENTS.md:273 no-local-paths)
    print("next           : validate with docs/arcopolis/stairs_fixture_regression.ps1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
