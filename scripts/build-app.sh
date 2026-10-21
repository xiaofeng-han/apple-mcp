#!/bin/sh
# Builds dist/AppleNotesMCP.app (arm64).
#
# Signing: the identity "Xiaofeng Local Code Signing" (a long-lived self-signed certificate in
# the login keychain, created 2026-10-20) gives every build the same designated requirement, so
# the permissions granted to one build (Full Disk Access, Automation) carry over to the next. SIGNING_IDENTITY picks
# another one. Without any, the build is ad-hoc signed, and macOS treats every rebuild as a new
# app that has to be allowed again.
# HARDENED=1 adds the hardened runtime with the Apple Events entitlement, which AppleScript to
# Notes needs under the hardened runtime.
set -eu
cd "$(dirname "$0")/.."

BUNDLE_ID=com.xiaofeng.apple-notes-mcp
APP=dist/AppleNotesMCP.app

swift build -c release --product AppleNotesMCP
BIN=$(swift build -c release --show-bin-path)/AppleNotesMCP

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/AppleNotesMCP"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The icon (compiled by build-icon.sh), and the permission prompt's text, which macOS shows in
# the system language.
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon-compiled/* "$APP/Contents/Resources/"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$APP/Contents/Resources/"
xattr -cr "$APP"

set -- --force --identifier "$BUNDLE_ID"
if [ "${HARDENED:-0}" = 1 ]; then
  set -- "$@" --options runtime --entitlements Resources/AppleNotesMCP.entitlements
fi
IDENTITY=${SIGNING_IDENTITY:-Xiaofeng Local Code Signing}
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign "$@" --sign "$IDENTITY" --timestamp=none "$APP"
else
  echo "warning: signing identity \"$IDENTITY\" not found; ad-hoc signing." >&2
  echo "         Full Disk Access and Automation must be granted again after every rebuild." >&2
  codesign "$@" --sign - "$APP"
fi
codesign --verify --strict "$APP"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /designated requirement: /p'
echo "built $APP"
