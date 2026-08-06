#!/bin/bash
# Builds and installs Claude Status: the menu bar app + the Claude Code hooks
# that feed it. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATUS_DIR="$HOME/.claude/claude-status"
APP_NAME="Claude Status.app"

if [ -w /Applications ]; then
    APP_DEST="/Applications"
else
    APP_DEST="$HOME/Applications"
fi
mkdir -p "$APP_DEST"

# swiftc lives behind the Xcode Command Line Tools. Without them /usr/bin/swiftc
# is a stub that fails with a cryptic message halfway through the build.
if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
    echo "Xcode Command Line Tools are required to build the app." >&2
    echo "Install them and re-run:  xcode-select --install" >&2
    exit 1
fi

# Claude Code itself is what this indicator watches.
if [ ! -d "$HOME/.claude" ]; then
    echo "warning: ~/.claude not found - is Claude Code installed?" >&2
fi

# A stable interpreter that does not depend on conda/asdf being on PATH.
if [ -x /usr/bin/python3 ]; then
    PYTHON=/usr/bin/python3
elif command -v python3 >/dev/null 2>&1; then
    PYTHON="$(command -v python3)"
else
    echo "python3 is required. Install Xcode Command Line Tools: xcode-select --install" >&2
    exit 1
fi
echo "Python: $PYTHON"

echo "1/4 Building the app…"
"$HERE/app/build.sh" "$HERE/app/build" >/dev/null

echo "2/4 Installing into ${APP_DEST}…"
pkill -f "$APP_NAME/Contents/MacOS/ClaudeStatus" 2>/dev/null || true
sleep 0.3
rm -rf "$APP_DEST/$APP_NAME"
cp -R "$HERE/app/build/$APP_NAME" "$APP_DEST/$APP_NAME"

echo "3/4 Installing the hook…"
mkdir -p "$STATUS_DIR"
cp "$HERE/hook/claude-status-hook.py" "$STATUS_DIR/hook.py"
chmod +x "$STATUS_DIR/hook.py"
"$PYTHON" "$HERE/hook/install-hooks.py" "$PYTHON"

echo "4/4 Launching…"
open -a "$APP_DEST/$APP_NAME"

cat <<EOF

Done.

  App:    $APP_DEST/$APP_NAME
  Hook:   $STATUS_DIR/hook.py
  State:  $STATUS_DIR/state.json

The icon is already in the menu bar. Hooks are read when a session starts, so
restart any open Claude Code terminals before they start reporting.

Open at login is a checkbox in the icon's menu.
To remove everything: ./uninstall.sh
EOF
