#!/bin/sh
# Points an app's Homebrew cask at the release that build-pkg.sh built and `gh release create`
# published, in a checkout of github.com/xiaofeng-han/homebrew-tap (by default ../homebrew-tap),
# then commits and pushes:
#
#   scripts/update-cask.sh notes|reminders [TAP]
#
# It sets version and sha256, and keeps the cask pointed at this repository: the package under the
# app's own tags (notes-v<version>, reminders-v<version>), the app's documentation as its homepage,
# and livecheck reading only that app's tags. The casks' names, commands and everything else stay.
#
# Homebrew users pick up the cask from the tap's main branch on their next `brew update`, so the
# package must already be on GitHub: the script first checks that the release is published and
# serves the very file in dist/.
set -eu
APP_ID=${1:-}
TAP=$(cd "${2:-$(dirname "$0")/../../homebrew-tap}" && pwd)
cd "$(dirname "$0")/.."
. scripts/app.sh

FILE=Casks/$CASK.rb
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$RESOURCES/Info.plist")
TAG=$TAG_PREFIX$VERSION
PKG=$APP-$VERSION.pkg
SHA=$(cut -d ' ' -f 1 "dist/$PKG.sha256")

PUBLISHED=$(gh release view "$TAG" -R "$REPO" --json isDraft,assets \
  --jq "if .isDraft then \"a draft (publish it first)\" else (.assets[] | select(.name == \"$PKG\") | .digest) end")
if [ "$PUBLISHED" != "sha256:$SHA" ]; then
  echo "error: release $TAG has no $PKG with sha256 $SHA (GitHub has: ${PUBLISHED:-none})" >&2
  exit 1
fi

awk -f scripts/cask.awk -v version="$VERSION" -v sha="$SHA" -v repo="$REPO" -v prefix="$TAG_PREFIX" -v app="$APP" -v doc="$DOC" \
  "$TAP/$FILE" > "$TAP/$FILE.new"
mv "$TAP/$FILE.new" "$TAP/$FILE"
if ! grep -q "^  version \"$VERSION\"$" "$TAP/$FILE" || ! grep -q "^  sha256 \"$SHA\"$" "$TAP/$FILE" ||
  ! grep -q "/releases/download/$TAG_PREFIX#{version}/" "$TAP/$FILE"; then
  echo "error: could not point $TAP/$FILE at $TAG" >&2
  exit 1
fi
# Push even when there is nothing to commit, so a commit left behind by a failed push goes out.
if git -C "$TAP" diff --quiet HEAD -- "$FILE"; then
  echo "the cask is already at $VERSION"
else
  git -C "$TAP" commit -m "$CASK $VERSION" -- "$FILE"
fi
git -C "$TAP" push
echo "the tap now has the cask at $VERSION"
