#!/usr/bin/env python3
"""Claude Code -> menu bar status bridge.

Reads one hook event on stdin and folds it into ~/.claude/claude-status/state.json,
which the ClaudeStatus menu bar app renders.

Run with --statusline it acts as a Claude Code `statusLine` command instead,
folding the account's plan usage windows into limits.json for the same app.

Runs on every tool call, so it must be fast, silent and unable to break the
session: it never writes to stdout (UserPromptSubmit stdout is injected into
Claude's context) and always exits 0.
"""

import errno
import fcntl
import json
import os
import sys
import time

HOME = os.path.expanduser("~")
BASE = os.path.join(HOME, ".claude", "claude-status")
STATE = os.path.join(BASE, "state.json")
LOCK = os.path.join(BASE, "state.lock")
LIMITS = os.path.join(BASE, "limits.json")
LIMITS_LOCK = os.path.join(BASE, "limits.lock")
LOG = os.path.join(BASE, "hook.log")

STATE_VERSION = 1
MAX_SESSIONS = 60
SESSION_TTL = 24 * 3600  # forget sessions untouched for a day
LOCK_TIMEOUT = 1.5       # never stall a tool call for longer than this

LIMITS_VERSION = 1
# The status line sits in front of an on-screen UI element and fires several
# times a second while a turn streams, so this path is stingier than the hook
# one: never queue long behind another session, never rewrite an unchanged file.
LIMITS_LOCK_TIMEOUT = 0.3
LIMITS_HEARTBEAT = 60
# The only two windows the status line payload carries. seven_day_opus,
# model_scoped and the rest exist solely in the SDK's get_usage response.
LIMIT_WINDOWS = (("five_hour", "5h"), ("seven_day", "7d"))
INF = float("inf")


def debug(msg):
    if os.environ.get("CLAUDE_STATUS_DEBUG") != "1":
        return
    try:
        with open(LOG, "a") as fh:
            fh.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))
    except Exception:
        pass


# --------------------------------------------------------------------------
# describing what Claude is doing right now
# --------------------------------------------------------------------------

# StopFailure.error is an enum; show it in words rather than as a slug.
API_ERRORS = {
    "rate_limit": "Rate limit",
    "overloaded": "Service overloaded",
    "authentication_failed": "Authentication failed",
    "oauth_org_not_allowed": "Organisation not allowed",
    "billing_error": "Billing problem",
    "invalid_request": "Invalid request",
    "model_not_found": "Model not found",
    "server_error": "Server error",
    "max_output_tokens": "Output limit exceeded",
    "unknown": "Unknown error",
}


def _clip(text, limit):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def describe_tool(tool, args):
    args = args if isinstance(args, dict) else {}

    def arg(*names):
        for name in names:
            value = args.get(name)
            if value:
                return value
        return None

    if tool == "Bash":
        return _clip(arg("command") or "", 90)
    if tool in ("Read", "Edit", "Write", "NotebookEdit"):
        path = arg("file_path", "notebook_path")
        return os.path.basename(path) if path else ""
    if tool in ("Grep", "Glob"):
        return _clip(arg("pattern") or "", 60)
    if tool in ("WebFetch", "WebSearch"):
        return _clip(arg("url", "query") or "", 60)
    if tool in ("Task", "Agent"):
        return _clip(arg("description", "subagent_type") or "", 60)
    if tool == "Skill":
        return _clip(arg("skill") or "", 40)
    return _clip(arg("description") or "", 60)


# --------------------------------------------------------------------------
# state file
# --------------------------------------------------------------------------

def lock(path, timeout):
    """Exclusive flock, or None if someone else still holds it. Never waits
    longer than `timeout`: no status file is worth stalling a session over."""
    deadline = time.time() + timeout
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except IOError:
            if time.time() > deadline:
                os.close(fd)
                return None
            time.sleep(0.01)


def unlock(fd):
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
    except Exception:
        pass


def blank_state():
    return {"version": STATE_VERSION, "updated_at": time.time(), "sessions": {}}


def load_state():
    try:
        with open(STATE) as fh:
            data = json.load(fh)
        if isinstance(data, dict) and isinstance(data.get("sessions"), dict):
            return data
    except Exception:
        pass
    return blank_state()


def pid_alive(pid):
    if not pid:
        return True  # unknown pid: assume alive, staleness will catch it
    try:
        os.kill(int(pid), 0)
        return True
    except OSError as exc:
        return exc.errno == errno.EPERM  # exists but owned by someone else
    except Exception:
        return True


def prune(state, keep_id):
    now = time.time()
    sessions = state["sessions"]
    for sid in list(sessions.keys()):
        if sid == keep_id:
            continue
        rec = sessions[sid]
        if not isinstance(rec, dict):
            del sessions[sid]
            continue
        if now - rec.get("updated_at", 0) > SESSION_TTL or not pid_alive(rec.get("pid")):
            del sessions[sid]
    if len(sessions) > MAX_SESSIONS:
        ordered = sorted(sessions.items(), key=lambda kv: kv[1].get("updated_at", 0))
        for sid, _ in ordered[: len(sessions) - MAX_SESSIONS]:
            if sid != keep_id:
                del sessions[sid]


def save_state(state):
    state["version"] = STATE_VERSION
    state["updated_at"] = time.time()
    tmp = "%s.%d.tmp" % (STATE, os.getpid())
    with open(tmp, "w") as fh:
        json.dump(state, fh, ensure_ascii=False)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, STATE)


# --------------------------------------------------------------------------
# event -> state folding
# --------------------------------------------------------------------------

def new_record(sid, event):
    now = time.time()
    cwd = event.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or ""
    return {
        "session_id": sid,
        "status": "idle",
        "cwd": cwd,
        "project": os.path.basename(cwd.rstrip("/")) or cwd or "claude",
        "pid": _claude_pid(),
        "entrypoint": os.environ.get("CLAUDE_CODE_ENTRYPOINT", ""),
        "background": _is_background(),
        "started_at": now,
        "updated_at": now,
        "turn_started_at": now,
        "detail": "",
        "tool": "",
        "waiting_reason": "",
        "consecutive_failures": 0,
        "errors_total": 0,
        "tool_count": 0,
        "last_error": None,
        "last_event": "",
        "last_message": "",
    }


# Non-interactive entrypoints: `claude -p` and SDK/MCP callers. These are the
# sessions worth hiding. CLAUDE_CODE_CHILD_SESSION cannot be used for this -
# some setups run the user's own terminal under an agent harness that sets it,
# which would hide the very sessions the indicator exists for.
BACKGROUND_ENTRYPOINTS = ("sdk-cli", "sdk-py", "sdk-ts", "mcp")


def _is_background():
    entrypoint = os.environ.get("CLAUDE_CODE_ENTRYPOINT", "")
    if entrypoint:
        return entrypoint in BACKGROUND_ENTRYPOINTS
    # Unknown entrypoint: fall back to the child flag, and prefer showing.
    return os.environ.get("CLAUDE_CODE_CHILD_SESSION") == "1"


def _claude_pid():
    raw = os.environ.get("CLAUDE_PID")
    if raw and raw.isdigit():
        return int(raw)
    return os.getppid()


def apply_event(state, event):
    name = event.get("hook_event_name") or ""
    sid = event.get("session_id") or os.environ.get("CLAUDE_CODE_SESSION_ID")
    if not sid:
        return None

    sessions = state["sessions"]
    rec = sessions.get(sid)
    if not isinstance(rec, dict):
        rec = new_record(sid, event)
        sessions[sid] = rec

    now = time.time()
    rec["updated_at"] = now
    rec["last_event"] = name
    if event.get("cwd"):
        rec["cwd"] = event["cwd"]
        rec["project"] = os.path.basename(event["cwd"].rstrip("/")) or event["cwd"]
    # A session that predates the app install has no pid yet.
    if not rec.get("pid"):
        rec["pid"] = _claude_pid()
    # Recomputed on every event so a record created before this rule existed,
    # or first seen through a subagent, corrects itself.
    rec["background"] = _is_background()

    if name == "SessionStart":
        # source is one of startup/resume/clear/compact/fork. "compact" fires
        # mid-turn on auto-compaction under the same session_id - it is not a
        # new session, so the running turn's status and counters must survive.
        if event.get("source") != "compact":
            rec["status"] = "idle"
            rec["detail"] = ""
            rec["consecutive_failures"] = 0
            rec["errors_total"] = 0

    elif name == "UserPromptSubmit":
        rec["status"] = "working"
        rec["turn_started_at"] = now
        rec["detail"] = _clip(event.get("prompt") or "", 70)
        rec["tool"] = ""
        rec["waiting_reason"] = ""
        rec["consecutive_failures"] = 0
        rec["errors_total"] = 0
        rec["tool_count"] = 0
        rec["last_error"] = None
        rec["last_message"] = ""

    elif name == "PreToolUse":
        tool = event.get("tool_name") or "tool"
        rec["status"] = "working"
        rec["tool"] = tool
        rec["detail"] = describe_tool(tool, event.get("tool_input"))
        rec["waiting_reason"] = ""
        rec["tool_count"] = rec.get("tool_count", 0) + 1

    elif name == "PostToolUse":
        rec["status"] = "working"
        rec["waiting_reason"] = ""
        rec["consecutive_failures"] = 0  # Claude recovered; stop badging

    elif name == "PostToolUseFailure":
        tool = event.get("tool_name") or "tool"
        if event.get("is_interrupt"):
            # user pressed Esc - not a failure worth alarming about
            rec["status"] = "done"
            rec["detail"] = "Interrupted"
            rec["consecutive_failures"] = 0
        else:
            rec["status"] = "working"
            rec["consecutive_failures"] = rec.get("consecutive_failures", 0) + 1
            rec["errors_total"] = rec.get("errors_total", 0) + 1
            rec["last_error"] = {
                "tool": tool,
                "message": _clip(event.get("error") or "", 300),
                "at": now,
            }
        rec["waiting_reason"] = ""

    elif name == "PermissionRequest":
        rec["status"] = "waiting"
        tool = event.get("tool_name") or "tool"
        rec["waiting_reason"] = "Permission needed: %s" % tool
        rec["detail"] = describe_tool(tool, event.get("tool_input")) or rec.get("detail", "")

    elif name == "PermissionDenied":
        # A denial is the user's decision, not a failure - just forward progress.
        rec["status"] = "working"
        rec["waiting_reason"] = ""

    elif name == "Notification":
        message = _clip(event.get("message") or "", 120)
        kind = event.get("notification_type") or event.get("type") or ""
        if kind == "idle_prompt":
            # Fires a minute after Claude goes quiet, including after a finished
            # turn - only treat it as a pause if Claude was mid-flight.
            if rec.get("status") == "working":
                rec["status"] = "waiting"
                rec["waiting_reason"] = message or "Waiting for you"
        elif kind in ("permission_prompt", "agent_needs_input", "elicitation_dialog"):
            rec["status"] = "waiting"
            rec["waiting_reason"] = message or "Waiting for you"
        elif not kind and rec.get("status") == "working":
            # Unknown/older builds: fall back to the conservative rule.
            rec["status"] = "waiting"
            rec["waiting_reason"] = message or "Waiting for you"
        elif message:
            rec["waiting_reason"] = message

    elif name == "StopFailure":
        # The turn died on an API/session error - rate limit, overload, auth.
        kind = event.get("error") or ""
        detail = _clip(event.get("error_details") or "", 240)
        rec["status"] = "error"
        rec["tool"] = ""
        rec["waiting_reason"] = ""
        rec["errors_total"] = rec.get("errors_total", 0) + 1
        rec["last_error"] = {
            "tool": API_ERRORS.get(kind, kind or "API"),
            "message": detail,
            "at": now,
        }
        rec["detail"] = API_ERRORS.get(kind, kind or "API error")

    elif name == "Stop":
        failures = rec.get("consecutive_failures", 0)
        rec["status"] = "error" if failures > 0 else "done"
        rec["tool"] = ""
        rec["waiting_reason"] = ""
        rec["last_message"] = _clip(event.get("last_assistant_message") or "", 120)
        rec["detail"] = rec["last_message"]

    elif name == "SessionEnd":
        sessions.pop(sid, None)
        return sid

    return sid


# --------------------------------------------------------------------------
# plan usage limits
#
# Claude Code puts the account's rate-limit windows in the JSON it hands to the
# `statusLine` command. That is the only local surface carrying them: no hook
# event has a usage field, and neither does the subagent status line, the OTel
# metrics or the injected environment. So the same script doubles as a status
# line - it folds the numbers into limits.json for the app, and prints them for
# the terminal whose slot it took.
# --------------------------------------------------------------------------

def blank_limits():
    return {
        "version": LIMITS_VERSION,
        "updated_at": 0.0,
        "seen_at": 0.0,        # last status line run, whatever it carried
        "first_seen_at": 0.0,
        "last_seen_at": 0.0,   # last run that actually carried rate_limits
        "rate_limits_seen": False,
        "windows": {},
    }


def load_limits():
    try:
        with open(LIMITS) as fh:
            data = json.load(fh)
        if isinstance(data, dict) and isinstance(data.get("windows"), dict):
            state = blank_limits()
            state.update(data)
            return state
    except Exception:
        pass
    return blank_limits()


def _number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if value != value or value == INF or value == -INF:  # NaN, +/-inf
        return None
    return float(value)


def read_windows(payload, now):
    """`rate_limits` is absent for API-key, Bedrock and Vertex sessions, and for
    every session until its first API response: the numbers ride in on
    anthropic-ratelimit-unified-* response headers, and each Claude Code process
    keeps its own copy fed only by its own requests."""
    limits = payload.get("rate_limits")
    if not isinstance(limits, dict):
        return {}
    found = {}
    for key, _ in LIMIT_WINDOWS:
        window = limits.get(key)
        if not isinstance(window, dict):
            continue
        used = _number(window.get("used_percentage"))
        resets = _number(window.get("resets_at"))
        # Claude Code drops a window the moment it resets, and a non-numeric
        # utilisation would arrive as null. Either way there is nothing to show.
        if used is None or resets is None or resets <= now:
            continue
        found[key] = {"used_percentage": used, "resets_at": int(resets)}
    return found


def pick_window(stored, fresh):
    """Utilisation only climbs until the window resets, so within one window a
    lower reading is an older session's stale view rather than a refund -
    shift-tabbing in a terminal idle since morning re-fires its status line with
    this morning's number. Taking the maximum kills that flicker.

    Two *live* windows with different resets_at cannot be the same window,
    though: a stale process reports the same fixed reset time, and an expired
    one has already been filtered out. So a differing reset time means a new
    generation or - after `/login` - a different account, and the fresh reading
    wins in both directions. Without that, switching accounts would leave the
    previous account's numbers on screen until its window ran out."""
    if fresh is None:
        return stored
    if stored is None:
        return fresh
    if fresh["resets_at"] != stored["resets_at"]:
        return fresh
    if fresh["used_percentage"] >= stored["used_percentage"]:
        return fresh
    return stored


def _digest(window):
    if not isinstance(window, dict):
        return None
    return (round(window.get("used_percentage", 0), 1), window.get("resets_at"))


def merge_limits(fresh, session_id, now):
    """Folds one status line payload into limits.json and returns what the app
    will see, so the terminal prints the same thing the menu bar shows."""
    fd = lock(LIMITS_LOCK, LIMITS_LOCK_TIMEOUT)
    if fd is None:
        debug("limits lock busy")
        return fresh
    try:
        state = load_limits()
        stored = state.get("windows")
        stored = stored if isinstance(stored, dict) else {}
        merged = {}
        changed = False

        for key, _ in LIMIT_WINDOWS:
            before = stored.get(key)
            if not isinstance(before, dict) or before.get("resets_at", 0) <= now:
                before = None            # rolled over while nothing was watching
            sample = fresh.get(key)
            chosen = pick_window(before, sample)
            if chosen is None:
                changed = changed or key in stored
                continue
            record = dict(chosen)
            # A missing window means "this process has not heard yet", never
            # "the limit is gone", so absence must not erase what we know. The
            # timestamp is what lets the app admit the number may be hours old,
            # so it follows the reading that actually WON: a stale session
            # re-reporting an old number must not refresh a stamp it did not
            # earn. pick_window returns the object it picked, so `is` is exact.
            if chosen is sample:
                record["captured_at"] = now
                record["session_id"] = session_id or ""
            else:
                record["captured_at"] = (before or {}).get("captured_at", 0)
                record["session_id"] = (before or {}).get("session_id", "")
            merged[key] = record
            changed = changed or _digest(before) != _digest(record)

        state["windows"] = merged
        state["seen_at"] = now
        if not state.get("first_seen_at"):
            state["first_seen_at"] = now
        if fresh:
            state["rate_limits_seen"] = True
            state["last_seen_at"] = now

        # The status line fires several times a second while a turn streams and
        # these numbers move a percent every few minutes, so write only when
        # something moved - plus a slow heartbeat, so "as of" stays honest.
        if changed or now - float(state.get("updated_at") or 0) >= LIMITS_HEARTBEAT:
            state["version"] = LIMITS_VERSION
            state["updated_at"] = now
            save_limits(state)
        return merged
    except Exception as exc:
        debug("limits failed: %s" % exc)
        return fresh
    finally:
        unlock(fd)


def save_limits(state):
    # No fsync, unlike save_state: this file is a cache of a number the next
    # status line run reproduces, and fsync has no business on a UI path.
    # One fixed temp name, not a pid-suffixed one: every writer holds
    # LIMITS_LOCK, so they cannot collide - and if the replace fails (a
    # limits.json left as a directory by a botched restore, say) a pid-suffixed
    # name would strand one orphan per status line redraw, thousands an hour.
    tmp = LIMITS + ".tmp"
    try:
        with open(tmp, "w") as fh:
            json.dump(state, fh, ensure_ascii=False)
        os.replace(tmp, LIMITS)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def statusline_text(windows):
    parts = []
    for key, label in LIMIT_WINDOWS:
        window = windows.get(key)
        if window:
            parts.append("%s %d%%" % (label, int(round(window["used_percentage"]))))
    return " · ".join(parts)


def statusline_main():
    """--statusline mode. stdout IS the terminal's status line here, so this is
    the one path that prints - and it still has to exit 0: any other exit code
    makes Claude Code discard the output and blank the row."""
    try:
        raw = sys.stdin.buffer.read()
    except Exception:
        raw = b""

    payload = {}
    if raw.strip():
        try:
            payload = json.loads(raw.decode("utf-8", "replace"), strict=False)
        except Exception as exc:
            debug("statusline parse failed: %s" % exc)
    if not isinstance(payload, dict):
        payload = {}

    now = time.time()
    windows = read_windows(payload, now)
    try:
        os.makedirs(BASE, exist_ok=True)
        windows = merge_limits(windows, payload.get("session_id"), now)
    except Exception as exc:
        debug("statusline failed: %s" % exc)

    text = statusline_text(windows)
    if text:
        try:
            sys.stdout.write(text + "\n")
        except Exception:
            pass


# --------------------------------------------------------------------------

def main():
    try:
        raw = sys.stdin.read()
    except Exception:
        return
    if not raw.strip():
        return
    try:
        # Claude Code embeds raw newlines inside strings (e.g. the `error`
        # field of PostToolUseFailure), which strict JSON rejects.
        event = json.loads(raw, strict=False)
    except Exception as exc:
        debug("parse failed: %s" % exc)
        return
    if not isinstance(event, dict):
        return

    try:
        os.makedirs(BASE, exist_ok=True)
    except Exception:
        return

    lock_fd = lock(LOCK, LOCK_TIMEOUT)
    if lock_fd is None:
        debug("lock timeout for %s" % event.get("hook_event_name"))
        return
    try:
        state = load_state()
        sid = apply_event(state, event)
        prune(state, sid)
        save_state(state)
        debug("%s -> ok" % event.get("hook_event_name"))
    except Exception as exc:
        debug("failed: %s" % exc)
    finally:
        unlock(lock_fd)


if __name__ == "__main__":
    try:
        if "--statusline" in sys.argv:
            statusline_main()
        else:
            main()
    except Exception:
        pass
    # Always succeed. A non-zero exit or stray stdout would disturb the session,
    # and in --statusline mode it also makes Claude Code discard the output and
    # blank the line.
    sys.exit(0)
