#!/bin/bash
# Removes the hooks, the launch agent and the app. Leaves ~/.claude/settings.json
# backups in place.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATUS_DIR="$HOME/.claude/claude-status"
APP_NAME="Claude Status.app"
LABEL="com.claudestatus.agent"

PYTHON="$( [ -x /usr/bin/python3 ] && echo /usr/bin/python3 || command -v python3 )"

echo "Removing hooks…"
"$PYTHON" "$HERE/hook/install-hooks.py" --uninstall

echo "Stopping the app…"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -f "$APP_NAME/Contents/MacOS/ClaudeStatus" 2>/dev/null || true

rm -rf "/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME"
rm -rf "$STATUS_DIR"
defaults delete com.claudestatus.menubar 2>/dev/null || true

echo "Done. Restart any open Claude Code sessions."
