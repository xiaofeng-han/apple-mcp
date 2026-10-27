#!/bin/sh
# Builds the installer package dist/AppleNotesMCP-<version>.pkg or dist/AppleRemindersMCP-<version>.pkg
# and the zipped app dist/AppleNotesMCP-<version>.zip or dist/AppleRemindersMCP-<version>.zip (each
# with its .sha256) from one fresh build-app.sh build, for a GitHub release:
#
#   scripts/build-pkg.sh notes|reminders
#
# Installing "for me only" puts the app in ~/Applications without an administrator password;
# installing for all users puts it in /Applications. From the terminal:
#   installer -pkg AppleNotesMCP-<version>.pkg -target CurrentUserHomeDirectory
# The Homebrew casks (github.com/xiaofeng-han/homebrew-tap) install the zip: Homebrew moves the app
# into /Applications itself, so it needs no administrator password, where installing the package
# would take `sudo installer -target /`. scripts/update-cask.sh points a cask at a new release.
#
# The package itself is unsigned (there is no Developer ID); the app inside keeps the signature
# build-app.sh gave it, so permissions granted to an earlier build still apply.
# Files built under an app that macOS tracks for provenance carry a com.apple.provenance
# attribute that cannot be removed; pkgbuild then prints "write: Permission denied" a few times,
# and the package still installs with a valid signature.
set -eu
cd "$(dirname "$0")/.."
APP_ID=${1:-}
. scripts/app.sh

./scripts/build-app.sh "$APP_ID"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$RESOURCES/Info.plist")
PKG_ID=$BUNDLE_ID.pkg
WORK=dist/pkg-$APP_ID
OUT=dist/$APP-$VERSION.pkg
ZIP=dist/$APP-$VERSION.zip

rm -rf "$WORK" "$OUT" "$OUT.sha256" "$ZIP" "$ZIP.sha256"
mkdir -p "$WORK/root" "$WORK/resources"
ditto "dist/$APP.app" "$WORK/root/$APP.app"
cp "$RESOURCES/Installer/conclusion.html" "$WORK/resources/"

# By default Installer moves the update to wherever it finds an app with the same bundle id (a
# build in dist/, say) and skips it when that copy has a higher version. Always install in place.
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/components.plist"
plutil -replace 0.BundleIsVersionChecked -bool NO "$WORK/components.plist"
pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" \
  --identifier "$PKG_ID" --version "$VERSION" --install-location /Applications \
  "$WORK/$APP.pkg"

cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>$TITLE $VERSION</title>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <domains enable_anywhere="false" enable_currentUserHome="true" enable_localSystem="true"/>
  <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
  <volume-check>
    <allowed-os-versions><os-version min="26.0"/></allowed-os-versions>
  </volume-check>
  <choices-outline><line choice="app"/></choices-outline>
  <choice id="app" title="$TITLE"><pkg-ref id="$PKG_ID"/></choice>
  <pkg-ref id="$PKG_ID" version="$VERSION">$APP.pkg</pkg-ref>
</installer-gui-script>
XML
productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/resources" \
  --package-path "$WORK" "$OUT"

(cd dist && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "built $OUT"

# The same app for the Homebrew casks, without extended attributes (the signature does not cover
# them, and without them the zip has no __MACOSX folder). Check that it still verifies once
# unpacked with unzip, as Homebrew unpacks it.
ditto -c -k --keepParent --norsrc --noextattr --noacl "dist/$APP.app" "$ZIP"
unzip -qq -o "$ZIP" -d "$WORK/unzipped"
codesign --verify --strict "$WORK/unzipped/$APP.app"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "built $ZIP"
