#!/bin/sh
# Builds dist/AppleRemindersMCP.app (arm64).
#
# Signing: the identity "Xiaofeng Local Code Signing" (a long-lived self-signed certificate in
# the login keychain, created 2026-10-20) gives every build the same designated requirement, so
# the Reminders permission granted to one build carries over to the next. SIGNING_IDENTITY picks
# another one. Without any, the build is ad-hoc signed, and macOS treats every rebuild as a new
# app that has to be allowed again.
# HARDENED=1 adds the hardened runtime with the calendars entitlement, which EventKit needs
# under the hardened runtime.
set -eu
cd "$(dirname "$0")/.."

BUNDLE_ID=com.xiaofeng.apple-reminders-mcp
APP=dist/AppleRemindersMCP.app

swift build -c release --product AppleRemindersMCP
BIN=$(swift build -c release --show-bin-path)/AppleRemindersMCP

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/AppleRemindersMCP"
cp Resources/Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP"

set -- --force --identifier "$BUNDLE_ID"
if [ "${HARDENED:-0}" = 1 ]; then
  set -- "$@" --options runtime --entitlements Resources/AppleRemindersMCP.entitlements
fi
IDENTITY=${SIGNING_IDENTITY:-Xiaofeng Local Code Signing}
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign "$@" --sign "$IDENTITY" --timestamp=none "$APP"
else
  echo "warning: signing identity \"$IDENTITY\" not found; ad-hoc signing." >&2
  echo "         macOS will ask for the Reminders permission again after every rebuild." >&2
  codesign "$@" --sign - "$APP"
fi
codesign --verify --strict "$APP"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /designated requirement: /p'
echo "built $APP"
