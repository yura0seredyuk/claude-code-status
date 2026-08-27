#!/bin/bash
# Builds "Statuslamp.app" from two Swift files - no Xcode project needed.
#
#   ./build.sh [outdir]
#
# Environment:
#   SIGN_IDENTITY   codesigning identity; "-" (the default) is an ad-hoc
#                   signature, good enough to run locally. For a release set it
#                   to "Developer ID Application: NAME (TEAMID)" and the build
#                   comes out notarizable as-is - the hardened runtime is
#                   already on either way.
#   VERSION         CFBundleShortVersionString (default 1.0)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/build}"
APP="$OUT/Statuslamp.app"
BIN="$APP/Contents/MacOS/Statuslamp"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SHORT_VERSION="${VERSION:-1.0}"
# Monotonic and automatic: a hand-maintained CFBundleVersion is a build that
# ships twice under the same number and an update that never installs.
BUILD_NUMBER="$(git -C "$HERE" rev-list --count HEAD 2>/dev/null || echo 1)"
YEAR="$(date +%Y)"
AUTHOR="${COPYRIGHT_HOLDER:-$(git -C "$HERE" config user.name 2>/dev/null || true)}"
AUTHOR="${AUTHOR:-Statuslamp contributors}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal, not "whatever this machine is": a build made on Apple silicon that
# refuses to launch on an Intel Mac is not a build anyone can hand out.
echo "Compiling (arm64 + x86_64)…"
SLICES="$(mktemp -d)"
trap 'rm -rf "$SLICES"' EXIT
for arch in arm64 x86_64; do
    swiftc -swift-version 5 -O \
        -target "${arch}-apple-macosx13.0" \
        -framework AppKit -framework UserNotifications -framework ServiceManagement \
        -o "$SLICES/Statuslamp-$arch" \
        "$HERE/StatusIcon.swift" "$HERE/main.swift"
done
lipo -create "$SLICES"/Statuslamp-* -output "$BIN"

# The hook Claude Code runs on every tool call. It ships inside the bundle and
# install.sh copies it out to ~/.claude/statuslamp/, so the registered hook
# keeps working when the app is moved, quit or updated.
echo "Compiling the hook…"
mkdir -p "$APP/Contents/Helpers"
for arch in arm64 x86_64; do
    swiftc -swift-version 5 -O \
        -target "${arch}-apple-macosx13.0" \
        -o "$SLICES/hook-$arch" \
        "$HERE/../hook/main.swift"
done
lipo -create "$SLICES"/hook-* -output "$APP/Contents/Helpers/statuslamp-hook"
chmod +x "$APP/Contents/Helpers/statuslamp-hook"

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

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Statuslamp</string>
    <key>CFBundleDisplayName</key>     <string>Statuslamp</string>
    <key>CFBundleIdentifier</key>      <string>io.github.yura0seredyuk.statuslamp</string>
    <key>CFBundleExecutable</key>      <string>Statuslamp</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key>         <string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key> <string>© $YEAR $AUTHOR</string>
    <!-- Clicking a session opens its folder. If that folder happens to live in
         one of these, macOS asks the user - and an empty reason string reads as
         a bug. -->
    <key>NSDesktopFolderUsageDescription</key>
        <string>Opens the folder of the Claude Code session you clicked.</string>
    <key>NSDocumentsFolderUsageDescription</key>
        <string>Opens the folder of the Claude Code session you clicked.</string>
    <key>NSDownloadsFolderUsageDescription</key>
        <string>Opens the folder of the Claude Code session you clicked.</string>
</dict>
</plist>
PLIST

# The hardened runtime is on for both identities, so an ad-hoc build and a
# release build differ only in who signed them - no last-minute surprises when
# the notarizer finally sees it. No `|| true` either: a signature that silently
# failed to apply is a bundle that will not launch on someone else's Mac, and
# finding that out at build time is the entire point.
# Nested code first, bundle second: codesign seals what it finds, and a helper
# signed after the bundle invalidates the bundle's own seal.
for target in "$APP/Contents/Helpers/statuslamp-hook" "$APP"; do
    if [ "$SIGN_IDENTITY" = "-" ]; then
        codesign --force --options runtime --timestamp=none --sign - "$target"
    else
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$target"
    fi
done
codesign --verify --strict "$APP"

# Nudge Finder/LaunchServices to re-read the bundle instead of showing a
# cached icon from a previous build.
touch "$APP"

echo "Built: $APP"
echo "  version $SHORT_VERSION ($BUILD_NUMBER)  $(lipo -archs "$BIN")  signed by ${SIGN_IDENTITY}"
