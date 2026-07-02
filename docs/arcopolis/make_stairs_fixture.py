#!/usr/bin/env python3
"""Arcopolis Spike 23 - build the deterministic aligned two-floor stair witness fixture.
Spike 29 (folded) - parameterize it to N floors + an optional ground package (see the
"Spike 29 extension" section below; the DEFAULT invocation is unchanged Spike 23 behavior).

Creates the ``ArcopolisStairsTest`` world by CLONING the canonical ``ArcopolisTest`` world and
writing a MATCHED stair pair into the avatar's column WITHOUT moving the avatar:

  * z=0  (the avatar's OWN tile)         : ``t_floor``           -> ``t_stairs_down`` (flag GOES_DOWN)
  * z=-1 (directly below, same x,y)      : ``t_linoleum_white``  -> ``t_stairs_up``   (flag GOES_UP)

This is a FIXTURE-ONLY tool. It does NOT add any Arcopolis ``move_up`` / ``move_down`` command
support and proves NO vertical movement. Spike 24 is the ``move_down`` backend-input witness that
drives the default fixture; the folded Spike 29 slice witnesses drive the N-floor variants.

WHY a matched aligned pair (the load-bearing determinism requirement, docs/arcopolis/47 section 4):
  * ``game::vertical_move`` (src/game.cpp) -> ``find_stairs`` has a deterministic FAST PATH: descending
    one z returns the tile DIRECTLY BELOW at the same (x,y) iff it carries ``TFLAG_GOES_UP``
    (src/game.cpp:14840-14846). Hitting it pins the destination and raises NO prompt.
  * If the fast path MISSES, ``find_or_make_stairs`` FABRICATES a stair and raises up to four
    lava/deep-water/no-return ``query_yn`` confirms (src/game.cpp:14911-14939); and ``find_stairs``
    raises a "push past?" ``query_yn`` if a CREATURE occupies the chosen tile (src/game.cpp:14885-14887).
    Under Arcopolis any of those is an unexpected prompt -> fail loud, never a clean witness.
  * So the fixture asserts, PER FLOOR PAIR: (1) the pair's top tile carries the travel-direction
    stair (GOES_DOWN); (2) the counterpart GOES_UP stair sits directly below at the same (x,y);
    (3) no creature on either tile. All three => no climb diversion, no fabrication, no query_yn,
    deterministic traversal in BOTH directions.

WHY these terrain ids / these tiles:
  * ``t_stairs_down`` / ``t_stairs_up``
    (data/json/furniture_and_terrain/terrain-zlevel-transitions.json:119,142) are the stock BN stair
    pair: ``move_cost 2`` (passable), flags ``GOES_DOWN`` / ``GOES_UP``, and NONE of the prompt-raising
    flags (no DEEP_WATER, no lava) -- so traversal hits the clean fast path.
  * The avatar's own z=0 tile is plain ``t_floor`` (no furniture, no items, no spawns -- this tool
    ABORTS otherwise), and the tile directly below at z=-1 is ``t_linoleum_white`` (a finished
    basement floor in the source world's already-saved bubble). Both submaps ALREADY EXIST in the
    saved ``map.sqlite3``, so the DEFAULT (2-floor) build needs only two terrain edits -- NO submap
    synthesis/injection. (N-floor builds DO synthesize lower floors -- see the Spike 29 extension.)

WHY NOT move the avatar onto an existing stair instead:
  * BN's loader recomputes the reality-bubble origin from ``player.abs_pos`` (src/savegame.cpp:350-352);
    shifting ``abs_pos`` across a submap boundary moves the bubble origin and fires mapgen on the new
    edge submaps (src/map.cpp:8725-8744) -- non-deterministic. So this tool leaves ``abs_pos`` UNTOUCHED
    and instead mutates terrain under the stationary avatar. The fixture's load-time determinism profile
    is therefore byte-identical to the source world except for the edited terrain cells (and, for
    N-floor builds, the newly INSERTED lower-z rows and the package tile).

NPC-topology limit (read this before reusing for a moved-avatar fixture):
  * This tool asserts no MONSTER on any stair/package tile (``active_monsters[*].pos_abs`` scan) and
    ``stair_monsters == []``. It does NOT scan NPCs, because NPCs live in the overmap files, not the
    ``.sav``. That is sufficient HERE only because the topology guarantees it: the z=0 stair is the
    avatar's own tile (never occupied by the shelter NPC Edwardo, who sits one tile NORTH per
    docs/arcopolis/TEST_FIXTURES.md), and every other witness tile is in a basement / synthesized
    floor no NPC visits. A later spike that MOVES the avatar or changes NPC placement must add an
    overmap-NPC scan.

WHY save-injection (same rationale as make_wall_fixture.py / make_furniture_fixture.py):
  * Scriptable, reproducible, needs NO interactive client and NO build -- one ``python`` invocation.
  * NOT "faking engine state": terrain is a normal submap field; this authors an INITIAL world
    condition (a matched stair pair), exactly what a mapgen/build would leave. Nothing engine-internal
    is mutated at runtime.

WHERE the terrain lives:
  * Submap terrain lives in the ``.map`` (``map.sqlite3``) ``terrain`` field as an RLE array of id
    strings and ``[id, count]`` runs, indexed ROW-MAJOR (y outer, x inner: index = y*SEEX + x). This
    tool decodes it, sets the witness tiles, re-encodes the full 144-tile RLE, and rewrites the
    zlib-compressed row. The source world stays untouched.

Spike 29 extension (the folded N-floor + package parameterization; docs/arcopolis/61):

  * ``--floors N`` (default 2 = exactly the Spike 23 behavior above). Pair k (k = 0..N-2) joins
    z=-k to z=-k-1 through a stairwell at column (ax, ay+k) -- wells OFFSET ONE TILE SOUTH per
    floor, because one tile cannot carry both stair directions and the SOURCE basement is only
    clean southward: on ``ArcopolisBackpackTest`` z=-1 the eastward tile (ax+1,ay) carries
    furniture while (ax,ay+1..ay+4) are clean ``t_linoleum_white`` (verified 2026-07-01).
  * Floors z<=-2 do not exist in the source save (rows only at z in {-1,0,+1}), so they are
    SYNTHESIZED: every quad row covering the reality-bubble footprint (submaps ax_sm +/- 6) is
    cloned from the source's z=-1 basement quad, coordinates rewritten, terrain rewritten to a
    uniform fill (``t_linoleum_white`` on the stairwell quad, ``t_rock`` elsewhere -- hermetic:
    nothing spawns, nothing to walk into), all position-keyed dynamic content emptied, and the row
    INSERTED (``files(path, parent, compression, data)`` -- an UPDATE would silently no-op on a
    missing row). Supplying the full footprint pre-empts ``map::loadn``'s mapgen fallback
    (src/map.cpp:8759-8778) entirely on the new floors. Loader acceptance of an INSERTED never-
    existing z row was probe-witnessed at z=-2 on 2026-07-01 before this tool relied on it.
  * ``--package-typeid ID --package-offset DX,DY,DZ`` drops one fresh ground item at
    (ax+DX, ay+DY, az+DZ) -- the Stage A package (e.g. ``box_small``). The tile must be a clean
    expected floor (asserted); the walk tiles between the deepest stair landing and the package
    are asserted clean too.
  * The DEFAULT invocation (no new flags) is behavior-identical to Spike 23: same two edits, same
    prints, same read-back -- ``ArcopolisStairsTest`` regenerates content-identically and
    ``stairs_fixture_regression.ps1`` passes unchanged. That invariant is a ratified non-goal of
    the folded Spike 29; treat any drift as a defect.

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

This is a developer fixture tool: stdlib-only, read-only on the source world, only writes the new world
folder. Run it, then validate with ``docs/arcopolis/stairs_fixture_regression.ps1`` (default fixture) or
``docs/arcopolis/slice_regression.ps1`` (the Spike 29 slice fixtures).

Usage::

    python docs/arcopolis/make_stairs_fixture.py             # build/refresh ArcopolisStairsTest
    python docs/arcopolis/make_stairs_fixture.py --force      # overwrite an existing dest world
    python docs/arcopolis/make_stairs_fixture.py --check-only # assert preconditions (+ read-back if dest
                                                              # exists) WITHOUT writing -- used by the gate

    # Spike 29 slice fixtures (see docs/arcopolis/61 and TEST_FIXTURES.md):
    python docs/arcopolis/make_stairs_fixture.py --source-world ArcopolisBackpackTest \
        --dest-world ArcopolisSliceTest --package-typeid box_small --package-offset 0,2,-1
    python docs/arcopolis/make_stairs_fixture.py --source-world ArcopolisBackpackTest \
        --dest-world ArcopolisTowerTest --floors 6 --package-typeid box_small --package-offset 0,6,-5
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
STAIRS_DOWN_TER = "t_stairs_down"   # written at each pair's TOP tile (z=-k)
STAIRS_UP_TER = "t_stairs_up"       # written at each pair's BOTTOM tile (z=-k-1, same x,y)
# The witness tiles must be these plain passable floors BEFORE the swap, so the stairs are the only
# difference from the clone (and a future BN floor rename fails loud here rather than producing a broken
# witness).
EXPECTED_TER_Z0 = "t_floor"           # avatar's own z=0 tile in the source world
EXPECTED_TER_ZM1 = "t_linoleum_white"  # the basement tile directly below it (z=-1)
# Spike 29: synthesized-floor fills. The stairwell quad is walkable finished floor (same id as the real
# basement, so one expected-terrain rule covers z=-1 and synthesized floors alike); every other footprint
# quad is solid rock -- hermetic (no spawns, nothing passable) and matching what mapgen itself produced
# for the missing-neighbor quads in the 2026-07-01 probe.
SYNTH_FILL_STAIR_QUAD = "t_linoleum_white"
SYNTH_FILL_ELSEWHERE = "t_rock"
# Footprint half-width in SUBMAPS around the avatar's submap. The reality bubble is 11x11 submaps
# (MAPSIZE), i.e. avatar submap +/- 5; +/- 6 adds a one-submap safety margin so no loadn on a
# synthesized floor can miss a row and fall through to mapgen.
FOOTPRINT_MARGIN_SM = 6
# Position-keyed dynamic submap content emptied in synthesized floors (the clone template is the real
# basement quad; its furniture/items/etc must not leak into floors we author as uniform fill). Scalars
# (turn_last_touched, temperature, version) and the per-tile radiation RLE stay cloned.
SYNTH_EMPTIED_KEYS = (
    "items", "furniture", "furniture_vars", "active_furniture", "traps", "cosmetics",
    "spawns", "vehicles", "partial_constructions", "fields", "terrain_vars",
)


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


def quad_file_path(fx, fy, z):
    """The map.sqlite3 ``files.path`` for the quad (OMT) at quad-coords (fx,fy,z) directly."""
    return "maps/%d.%d.%d/%d.%d.%d.map" % (fx // 32, fy // 32, z, fx, fy, z)


def read_submap_file(db, path):
    """Return ``(was_compressed, submap_list)`` for a .map row, or ``(None, None)`` if absent."""
    if not os.path.exists(db):
        # Guard before sqlite3.connect(): a missing/mis-pathed db would otherwise be implicitly CREATED as
        # an empty file, then fail with an opaque "no such table: files" rather than naming the real cause.
        raise SystemExit("fatal: map database not found: %s" % db)
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
    """Rewrite an EXISTING .map row with the modified submap list, matching the original compression.
    NOTE (probe-proven 2026-07-01): UPDATE is a silent no-op for a row that does not exist -- creating a
    NEW row (a synthesized lower floor) must go through insert_submap_file below instead."""
    payload = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    if compressed:
        payload = zlib.compress(payload)
    con = sqlite3.connect(db)
    try:
        cur = con.execute("UPDATE files SET data=? WHERE path=?", (sqlite3.Binary(payload), path))
        if cur.rowcount != 1:
            raise SystemExit("fatal: UPDATE matched %d rows for %s (expected 1) -- a new row needs "
                             "insert_submap_file, not write_submap_file" % (cur.rowcount, path))
        con.commit()
    finally:
        con.close()


def insert_submap_file(db, path, obj, compressed):
    """INSERT a NEW .map row (a synthesized lower-z floor). The ``files`` table schema is
    ``files(path TEXT PK, parent TEXT NOT NULL, compression TEXT NULL, data BLOB NOT NULL)`` --
    probe-verified 2026-07-01; ``parent`` is the directory prefix and ``compression`` mirrors the
    template row ('zlib' or NULL). Fails loud if the row already exists (a synthesized floor must
    never silently overwrite engine-written data)."""
    payload = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    if compressed:
        payload = zlib.compress(payload)
    parent = path.rsplit("/", 1)[0]
    con = sqlite3.connect(db)
    try:
        existing = con.execute("SELECT 1 FROM files WHERE path=?", (path,)).fetchone()
        if existing:
            raise SystemExit("fatal: synthesized row already exists: %s -- the dest world is not a "
                             "fresh clone (or the source save gained lower floors); refusing to "
                             "overwrite" % path)
        con.execute("INSERT INTO files (path, parent, compression, data) VALUES (?, ?, ?, ?)",
                    (path, parent, "zlib" if compressed else None, sqlite3.Binary(payload)))
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


def fresh_item(typeid, turn):
    """A minimal item JSON object the engine's item::deserialize loads cleanly (typeid + bday + owner;
    prototype supplies the type-specific defaults). Same shape as make_carried_nested_fixture.py's
    helper -- kept duplicated so each fixture generator is standalone, per the existing convention."""
    return {
        "typeid": typeid,
        "bday": turn,
        "owner": "your_followers",
        "last_rot_check": 0,
        "melee_damage_bonus": [],
        "ranged_damage_bonus": [],
    }


def expected_floor_ter(tz):
    """The clean floor terrain a witness tile must carry BEFORE an edit, by z-level: the avatar floor at
    z=0, the finished basement at z=-1, and the synthesized stairwell-quad fill below that (identical to
    the basement id by design, so one rule covers real and synthesized floors)."""
    if tz == 0:
        return EXPECTED_TER_Z0
    return EXPECTED_TER_ZM1  # z=-1 basement AND synthesized stair-quad floors share this id


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
    module docstring; the fixture topology guarantees no NPC on any witness tile."""
    for m in data.get("active_monsters", []):
        if list(m.get("pos_abs", [])) in tiles:
            raise SystemExit("fatal: a monster occupies a witness tile (pos_abs %s) -- find_stairs would "
                             "raise a push-past query_yn; pick a clear column" % m.get("pos_abs"))
    if data.get("stair_monsters"):
        raise SystemExit("fatal: stair_monsters is non-empty (%d) -- a creature is mid-stair-transit; "
                         "the fixture column must be clear" % len(data.get("stair_monsters")))


def stair_pairs(ax, ay, floors):
    """The N-floor stairwell layout: pair k (k = 0..floors-2) joins z=-k to z=-k-1 at column
    (ax, ay+k) -- offset one tile SOUTH per pair (see the Spike 29 extension in the docstring for why
    south). Returns [(k, top_tile, bottom_tile), ...] where top carries t_stairs_down and bottom
    t_stairs_up."""
    return [(k, [ax, ay + k, -k], [ax, ay + k, -k - 1]) for k in range(floors - 1)]


def parse_package(args):
    """Parse the optional package flags. Returns (typeid, [dx,dy,dz]) or (None, None). Both-or-neither;
    the offset is avatar-relative."""
    if bool(args.package_typeid) != bool(args.package_offset):
        raise SystemExit("fatal: --package-typeid and --package-offset must be given together")
    if not args.package_typeid:
        return None, None
    parts = args.package_offset.split(",")
    if len(parts) != 3:
        raise SystemExit("fatal: --package-offset must be DX,DY,DZ (got %r)" % args.package_offset)
    try:
        off = [int(p) for p in parts]
    except ValueError:
        raise SystemExit("fatal: --package-offset must be three integers (got %r)" % args.package_offset)
    return args.package_typeid, off


def package_walk_tiles(ax, ay, floors, pkg_tile):
    """The tiles the slice driver walks between the deepest stair landing (ax, ay+floors-2, z_deep) and
    the package tile, exclusive of both endpoints -- each must be clean passable floor. Only the
    straight south column is supported (the witness geometry); anything else fails loud."""
    z_deep = -(floors - 1)
    px, py, pz = pkg_tile
    if pz != z_deep or px != ax or py <= ay + (floors - 2):
        raise SystemExit("fatal: the package must sit strictly SOUTH of the deepest landing on the "
                         "deepest floor (landing (%d,%d,%d), package (%d,%d,%d)) -- the witness "
                         "geometry is the straight south column"
                         % (ax, ay + floors - 2, z_deep, px, py, pz))
    return [[ax, dy, z_deep] for dy in range(ay + floors - 1, py)]


def synth_floor_quads(dst_db, a_sx, a_sy, z, template_row, template_fx, template_fy):
    """Synthesize and INSERT every footprint quad row for one lower floor ``z``: clone the template
    (the source basement quad), rewrite each submap's coordinates positionally, rewrite terrain to the
    uniform fill (stairwell quad walkable, elsewhere rock), and empty the position-keyed dynamic
    content. Returns the number of rows inserted."""
    compressed, template = template_row
    fx_lo = (a_sx - FOOTPRINT_MARGIN_SM) // 2
    fx_hi = (a_sx + FOOTPRINT_MARGIN_SM) // 2
    fy_lo = (a_sy - FOOTPRINT_MARGIN_SM) // 2
    fy_hi = (a_sy + FOOTPRINT_MARGIN_SM) // 2
    stair_fx, stair_fy = a_sx // 2, a_sy // 2
    inserted = 0
    for fx in range(fx_lo, fx_hi + 1):
        for fy in range(fy_lo, fy_hi + 1):
            fill = SYNTH_FILL_STAIR_QUAD if (fx == stair_fx and fy == stair_fy) else SYNTH_FILL_ELSEWHERE
            quad = json.loads(json.dumps(template))  # deep copy
            for sm in quad:
                c = sm.get("coordinates")
                if not (isinstance(c, list) and len(c) == 3):
                    raise SystemExit("fatal: template submap has no [sx,sy,z] coordinates: %r" % (c,))
                di, dj = c[0] - 2 * template_fx, c[1] - 2 * template_fy
                if di not in (0, 1) or dj not in (0, 1):
                    raise SystemExit("fatal: template submap (%d,%d) is not positionally inside quad "
                                     "(%d,%d)" % (c[0], c[1], template_fx, template_fy))
                sm["coordinates"] = [2 * fx + di, 2 * fy + dj, z]
                sm["terrain"] = [[fill, SEEX * SEEY]]
                for key in SYNTH_EMPTIED_KEYS:
                    if key in sm:
                        sm[key] = [] if isinstance(sm[key], list) else {}
            insert_submap_file(dst_db, quad_file_path(fx, fy, z), quad, compressed)
            inserted += 1
    return inserted


def inject_package(dst_db, tile, typeid, turn):
    """Drop one fresh ground item onto a clean floor tile (asserted). Appends a new
    ``[wx, wy, [item]]`` triple to the submap's flat items array -- the shape the engine's own saves
    use (verified by make_carried_nested_fixture.py)."""
    tx, ty, tz = tile
    path, compressed, submaps, submap, wx, wy = get_clean_floor_submap(
        dst_db, tx, ty, tz, expected_floor_ter(tz), "package")
    submap.setdefault("items", [])
    submap["items"].extend([wx, wy, [fresh_item(typeid, turn)]])
    write_submap_file(dst_db, path, submaps, compressed)


def verify_world(world_dir, floors=2, package_typeid=None, package_offset=None):
    """Read-back: assert the produced world carries the matched stair pair(s) -- t_stairs_down at each
    pair's top tile, t_stairs_up directly below -- plus the package item when one was requested, each in
    an intact 144-tile submap. Used after the write and standalone by ``--check-only`` when the dest
    world exists. Raises SystemExit on any mismatch."""
    data = load_sav(world_dir)
    ax, ay, az = data["player"]["abs_pos"]
    db = os.path.join(world_dir, "map.sqlite3")
    pairs = stair_pairs(ax, ay, floors)
    witness_tiles = []
    checks = []
    for (k, top, bottom) in pairs:
        checks.append((top, STAIRS_DOWN_TER, "pair-%d z=%d down-stair" % (k, top[2])))
        checks.append((bottom, STAIRS_UP_TER, "pair-%d z=%d up-stair" % (k, bottom[2])))
        witness_tiles += [top, bottom]
    for ((tx, ty, tz), want, label) in checks:
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
    if package_typeid:
        px, py, pz = ax + package_offset[0], ay + package_offset[1], az + package_offset[2]
        sx, sy, wx, wy = submap_of(px, py, pz)
        _, submaps = read_submap_file(db, map_file_path(sx, sy, pz))
        submap = next((s for s in submaps if s.get("coordinates") == [sx, sy, pz]), None) if submaps else None
        if submap is None:
            raise SystemExit("fatal: read-back failed -- package submap (%d,%d,%d) not found" % (sx, sy, pz))
        items = submap.get("items", [])
        found = False
        for i in range(0, len(items) - 2, 3):
            if items[i] == wx and items[i + 1] == wy:
                found = any(it.get("typeid") == package_typeid for it in items[i + 2])
        if not found:
            raise SystemExit("fatal: read-back failed -- package '%s' not on ground at (%d,%d,%d)"
                             % (package_typeid, px, py, pz))
        witness_tiles.append([px, py, pz])
    # Read-back also re-asserts the no-creature invariant on the DEST itself (not only the source), so a
    # committed/regenerated world that drifted to carry a monster or a mid-transit stair_monster on any
    # witness tile FAILS the read-back / regression gate rather than passing on terrain alone.
    assert_no_creature(data, witness_tiles)
    print("read-back ok   : %s @ %s (z=0) + %s @ (%d,%d,%d) (z=-1)"
          % (STAIRS_DOWN_TER, [ax, ay, az], STAIRS_UP_TER, ax, ay, az - 1))
    for (k, top, bottom) in pairs[1:]:
        print("read-back ok   : pair %d -- %s @ %s + %s @ %s"
              % (k, STAIRS_DOWN_TER, top, STAIRS_UP_TER, bottom))
    if package_typeid:
        print("read-back ok   : package %s on ground @ %s" % (package_typeid, [px, py, pz]))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Build the aligned stair witness fixtures: the Spike 23 two-floor default and the "
                    "folded Spike 29 N-floor + package variants.")
    parser.add_argument("--fixture-root", default=_default_fixture_root(),
                        help="userdir holding save/<world> (default: the AGENTS.md fixture root)")
    parser.add_argument("--source-world", default="ArcopolisTest", help="world to clone (read-only)")
    parser.add_argument("--dest-world", default="ArcopolisStairsTest", help="world to create")
    parser.add_argument("--floors", type=int, default=2,
                        help="total floors incl. z=0 (default 2 = the Spike 23 fixture; 6 = the Spike 29 "
                             "tower). Floors z<=-2 are synthesized -- see the docstring.")
    parser.add_argument("--package-typeid", default=None,
                        help="optional ground package itype_id (e.g. box_small); requires --package-offset")
    parser.add_argument("--package-offset", default=None,
                        help="avatar-relative package tile DX,DY,DZ (e.g. 0,2,-1); requires --package-typeid")
    parser.add_argument("--check-only", action="store_true",
                        help="assert source preconditions (and read-back the dest if it exists) WITHOUT "
                             "writing -- used by the regression gates")
    parser.add_argument("--force", action="store_true", help="overwrite an existing dest world")
    args = parser.parse_args(argv)

    if not 2 <= args.floors <= 11:
        raise SystemExit("fatal: --floors must be 2..11 (z bottoms out at -10; only 2 and 6 are "
                         "witnessed -- see docs/arcopolis/61)")
    package_typeid, package_offset = parse_package(args)

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

    # Avatar abs_pos (read-only). Pair 0's top tile is the avatar's own tile; the avatar is NEVER moved
    # (see the docstring's bubble-origin rationale).
    data = load_sav(src)
    ax, ay, az = data["player"]["abs_pos"]
    if az != 0:
        raise SystemExit("fatal: source avatar is at z=%d (expected 0) -- the pair layout assumes a "
                         "surface start" % az)
    turn = data["turn"]
    pairs = stair_pairs(ax, ay, args.floors)
    down_tile = pairs[0][1]
    up_tile = pairs[0][2]
    pkg_tile = None
    walk_tiles = []
    if package_typeid:
        pkg_tile = [ax + package_offset[0], ay + package_offset[1], az + package_offset[2]]
        walk_tiles = package_walk_tiles(ax, ay, args.floors, pkg_tile)
    print("source world   : save/%s" % args.source_world)  # fixture-root-relative (AGENTS.md:273 no-local-paths)
    print("avatar abs_pos : %s (unchanged -- stairs are written under the stationary avatar)" % [ax, ay, az])
    print("down-stair tile: abs %s -> %s" % (down_tile, STAIRS_DOWN_TER))
    print("up-stair tile  : abs %s -> %s" % (up_tile, STAIRS_UP_TER))
    for (k, top, bottom) in pairs[1:]:
        print("pair %d         : abs %s -> %s ; abs %s -> %s"
              % (k, top, STAIRS_DOWN_TER, bottom, STAIRS_UP_TER))
    if package_typeid:
        print("package        : %s at abs %s (walk tiles: %s)" % (package_typeid, pkg_tile, walk_tiles or "none"))

    # Preconditions on the SOURCE (read-only): every witness tile that lives on an EXISTING floor
    # (z >= -1) is a clean expected floor in an existing submap, and no creature sits on any witness
    # tile. Fail loud on drift BEFORE cloning so a stale offset/world never produces a broken witness.
    # Tiles on synthesized floors (z <= -2) have no source counterpart -- they are authored below and
    # asserted on the DEST instead.
    src_db = os.path.join(src, "map.sqlite3")
    if not os.path.exists(src_db):
        # Guard before any sqlite3.connect(): a missing source db would otherwise be implicitly CREATED as
        # an empty file in the read-only source world, then fail with an opaque "no such table" error.
        raise SystemExit("fatal: source map database not found: save/%s/map.sqlite3" % args.source_world)
    creature_tiles = []
    for (k, top, bottom) in pairs:
        creature_tiles += [top, bottom]
        if top[2] >= -1:
            get_clean_floor_submap(src_db, *top, expected_floor_ter(top[2]),
                                   "pair-%d z=%d down-stair" % (k, top[2]))
        if bottom[2] >= -1:
            get_clean_floor_submap(src_db, *bottom, expected_floor_ter(bottom[2]),
                                   "pair-%d z=%d up-stair" % (k, bottom[2]))
    if package_typeid:
        creature_tiles.append(pkg_tile)
        for wt in walk_tiles:
            creature_tiles.append(wt)
            if wt[2] >= -1:
                get_clean_floor_submap(src_db, *wt, expected_floor_ter(wt[2]), "walk tile %s" % (wt,))
        if pkg_tile[2] >= -1:
            get_clean_floor_submap(src_db, *pkg_tile, expected_floor_ter(pkg_tile[2]), "package")
    assert_no_creature(data, creature_tiles)
    print("preconditions  : ok (existing-floor witness tiles clean; no creature on any witness tile)")

    if args.check_only:
        if os.path.isdir(dst):
            verify_world(dst, floors=args.floors, package_typeid=package_typeid,
                         package_offset=package_offset)
            print("check-only     : preconditions + dest read-back both pass")
        else:
            print("check-only     : preconditions pass (dest world does not exist yet; nothing to read back)")
        return 0

    if os.path.exists(dst):
        if not args.force:
            raise SystemExit("fatal: %s already exists (use --force to overwrite)" % dst)
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
    dst_db = os.path.join(dst, "map.sqlite3")

    # Synthesize the lower floors FIRST (z=-2 .. z=-(floors-1)), so every later stair/package edit --
    # real or synthesized floor alike -- goes through the same clean-tile read-modify-write path.
    if args.floors > 2:
        a_sx, a_sy = ax // SEEX, ay // SEEY
        template_fx, template_fy = a_sx // 2, a_sy // 2
        template_path = quad_file_path(template_fx, template_fy, -1)
        template_row = read_submap_file(dst_db, template_path)
        if template_row[1] is None:
            raise SystemExit("fatal: basement template quad not found: %s" % template_path)
        for z in range(-2, -(args.floors - 1) - 1, -1):
            n = synth_floor_quads(dst_db, a_sx, a_sy, z, template_row, template_fx, template_fy)
            print("synthesized    : z=%d -- %d footprint quad rows inserted (stair quad %s, elsewhere %s)"
                  % (z, n, SYNTH_FILL_STAIR_QUAD, SYNTH_FILL_ELSEWHERE))

    # Apply the stair edits on the CLONED map.sqlite3 -- pair 0 first (the Spike 23 pair, same order and
    # prints as the original tool), then the deeper pairs.
    for (k, top, bottom) in pairs:
        for (tile, want, label) in ((top, STAIRS_DOWN_TER, "pair-%d z=%d down-stair" % (k, top[2])),
                                    (bottom, STAIRS_UP_TER, "pair-%d z=%d up-stair" % (k, bottom[2]))):
            tx, ty, tz = tile
            path, compressed, submaps, submap, wx, wy = get_clean_floor_submap(
                dst_db, tx, ty, tz, expected_floor_ter(tz), label)
            flat = decode_terrain(submap["terrain"])
            flat[wy * SEEX + wx] = want
            submap["terrain"] = encode_terrain(flat)
            write_submap_file(dst_db, path, submaps, compressed)
            print("placed stair   : %s at submap (%d,%d,%d) within (%d,%d) (was %s)"
                  % (want, *submap_of(tx, ty, tz)[:2], tz, wx, wy, expected_floor_ter(tz)))

    # Walk tiles on the dest (any floor): clean passable floor between the deepest landing and the
    # package -- read-only assert, no write.
    for wt in walk_tiles:
        get_clean_floor_submap(dst_db, *wt, expected_floor_ter(wt[2]), "walk tile %s" % (wt,))

    # Package injection (after every floor exists).
    if package_typeid:
        inject_package(dst_db, pkg_tile, package_typeid, turn)
        print("placed package : %s at abs %s" % (package_typeid, pkg_tile))

    # Read-back sanity on the produced world.
    verify_world(dst, floors=args.floors, package_typeid=package_typeid, package_offset=package_offset)

    print("created world  : save/%s" % args.dest_world)  # fixture-root-relative (AGENTS.md:273 no-local-paths)
    print("next           : validate with docs/arcopolis/stairs_fixture_regression.ps1 (default fixture) "
          "or docs/arcopolis/slice_regression.ps1 (Spike 29 slice fixtures)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
