#!/bin/sh
# Compiles an app's Resources/<App>/AppIcon.icon (an Icon Composer document) into
# Resources/<App>/AppIcon-compiled: Assets.car, which macOS 26 and later draw in their own icon
# shape, and AppIcon.icns for anything that reads the old format. Needs Xcode for actool, so the
# output is committed and build-app.sh only copies it; run this after changing the icon:
#
#   scripts/build-icon.sh notes|reminders
#
# The artwork is the full-bleed square: macOS masks it to its rounded shape. A transparent
# icon that draws its own shape is shown shrunk inside a grey tile instead.
set -eu
cd "$(dirname "$0")/.."
APP_ID=${1:-}
. scripts/app.sh

DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export DEVELOPER_DIR
OUT=$RESOURCES/AppIcon-compiled
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

xcrun actool "$RESOURCES/AppIcon.icon" --compile "$WORK" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist "$WORK/partial.plist" \
  --output-format human-readable-text --notices --warnings --errors
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$WORK/Assets.car" "$WORK/AppIcon.icns" "$OUT/"
echo "compiled $OUT:"
ls -l "$OUT"
