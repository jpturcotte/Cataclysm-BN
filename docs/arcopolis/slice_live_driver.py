#!/usr/bin/env python3
"""Arcopolis folded-Spike-29 vertical-slice composite live driver (docs/arcopolis/61).

Drives ONE persistent ``--arcopolis-live`` backend over an N-floor slice fixture
(``ArcopolisSliceTest`` --floors 2, ``ArcopolisTowerTest`` --floors 6; both built by
``make_stairs_fixture.py``) and witnesses the former-Spike-28 composite loop in one session:

    export -> vertical_move down (xN-1, planar between wells) -> planar move to the package
    -> level-4 ``pickup`` prompt transaction -> planar return -> vertical_move up (xN-1)
    -> ``op:"query" has_item`` + position conjunction GREEN at the contact tile.

This is an **Arcopolis-layer L1 composite** (docs/arcopolis/53/55): the conjunction

    carried_at_contact = avatar.pos_abs == contact_pos_abs
                         && query.has == true
                         && query.scope == "on_person_dialogue_predicate"

is computed CONSUMER-SIDE (here, in this driver), never by the backend. Per-verb levels are the
already-recorded ones -- ``vertical_move``/``move`` level 2/3 (action injected at the handle_action
seam, doc 49), ``pickup`` level 4 at its Spike-12A witnessed site (the real ``input_context("PICKUP")``
loop consumes the served DOWN/RIGHT/CONFIRM), ``has_item`` class C (the engine predicate's own
``has_charges||has_amount`` result, Spike 26A), position class S. **No new equivalence claim.**
NOTE: these live runs are also the FIRST live-transport ``vertical_move`` witness (doc 49 added no
live probe; doc 60 FE-1 named that gap) -- a vertical failure here is a backend finding.

False-green guards (the doc-53 set + the composite-specific ones from the folded-spike plan):

  * possession_false_at_start      -- query false at contact BEFORE anything happens;
  * floor_provenance_before/after  -- the package is ON the deepest floor's ground before the pickup
    (entities.items[]) and absent from avatar.carried_items[]; after the pickup ground -1 == carried +1
    with location "inventory". carried_items[] is used ONLY for these provenance count-deltas (display
    observability, its approved use, doc 51); the possession HALF of the conjunction reads ONLY the
    class-C query -- never the flat export (this fixture's package is top-level, so no nested-divergence
    state exists here; the anti-flat divergence witness remains doc 53's on ArcopolisCarriedNestedTest);
  * z_changed_off_contact_pinned   -- evaluated at the PINNED pre-ascent tile (contact x, contact y,
    z=-1): x/y EQUAL the contact tile and only z differs, so a z-blind conjunction (comparing pos_abs[0:2]
    only) FAILS this gate -- the red-team's Lens-A divergence, exercised, not asserted;
  * off_contact_displacement       -- after the final green, a proven one-tile displacement at z=0
    (delta [0,1,0]) flips the conjunction false while possession stays true (the doc-53 gate);
  * no_damage_interference         -- avatar.damage_taken[] empty in EVERY snapshot (the buffer drains
    per snapshot -- doc 58 -- so this is per-window, not cumulative);
  * hermetic_lower_floors          -- zero monsters/NPCs in every z<=-2 window (the synthesized floors
    are authored empty; mapgen never runs there because the generator supplies the full footprint);
  * scope_label_guard              -- every successful query response carries the literal
    "on_person_dialogue_predicate" scope string verbatim (the Spike-26A labelling guard).

Witness scope -- what this does NOT prove: no mission completion, no MGOAL_FIND_ITEM /
crafting_inventory() scope, no NPC turn-in, no L4 vertical, no multi-z snapshot, no floor count beyond
the fixture actually driven, no stealth/perception claim.

Stdlib-only. Reuses the Spike 9A/9B client-harness ``LiveSession`` (deadline recv + protocol.jsonl tee;
a Windows pipe readline cannot be interrupted, so the main thread must never block on it directly) via
the same import shim as ``prompt_menu_live_driver.py``, and the stage_a_return_condition_driver.py
gate/summary shape. NO src/ change.

Usage::

    python docs/arcopolis/slice_live_driver.py --exe <cataclysm-bn-tiles.exe> --world ArcopolisSliceTest \
        --floors 2 --userdir <userdir> --export-dir <dir> --out <result.json>
    python docs/arcopolis/slice_live_driver.py --exe <...> --world ArcopolisTowerTest --floors 6 ...
"""

import argparse
import json
import os
import subprocess
import sys
import time

# The load-bearing labelling guard repeated verbatim across the Spike 26A response payload, doc 52, the
# ARCOPOLIS_STATE row, doc 53, and doc 61. A drift here would silently re-scope the possession half.
SCOPE = "on_person_dialogue_predicate"


def leg_plan(ax, ay, floors):
    """The traversal legs for an N-floor slice fixture built by make_stairs_fixture.py: pair k joins
    z=-k to z=-k-1 through a well at (ax, ay+k) -- wells offset one tile SOUTH per pair. Returns the
    descend list, package detour, ascend-to-pinned list, and the key tiles. Every leg carries the
    expected post-leg (pos, avatar-tile terrain)."""
    z_deep = -(floors - 1)
    descend = []
    for k in range(floors - 1):
        descend.append((("vertical_move", "down"), [ax, ay + k, -(k + 1)], "t_stairs_up"))
        if k < floors - 2:
            descend.append((("move", "move_s"), [ax, ay + k + 1, -(k + 1)], "t_stairs_down"))
    landing = [ax, ay + floors - 2, z_deep]
    walk = [ax, ay + floors - 1, z_deep]
    package = [ax, ay + floors, z_deep]
    # Ascend from the landing back up to the PINNED pre-ascent tile (ax, ay, -1) -- everything except
    # the final pair-0 up, which runs after the pinned z-guard is evaluated.
    ascend_to_pinned = []
    for k in range(floors - 2, 0, -1):
        ascend_to_pinned.append((("vertical_move", "up"), [ax, ay + k, -k], "t_stairs_down"))
        ascend_to_pinned.append((("move", "move_n"), [ax, ay + k - 1, -k], "t_stairs_up"))
    return {"descend": descend, "landing": landing, "walk": walk, "package": package,
            "ascend_to_pinned": ascend_to_pinned, "pinned": [ax, ay, -1], "z_deep": z_deep}


class Driver:
    def __init__(self, args):
        self.args = args
        self.req_id = 0
        self.snapshots = []  # every loaded snapshot, for the cross-cutting guards
        self.successful_query_scopes = []
        self.summary = {"gates": {}, "ok": True}

    def record(self, name, gate):
        self.summary["gates"][name] = gate
        if not gate.get("pass"):
            self.summary["ok"] = False

    # --- protocol plumbing (LiveSession recv with a hard deadline; a hang kills the run) ---
    def send(self, payload):
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()

    def recv(self, what, timeout=60.0):
        return self.session.recv(time.monotonic() + timeout, what)

    def next_id(self):
        self.req_id += 1
        return self.req_id

    def export(self, name):
        """op:export -> response -> load the snapshot; returns (pos_abs, snapshot)."""
        self.send({"id": self.next_id(), "op": "export", "name": name})
        resp = self.recv("export response for %s" % name)
        if resp.get("type") != "response" or resp.get("ok") is not True or resp.get("op") != "export":
            raise SystemExit("fatal: export %r did not succeed: %r" % (name, resp))
        path = os.path.join(self.args.export_dir, resp["snapshot"])
        with open(path, "r", encoding="utf-8") as f:
            snap = json.load(f)
        self.snapshots.append((name, snap))
        pos = snap.get("avatar", {}).get("pos_abs")
        if not (isinstance(pos, list) and len(pos) == 3):
            raise SystemExit("fatal: snapshot %r has no avatar.pos_abs list: %r" % (name, pos))
        return pos, snap

    def query(self, item, count=1):
        self.send({"id": self.next_id(), "op": "query", "kind": "has_item", "item": item, "count": count})
        resp = self.recv("has_item query response for %s" % item)
        if resp.get("ok") is True:
            self.successful_query_scopes.append(resp.get("scope"))
        return resp

    def command(self, command, direction):
        """A prompt-free command (move / vertical_move): send, expect ONE terminal response."""
        self.send({"id": self.next_id(), "op": "command", "command": command, "direction": direction})
        resp = self.recv("command response for %s %s" % (command, direction))
        return resp

    @staticmethod
    def avatar_tile_ter(snap):
        tile = next((t for t in snap.get("tiles", []) if t and t.get("is_avatar")), None)
        return tile.get("ter") if tile else None

    @staticmethod
    def carried_count(snap, typeid):
        return sum(1 for e in snap.get("avatar", {}).get("carried_items", [])
                   if e.get("type_id") == typeid)

    @staticmethod
    def carried_locations(snap, typeid):
        return [e.get("location") for e in snap.get("avatar", {}).get("carried_items", [])
                if e.get("type_id") == typeid]

    @staticmethod
    def ground_count_at(snap, typeid, tile):
        return sum(1 for e in snap.get("entities", {}).get("items", [])
                   if e.get("type_id") == typeid and list(e.get("pos_abs", [])) == tile)

    def composite(self, pos, contact, q):
        """The consumer-side Stage A conjunction (docs 53/55) -- computed HERE, never by the backend.
        The possession half reads ONLY the class-C query result; pos_abs carries [x,y,z], so a z change
        alone must flip it (the pinned gate exercises exactly that)."""
        return bool(pos == contact and q.get("has") is True and q.get("scope") == SCOPE)

    def run_legs(self, legs, gate_name):
        """Drive a list of prompt-free legs, exporting + asserting pos/ter/turn after each. Aggregate gate."""
        detail = []
        all_ok = True
        for i, ((command, direction), want_pos, want_ter) in enumerate(legs):
            resp = self.command(command, direction)
            leg_ok = (resp.get("ok") is True)
            pos, snap = self.export("%s_%02d" % (gate_name, i))
            ter = self.avatar_tile_ter(snap)
            turn = snap.get("backend", {}).get("turn")
            turn_ok = (self.prev_turn is None or (isinstance(turn, int) and turn > self.prev_turn))
            self.prev_turn = turn
            ok = leg_ok and pos == want_pos and ter == want_ter and turn_ok
            detail.append({"leg": i, "command": command, "direction": direction,
                           "resp_ok": resp.get("ok"), "pos": pos, "want_pos": want_pos,
                           "ter": ter, "want_ter": want_ter, "turn": turn, "pass": ok})
            if not ok:
                all_ok = False
        self.record(gate_name, {"legs": detail, "pass": all_ok})
        return all_ok

    def run(self):
        args = self.args
        pkg = args.package_typeid
        cmd = [args.exe, "--arcopolis-live", "--world", args.world, "--userdir", args.userdir,
               "--arcopolis-export-dir", args.export_dir]
        stderr_handle = open(os.path.join(args.export_dir, "backend_stderr.txt"), "w", encoding="utf-8")
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=stderr_handle, text=True, encoding="utf-8", errors="replace")
        here = os.path.dirname(os.path.abspath(__file__))
        sys.path.insert(0, os.path.normpath(os.path.join(here, "..", "..", "tools", "arcopolis_client")))
        from harness import LiveSession  # noqa: E402  (deadline recv; see module docstring)
        self.session = LiveSession(self.proc, os.path.join(args.export_dir, "protocol.jsonl"))
        try:
            ready = self.recv("the ready event", timeout=180.0)  # world load happens before ready
            if ready.get("type") != "ready" or ready.get("ok") is not True:
                raise SystemExit("fatal: first protocol line is not an ok ready event: %r" % (ready,))
            self.summary["ready"] = {"world": ready.get("world"),
                                     "protocol_version": ready.get("protocol_version")}
            self.prev_turn = None

            # --- Contact instant. ---
            contact, contact_snap = self.export("contact_start")
            if contact[2] != 0:
                raise SystemExit("fatal: contact tile not at z=0: %r" % (contact,))
            self.prev_turn = contact_snap.get("backend", {}).get("turn")
            self.summary["contact_pos_abs"] = contact
            ax, ay = contact[0], contact[1]
            plan = leg_plan(ax, ay, args.floors)
            self.summary["plan"] = {k: plan[k] for k in ("landing", "walk", "package", "pinned", "z_deep")}

            # Gate: possession false at contact before anything happens (conjunction false via has).
            q0 = self.query(pkg)
            self.record("possession_false_at_start", {
                "query_ok": q0.get("ok"), "query_has": q0.get("has"),
                "composite": self.composite(contact, contact, q0), "expected_has": False,
                "pass": (q0.get("ok") is True and q0.get("has") is False and
                         self.composite(contact, contact, q0) is False),
            })

            # --- Descend to the deepest landing. ---
            self.run_legs(plan["descend"], "descent_trajectory")

            # Gate: floor provenance BEFORE the pickup -- the package is deepest-floor GROUND state,
            # not on-person: entities.items[] has it at the package tile, carried_items[] does not,
            # and the on-person predicate still answers false.
            pos_land, land_snap = self.export("pre_pickup")
            qb = self.query(pkg)
            gb = self.ground_count_at(land_snap, pkg, plan["package"])
            cb = self.carried_count(land_snap, pkg)
            self.record("floor_provenance_before", {
                "pos": pos_land, "landing": plan["landing"], "ground_at_package_tile": gb,
                "carried_count": cb, "query_has": qb.get("has"),
                "pass": (pos_land == plan["landing"] and gb == 1 and cb == 0 and
                         qb.get("ok") is True and qb.get("has") is False),
            })

            # --- Walk to the package-adjacent tile. ---
            self.run_legs([(("move", "move_s"), plan["walk"], EXPECTED_WALK_TER)],
                          "walk_to_package")

            # --- The level-4 pickup prompt transaction (the Spike 12A/16 witnessed shape). ---
            self.send({"id": self.next_id(), "op": "command", "command": "pickup",
                       "direction": "move_s"})
            prompt = self.recv("the pickup prompt event", timeout=90.0)
            gate = {"prompt_type": prompt.get("type"), "prompt_kind": prompt.get("kind"),
                    "choices": prompt.get("choices"), "pass": False}
            if prompt.get("type") == "prompt" and prompt.get("kind") == "menu":
                choices = prompt.get("choices") or []
                # The package tile holds exactly one item, so the engine's real menu has exactly one
                # entry (min=0 opens the menu even for a single item -- src/pickup.cpp:728 leaf).
                if len(choices) == 1 and choices[0].get("enabled") is True:
                    self.send({"id": self.next_id(), "op": "prompt_answer",
                               "prompt_id": prompt.get("prompt_id"),
                               "choice": choices[0].get("index", 0)})
                    ack = self.recv("the prompt_answer ack")
                    gate["ack_ok"] = ack.get("ok")
                    if ack.get("type") == "response" and ack.get("op") == "prompt_answer" and \
                            ack.get("ok") is True:
                        final = self.recv("the pickup command terminal response", timeout=90.0)
                        gate["command_ok"] = final.get("ok")
                        gate["pass"] = (final.get("type") == "response" and final.get("ok") is True)
                else:
                    gate["fail_reason"] = "expected exactly one enabled menu entry"
            else:
                gate["fail_reason"] = "no menu prompt arrived (auto-pickup or unexpected event?)"
            self.record("pickup_l4_transaction", gate)

            # Gate: floor provenance AFTER -- ground -1 == carried +1, location "inventory", query true.
            pos_after, after_snap = self.export("post_pickup")
            qa = self.query(pkg)
            ga = self.ground_count_at(after_snap, pkg, plan["package"])
            ca = self.carried_count(after_snap, pkg)
            locs = self.carried_locations(after_snap, pkg)
            self.record("floor_provenance_after", {
                "pos": pos_after, "ground_at_package_tile": ga, "carried_count": ca,
                "carried_locations": locs, "query_has": qa.get("has"),
                "pass": (pos_after == plan["walk"] and ga == 0 and ca == 1 and
                         locs == ["inventory"] and qa.get("ok") is True and qa.get("has") is True),
            })

            # --- Planar return to the landing, then ascend to the PINNED pre-ascent tile. ---
            # For floors=2 the landing IS the pinned tile (ax, ay, -1) and ascend_to_pinned is empty;
            # for floors>2 the ascent's OWN last leg (the move_n onto pair-0's up-stair) lands exactly
            # on the pinned tile -- no extra leg either way (an extra move_n here was the one driver
            # bug the tower smoke caught: it stepped one tile past the stair onto plain floor).
            self.run_legs([(("move", "move_n"), plan["landing"], "t_stairs_up")], "return_to_landing")
            if plan["ascend_to_pinned"]:
                self.run_legs(plan["ascend_to_pinned"], "ascent_trajectory")

            # Gate (the red-team Lens-A fix): the z-changed off-contact guard, PINNED to the aligned
            # pre-ascent tile -- x/y EQUAL the contact tile, only z differs. A z-blind conjunction
            # (pos_abs[0:2] comparison) would wrongly read true here; the real one must read false.
            pos_pin, _pin_snap = self.export("pinned_pre_ascent")
            qp = self.query(pkg)
            comp_pin = self.composite(pos_pin, contact, qp)
            self.record("z_changed_off_contact_pinned", {
                "pos": pos_pin, "contact": contact,
                "xy_equal": pos_pin[:2] == contact[:2], "z_differs": pos_pin[2] != contact[2],
                "query_has": qp.get("has"), "composite": comp_pin, "expected": False,
                "pass": (pos_pin[:2] == contact[:2] and pos_pin[2] == -1 and
                         qp.get("ok") is True and qp.get("has") is True and comp_pin is False),
            })

            # --- Final ascend: the composite goes green at the contact tile. ---
            self.run_legs([(("vertical_move", "up"), contact, "t_stairs_down")], "final_ascent")
            pos_end, _end_snap = self.export("back_at_contact")
            qg = self.query(pkg)
            comp_green = self.composite(pos_end, contact, qg)
            self.record("composite_green_at_contact", {
                "pos": pos_end, "contact": contact, "query_has": qg.get("has"),
                "scope": qg.get("scope"), "composite": comp_green, "expected": True,
                "pass": (pos_end == contact and qg.get("ok") is True and qg.get("has") is True and
                         comp_green is True),
            })

            # Gate (doc 53): proven off-contact displacement flips the conjunction false while
            # possession stays true. Never trust the move alone -- prove the delta from the export.
            mv = self.command("move", "move_s")
            pos_off, _off_snap = self.export("off_contact")
            delta = [pos_off[i] - contact[i] for i in range(3)]
            qo = self.query(pkg)
            comp_off = self.composite(pos_off, contact, qo)
            self.record("off_contact_displacement", {
                "move_ok": mv.get("ok"), "pos": pos_off, "delta": delta,
                "query_has": qo.get("has"), "composite": comp_off, "expected": False,
                "pass": (mv.get("ok") is True and delta == [0, 1, 0] and qo.get("ok") is True and
                         qo.get("has") is True and comp_off is False),
            })

            # --- Cross-cutting guards over EVERY loaded snapshot. ---
            damage_hits = [(n, s["avatar"].get("damage_taken")) for (n, s) in self.snapshots
                           if s.get("avatar", {}).get("damage_taken")]
            self.record("no_damage_interference", {
                "snapshots": len(self.snapshots), "hits": damage_hits, "pass": not damage_hits,
            })
            lower = [(n, len(s["entities"]["monsters"]), len(s["entities"]["npcs"]))
                     for (n, s) in self.snapshots if s["avatar"]["pos_abs"][2] <= -2]
            bad_lower = [t for t in lower if t[1] or t[2]]
            self.record("hermetic_lower_floors", {
                "lower_floor_snapshots": len(lower), "violations": bad_lower, "pass": not bad_lower,
            })
            # Scope guard: every successful query carried the literal scope verbatim, and the count pins
            # the six successful queries (q0 start, qb before, qa after, qp pinned, qg green, qo off) --
            # a load-bearing count, not decoration: it stops all([]) passing vacuously if queries failed.
            expected_queries = 6
            scope_ok = (all(s == SCOPE for s in self.successful_query_scopes) and
                        len(self.successful_query_scopes) == expected_queries)
            self.record("scope_label_guard", {
                "scopes": self.successful_query_scopes, "expected_count": expected_queries,
                "pass": scope_ok,
            })

            # --- Clean quit. ---
            self.send({"id": self.next_id(), "op": "quit"})
            qresp = self.recv("the quit response")
            self.summary["quit_ok"] = (qresp.get("ok") is True and qresp.get("status") == "session_end")
            if not self.summary["quit_ok"]:
                self.summary["ok"] = False
            try:
                rc = self.proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=10)
                rc = -1
            self.summary["process_exit_code"] = rc
            if rc != 0:
                self.summary["ok"] = False
            return self.summary
        finally:
            if self.proc.poll() is None:
                self.proc.kill()  # never leave an orphaned backend if the driver aborts mid-session
                self.proc.wait(timeout=5)
            stderr_handle.close()


# The walk tile's terrain: on floors=2 it is the real basement's t_linoleum_white; on the tower the
# walk tile sits on a synthesized floor filled with the same id by design (see the generator).
EXPECTED_WALK_TER = "t_linoleum_white"


def main(argv=None):
    parser = argparse.ArgumentParser(description="Folded-Spike-29 vertical-slice composite live driver.")
    parser.add_argument("--exe", required=True, help="path to cataclysm-bn-tiles.exe")
    parser.add_argument("--world", required=True, help="slice world (ArcopolisSliceTest / ArcopolisTowerTest)")
    parser.add_argument("--floors", type=int, required=True, help="the fixture's floor count (2 or 6)")
    parser.add_argument("--userdir", required=True, help="user directory holding save/<world>")
    parser.add_argument("--export-dir", required=True, help="--arcopolis-export-dir for the backend")
    parser.add_argument("--package-typeid", default="box_small", help="the package itype_id")
    parser.add_argument("--out", required=True, help="path to write the JSON result summary")
    args = parser.parse_args(argv)
    summary = Driver(args).run()
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    print(json.dumps({"ok": summary["ok"], "gates": len(summary["gates"]),
                      "process_exit_code": summary.get("process_exit_code")}))
    return 0 if summary["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
