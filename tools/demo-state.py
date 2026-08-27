#!/usr/bin/env python3
"""Dev tool: injects fake sessions into state.json so every icon state can be
eyeballed without waiting for a real Claude Code session to misbehave.

Takes the same lock the hook does, so it merges instead of clobbering.

    tools/demo-state.py            # add three demo sessions
    tools/demo-state.py --limits   # also fake the plan usage windows
    tools/demo-state.py --clear    # remove both again
"""

import fcntl
import json
import os
import sys
import time

BASE = os.path.expanduser("~/.claude/statuslamp")
STATE = os.path.join(BASE, "state.json")
LOCK = os.path.join(BASE, "state.lock")
LIMITS = os.path.join(BASE, "limits.json")
PREFIX = "demo-"


def demo_sessions(now):
    def rec(sid, status, project, **kw):
        base = {
            "session_id": sid, "status": status,
            "cwd": os.path.expanduser("~/Documents/Work/" + project), "project": project,
            "pid": 1,  # launchd: always alive, so the liveness filter keeps it
            "entrypoint": "cli", "background": False,
            "started_at": now - 900, "updated_at": now, "turn_started_at": now - 95,
            "detail": "", "tool": "", "waiting_reason": "",
            "consecutive_failures": 0, "errors_total": 0, "tool_count": 0,
            "last_error": None, "last_event": "", "last_message": "",
        }
        base.update(kw)
        return base

    return {
        PREFIX + "waiting": rec(
            PREFIX + "waiting", "waiting", "mebelmarket",
            detail="rm -rf node_modules", tool="Bash",
            waiting_reason="Permission needed: Bash", tool_count=14),
        PREFIX + "working": rec(
            PREFIX + "working", "working", "berig",
            detail="npm test -- --watch=false", tool="Bash",
            consecutive_failures=1, errors_total=2, tool_count=31,
            turn_started_at=now - 142,
            last_error={"tool": "Bash", "message": "Exit code 1\nTest suite failed to run",
                        "at": now - 8}),
        PREFIX + "done": rec(
            PREFIX + "done", "done", "stubbs", updated_at=now - 240,
            detail="All tests pass",
            last_message="All tests pass", tool_count=9),
        PREFIX + "error": rec(
            PREFIX + "error", "error", "myntkaup-app", updated_at=now - 30,
            detail="Build failed", tool_count=22,
            consecutive_failures=2, errors_total=3,
            last_error={"tool": "Bash", "message": "Exit code 1\nswiftc: error: no such file",
                        "at": now - 30}),
    }


def demo_limits(now, used_5h=87.0, used_7d=41.0):
    return {
        "version": 1,
        "updated_at": now,
        "seen_at": now,
        "first_seen_at": now - 3600,
        "last_seen_at": now,
        "rate_limits_seen": True,
        "windows": {
            "five_hour": {"used_percentage": used_5h, "resets_at": now + 4520,
                          "captured_at": now, "session_id": PREFIX + "working"},
            "seven_day": {"used_percentage": used_7d, "resets_at": now + 291600,
                          "captured_at": now, "session_id": PREFIX + "working"},
        },
    }


def write_limits(state):
    tmp = LIMITS + ".demo.tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh, ensure_ascii=False)
    os.replace(tmp, LIMITS)


def main():
    clear = "--clear" in sys.argv
    only = None
    used = None
    for arg in sys.argv[1:]:
        if arg.startswith("--status="):
            only = arg.split("=", 1)[1]
        if arg.startswith("--limits="):
            used = float(arg.split("=", 1)[1])

    os.makedirs(BASE, exist_ok=True)
    if clear:
        try:
            os.remove(LIMITS)
        except OSError:
            pass
    elif "--limits" in sys.argv or used is not None:
        now = time.time()
        write_limits(demo_limits(now) if used is None else demo_limits(now, used, used / 2))
        print("limits: %s" % LIMITS)

    fd = os.open(LOCK, os.O_CREAT | os.O_RDWR, 0o644)
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        try:
            state = json.load(open(STATE))
        except Exception:
            state = {"version": 1, "updated_at": time.time(), "sessions": {}}

        sessions = state.setdefault("sessions", {})
        for sid in list(sessions):
            if sid.startswith(PREFIX):
                del sessions[sid]

        if not clear:
            now = time.time()
            for sid, rec in demo_sessions(now).items():
                if only and rec["status"] != only:
                    continue
                sessions[sid] = rec

        state["updated_at"] = time.time()
        tmp = STATE + ".demo.tmp"
        with open(tmp, "w") as fh:
            json.dump(state, fh, ensure_ascii=False)
        os.replace(tmp, STATE)
        print("sessions: %s" % sorted(sessions))
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


if __name__ == "__main__":
    main()
