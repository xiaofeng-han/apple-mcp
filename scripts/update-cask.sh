#!/bin/sh
# Points the Homebrew cask at the release that build-pkg.sh built and `gh release create`
# published: sets version and sha256 in Casks/apple-reminders-mcp.rb of a checkout of
# github.com/xiaofeng-han/homebrew-tap (by default ../homebrew-tap), then commits and pushes.
#
# Homebrew users pick up the cask from the tap's main branch on their next `brew update`, so the
# package must already be on GitHub: the script first checks that the release is published and
# serves the very file in dist/.
set -eu
TAP=$(cd "${1:-$(dirname "$0")/../../homebrew-tap}" && pwd)
cd "$(dirname "$0")/.."

CASK=Casks/apple-reminders-mcp.rb
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
PKG=AppleRemindersMCP-$VERSION.pkg
SHA=$(cut -d ' ' -f 1 "dist/$PKG.sha256")

PUBLISHED=$(gh release view "v$VERSION" -R xiaofeng-han/apple-reminders-mcp --json isDraft,assets \
  --jq "if .isDraft then \"a draft (publish it first)\" else (.assets[] | select(.name == \"$PKG\") | .digest) end")
if [ "$PUBLISHED" != "sha256:$SHA" ]; then
  echo "error: release v$VERSION has no $PKG with sha256 $SHA (GitHub has: ${PUBLISHED:-none})" >&2
  exit 1
fi

sed -i '' -E -e "s/^  version \"[^\"]*\"$/  version \"$VERSION\"/" \
  -e "s/^  sha256 \"[0-9a-f]{64}\"$/  sha256 \"$SHA\"/" "$TAP/$CASK"
if ! grep -q "^  version \"$VERSION\"$" "$TAP/$CASK" || ! grep -q "^  sha256 \"$SHA\"$" "$TAP/$CASK"; then
  echo "error: could not set version and sha256 in $TAP/$CASK" >&2
  exit 1
fi
# Push even when there is nothing to commit, so a commit left behind by a failed push goes out.
if git -C "$TAP" diff --quiet HEAD -- "$CASK"; then
  echo "the cask is already at $VERSION"
else
  git -C "$TAP" commit -m "apple-reminders-mcp $VERSION" -- "$CASK"
fi
git -C "$TAP" push
echo "the tap now has the cask at $VERSION"
