#!/usr/bin/env python3
"""Claude Code -> menu bar status bridge.

Reads one hook event on stdin and folds it into ~/.claude/claude-status/state.json,
which the ClaudeStatus menu bar app renders.

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
LOG = os.path.join(BASE, "hook.log")

STATE_VERSION = 1
MAX_SESSIONS = 60
SESSION_TTL = 24 * 3600  # forget sessions untouched for a day
LOCK_TIMEOUT = 1.5       # never stall a tool call for longer than this


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

    deadline = time.time() + LOCK_TIMEOUT
    lock_fd = None
    try:
        lock_fd = os.open(LOCK, os.O_CREAT | os.O_RDWR, 0o644)
        while True:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except IOError:
                if time.time() > deadline:
                    debug("lock timeout for %s" % event.get("hook_event_name"))
                    return
                time.sleep(0.01)

        state = load_state()
        sid = apply_event(state, event)
        prune(state, sid)
        save_state(state)
        debug("%s -> ok" % event.get("hook_event_name"))
    except Exception as exc:
        debug("failed: %s" % exc)
    finally:
        if lock_fd is not None:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
                os.close(lock_fd)
            except Exception:
                pass


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    # Always succeed: a non-zero exit or stray stdout would disturb the session.
    sys.exit(0)
