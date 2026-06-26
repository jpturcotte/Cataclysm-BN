#!/usr/bin/env python3
"""Arcopolis Stage A return-condition L1 composite live driver.

Drives ONE persistent ``--arcopolis-live`` backend over the ``ArcopolisCarriedNestedTest`` fixture and
proves that a frontend/consumer can compute the chosen Stage A return signal

    carried_at_contact = avatar.pos_abs == contact_pos_abs
                         && query.has == true
                         && query.scope == "on_person_dialogue_predicate"

PURELY from existing native observations -- without the backend gaining any new "return condition" API,
mutating state, or touching mission/NPC/dialogue/crafting systems. This is **L1 observation only** (see
docs/arcopolis/53_STAGE_A_RETURN_CONDITION_WITNESS.md): it does NOT prove MGOAL_FIND_ITEM,
crafting_inventory(), mission completion, NPC turn-in, dialogue, or L4 input equivalence.

The composite is computed CONSUMER-SIDE from two existing surfaces, never a new backend conjunction:

  * position half (native-authority class S -- simulation-state): live ``op:"export"`` -> the snapshot's
    ``avatar.pos_abs`` (``ctx.u.abs_pos()``, src/arcopolis_export.cpp);
  * possession half (native-authority class C -- predicate-fidelity): live
    ``op:"query", kind:"has_item"`` -> BN's on-person dialogue predicate
    ``has_charges(id,count) || has_amount(id,count)`` (Spike 26A, src/arcopolis_live.cpp), labelled
    ``scope:"on_person_dialogue_predicate"``.

The ``command move`` step is NOT the claim under test; it is existing level-2/3 movement machinery used
only to manufacture the OFF-contact false-green case. The driver never trusts command success alone: it
exports AFTER the move and asserts ``avatar.pos_abs != contact_pos_abs`` (and the exact south delta),
failing loud if the move was blocked / prompted / a no-op rather than counting it as the wrong-position
case.

Witness cases (in dispatch order), each a row in the false-green matrix:

  (1) carried_at_contact_glass_shard -- AT contact, query glass_shard -> has:true.
      Composite TRUE. Pins the nested carried package at the contact tile (visit_internal recurses into
      the worn backpack pocket; the flat carried_items[] export would MISS it -- see (anti-flat) below).
  (2) dropped_at_contact_feather     -- AT contact, query feather -> has:false (the feather is on the
      avatar's OWN ground tile via crafting_inventory() reach; the on-person predicate excludes it).
      Composite FALSE. Pins dropped-near-contact / anti-crafting_inventory() false green.
  (3) wrong_position_glass_shard     -- AFTER a proven off-contact move, query glass_shard -> still
      has:true but pos_abs != contact. Composite FALSE. Pins possession-only false green.
  (4) absent_hairpin                 -- AFTER the move, a valid-but-absent id -> has:false.
      Composite FALSE.
  (5) unknown_id_fail_loud           -- a garbage itype_id -> ok:false, code:"bad_request" (recoverable;
      health/recovery only -- Spike 26A already proves it, NOT new Stage A evidence).

  (anti-flat) flat_carried_items_not_authority -- the contact export's flat avatar.carried_items[] does
      NOT contain the nested glass_shard, yet the query returns has:true. Proves the flat export cannot be
      substituted for the predicate.
  (scope) scope_label_guard -- every SUCCESSFUL query response carries scope="on_person_dialogue_predicate"
      verbatim (the load-bearing labelling guard).

Then ``quit``; the driver expects backend exit 0. This driver is stdlib-only, mirrors the Spike 26A
``spike26a_query_driver.py`` style (one persistent process, one request at a time, every stdout line a
verified JSON protocol object), and reuses the same protocol parser shape -- no new infrastructure, and
NO src/ change.

Usage::

    python docs/arcopolis/stage_a_return_condition_driver.py --exe <cataclysm-bn-tiles.exe> \
        --world ArcopolisCarriedNestedTest --userdir <userdir> --export-dir <dir> --out <result.json>
"""

import argparse
import json
import os
import subprocess

# The load-bearing labelling guard repeated verbatim across the Spike 26A response payload, doc 52, the
# ARCOPOLIS_STATE row, and the Stage A doc 53. A drift here would silently re-scope the possession half.
SCOPE = "on_person_dialogue_predicate"

# Witness ids (must match docs/arcopolis/make_carried_nested_fixture.py). glass_shard is the nested
# carried package; feather is the anti-crafting_inventory() ground scope-pin; hairpin is a valid-but-absent
# id; GARBAGE_UNKNOWN_ID exercises the fail-loud unknown-id path.
NESTED = "glass_shard"
GROUND = "feather"
ABSENT = "hairpin"
UNKNOWN = "GARBAGE_UNKNOWN_ID"


def _send(p, payload):
    """Write one JSON object as a single line + flush to the backend's stdin."""
    p.stdin.write((json.dumps(payload) + "\n").encode("utf-8"))
    p.stdin.flush()


def _read_line_json(p, expected_type=None):
    """Read one line from stdout and return the parsed JSON object. The first non-JSON line fails."""
    line = p.stdout.readline()
    if not line:
        raise SystemExit("fatal: backend closed stdout unexpectedly")
    try:
        obj = json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        # Invalid UTF-8 / non-JSON is a genuine stdout-purity violation (Spike 9B invariant), not a
        # normal condition -- fail loud with a readable diagnostic rather than masking corrupt bytes.
        raise SystemExit("fatal: non-JSON/non-UTF-8 stdout line: %r (%s)" % (line[:200], e))
    if expected_type is not None and obj.get("type") != expected_type:
        raise SystemExit("fatal: expected type=%r, got %r" % (expected_type, obj))
    return obj


def _load_snapshot(export_dir, filename):
    """Load the snapshot JSON the export response referenced (written under --arcopolis-export-dir)."""
    path = os.path.join(export_dir, filename)
    if not os.path.exists(path):
        raise SystemExit("fatal: export response named %r but no file at %s" % (filename, path))
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _carried_type_ids(snapshot):
    """The flat top-level avatar.carried_items[] type_ids (Spike 25 -- top-level only, never nested)."""
    avatar = snapshot.get("avatar", {})
    return [e.get("type_id") for e in avatar.get("carried_items", [])]


def _export(p, req_id, name, export_dir):
    """Send op:export, read the response, load the snapshot. Returns (response, snapshot)."""
    _send(p, {"id": req_id, "op": "export", "name": name})
    resp = _read_line_json(p, expected_type="response")
    if resp.get("ok") is not True or resp.get("op") != "export":
        raise SystemExit("fatal: export %r did not succeed: %r" % (name, resp))
    snap = _load_snapshot(export_dir, resp["snapshot"])
    return resp, snap


def _query(p, req_id, item, count=1):
    """Send op:query has_item, read the response. Returns the raw response object."""
    _send(p, {"id": req_id, "op": "query", "kind": "has_item", "item": item, "count": count})
    return _read_line_json(p, expected_type="response")


def _composite(pos_match, has, scope):
    """The consumer-side Stage A conjunction. Computed HERE in the driver, never by the backend."""
    return bool(pos_match and has and scope == SCOPE)


def run(args):
    cmd = [args.exe, "--arcopolis-live", "--world", args.world, "--userdir", args.userdir,
           "--arcopolis-export-dir", args.export_dir]
    # Inherit the parent's stderr (the pwsh wrapper redirects it to a log file) instead of capturing it in
    # an unread PIPE: an unread stderr=PIPE can deadlock if the backend floods it, and silently discards
    # crash logs. Wrap the session in try/finally so the backend is never left running if the driver aborts
    # mid-session (e.g. a SystemExit from _read_line_json). Matches the examine/prompt_menu driver pattern.
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        ready = _read_line_json(p, expected_type="ready")
        summary = {
            "ready": {"world": ready.get("world"), "protocol_version": ready.get("protocol_version")},
            "gates": {},
            "ok": True,
        }
        successful_query_scopes = []

        def record(name, gate):
            summary["gates"][name] = gate
            if not gate.get("pass"):
                summary["ok"] = False

        # --- Contact instant: export position, then query the two contact-time cases. ---
        _, contact_snap = _export(p, 1, "contact_start", args.export_dir)
        contact_pos = contact_snap.get("avatar", {}).get("pos_abs")
        if not (isinstance(contact_pos, list) and len(contact_pos) == 3):
            raise SystemExit("fatal: contact snapshot has no avatar.pos_abs list: %r" % (contact_pos,))
        flat_carried = _carried_type_ids(contact_snap)
        flat_has_nested = NESTED in flat_carried
        summary["contact_pos_abs"] = contact_pos
        summary["flat_carried_type_ids"] = flat_carried

        # (1) carried_at_contact_glass_shard: AT contact, has:true -> composite TRUE.
        q1 = _query(p, 2, NESTED)
        if q1.get("ok") is True:
            successful_query_scopes.append(q1.get("scope"))
        composite1 = _composite(True, q1.get("has") is True, q1.get("scope"))
        # The anti-flat divergence is part of THIS gate's evidence: the predicate finds the nested package the
        # flat export structurally cannot. We require has:true AND flat lacks the nested id (the divergence the
        # postmortem named). A flat export that suddenly DOES contain it is a STOP -> re-audit, not a soft pass.
        record("carried_at_contact_glass_shard", {
            "pos_match": True, "query_ok": q1.get("ok"), "query_has": q1.get("has"),
            "scope": q1.get("scope"), "flat_carried_has": flat_has_nested,
            "composite": composite1, "expected": True,
            "pass": (q1.get("ok") is True and composite1 is True),
        })
        # Dedicated anti-flat-authority gate: query true while the flat export omits the nested package.
        record("flat_carried_items_not_authority", {
            "query_has": q1.get("has"), "flat_carried_has": flat_has_nested,
            "expected": "query has:true AND flat lacks " + NESTED,
            "pass": (q1.get("has") is True and flat_has_nested is False),
        })

        # (2) dropped_at_contact_feather: AT contact, has:false -> composite FALSE (anti-crafting_inventory).
        q2 = _query(p, 3, GROUND)
        if q2.get("ok") is True:
            successful_query_scopes.append(q2.get("scope"))
        composite2 = _composite(True, q2.get("has") is True, q2.get("scope"))
        record("dropped_at_contact_feather", {
            "pos_match": True, "query_ok": q2.get("ok"), "query_has": q2.get("has"),
            "scope": q2.get("scope"), "composite": composite2, "expected": False,
            "pass": (q2.get("ok") is True and q2.get("has") is False and composite2 is False),
        })

        # --- Move OFF contact (witness tool only -- existing level 2/3 movement). Do not trust success. ---
        _send(p, {"id": 4, "op": "command", "command": "move", "direction": "move_s"})
        mv = _read_line_json(p, expected_type="response")
        move_ok = (mv.get("ok") is True and mv.get("op") == "command")
        if not move_ok:
            # Blocked / prompted / rejected (e.g. Spike 21 unexpected_prompt). FAIL LOUD -- never silently
            # treated as the wrong-position case. We still gather the post-move evidence below.
            summary["ok"] = False
        summary["move"] = {"ok": mv.get("ok"), "op": mv.get("op"),
                           "error_code": (mv.get("error") or {}).get("code")}

        # Export AFTER the move and PROVE the position changed (the plan's hard requirement).
        _, after_snap = _export(p, 5, "after_move", args.export_dir)
        after_pos = after_snap.get("avatar", {}).get("pos_abs")
        if not (isinstance(after_pos, list) and len(after_pos) == 3):
            raise SystemExit("fatal: after-move snapshot has no avatar.pos_abs list: %r" % (after_pos,))
        delta = [after_pos[i] - contact_pos[i] for i in range(3)]
        moved_off_contact = (after_pos != contact_pos)
        south_single_tile = (delta == [0, 1, 0])  # move_s = +y, one tile (move_se asserts [1,1,0])
        summary["after_pos_abs"] = after_pos
        summary["move"].update({"moved_off_contact": moved_off_contact, "delta": delta,
                                "south_single_tile": south_single_tile})

        # (3) wrong_position_glass_shard: AFTER the move, still has:true but pos != contact -> composite FALSE.
        q3 = _query(p, 6, NESTED)
        if q3.get("ok") is True:
            successful_query_scopes.append(q3.get("scope"))
        after_pos_match = (after_pos == contact_pos)
        composite3 = _composite(after_pos_match, q3.get("has") is True, q3.get("scope"))
        record("wrong_position_glass_shard", {
            "pos_match": after_pos_match, "query_ok": q3.get("ok"), "query_has": q3.get("has"),
            "scope": q3.get("scope"), "composite": composite3, "expected": False,
            "moved_off_contact": moved_off_contact, "delta": delta, "move_ok": move_ok,
            # Possession must still be true (the package is carried), position must differ, and the move must
            # have genuinely happened (proven off-contact + clean command), or the false-green is unproven.
            "pass": (q3.get("ok") is True and q3.get("has") is True and composite3 is False and
                     moved_off_contact and south_single_tile and move_ok),
        })

        # (4) absent_hairpin: a valid-but-absent id -> has:false -> composite FALSE.
        q4 = _query(p, 7, ABSENT)
        if q4.get("ok") is True:
            successful_query_scopes.append(q4.get("scope"))
        composite4 = _composite(after_pos_match, q4.get("has") is True, q4.get("scope"))
        record("absent_hairpin", {
            "pos_match": after_pos_match, "query_ok": q4.get("ok"), "query_has": q4.get("has"),
            "scope": q4.get("scope"), "composite": composite4, "expected": False,
            "pass": (q4.get("ok") is True and q4.get("has") is False and composite4 is False),
        })

        # (5) unknown_id_fail_loud: garbage itype_id -> ok:false, bad_request (recoverable). Health gate only;
        # Spike 26A already proves it -- NOT new Stage A evidence.
        q5 = _query(p, 8, UNKNOWN)
        record("unknown_id_fail_loud", {
            "query_ok": q5.get("ok"), "error_code": (q5.get("error") or {}).get("code"),
            "expected": "ok:false code:bad_request",
            "pass": (q5.get("ok") is False and (q5.get("error") or {}).get("code") == "bad_request"),
        })

        # (scope) labelling guard: every SUCCESSFUL query carried the literal scope string verbatim. The count
        # guard (== 4) is load-bearing, not decorative: it pins the four successful queries (q1 glass@contact,
        # q2 feather@contact, q3 glass@after, q4 hairpin@after; q5 is the unknown id -> ok:false, never appended)
        # AND stops all([]) from passing vacuously if every query had failed. Update it if a query case is added.
        scope_label_ok = all(s == SCOPE for s in successful_query_scopes) and len(successful_query_scopes) == 4
        # Recorded at the top level (parallel to summary["ok"]), intentionally NOT under summary["gates"]: this is
        # a cross-cutting invariant over all queries, not a per-case gate; the wrapper reads $result.scope_label_ok.
        summary["scope_label_ok"] = scope_label_ok
        summary["successful_query_scopes"] = successful_query_scopes
        if not scope_label_ok:
            summary["ok"] = False

        # --- Clean quit. ---
        _send(p, {"id": 99, "op": "quit"})
        qresp = _read_line_json(p, expected_type="response")
        summary["quit_ok"] = (qresp.get("ok") is True and qresp.get("status") == "session_end")
        if not summary["quit_ok"]:
            summary["ok"] = False
        try:
            rc = p.wait(timeout=15)
        except subprocess.TimeoutExpired:
            p.kill()
            rc = -1
        summary["process_exit_code"] = rc
        if rc != 0:
            summary["ok"] = False

        return summary
    finally:
        if p.poll() is None:
            p.kill()  # never leave an orphaned backend if the driver aborts mid-session


def main(argv=None):
    parser = argparse.ArgumentParser(description="Stage A return-condition L1 composite live driver.")
    parser.add_argument("--exe", required=True, help="path to cataclysm-bn-tiles.exe")
    parser.add_argument("--world", required=True, help="world to load (e.g. ArcopolisCarriedNestedTest)")
    parser.add_argument("--userdir", required=True, help="user directory holding save/<world>")
    parser.add_argument("--export-dir", required=True, help="--arcopolis-export-dir for the backend (snapshots)")
    parser.add_argument("--out", required=True, help="path to write the JSON result summary")
    args = parser.parse_args(argv)
    summary = run(args)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    print(json.dumps({"ok": summary["ok"], "gates": len(summary["gates"]),
                      "process_exit_code": summary.get("process_exit_code")}))
    return 0 if summary["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
