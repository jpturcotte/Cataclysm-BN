#!/usr/bin/env python3
"""Prompt-aware raw-request live-protocol driver for the Spike 12A pickup prompt/menu regression.

Extends the Spike 11A ``examine_live_driver.py`` model (one persistent ``--arcopolis-live`` backend, raw
JSON Lines requests, a STRICT per-response timeout so a hang KILLS the backend and FAILS) with the one
thing the pickup transaction needs: a ``{"type":"prompt"}`` line is NON-TERMINAL. A command that reaches a
real in-action menu emits a ``prompt`` event first, and its own terminal ``response`` only arrives after the
client answers. So this driver does not assume one response per request; it sends the next scripted request
at the right moments and keeps receiving until each command actually resolves.

When to send the next scripted request (``should_send_next``):
  * after a ``prompt`` event          -> send the next request (it is the prompt_answer / prompt_cancel);
  * after an ``ok:false`` prompt_answer-> the prompt stays OPEN, so send the next request (a retry);
  * after any other terminal response -> the previous command is done, send the next top-level request;
  * after an ``ok:true`` prompt_answer -> do NOT send; wait for the command's own terminal response.

Every received line (ready / prompt / response / ack) is captured verbatim into the result JSON for the
PowerShell regression to assert; this driver checks protocol mechanics only (ready seen, clean exit, no
hang), never gameplay outcomes. Stdlib-only; reuses the Spike 9A/9B client harness ``LiveSession`` (daemon
reader thread + deadline ``recv`` + ``protocol.jsonl`` tee -- a Windows pipe ``readline`` cannot be
interrupted, so the main thread must never block on it directly).

Request-file format: one JSON request per line; blank lines and ``#`` comment lines are skipped. Lines after
an ``op:"quit"`` request are ignored (the session is over).

Exit codes: 0 = every request sent, every command resolved, and the backend exited cleanly; 1 = launch
failure, protocol violation, timeout (backend killed), or a nonzero backend exit. The result JSON carries
the detail either way.
"""

import argparse
import json
import os
import subprocess
import sys
import time


def should_send_next(resp):
    """True iff receiving ``resp`` means the client should now send the next scripted request."""
    kind = resp.get("type")
    if kind == "prompt":
        return True  # the server is waiting for a prompt_answer / prompt_cancel
    if kind == "response":
        if resp.get("op") == "prompt_answer":
            # ok:false => invalid/rejected, prompt stays open -> send a retry; ok:true => the command
            # response is still coming, so wait for it.
            return not resp.get("ok", False)
        return True  # command / export / quit / error response -> the request is done
    return False  # "ready" or anything else: keep receiving


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True, help="cataclysm-bn-tiles binary")
    parser.add_argument("--world", required=True, help="world name under <userdir>/save")
    parser.add_argument("--userdir", required=True, help="sandbox userdir (--userdir passthrough)")
    parser.add_argument("--out", required=True,
                        help="export dir (snapshots + session.jsonl + protocol.jsonl)")
    parser.add_argument("--requests", required=True,
                        help="file of raw JSON request lines (# and blank lines skipped)")
    parser.add_argument("--timeout", type=float, default=30.0,
                        help="seconds allowed per received line (also for ready and process exit)")
    parser.add_argument("--result", required=True, help="path the result JSON is written to")
    args = parser.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, os.path.normpath(os.path.join(here, "..", "..", "tools", "arcopolis_client")))
    from harness import LiveProtocolError, LiveSession

    result = {"ok": False, "ready_seen": False, "protocol_version": None,
              "responses": [], "exit_code": None, "error": None}

    def finish(code):
        with open(args.result, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=1)
        return code

    with open(args.requests, "r", encoding="utf-8") as handle:
        request_lines = [line.strip() for line in handle
                         if line.strip() and not line.strip().startswith("#")]
    if not request_lines:
        result["error"] = "no requests in %s" % args.requests
        return finish(1)

    os.makedirs(args.out, exist_ok=True)
    stderr_handle = open(os.path.join(args.out, "backend_stderr.txt"), "w", encoding="utf-8")
    argv = [args.exe, "--world", args.world, "--arcopolis-live",
            "--arcopolis-export-dir", args.out, "--userdir", args.userdir]
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=stderr_handle, text=True, encoding="utf-8",
                                errors="replace")
    except OSError as err:
        result["error"] = "could not launch the backend: %s" % err
        stderr_handle.close()
        return finish(1)

    session = LiveSession(proc, os.path.join(args.out, "protocol.jsonl"))

    def send_raw(line):
        # Raw write (not LiveSession.send): malformed probes must arrive verbatim.
        proc.stdin.write(line + "\n")
        proc.stdin.flush()

    def op_of(line):
        try:
            parsed = json.loads(line)
        except ValueError:
            return None
        return parsed.get("op") if isinstance(parsed, dict) else None

    try:
        ready = session.recv(time.monotonic() + args.timeout, "the ready event")
        if ready.get("type") != "ready" or ready.get("ok") is not True:
            raise LiveProtocolError("first protocol line is not an ok ready event: %s"
                                    % json.dumps(ready)[:300])
        result["ready_seen"] = True
        result["protocol_version"] = ready.get("protocol_version")

        next_idx = 0
        quit_sent = False
        # Send the first request, then receive lines, sending further requests only at the moments
        # should_send_next() dictates (a prompt or a rejected answer mid-command, or a command finishing).
        send_raw(request_lines[next_idx])
        quit_sent = op_of(request_lines[next_idx]) == "quit"
        next_idx += 1

        while True:
            resp = session.recv(time.monotonic() + args.timeout, "a protocol line")
            result["responses"].append(resp)
            if not should_send_next(resp):
                continue  # e.g. an ok:true prompt_answer ack -> the command response is still coming
            if quit_sent:
                break  # the quit response arrived; the session is ending
            if next_idx >= len(request_lines):
                break  # all requests sent and the last one resolved
            send_raw(request_lines[next_idx])
            quit_sent = op_of(request_lines[next_idx]) == "quit"
            next_idx += 1

        if not quit_sent:
            proc.stdin.close()  # EOF is the protocol's other clean end
        result["exit_code"] = proc.wait(timeout=args.timeout)
        if result["exit_code"] != 0:
            result["error"] = "backend exited %s (expected 0)" % result["exit_code"]
            return finish(1)
        if next_idx < len(request_lines):
            result["error"] = ("backend ended after %d/%d requests sent"
                               % (next_idx, len(request_lines)))
            return finish(1)
        result["ok"] = True
        return finish(0)
    except (LiveProtocolError, subprocess.TimeoutExpired, OSError) as err:
        result["error"] = "%s: %s" % (type(err).__name__, err)
        try:
            proc.kill()
            proc.wait(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            pass
        result["exit_code"] = proc.poll()
        return finish(1)
    finally:
        session.close()
        # Defense in depth: reap a process the except path did not (e.g. KeyboardInterrupt). On Windows an
        # orphan is not reaped on parent exit and would sit blocked on stdin holding a loaded world.
        if proc.poll() is None:
            try:
                proc.kill()
                proc.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                pass
        stderr_handle.close()


if __name__ == "__main__":
    sys.exit(main())
