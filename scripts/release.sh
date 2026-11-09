#!/bin/sh
# Builds the downloadable release into build/release/:
#   FanPilot-<version>.dmg   drag-to-Applications disk image
#   FanPilot-<version>.zip   the app, zipped
#   SHA256SUMS.txt
#
# Signing: build-app.sh uses a Developer ID / Apple Development identity from
# the keychain when there is one, ad-hoc otherwise. With a Developer ID and
#   NOTARY_PROFILE=<notarytool keychain profile> scripts/release.sh
# the app and the disk image are notarized and stapled, so they open without
# Gatekeeper warnings. (Create the profile once with
# `xcrun notarytool store-credentials`; NOTARY_KEYCHAIN names the keychain
# holding it when it isn't the default one.)
#
# Publishing is done by .github/workflows/release.yml when a version tag is
# pushed (see docs/RELEASING.md); this script only builds the files.
set -eu
cd "$(dirname "$0")/.."

# The app's version; the helper has its own (FanPilot.version in Constants.swift).
VERSION="$(tr -d '[:space:]' < VERSION)"
APP="build/FanPilot.app"
OUT="build/release"
STAGE="build/dmg-stage"
NAME="FanPilot-$VERSION"

CONFIG=release scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 "$APP"
IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"

rm -rf "$OUT" "$STAGE"
mkdir -p "$OUT" "$STAGE"

notarize() { # <file>
    if [ -n "${NOTARY_KEYCHAIN:-}" ]; then
        xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --keychain "$NOTARY_KEYCHAIN" --wait
    else
        xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
    fi
}

if [ -n "${NOTARY_PROFILE:-}" ]; then
    case "$IDENTITY" in
    "Developer ID Application:"*) ;;
    *) echo "NOTARY_PROFILE is set but the app isn't signed with a Developer ID ($IDENTITY)" >&2; exit 1 ;;
    esac
    ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
    notarize "$OUT/notarize.zip"
    rm "$OUT/notarize.zip"
    xcrun stapler staple "$APP"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$NAME.zip"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "Resources/Read Me First.txt" "$STAGE/Read Me First.txt"
hdiutil create -volname "FanPilot $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$NAME.dmg" >/dev/null
rm -rf "$STAGE"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$OUT/$NAME.dmg"
    notarize "$OUT/$NAME.dmg"
    xcrun stapler staple "$OUT/$NAME.dmg"
fi

(cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)

echo
echo "FanPilot $VERSION, signed by: ${IDENTITY:-ad-hoc}$([ -n "${NOTARY_PROFILE:-}" ] && echo ", notarized")"
ls -lh "$OUT"
