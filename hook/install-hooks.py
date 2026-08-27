#!/usr/bin/env python3
"""Adds (or removes) the Claude Status hooks in ~/.claude/settings.json.

Idempotent: every entry it writes is tagged with MARKER, so re-running replaces
its own entries and leaves hooks installed by anything else untouched.

    install-hooks.py               hooks + the statusLine that feeds the plan
                                   usage rows
    install-hooks.py --no-limits   hooks only, statusLine slot given back
    install-hooks.py --uninstall   remove both
"""

import json
import os
import shlex
import shutil
import sys
import time

HOME = os.path.expanduser("~")
SETTINGS = os.path.join(HOME, ".claude", "settings.json")
LIMITS = os.path.join(HOME, ".claude", "claude-status", "limits.json")
# Matches both the compiled hook and the Python one earlier versions installed,
# so an upgrade strips the old entries instead of running two hooks.
MARKER = "claude-status/hook"

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


# Unlike the hooks, this one must NOT be silenced: its stdout is the status
# line. And no `|| true` - the script already exits 0 on every path, whereas a
# genuinely broken interpreter should show up in `claude --debug` as a non-zero
# exit rather than as a mysteriously empty row.
def statusline_command(hook):
    # shlex, not bare quotes: /bin/sh -c runs this, and a home directory
    # containing $ or " would otherwise mangle or fail to parse the command -
    # and a non-zero exit blanks the status line row permanently.
    return "%s --statusline" % shlex.quote(hook)


def apply_statusline(settings, command, mode):
    """settings.json has exactly one statusLine slot - it is a scalar, not a
    merged list like hooks - so claiming it means taking it away from whatever
    the user already had. Never do that silently, and never wrap their command
    to chain to it: that would put a Python start in front of theirs on every
    keystroke-driven redraw, and leave a restore path that a failed uninstall
    could strand."""
    existing = settings.get("statusLine")
    current = existing.get("command", "") if isinstance(existing, dict) else None
    ours = current is not None and MARKER in current and "--statusline" in current

    if mode == "off":
        if ours:
            settings.pop("statusLine", None)
            # Nothing will refresh limits.json again, and a file left behind
            # would keep the app showing rows - and switches for them - for a
            # feature the user just turned off.
            try:
                os.unlink(LIMITS)
            except OSError:
                pass
            return "plan limits: statusLine entry removed"
        return None
    if current is not None and not ours:
        if mode == "keep":
            return None
        # Their script, their edit, their decision: no wrapper to uninstall, no
        # recursion when install.sh is re-run, no collision with /statusline.
        return ("plan limits: NOT enabled - statusLine is already taken by\n"
                "    %s\n"
                "  Claude Status will not overwrite it. To feed it too, read stdin\n"
                "  once at the top of your own script and fan it out:\n"
                "    input=$(cat)\n"
                "    printf '%%s' \"$input\" | %s >/dev/null 2>&1\n"
                "    printf '%%s' \"$input\" | <the rest of your status line>"
                % (current, command))
    if mode == "keep":
        if not ours:
            return None
        settings["statusLine"] = {"type": "command", "command": command}
        return "plan limits: still on"
    settings["statusLine"] = {"type": "command", "command": command}
    return "plan limits: statusLine -> %s" % command


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
    # On unless asked otherwise. An already-occupied statusLine is still never
    # overwritten - that is about not destroying someone else's config, not
    # about which features are on.
    limits = "off" if uninstall else "on"
    if "--no-limits" in sys.argv:
        limits = "off"

    settings = load()

    if os.path.exists(SETTINGS):
        backup = "%s.bak-%s" % (SETTINGS, time.strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(SETTINGS, backup)
        print("  backup: %s" % backup)

    hook = os.path.join(HOME, ".claude", "claude-status", "hook")

    strip_ours(settings)
    if not uninstall:
        # Silenced and forced to succeed: a status indicator must never be able
        # to disturb a Claude Code session.
        add_ours(settings, "%s >/dev/null 2>&1 || true" % shlex.quote(hook))
    note = apply_statusline(settings, statusline_command(hook), limits)

    # Resolved first: os.replace renames the symlink itself, so writing through
    # SETTINGS directly would turn a settings.json symlinked into a dotfiles
    # repo into a plain file and quietly orphan the repo copy. Claude Code
    # supports that setup deliberately, so preserve it.
    target = os.path.realpath(SETTINGS)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    tmp = target + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(settings, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, target)
    print("  %s: %s" % ("hooks removed from" if uninstall else "hooks written to", SETTINGS))
    if note:
        print("  %s" % note)


if __name__ == "__main__":
    main()
