#!/bin/sh
# Builds dist/AppleNotesMCP.app or dist/AppleRemindersMCP.app (arm64):
#
#   scripts/build-app.sh notes|reminders
#
# Signing: the identity "Xiaofeng Local Code Signing" (a long-lived self-signed certificate in
# the login keychain, created 2026-10-20) gives every build the same designated requirement, so
# the permissions granted to one build carry over to the next. SIGNING_IDENTITY picks another one.
# Without any, the build is ad-hoc signed, and macOS treats every rebuild as a new app that has to
# be allowed again.
# HARDENED=1 adds the hardened runtime with the app's entitlements: Apple Events for Notes
# (AppleScript to Notes needs it under the hardened runtime), calendars for Reminders (EventKit
# needs it there).
set -eu
cd "$(dirname "$0")/.."
APP_ID=${1:-}
. scripts/app.sh

BUNDLE=dist/$APP.app

swift build -c release --product "$APP"
BIN=$(swift build -c release --show-bin-path)/$APP

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP"
cp "$RESOURCES/Info.plist" "$BUNDLE/Contents/Info.plist"
# The icon (compiled by build-icon.sh), and the permission prompts' text, which macOS shows in
# the system language.
mkdir -p "$BUNDLE/Contents/Resources"
cp "$RESOURCES"/AppIcon-compiled/* "$BUNDLE/Contents/Resources/"
cp -R "$RESOURCES/en.lproj" "$RESOURCES/zh-Hans.lproj" "$BUNDLE/Contents/Resources/"
xattr -cr "$BUNDLE"

set -- --force --identifier "$BUNDLE_ID"
if [ "${HARDENED:-0}" = 1 ]; then
  set -- "$@" --options runtime --entitlements "$RESOURCES/$APP.entitlements"
fi
IDENTITY=${SIGNING_IDENTITY:-Xiaofeng Local Code Signing}
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign "$@" --sign "$IDENTITY" --timestamp=none "$BUNDLE"
else
  echo "warning: signing identity \"$IDENTITY\" not found; ad-hoc signing." >&2
  echo "         macOS will ask for $TITLE's permissions again after every rebuild." >&2
  codesign "$@" --sign - "$BUNDLE"
fi
codesign --verify --strict "$BUNDLE"
codesign -d -r- "$BUNDLE" 2>&1 | sed -n 's/^designated => /designated requirement: /p'
echo "built $BUNDLE"
