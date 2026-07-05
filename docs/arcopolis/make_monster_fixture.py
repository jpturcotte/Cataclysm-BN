#!/usr/bin/env python3
"""Arcopolis Spike 6B - build the deterministic monster-witness fixture.

Creates the ``ArcopolisNearMonsterTest`` world by CLONING the canonical
``ArcopolisTest`` world and injecting one monster INSIDE the radius-12 export
window, so the Spike 6A ``entities.monsters[]`` contract becomes witnessable
(``count > 0``) instead of present-but-empty. See
``docs/arcopolis/16_SPIKE6B_MONSTER_WITNESS_FIXTURE.md`` and the load/eject
analysis in ``docs/arcopolis/17_MONSTER_LOAD_AND_WALL_EJECT.md``.

WHY save-injection instead of the graphical debug "Spawn monster":
  * It is scriptable, reproducible, and needs NO interactive client and NO
    build -- the whole fixture is one ``python`` invocation.
  * It is NOT "faking engine state": the engine deserializes the injected
    object into a real monster (it resolves the type, builds the body, and the
    export's hp_max/symbol/etc. come from the engine's own type lookup). This
    only authors an INITIAL world condition, exactly like the GUI debug spawn
    does -- the engine then simulates faithfully.

HOW it stays valid: it does NOT hand-author a monster from scratch (which risks
missing/!type-matching fields). It deep-copies a REAL, engine-written monster
already in the save (one of the stock wildlife), then changes only:
  * ``typeid``           -> the witness type (default mon_fungal_wall, IMMOBILE);
  * ``pos_abs`` & co.    -> avatar abs_pos + offset;
  * type-derived fields  -> reset (hp, speed; drop ``body`` so the engine builds
                            the witness type's own body) so the clone is a clean
                            instance of the new type.

PLACEMENT MUST BE ON PASSABLE TERRAIN. This is the load-bearing rule (root-caused
2026-06-05, see doc 17). At load the monster is added at its exact ``pos_abs``
(no terrain check). On the first processed turn ``game::monmove()`` runs a
lifecycle guard (the impassable-tile eject in ``game::monmove``, ~src/game.cpp:6124 — the
line drifts; match by the "Critters in impassable tiles get pushed away" comment) that, for any critter standing on a tile it
``can_move_to`` is false for (i.e. impassable -- a wall, a tree, ...), searches
``points_in_radius(pos, 3)`` for the first passable+empty tile and ``setpos()``
es it there -- or, if none exists within radius 3, **kills it**. So an in-wall
witness DRIFTS (a single deterministic teleport, looks like "moving toward the
avatar") and a witness walled-in by >3 tiles of solid terrain VANISHES. On
passable terrain (floor/grass/dirt) the guard never fires, and because the
default type is IMMOBILE it also never wanders -- so the witness is EXACTLY
stationary on every frame (validated). The default offset below lands on grass.

``last_updated`` is set to ``turn`` so ``monster::on_load``'s
``batch_turns(turn - last_updated)`` is a no-op if it runs (it advances
cooldowns/anger/regen, never position -- it was NOT the cause of the drift).

This is a developer fixture tool: stdlib-only, read-only on ``ArcopolisTest``,
and it only writes the new world folder. Run it, then validate with
``docs/arcopolis/monster_export_regression.ps1``.

Usage::

    python docs/arcopolis/make_monster_fixture.py            # defaults (grass, 8 south)
    python docs/arcopolis/make_monster_fixture.py --offset 0,5,0 --monster mon_fungal_wall

    # World-tick LIVENESS witness (a HOSTILE MOBILE approacher, doc 56). The 0,2,0 offset is
    # load-bearing -- it is the committed ArcopolisLivenessTest placement (2 south, in dark-shelter
    # detection range); 0,8,0 would land out of detection range and break the reached_adjacency gate:
    python docs/arcopolis/make_monster_fixture.py --dest-world ArcopolisLivenessTest \
        --monster mon_zombie --offset 0,2,0 --anger 100 --morale 100 --aggro-character --force

    # Two-attacker INSTANCE-AMBIGUITY witness (Stage-1 shadow-test, doc 59). Two hostile mon_zombie so a
    # `mon_zombie` damage event's source_type_id alone cannot say WHICH one hit -- the gap the deferred
    # stable-attacker-id would close. --extra-offset places the second at another in-detection floor tile:
    python docs/arcopolis/make_monster_fixture.py --dest-world ArcopolisTwoZombieTest \
        --monster mon_zombie --offset 0,2,0 --extra-offset 1,2,0 \
        --anger 100 --morale 100 --aggro-character --force
    # (a NEGATIVE extra offset needs the = form so argparse does not read it as a flag: --extra-offset=-1,2,0)

    # Fight-mechanic witness (Spike 29A, doc 62): an ADJACENT hostile at the type's NATURAL hp (80 =
    # mon_zombie's type->hp, a freshly-spawned zombie) so K=6 avatar bumps are PROVABLY kill-safe
    # (crit-inclusive worst case 6x12=72<80 -- doc 62 shows the arithmetic; K=8 would allow 96>80) --
    # the runtime-sandbox fixture fight_mechanic_regression.ps1 generates (never committed):
    python docs/arcopolis/make_monster_fixture.py --dest-world ArcopolisFightTest \
        --monster mon_zombie --offset 0,1,0 --anger 100 --morale 100 --aggro-character --hp 80 --force

The default (no hostility flags, ``--hp`` 20) reproduces the original IMMOBILE-witness behavior
BYTE-FOR-BYTE, so ``ArcopolisNearMonsterTest`` regenerates unchanged (mechanically gated at .sav
scope -- this script's only content write -- by the G-ID checks in monster_export_regression.ps1
and fight_mechanic_regression.ps1; a future flag that writes OTHER world files needs a wider gate). The opt-in ``--anger`` /
``--morale`` / ``--aggro-character`` flags author a monster that the engine's own ``monmove`` will
path toward the avatar on its OWN turn -- the initial condition the world-tick liveness witness
observes; the opt-in ``--hp`` authors the witness's starting hp (default 20 = the historical witness
value; a type-natural value like mon_zombie's 80 gives a repeated-melee witness kill-headroom).
(Authoring an initial anger/aggro/hp state is exactly what the GUI debug spawn does; the engine then
simulates faithfully -- it is NOT faking engine state.)
"""

import argparse
import copy
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

# Heuristic only — for a WARNING. The engine's real test is `impassable && !can_move_to` (move-cost 0
# terrain/furniture); we can't replicate the full flag logic from raw JSON cheaply, so we flag the obvious
# impassable terrain families. A false negative just reverts to the documented eject/die behaviour.
IMPASSABLE_HINTS = ("wall", "rock", "tree", "bars", "grate", "_door_c", "door_locked", "boulder")
PASSABLE_HINTS = ("floor", "grass", "dirt", "sand", "mud", "gravel", "underbrush", "pavement",
                  "road", "sidewalk", "concrete", "shrub")


def load_sav(world_dir):
    """Return ``(sav_path, prefix_bytes, data)`` for a world's main .sav.

    BN .sav files are a one-line ``# version N`` prefix followed by the JSON
    object; the prefix bytes are preserved verbatim on write.
    """
    matches = sorted(glob.glob(os.path.join(world_dir, "*.sav")))
    if not matches:
        raise SystemExit("fatal: no .sav file in %s" % world_dir)
    with open(matches[0], "rb") as f:
        raw = f.read()
    nl = raw.find(b"\n")
    if nl == -1 or not raw.lstrip().startswith(b"#"):
        return matches[0], b"", json.loads(raw.decode("utf-8"))
    return matches[0], raw[: nl + 1], json.loads(raw[nl + 1:].decode("utf-8"))


def terrain_id_at(world_dir, x, y, z):
    """Best-effort: read the terrain id at absolute ms (x,y,z) from map.sqlite3.

    Returns the ter id string, or ``None`` if anything about the read fails
    (missing db, format drift, etc.) — callers treat ``None`` as "unknown, skip
    the warning". Coordinate math per docs/arcopolis (memory: read-fixture-without-build):
    submap = floor(abs/12); file maps/<sx//2//32>.<sy//2//32>.<z>/<sx//2>.<sy//2>.<z>.map.
    """
    try:
        sx, sy = x // SEEX, y // SEEY
        wx, wy = x - sx * SEEX, y - sy * SEEY
        fx, fy = sx // 2, sy // 2
        path = "maps/%d.%d.%d/%d.%d.%d.map" % (fx // 32, fy // 32, z, fx, fy, z)
        db = os.path.join(world_dir, "map.sqlite3")
        if not os.path.exists(db):
            # Don't let sqlite3.connect() create a stray empty db. This best-effort reader returns None
            # (the caller skips its soft warning) rather than raise() like the tuple-returning
            # read_submap_file in the other generators -- an intentional per-file shape difference.
            return None
        con = sqlite3.connect(db)
        try:
            row = con.execute("SELECT data FROM files WHERE path=?", (path,)).fetchone()
        finally:
            con.close()
        if not row:
            return None
        raw = row[0]
        try:
            raw = zlib.decompress(raw)
        except zlib.error:
            pass
        submaps = json.loads(raw)
        submaps = submaps if isinstance(submaps, list) else submaps.get("submaps", [submaps])
        sub = next((s for s in submaps if s.get("coordinates") == [sx, sy, z]), None)
        if not sub:
            return None
        flat = []
        for e in sub["terrain"]:
            flat += [e[0]] * e[1] if isinstance(e, list) else [e]
        return flat[wy * SEEX + wx]
    except Exception:
        return None


def build_witness(template, monster_id, pos_abs, turn, anger=0, morale=0, aggro_character=False,
                  hp=20):
    """Clone a real engine-written monster into a clean instance of ``monster_id``.

    Defaults (anger/morale 0, not aggroed, hp 20) reproduce the original IMMOBILE-witness output
    BYTE-FOR-BYTE. Pass anger>0 + aggro_character=True for the world-tick LIVENESS witness: a
    hostile instance the engine's own ``monmove`` paths toward the avatar on its own turn; pass
    ``hp`` for a witness needing a different starting pool (the Spike-29A fight fixture uses the
    type-natural 80 for kill-headroom under repeated bumps). The
    fields below are an authored INITIAL world condition (as the GUI debug spawn authors one);
    the engine simulates from there -- nothing here mutates the running simulation.
    """
    w = copy.deepcopy(template)
    w["typeid"] = monster_id
    w["pos_abs"] = list(pos_abs)
    w["wander_pos_abs"] = list(pos_abs)
    w["destination"] = [0, 0, 0]
    w["hp"] = hp
    w["moves"] = 0
    w["speed"] = 100
    w["last_updated"] = turn  # no-op catch-up if on_load runs; never affects position (see doc 17)
    w["wandf"] = 0
    w["anger"] = anger
    w["morale"] = morale
    w["hallucination"] = False
    w["friendly"] = 0
    w["aggro_character"] = aggro_character
    w["effects"] = {}
    w["special_attacks"] = {}
    w["unique_name"] = ""
    if "path" in w:
        w["path"] = []
    w.pop("body", None)            # let the engine rebuild the new type's body (fungal_wall is NOHEAD)
    w.pop("corpse_components", None)
    return w


def main(argv=None):
    parser = argparse.ArgumentParser(description="Build the ArcopolisNearMonsterTest monster-witness fixture.")
    parser.add_argument("--fixture-root", default=_default_fixture_root(),
                        help="userdir holding save/<world> (default: the AGENTS.md fixture root)")
    parser.add_argument("--source-world", default="ArcopolisTest", help="world to clone (read-only)")
    parser.add_argument("--dest-world", default="ArcopolisNearMonsterTest", help="world to create")
    parser.add_argument("--monster", default="mon_fungal_wall",
                        help="witness monster type id. IMMOBILE (mon_fungal_wall) for the stationary export "
                             "witness; a MOBILE hostile type (e.g. mon_zombie) WITH --aggro-character for the "
                             "world-tick liveness witness.")
    parser.add_argument("--offset", default="0,8,0",
                        help="witness pos_abs offset from the avatar as dx,dy,dz. DEFAULT 0,8,0 lands on grass "
                             "south of the shelter (passable, cheb 8, in-window). MUST be passable terrain — "
                             "see doc 17. For a mover, keep cheb>1 (out of melee) and <=12 (in-window).")
    # Opt-in hostility (default 0/0/False == the original immobile-witness output, byte-for-byte). Authoring an
    # initial anger/aggro state is an INITIAL world condition (as the GUI debug spawn is), not faked engine state.
    parser.add_argument("--anger", type=int, default=0,
                        help="witness current anger (0 = original immobile-witness default; >0 = hostile mover).")
    parser.add_argument("--morale", type=int, default=0,
                        help="witness current morale (0 = original default; raise with --anger so it does not flee).")
    parser.add_argument("--aggro-character", dest="aggro_character", action="store_true",
                        help="mark the witness aggressive toward the avatar (the liveness-mover flag).")
    parser.add_argument("--hp", type=int, default=20,
                        help="witness starting hp (default 20 = the original witness output, byte-for-byte). "
                             "Set to the type's natural max (e.g. 80 for mon_zombie) for a witness that needs "
                             "kill-headroom under repeated melee (the Spike-29A fight fixture).")
    parser.add_argument("--extra-offset", action="append", default=[], metavar="DX,DY,DZ",
                        help="place an ADDITIONAL witness at this offset with the SAME "
                             "--monster/--anger/--morale/--aggro-character (repeatable). Default none = "
                             "single-witness output BYTE-FOR-BYTE unchanged. Used by the two-attacker "
                             "instance-ambiguity fixture (ArcopolisTwoZombieTest, Stage-1 shadow-test): two "
                             "same-type hostiles so a damage event's source_type_id alone cannot say WHICH one hit.")
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
        raise SystemExit("fatal: --offset must be dx,dy,dz integers, e.g. 0,8,0")
    if max(abs(dx), abs(dy)) > 12:
        sys.stderr.write("warning: offset Chebyshev %d > 12 -- the witness may fall OUTSIDE the export window.\n"
                         % max(abs(dx), abs(dy)))

    if os.path.exists(dst):
        if not args.force:
            raise SystemExit("fatal: %s already exists (use --force to overwrite)" % dst)
        shutil.rmtree(dst)
    shutil.copytree(src, dst)

    sav, prefix, data = load_sav(dst)
    turn = data["turn"]
    ax, ay, az = data["player"]["abs_pos"]
    monsters = data["active_monsters"]
    if not monsters:
        raise SystemExit("fatal: source world has no active_monsters to clone a template from")
    pos = (ax + dx, ay + dy, az + dz)

    # Passability guard (best-effort, TERRAIN ONLY -- does not inspect furniture): a witness on impassable
    # terrain is teleported (radius-3) or KILLED by the game::monmove impassable-tile eject on the first turn
    # (~src/game.cpp:6124, line drifts; see doc 17). Warn loudly so the author fixes the offset rather than
    # shipping a drifting/vanishing witness. For a HOSTILE MOVER the world_tick_liveness_regression's
    # no-teleport + passable-terrain gates also fail loud on a bad placement, so this warning is a first line,
    # not the only one.
    ter = terrain_id_at(dst, *pos)
    if ter is not None:
        # Flag only on a CLEAR impassable signal (an impassable family token AND no passable one), so a
        # passable id that merely CONTAINS an impassable substring -- e.g. t_rock_floor -> "rock" -- is not
        # a false positive (gemini PR #89); for a HOSTILE MOVER gate 8 (no-teleport) is the runtime backstop.
        bad = any(h in ter for h in IMPASSABLE_HINTS) and not any(h in ter for h in PASSABLE_HINTS)
        flag = "  <-- LIKELY IMPASSABLE, will drift/vanish (see doc 17)" if bad else "  (passable)"
        print("terrain at witness tile: %s%s" % (ter, flag))
        if bad:
            sys.stderr.write("warning: witness tile %s looks impassable; pick an offset over floor/grass "
                             "(the engine ejects or kills monsters on impassable terrain — doc 17).\n" % ter)
    else:
        print("terrain at witness tile: <unreadable map.sqlite3 — verify the tile is passable per doc 17>")

    template = monsters[0]  # the stock wildlife template; index 0 is stable because witnesses only append
    witness = build_witness(template, args.monster, pos, turn,
                            anger=args.anger, morale=args.morale,
                            aggro_character=args.aggro_character, hp=args.hp)
    monsters.append(witness)

    # Extra witnesses (ADDITIVE; default [] => the single-witness .sav above is byte-for-byte unchanged, so
    # ArcopolisNearMonsterTest / ArcopolisLivenessTest regenerate identically). Each --extra-offset places
    # ANOTHER witness with the SAME --monster/--anger/--morale/--aggro-character, cloned from the SAME stock
    # `template`. This is how the two-attacker instance-ambiguity fixture (ArcopolisTwoZombieTest, doc 59)
    # gets two same-type hostiles: neither the damage funnel nor the export gives a per-instance id, so a
    # `mon_zombie` damage event cannot be pinned to one of the two exported `mon_zombie`.
    for off in args.extra_offset:
        try:
            edx, edy, edz = (int(v) for v in off.split(","))
        except ValueError:
            raise SystemExit("fatal: --extra-offset must be dx,dy,dz integers, e.g. -1,2,0 (got %r)" % off)
        if max(abs(edx), abs(edy)) > 12:
            sys.stderr.write("warning: --extra-offset %s Chebyshev %d > 12 -- witness may fall OUTSIDE the "
                             "export window.\n" % (off, max(abs(edx), abs(edy))))
        epos = (ax + edx, ay + edy, az + edz)
        eter = terrain_id_at(dst, *epos)
        if eter is not None:
            ebad = any(h in eter for h in IMPASSABLE_HINTS) and not any(h in eter for h in PASSABLE_HINTS)
            print("extra witness tile : %s ter=%s%s"
                  % (list(epos), eter, "  <-- LIKELY IMPASSABLE, will drift/vanish (doc 17)" if ebad else "  (passable)"))
            if ebad:
                sys.stderr.write("warning: extra witness tile %s looks impassable; pick floor/grass (doc 17).\n" % eter)
        else:
            print("extra witness tile : %s ter=<unreadable map.sqlite3 — verify passable per doc 17>" % list(epos))
        monsters.append(build_witness(template, args.monster, epos, turn,
                                      anger=args.anger, morale=args.morale,
                                      aggro_character=args.aggro_character, hp=args.hp))

    with open(sav, "wb") as f:
        f.write(prefix + json.dumps(data, separators=(",", ":")).encode("utf-8"))

    mode = ("HOSTILE MOVER (anger=%d, morale=%d, aggro_character=%s)"
            % (args.anger, args.morale, args.aggro_character)) if args.aggro_character or args.anger else "immobile/passive (stationary witness)"
    added = 1 + len(args.extra_offset)
    print("created world : %s" % dst)
    print("witness       : %s @ pos_abs %s (avatar %s + offset %s, cheb %d) — %s"
          % (args.monster, list(pos), [ax, ay, az], [dx, dy, dz], max(abs(dx), abs(dy)), mode))
    if args.extra_offset:
        print("extra witnesses: %d (same type/hostility, offsets %s)" % (len(args.extra_offset), ", ".join(args.extra_offset)))
    print("active_monsters: %d (was %d, +%d witness%s)" % (len(monsters), len(monsters) - added, added, "es" if added != 1 else ""))
    print("next          : validate with docs/arcopolis/monster_export_regression.ps1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
