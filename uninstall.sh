#!/bin/bash
# Removes the hooks, the launch agent and the app. Leaves ~/.claude/settings.json
# backups in place.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATUS_DIR="$HOME/.claude/statuslamp"
APP_NAME="Statuslamp.app"
LABEL="com.claudestatus.agent"

PYTHON="$( [ -x /usr/bin/python3 ] && echo /usr/bin/python3 || command -v python3 )"

echo "Removing hooks and the status line entry…"
"$PYTHON" "$HERE/hook/install-hooks.py" --uninstall

echo "Stopping the app…"
# Drop the login item while the bundle is still there to do it: an SMAppService
# registration outlives the app it points at, and deleting the app first leaves
# an entry in System Settings that only the user can clear.
for dir in /Applications "$HOME/Applications"; do
    BINARY="$dir/$APP_NAME/Contents/MacOS/Statuslamp"
    if [ -x "$BINARY" ]; then "$BINARY" --unregister-login-item 2>/dev/null || true; fi
done
# Installs from before SMAppService left a LaunchAgent behind.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -f "$APP_NAME/Contents/MacOS/Statuslamp" 2>/dev/null || true

rm -rf "/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME"
rm -rf "$STATUS_DIR"
defaults delete io.github.yura0seredyuk.statuslamp 2>/dev/null || true
# and anything the pre-rename version left behind
defaults delete com.claudestatus.menubar 2>/dev/null || true
rm -rf "$HOME/.claude/claude-status"

echo "Done. Restart any open Claude Code sessions."
