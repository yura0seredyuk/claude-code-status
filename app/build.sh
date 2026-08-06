#!/bin/bash
# Builds "Claude Status.app" from a single Swift file - no Xcode project needed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/build}"
APP="$OUT/Claude Status.app"
BIN="$APP/Contents/MacOS/ClaudeStatus"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -swift-version 5 -O \
    -target "$(uname -m)-apple-macosx13.0" \
    -framework AppKit -framework UserNotifications \
    -o "$BIN" \
    "$HERE/StatusIcon.swift" "$HERE/main.swift"

# The .icns is generated from tools/make-icon; rebuild it when it is missing or
# older than the generator, so the icon always matches the source.
ICON="$HERE/AppIcon.icns"
GEN="$HERE/../tools/make-icon/main.swift"
if [ ! -f "$ICON" ] || [ "$GEN" -nt "$ICON" ]; then
    echo "Generating the app icon…"
    TMP="$(mktemp -d)"
    swiftc -swift-version 5 -O -framework AppKit -o "$TMP/make-icon" "$GEN"
    "$TMP/make-icon" iconset "$TMP/AppIcon.iconset" segments >/dev/null
    iconutil -c icns "$TMP/AppIcon.iconset" -o "$ICON"
    rm -rf "$TMP"
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Claude Status</string>
    <key>CFBundleDisplayName</key>     <string>Claude Status</string>
    <key>CFBundleIdentifier</key>      <string>com.claudestatus.menubar</string>
    <key>CFBundleExecutable</key>      <string>ClaudeStatus</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for a locally built app, and keeps macOS from
# re-prompting every time the binary changes.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

# Nudge Finder/LaunchServices to re-read the bundle instead of showing a
# cached icon from a previous build.
touch "$APP"

echo "Built: $APP"
