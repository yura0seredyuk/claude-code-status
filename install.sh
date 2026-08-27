#!/bin/bash
# Builds and installs Statuslamp: the menu bar app + the Claude Code hooks
# that feed it. Safe to re-run.
#
#   ./install.sh              everything: the icon, and the plan usage limits
#                             (which claim the statusLine slot - see README)
#   ./install.sh --no-limits  leave the statusLine slot alone
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIMITS_FLAG=""
for arg in "$@"; do
    case "$arg" in
        --no-limits) LIMITS_FLAG="$arg" ;;
        --limits) ;;   # the default now; still accepted so it is not an error
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done
STATUS_DIR="$HOME/.claude/statuslamp"
APP_NAME="Statuslamp.app"

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
pkill -f "$APP_NAME/Contents/MacOS/Statuslamp" 2>/dev/null || true
sleep 0.3
rm -rf "$APP_DEST/$APP_NAME"
cp -R "$HERE/app/build/$APP_NAME" "$APP_DEST/$APP_NAME"

echo "3/4 Installing the hook…"
# The app was called Claude Status until it was renamed. Carry the state across
# rather than starting from an empty file, and take the old login item with the
# old bundle while it can still unregister itself - an SMAppService entry whose
# app has been deleted sits in System Settings until the user clears it by hand.
OLD_APP="Claude Status.app"
OLD_DIR="$HOME/.claude/claude-status"
for dir in /Applications "$HOME/Applications"; do
    OLD_BINARY="$dir/$OLD_APP/Contents/MacOS/ClaudeStatus"
    if [ -x "$OLD_BINARY" ]; then
        "$OLD_BINARY" --unregister-login-item 2>/dev/null || true
        pkill -f "$OLD_APP/Contents/MacOS/ClaudeStatus" 2>/dev/null || true
        rm -rf "$dir/$OLD_APP"
        echo "  removed the previous $OLD_APP"
    fi
done
if [ -d "$OLD_DIR" ] && [ ! -d "$STATUS_DIR" ]; then
    mv "$OLD_DIR" "$STATUS_DIR"
    echo "  moved $OLD_DIR to $STATUS_DIR"
fi

mkdir -p "$STATUS_DIR"
cp "$APP_DEST/$APP_NAME/Contents/Helpers/statuslamp-hook" "$STATUS_DIR/hook"
chmod +x "$STATUS_DIR/hook"
# Installs from before the hook was compiled left a Python script here. Nothing
# points at it any more, and leaving it invites confusion about which one runs.
rm -f "$STATUS_DIR/hook.py"
HOOK_OUT="$("$PYTHON" "$HERE/hook/install-hooks.py" ${LIMITS_FLAG:+"$LIMITS_FLAG"})"
printf '%s\n' "$HOOK_OUT"

# The closing banner must not advertise --limits to somebody who just ran it,
# nor to somebody the installer just refused.
case "$HOOK_OUT" in
    *"plan limits: statusLine ->"*|*"plan limits: still on"*)
        LIMITS_NOTE="Plan usage limits are on: the status line prints them and the menu shows the bars.
Hand the slot back with ./install.sh --no-limits" ;;
    *"plan limits: NOT enabled"*)
        LIMITS_NOTE="Plan usage limits were not enabled - your statusLine is already in use. See the
note above to feed both." ;;
    *)
        LIMITS_NOTE="Plan usage limits are off; turn them on by re-running without --no-limits." ;;
esac

echo "4/4 Launching…"
open -a "$APP_DEST/$APP_NAME"

cat <<EOF

Done.

  App:    $APP_DEST/$APP_NAME
  Hook:   $STATUS_DIR/hook
  State:  $STATUS_DIR/state.json
  Limits: $STATUS_DIR/limits.json

The icon is already in the menu bar. Hooks are read when a session starts, so
restart any open Claude Code terminals before they start reporting.

Open at login is a checkbox in the icon's menu.

$LIMITS_NOTE

To remove everything: ./uninstall.sh
EOF
