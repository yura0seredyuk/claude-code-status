#!/usr/bin/env python3
"""Adds (or removes) the Claude Status hooks in ~/.claude/settings.json.

Idempotent: every entry it writes is tagged with MARKER, so re-running replaces
its own entries and leaves hooks installed by anything else untouched.
"""

import json
import os
import shutil
import sys
import time

HOME = os.path.expanduser("~")
SETTINGS = os.path.join(HOME, ".claude", "settings.json")
MARKER = "claude-status/hook.py"

# matcher=None -> the event takes no matcher
EVENTS = [
    ("SessionStart", None),
    ("UserPromptSubmit", None),
    ("PreToolUse", "*"),
    ("PostToolUse", "*"),
    ("PostToolUseFailure", "*"),
    ("PermissionRequest", "*"),
    ("PermissionDenied", "*"),
    ("Notification", None),
    ("Stop", None),
    ("StopFailure", None),
    ("SessionEnd", None),
]


def load():
    if not os.path.exists(SETTINGS):
        return {}
    with open(SETTINGS) as fh:
        text = fh.read().strip()
    if not text:
        return {}
    return json.loads(text)


def strip_ours(settings):
    """Drop previously installed entries so re-running doesn't duplicate them."""
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return
    for event in list(hooks.keys()):
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue
        kept_groups = []
        for group in groups:
            if not isinstance(group, dict):
                kept_groups.append(group)
                continue
            entries = group.get("hooks")
            if not isinstance(entries, list):
                kept_groups.append(group)
                continue
            entries = [
                e for e in entries
                if not (isinstance(e, dict) and MARKER in str(e.get("command", "")))
            ]
            if entries:
                group["hooks"] = entries
                kept_groups.append(group)
        if kept_groups:
            hooks[event] = kept_groups
        else:
            del hooks[event]
    if not hooks:
        settings.pop("hooks", None)


def add_ours(settings, command):
    hooks = settings.setdefault("hooks", {})
    for event, matcher in EVENTS:
        entry = {"type": "command", "command": command, "timeout": 5}
        group = {"hooks": [entry]}
        if matcher is not None:
            group["matcher"] = matcher
        hooks.setdefault(event, []).append(group)


def main():
    uninstall = "--uninstall" in sys.argv
    settings = load()

    if os.path.exists(SETTINGS):
        backup = "%s.bak-%s" % (SETTINGS, time.strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(SETTINGS, backup)
        print("  backup: %s" % backup)

    strip_ours(settings)
    if not uninstall:
        python = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else sys.executable
        hook = os.path.join(HOME, ".claude", "claude-status", "hook.py")
        # Silenced and forced to succeed: a status indicator must never be able
        # to disturb a Claude Code session.
        add_ours(settings, '%s "%s" >/dev/null 2>&1 || true' % (python, hook))

    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    tmp = SETTINGS + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(settings, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, SETTINGS)
    print("  %s: %s" % ("hooks removed from" if uninstall else "hooks written to", SETTINGS))


if __name__ == "__main__":
    main()
