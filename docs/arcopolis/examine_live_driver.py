#!/usr/bin/env python3
"""Raw-request live-protocol driver for the Spike 11A examine regression.

Feeds a file of raw JSON Lines requests to ONE persistent ``--arcopolis-live``
backend, strictly one request at a time (the next request is sent only after
the previous response arrived), with a STRICT per-response timeout: a deadline
breach KILLS the backend and exits nonzero -- a hang is a test FAILURE, never a
stuck script. Responses are captured verbatim into a result JSON for the
PowerShell regression to assert; this driver checks protocol mechanics only
(ready seen, one response per request, clean exit), never gameplay outcomes.

Stdlib-only. It reuses the Spike 9A/9B client harness's ``LiveSession`` (the
daemon reader thread + deadline ``recv`` + ``protocol.jsonl`` tee -- a Windows
pipe ``readline`` cannot be interrupted, so the main thread must never block on
it directly) instead of reimplementing the pipe plumbing. Requests are sent as
RAW LINES so even deliberately malformed probes reach the backend
byte-for-byte. Request-file format: one JSON request per line; blank lines and
``#`` comment lines are skipped; lines after an ``op:"quit"`` request are
ignored (the session is over).

Exit codes: 0 = every request answered and the backend exited cleanly;
1 = launch failure, protocol violation, timeout (backend killed), or a nonzero
backend exit. The result JSON carries the detail either way.
"""

import argparse
import json
import os
import subprocess
import sys
import time


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
                        help="seconds allowed per response (also for ready and process exit)")
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
    try:
        ready = session.recv(time.monotonic() + args.timeout, "the ready event")
        if ready.get("type") != "ready" or ready.get("ok") is not True:
            raise LiveProtocolError("first protocol line is not an ok ready event: %s"
                                    % json.dumps(ready)[:300])
        result["ready_seen"] = True
        result["protocol_version"] = ready.get("protocol_version")

        quit_sent = False
        for line in request_lines:
            # Raw write (not LiveSession.send): malformed probes must arrive verbatim.
            proc.stdin.write(line + "\n")
            proc.stdin.flush()
            resp = session.recv(time.monotonic() + args.timeout,
                                "the response to: %s" % line[:120])
            result["responses"].append(resp)
            try:
                if json.loads(line).get("op") == "quit":
                    quit_sent = True
                    break
            except ValueError:
                pass  # a malformed probe still got its error response above; keep going
        if not quit_sent:
            proc.stdin.close()  # EOF is the protocol's other clean end
        result["exit_code"] = proc.wait(timeout=args.timeout)
        if result["exit_code"] != 0:
            result["error"] = "backend exited %s (expected 0)" % result["exit_code"]
            return finish(1)
        result["ok"] = True
        return finish(0)
    except (LiveProtocolError, subprocess.TimeoutExpired, OSError) as err:
        result["error"] = "%s: %s" % (type(err).__name__, err)
        try:
            proc.kill()
            proc.wait(timeout=10)
        except OSError:
            pass
        except subprocess.TimeoutExpired:
            pass
        result["exit_code"] = proc.poll()
        return finish(1)
    finally:
        session.close()
        stderr_handle.close()


if __name__ == "__main__":
    sys.exit(main())
