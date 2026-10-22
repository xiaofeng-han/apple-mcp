#!/bin/sh
# Publishes a release in one command:
#
#   scripts/release.sh 0.3.1             # release 0.3.1
#   scripts/release.sh --dry-run 0.3.1   # every local step, then undo; nothing is committed or published
#
# It sets the version in Resources/Info.plist (the build number is the previous one plus one) and
# in the READMEs' install commands, runs swift test, builds the package with build-pkg.sh, commits
# "Release <version>", tags v<version> and pushes both to main. Then it creates a draft GitHub
# release with the package and its checksum, checks that GitHub has the very file, publishes it,
# and points the Homebrew cask at it with update-cask.sh.
#
# The release note is the "## <version>" section of CHANGELOG.md: the English part, a line "---",
# then the Chinese part. The requirements and install commands for that version go in between.
#
# Run it on main, up to date with origin, with nothing uncommitted, after scripts/e2e.py has
# passed on this commit. It needs the signing identity build-app.sh uses (an ad-hoc signed build
# would make every user grant the permissions again), gh logged in, and a clean checkout of
# github.com/xiaofeng-han/homebrew-tap (by default ../homebrew-tap; TAP=<path> picks another).
set -eu
cd "$(dirname "$0")/.."

APP=AppleRemindersMCP
TITLE="Apple Reminders MCP"
REPO=xiaofeng-han/apple-reminders-mcp
CASK=apple-reminders-mcp

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; shift; fi
if [ $# -ne 1 ] || ! printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "usage: scripts/release.sh [--dry-run] <version>   (such as 0.3.1)" >&2
  exit 2
fi
VERSION=$1
TAG=v$VERSION
PKG=dist/$APP-$VERSION.pkg
NOTES=dist/release-notes-$VERSION.md
TAP=${TAP:-$(cd .. && pwd)/homebrew-tap}
IDENTITY=${SIGNING_IDENTITY:-Xiaofeng Local Code Signing}
EDITED="Resources/Info.plist README.md README.zh-CN.md"

STEP="checking"
HINT=""
finish() {
  status=$?
  if [ "$DRY_RUN" = 1 ]; then
    # shellcheck disable=SC2086
    git checkout -q -- $EDITED
  fi
  if [ $status -ne 0 ]; then
    echo "release.sh: stopped while $STEP." >&2
    [ -z "$HINT" ] || echo "$HINT" >&2
  fi
}
trap finish EXIT

fail() {
  echo "release.sh: $1" >&2
  exit 1
}
# Whether $1 is a higher version than $2.
higher() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$1" ]
}
# Prints stdin without its leading and trailing blank lines.
trim() {
  awk 'NF { last = NR } { line[NR] = $0 } END { for (i = 1; i <= last; i++) if (started || line[i] ~ /[^ ]/) { started = 1; print line[i] } }'
}

# --- Checks: nothing is changed until they all pass.
CURRENT=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)
higher "$VERSION" "$CURRENT" || fail "$VERSION is not higher than the current version, $CURRENT"
git fetch -q origin
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || [ -n "$(git ls-remote --tags origin "refs/tags/$TAG")" ]; then
  fail "the tag $TAG already exists"
fi
[ -z "$(git status --porcelain)" ] || fail "there are uncommitted changes; commit or set them aside first"
security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\"" || fail "the signing identity \"$IDENTITY\" is not in the keychain"

[ -f CHANGELOG.md ] || fail "there is no CHANGELOG.md"
SECTION=$(awk -v heading="## $VERSION" '$0 == heading { on = 1; next } on && /^## / { exit } on { print }' CHANGELOG.md | trim)
if [ -z "$SECTION" ]; then
  [ "$DRY_RUN" = 1 ] || fail "CHANGELOG.md has no \"## $VERSION\" section; write the release note there first"
  echo "warning: CHANGELOG.md has no \"## $VERSION\" section; the release would stop here" >&2
fi

if [ "$DRY_RUN" = 0 ]; then
  [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "run it on main"
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main is not the same as origin/main; pull or push first"
  gh auth status >/dev/null 2>&1 || fail "gh is not logged in"
  [ -d "$TAP/.git" ] || fail "no homebrew-tap checkout at $TAP (TAP=<path> picks another)"
  git -C "$TAP" fetch -q origin
  [ -z "$(git -C "$TAP" status --porcelain)" ] || fail "$TAP has uncommitted changes"
  [ "$(git -C "$TAP" rev-parse HEAD)" = "$(git -C "$TAP" rev-parse origin/main)" ] || fail "$TAP is not the same as its origin/main; pull it first"
fi

# --- The version: Info.plist and the install commands in the READMEs.
STEP="setting the version"
HINT="Nothing is committed; undo the edits with: git checkout -- $EDITED"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" -c "Set CFBundleVersion $((BUILD + 1))" Resources/Info.plist
for readme in README.md README.zh-CN.md; do
  sed -i '' -E -e "s/(gh release download v)[0-9]+\.[0-9]+\.[0-9]+/\1$VERSION/" \
    -e "s/($APP-)[0-9]+\.[0-9]+\.[0-9]+(\.pkg)/\1$VERSION\2/" "$readme"
  grep -q "gh release download $TAG " "$readme" && grep -q "$APP-$VERSION.pkg" "$readme" ||
    fail "could not set the version in the install commands of $readme"
done
echo "version $VERSION, build $((BUILD + 1))"

STEP="running swift test"
mkdir -p dist
swift test > dist/swift-test.log 2>&1 || { tail -40 dist/swift-test.log >&2; fail "swift test failed; the whole log is dist/swift-test.log"; }
echo "swift test passed"

STEP="building the package"
./scripts/build-pkg.sh
codesign -d -r- "dist/$APP.app" 2>&1 | grep -q 'certificate leaf' || fail "dist/$APP.app is not signed with \"$IDENTITY\""

STEP="writing the release note"
if [ -n "$SECTION" ]; then
  ENGLISH=$(printf '%s\n' "$SECTION" | awk '/^---$/ { exit } { print }' | trim)
  CHINESE=$(printf '%s\n' "$SECTION" | awk 'seen { print } /^---$/ { seen = 1 }' | trim)
  {
    printf '%s\n\n' "$ENGLISH"
    sed "s/@VERSION@/$VERSION/g" <<'EOF'
**Requirements:** macOS 26 or later on Apple silicon.

**Install or upgrade**

With Homebrew:

```bash
brew install --cask xiaofeng-han/tap/apple-reminders-mcp   # or: brew upgrade --cask apple-reminders-mcp
```

From the package:

```bash
gh release download v@VERSION@ -R xiaofeng-han/apple-reminders-mcp -p '*.pkg'
installer -pkg AppleRemindersMCP-@VERSION@.pkg -target CurrentUserHomeDirectory
```

Or open the package and choose to install for yourself only. The package has no Developer ID signature: if macOS refuses to open one downloaded in a browser, allow it under System Settings → Privacy & Security. Then open the app: set up your agents in the **AI Assistants** tab, pick their tools in **Tools**, and allow access to Reminders under **General**.
EOF
    [ -z "$CHINESE" ] || printf '\n---\n\n%s\n' "$CHINESE"
  } > "$NOTES"
  echo "release note: $NOTES"
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "dry run: built $PKG; the version edits are undone, and nothing was committed, pushed or published"
  exit 0
fi

# --- From here on, GitHub and the tap change.
STEP="committing and tagging"
HINT="Nothing is pushed yet. To start over: git reset --hard origin/main; git tag -d $TAG (if it was made)"
# shellcheck disable=SC2086
git commit -q -m "Release $VERSION" -- $EDITED
git tag -a "$TAG" -m "$TITLE $VERSION"

STEP="pushing the release commit and tag"
git push -q --atomic origin HEAD:main "$TAG"

STEP="creating the draft release"
HINT="The release commit and $TAG are on GitHub. Finish by hand:
  gh release create $TAG $PKG $PKG.sha256 -R $REPO --draft --verify-tag --title \"$TITLE $VERSION\" --notes-file $NOTES
  gh release edit $TAG -R $REPO --draft=false
  scripts/update-cask.sh \"$TAP\""
gh release create "$TAG" "$PKG" "$PKG.sha256" -R "$REPO" --draft --verify-tag --title "$TITLE $VERSION" --notes-file "$NOTES" >/dev/null

STEP="checking the draft's package"
HINT="The draft release $TAG is on GitHub but does not hold the package that was built here. Delete it
(gh release delete $TAG -R $REPO), then create it again as above."
SHA=$(cut -d ' ' -f 1 "$PKG.sha256")
DIGEST=$(gh release view "$TAG" -R "$REPO" --json assets --jq ".assets[] | select(.name == \"$APP-$VERSION.pkg\") | .digest")
[ "$DIGEST" = "sha256:$SHA" ] || fail "GitHub has ${DIGEST:-no package} for $APP-$VERSION.pkg, not sha256:$SHA"

STEP="publishing the release"
HINT="The draft release $TAG is checked. Finish by hand:
  gh release edit $TAG -R $REPO --draft=false
  scripts/update-cask.sh \"$TAP\""
gh release edit "$TAG" -R "$REPO" --draft=false >/dev/null

STEP="updating the Homebrew cask"
HINT="The release is published. Finish by hand: scripts/update-cask.sh \"$TAP\""
./scripts/update-cask.sh "$TAP"

STEP="done"
echo "released $TITLE $VERSION: https://github.com/$REPO/releases/tag/$TAG (cask $CASK)"
