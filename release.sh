#!/bin/bash
# Builds a distributable disk image.
#
#   ./release.sh                  unsigned build, for testing the packaging
#   VERSION=1.1 ./release.sh      set the marketing version
#
#   SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" \
#   NOTARY_PROFILE=statuslamp ./release.sh
#                                 signed, notarised and stapled
#
# The notary profile is a keychain item you create once:
#
#   xcrun notarytool store-credentials statuslamp \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Without SIGN_IDENTITY the disk image still builds and still installs, but
# macOS 15 and later no longer offer the Control-click shortcut past Gatekeeper:
# the person opening it has to go to System Settings > Privacy & Security and
# click "Open Anyway". Fine for you and people who trust you, a real drop-off
# for a stranger.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Statuslamp"
OUT="$HERE/dist"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# A tag is the version if there is one, so a release cannot silently ship under
# whatever number was last hard-coded.
if [ -z "${VERSION:-}" ]; then
    # || true, or pipefail turns "this repo has no tags yet" into a silent exit.
    VERSION="$(git -C "$HERE" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
    VERSION="${VERSION:-1.0}"
fi

rm -rf "$OUT"
mkdir -p "$OUT"

echo "Building $APP_NAME ${VERSION}…"
SIGN_IDENTITY="$SIGN_IDENTITY" VERSION="$VERSION" "$HERE/app/build.sh" "$OUT/build" >/dev/null
APP="$OUT/build/$APP_NAME.app"

echo "Staging…"
STAGE="$(mktemp -d)/$APP_NAME"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# The drag-to-install target every Mac user expects.
ln -s /Applications "$STAGE/Applications"

DMG="$OUT/$APP_NAME-$VERSION.dmg"
echo "Packaging…"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -quiet -format UDZO "$DMG"
rm -rf "$(dirname "$STAGE")"

if [ "$SIGN_IDENTITY" != "-" ]; then
    echo "Signing the disk image…"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

    if [ -n "$NOTARY_PROFILE" ]; then
        # An automated malware scan, not App Review: minutes, no queue, nobody's
        # editorial judgement. Stapling is what makes it work offline afterwards.
        echo "Notarising (this waits on Apple)…"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
    else
        echo "  NOTARY_PROFILE not set - signed but not notarised."
        echo "  Gatekeeper will still refuse this on another Mac."
    fi
fi

echo
echo "Built:  $DMG"
echo "Size:   $(du -h "$DMG" | cut -f1)"
echo "SHA256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "Signed: $SIGN_IDENTITY"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo
    echo "Ad-hoc only. On macOS 15+ the person who downloads this must open"
    echo "System Settings > Privacy & Security and click \"Open Anyway\" once."
fi
