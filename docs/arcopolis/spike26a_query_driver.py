#!/usr/bin/env python3
"""Arcopolis Spike 26A - dialogue-predicate query live driver.

Drives ONE persistent ``--arcopolis-live`` backend over the ``ArcopolisCarriedNestedTest`` fixture and
exercises every Spike 26A witness case (the four predicate cases + fail-loud + structural-error gates),
then emits a JSON summary the pwsh regression parses. This driver is stdlib-only, mirrors the existing
``tools/arcopolis_client/harness.py`` style (one persistent process, one request at a time, every stdout
line verified to be a JSON protocol object), and reuses the same protocol parser shape -- no new
infrastructure.

Witnessed cases (in dispatch order):

  (1) ``query has_item glass_shard count=1``    -> has:true, scope:"on_person_dialogue_predicate"
      (load-bearing: visit_internal recurses into the worn backpack pocket; the export carried_items[]
      would MISS this item by construction. The divergence the postmortem named.)
  (2) ``query has_item rock count=1``           -> has:true (wielded source enumerated)
  (3) ``query has_item hairpin``   -> has:false (a stable valid id stably absent from the avatar)
  (4) ``query has_item feather count=1``        -> has:false (load-bearing scope-pinning: the item is
      on the avatar's OWN tile via crafting_inventory(); on-person predicate excludes it)
  (5) ``query has_item GARBAGE_UNKNOWN_ID``     -> ok:false, code:"bad_request"  (fail-loud)
  (6) ``query has_item glass_shard count=2``    -> has:false (worn-nested stack has 1; cap-to-qty semantics)
  (7) recovery: a final ``query has_item glass_shard`` after the bad-id rejection -> has:true (the
      session keeps serving after a recoverable error).

Then ``quit``. The driver expects exit 0 from the backend. Every stdout line must be a single JSON
object; the FIRST non-JSON line fails the driver immediately (the stdout-purity invariant from
Spike 9B).

Usage::

    python docs/arcopolis/spike26a_query_driver.py --exe <cataclysm-bn-tiles.exe> --world ArcopolisCarriedNestedTest --userdir <userdir> --out <result.json>
"""

import argparse
import json
import os
import subprocess
import sys
import time


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
        # Invalid UTF-8 is a genuine stdout-purity violation, not a normal condition -- fail loud with a
        # readable diagnostic rather than masking corrupt bytes (errors="replace") or crashing with an
        # unhandled traceback. The stdout-purity invariant (Spike 9B) means any such line is a bug.
        raise SystemExit("fatal: non-JSON/non-UTF-8 stdout line: %r (%s)" % (line[:200], e))
    if expected_type is not None and obj.get("type") != expected_type:
        raise SystemExit("fatal: expected type=%r, got %r" % (expected_type, obj))
    return obj


def _drive_mid_prompt_query_gate(p):
    """Spike 26A Gate 8: drive the LIVE TRANSCRIPT-LEVEL mid-prompt query rejection witness.

    Opens a real Spike 12A pickup PICKUP menu (the avatar's tile holds the ground feather from the
    ``ArcopolisCarriedNestedTest`` fixture), submits ``op:"query"`` mid-prompt, asserts the rejection
    is ``bad_request`` (with the prompt left OPEN), ``prompt_cancel``s cleanly, reads the command
    success response, and runs a final query that must return ``has:true`` (the session survives the
    mid-prompt rejection -- recoverable invariant).

    Returns a dict mirroring the expected regression gate-8 keys (``prompt_kind``, ``mid_query_*``,
    ``cancel_ack_ok``, ``command_resp_ok``, ``pass``) and a separate ``post_query_pass`` boolean for
    the recovery query. On any protocol-level error caught as SystemExit, ``pass`` is False and the
    ``fatal`` field carries the error string.

    Extracted from the inline body of ``run`` so the dispatch loop stays readable -- the gate is a
    self-contained scenario (open -> mid-prompt -> reject -> cancel -> finalize) with its own
    request-id space (200/201/202/203), distinct from the query-loop's 1..7 ids.
    """
    summary = {"pass": False}
    post_query_pass = False
    try:
        # 1. Open the Spike 12A pickup PICKUP menu (the prompt-source reader takes over stdin).
        _send(p, {"id": 200, "op": "command", "command": "pickup", "direction": "here"})
        prompt_evt = _read_line_json(p, expected_type="prompt")
        active_prompt_id = prompt_evt.get("prompt_id")
        # 2. Submit the mid-prompt query (the LOAD-BEARING test).
        _send(p, {"id": 201, "op": "query", "kind": "has_item", "item": "glass_shard", "count": 1})
        mid_resp = _read_line_json(p, expected_type="response")
        mid_ok = (mid_resp.get("ok") is False and
                  (mid_resp.get("error") or {}).get("code") == "bad_request")
        # 3. Close the prompt cleanly with prompt_cancel (the GUI ESC).
        _send(p, {"id": 202, "op": "prompt_cancel", "prompt_id": active_prompt_id})
        ack = _read_line_json(p)
        ack_ok = (ack.get("ok") is True and ack.get("cancelled") is True)
        # 4. Read the command's success response (canonical Spike 12A transcript shape after cancel).
        cmd_resp = _read_line_json(p, expected_type="response")
        cmd_ok = (cmd_resp.get("ok") is True and cmd_resp.get("op") == "command")
        summary = {
            "prompt_kind": prompt_evt.get("kind"),
            "mid_query_resp_ok": mid_resp.get("ok"),
            "mid_query_error_code": (mid_resp.get("error") or {}).get("code"),
            "cancel_ack_ok": ack_ok,
            "command_resp_ok": cmd_ok,
            "pass": (mid_ok and ack_ok and cmd_ok),
        }
    except SystemExit as e:
        summary = {"pass": False, "fatal": str(e)}
        return summary, False
    # 5. Recoverable invariant: a final query AFTER the mid-prompt rejection still succeeds.
    try:
        _send(p, {"id": 203, "op": "query", "kind": "has_item", "item": "glass_shard", "count": 1})
        post_resp = _read_line_json(p, expected_type="response")
        post_query_pass = (post_resp.get("ok") is True and post_resp.get("has") is True and
                           post_resp.get("scope") == "on_person_dialogue_predicate")
    except SystemExit as e:
        summary["post_query_fatal"] = str(e)
    return summary, post_query_pass


def run(args):
    cmd = [args.exe, "--arcopolis-live", "--world", args.world, "--userdir", args.userdir]
    if args.export_dir:
        cmd += ["--arcopolis-export-dir", args.export_dir]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE)
    # Ready event (one-shot).
    ready = _read_line_json(p, expected_type="ready")
    summary = {
        "ready": {"world": ready.get("world"), "protocol_version": ready.get("protocol_version")},
        "cases": [],
        "ok": True,
    }

    # Define the witness cases in dispatch order. Each entry: (req-id, payload, expected response fields).
    cases = [
        # (1) worn-pocket positive (container recursion through backpack)
        {"label": "worn_nested_glass_shard",
         "req": {"id": 1, "op": "query", "kind": "has_item", "item": "glass_shard", "count": 1},
         "expect_ok": True, "expect_has": True, "expect_scope": "on_person_dialogue_predicate"},
        # (2) wielded positive
        {"label": "wielded_rock",
         "req": {"id": 2, "op": "query", "kind": "has_item", "item": "rock", "count": 1},
         "expect_ok": True, "expect_has": True, "expect_scope": "on_person_dialogue_predicate"},
        # (3) valid-but-absent
        {"label": "absent_hairpin",
         "req": {"id": 3, "op": "query", "kind": "has_item", "item": "hairpin", "count": 1},
         "expect_ok": True, "expect_has": False, "expect_scope": "on_person_dialogue_predicate"},
        # (4) ground-tile negative (scope-pinning, load-bearing anti-crafting_inventory)
        {"label": "ground_feather",
         "req": {"id": 4, "op": "query", "kind": "has_item", "item": "feather", "count": 1},
         "expect_ok": True, "expect_has": False, "expect_scope": "on_person_dialogue_predicate"},
        # (5) unknown id -> fail-loud bad_request (recoverable; the session keeps serving)
        {"label": "garbage_unknown_id",
         "req": {"id": 5, "op": "query", "kind": "has_item", "item": "GARBAGE_UNKNOWN_ID", "count": 1},
         "expect_ok": False, "expect_code": "bad_request"},
        # (6) count > 1 against a single nested stack -> has:false (cap-to-qty)
        {"label": "worn_nested_count_2",
         "req": {"id": 6, "op": "query", "kind": "has_item", "item": "glass_shard", "count": 2},
         "expect_ok": True, "expect_has": False, "expect_scope": "on_person_dialogue_predicate"},
        # (7) recovery after the bad-id rejection
        {"label": "recovery_glass_shard",
         "req": {"id": 7, "op": "query", "kind": "has_item", "item": "glass_shard", "count": 1},
         "expect_ok": True, "expect_has": True, "expect_scope": "on_person_dialogue_predicate"},
    ]

    for c in cases:
        _send(p, c["req"])
        resp = _read_line_json(p, expected_type="response")
        observed = {
            "label": c["label"],
            "req_id": c["req"]["id"],
            "resp_ok": resp.get("ok"),
            "resp_op": resp.get("op"),
            "resp_kind": resp.get("kind"),
            "resp_has": resp.get("has"),
            "resp_scope": resp.get("scope"),
            "resp_error_code": (resp.get("error") or {}).get("code"),
            "resp_error_message": (resp.get("error") or {}).get("message"),
        }
        # Per-case pass/fail decision.
        ok = True
        if c["expect_ok"]:
            if resp.get("ok") is not True:
                ok = False
            elif resp.get("op") != "query":
                ok = False
            elif resp.get("kind") != "has_item":
                ok = False
            elif resp.get("has") != c["expect_has"]:
                ok = False
            elif resp.get("scope") != c["expect_scope"]:
                ok = False
        else:
            if resp.get("ok") is True:
                ok = False
            elif (resp.get("error") or {}).get("code") != c["expect_code"]:
                ok = False
        observed["pass"] = ok
        if not ok:
            summary["ok"] = False
        summary["cases"].append(observed)

    # Spike 26A Gate 8 (live transcript-level mid-prompt witness): pickup PICKUP menu opens,
    # mid-prompt op:"query" rejected as bad_request, prompt_cancel closes, command finalizes,
    # post-cancel recovery query succeeds. See _drive_mid_prompt_query_gate's docstring.
    mid_prompt_summary, post_query_pass = _drive_mid_prompt_query_gate(p)
    summary["mid_prompt"] = mid_prompt_summary
    summary["post_mid_prompt_query_pass"] = post_query_pass
    if not mid_prompt_summary.get("pass") or not post_query_pass:
        summary["ok"] = False

    # Clean quit.
    _send(p, {"id": 99, "op": "quit"})
    qresp = _read_line_json(p, expected_type="response")
    summary["quit_ok"] = (qresp.get("ok") is True and qresp.get("status") == "session_end")
    if not summary["quit_ok"]:
        summary["ok"] = False
    # Wait for clean exit; the backend self-exits with std::_Exit(0) after the quit response.
    try:
        rc = p.wait(timeout=15)
    except subprocess.TimeoutExpired:
        p.kill()
        rc = -1
    summary["process_exit_code"] = rc
    if rc != 0:
        summary["ok"] = False

    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description="Spike 26A dialogue-predicate query live driver.")
    parser.add_argument("--exe", required=True, help="path to cataclysm-bn-tiles.exe")
    parser.add_argument("--world", required=True, help="world to load (e.g. ArcopolisCarriedNestedTest)")
    parser.add_argument("--userdir", required=True, help="user directory holding save/<world>")
    parser.add_argument("--export-dir", default=None, help="optional --arcopolis-export-dir for the backend")
    parser.add_argument("--out", required=True, help="path to write the JSON result summary")
    args = parser.parse_args(argv)
    summary = run(args)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    print(json.dumps({"ok": summary["ok"], "cases": len(summary["cases"]),
                      "process_exit_code": summary.get("process_exit_code")}))
    return 0 if summary["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
