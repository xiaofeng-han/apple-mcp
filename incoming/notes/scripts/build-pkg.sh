#!/bin/sh
# Builds the installer package dist/AppleNotesMCP-<version>.pkg (and its .sha256) from a fresh
# build-app.sh build, for a GitHub release.
#
# Installing "for me only" puts the app in ~/Applications without an administrator password;
# installing for all users puts it in /Applications. From the terminal:
#   installer -pkg AppleNotesMCP-<version>.pkg -target CurrentUserHomeDirectory
# The Homebrew cask (github.com/xiaofeng-han/homebrew-tap) installs this same package with
# `sudo installer -target /`, that is for all users, so the distribution must keep allowing the
# local system domain. scripts/update-cask.sh points the cask at a new release.
#
# The package itself is unsigned (there is no Developer ID); the app inside keeps the signature
# build-app.sh gave it, so permissions granted to an earlier build still apply.
# Files built under an app that macOS tracks for provenance carry a com.apple.provenance
# attribute that cannot be removed; pkgbuild then prints "write: Permission denied" a few times,
# and the package still installs with a valid signature.
set -eu
cd "$(dirname "$0")/.."

./scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
PKG_ID=com.xiaofeng.apple-notes-mcp.pkg
WORK=dist/pkg
OUT=dist/AppleNotesMCP-$VERSION.pkg

rm -rf "$WORK" "$OUT" "$OUT.sha256"
mkdir -p "$WORK/root" "$WORK/resources"
ditto dist/AppleNotesMCP.app "$WORK/root/AppleNotesMCP.app"
cp Resources/Installer/conclusion.html "$WORK/resources/"

# By default Installer moves the update to wherever it finds an app with the same bundle id (a
# build in dist/, say) and skips it when that copy has a higher version. Always install in place.
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/components.plist"
plutil -replace 0.BundleIsVersionChecked -bool NO "$WORK/components.plist"
pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" \
  --identifier "$PKG_ID" --version "$VERSION" --install-location /Applications \
  "$WORK/AppleNotesMCP.pkg"

cat > "$WORK/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Apple Notes MCP $VERSION</title>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <domains enable_anywhere="false" enable_currentUserHome="true" enable_localSystem="true"/>
  <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
  <volume-check>
    <allowed-os-versions><os-version min="26.0"/></allowed-os-versions>
  </volume-check>
  <choices-outline><line choice="app"/></choices-outline>
  <choice id="app" title="Apple Notes MCP"><pkg-ref id="$PKG_ID"/></choice>
  <pkg-ref id="$PKG_ID" version="$VERSION">AppleNotesMCP.pkg</pkg-ref>
</installer-gui-script>
EOF
productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/resources" \
  --package-path "$WORK" "$OUT"

(cd dist && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "built $OUT"
