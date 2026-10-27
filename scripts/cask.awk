#!/usr/bin/awk -f
# Used by update-cask.sh: prints a cask with its version, sha256, url (the release's zipped app),
# homepage and livecheck set for a release of this repository. Every other line is kept as it is.
#   -v version=0.4.0 -v sha=<64 hex> -v repo=xiaofeng-han/apple-mcp -v prefix=notes-v
#   -v app=AppleNotesMCP -v doc=docs/notes
/^  livecheck do$/ {
  print
  print "    url \"https://github.com/" repo "\""
  print "    regex(/^" prefix "(\\d+(?:\\.\\d+)+)$/i)"
  print "    strategy :github_releases"
  skipping = 1
  next
}
skipping && /^  end$/ { skipping = 0; print; next }
skipping { next }
/^  version "[^"]*"$/ { print "  version \"" version "\""; next }
/^  sha256 "[0-9a-f]+"$/ { print "  sha256 \"" sha "\""; next }
/^  url "/ { print "  url \"https://github.com/" repo "/releases/download/" prefix "#{version}/" app "-#{version}.zip\""; next }
/^  homepage "/ { print "  homepage \"https://github.com/" repo "/blob/main/" doc ".md\""; next }
{ print }
