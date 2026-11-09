#!/bin/sh
# Builds build/FanPilot.app: the menu bar app with the helper and CLI inside.
#
#   CONFIG=debug scripts/build-app.sh      debug build
#   UNIVERSAL=1 scripts/build-app.sh       arm64 + x86_64
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#                                          sign with a real identity (default: ad-hoc)
set -eu
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
# Sign with a real identity when the keychain has one (Developer ID, then Apple
# Development): macOS then keeps the helper's approval across updates. Ad-hoc
# ("-") otherwise, which macOS pins per build.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    SIGN_IDENTITY="$(printf '%s\n' "$IDENTITIES" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
    if [ -z "$SIGN_IDENTITY" ]; then
        SIGN_IDENTITY="$(printf '%s\n' "$IDENTITIES" | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
    fi
    if [ -z "$SIGN_IDENTITY" ]; then SIGN_IDENTITY="-"; fi
fi
# The app's version; the helper has its own (FanPilot.version in Constants.swift).
VERSION="$(tr -d '[:space:]' < VERSION)"
# Every build gets its own build number: macOS pins the approved helper to a
# build, and only re-pins it when the app's build number changes.
BUILD="$(date +%s)"

ARCH_FLAGS=""
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCH_FLAGS="--arch arm64 --arch x86_64"; fi

# shellcheck disable=SC2086
swift build -c "$CONFIG" $ARCH_FLAGS
# shellcheck disable=SC2086
BIN="$(swift build -c "$CONFIG" $ARCH_FLAGS --show-bin-path)"

APP="build/FanPilot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/FanPilotApp" "$APP/Contents/MacOS/FanPilot"
cp "$BIN/fanpilotd" "$APP/Contents/MacOS/fanpilotd"
cp "$BIN/fanpilotctl" "$APP/Contents/MacOS/fanpilotctl"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
# The helper is registered by the app with SMAppService from this embedded launchd plist.
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cp Resources/com.antonarnaudov.fanpilot.helper.plist "$APP/Contents/Library/LaunchDaemons/"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi

# A Developer ID build gets the hardened runtime and a secure timestamp (needed
# for notarization); ad-hoc and development builds don't.
SIGN_FLAGS=""
case "$SIGN_IDENTITY" in "Developer ID Application:"*) SIGN_FLAGS="--options runtime --timestamp" ;; esac
# shellcheck disable=SC2086
codesign --force --sign "$SIGN_IDENTITY" $SIGN_FLAGS --identifier com.antonarnaudov.fanpilot.helper "$APP/Contents/MacOS/fanpilotd"
# shellcheck disable=SC2086
codesign --force --sign "$SIGN_IDENTITY" $SIGN_FLAGS --identifier com.antonarnaudov.fanpilot.ctl "$APP/Contents/MacOS/fanpilotctl"
# shellcheck disable=SC2086
codesign --force --sign "$SIGN_IDENTITY" $SIGN_FLAGS --identifier com.antonarnaudov.fanpilot "$APP"

echo "built $APP ($VERSION, $CONFIG, signed: $SIGN_IDENTITY)"
