# Sourced by the build and release scripts after `cd` to the repository: sets, for the app named in
# $APP_ID (notes, reminders or journal), everything that differs between Apple Notes MCP, Apple
# Reminders MCP and Apple Journal MCP. Each app keeps its own bundle id, package id, cask and tags;
# see docs/MERGE-PLAN.md.
#
#   APP          AppleNotesMCP: the executable, the app bundle and the package's name
#   TITLE        Apple Notes MCP
#   BUNDLE_ID    com.xiaofeng.apple-notes-mcp (the package's id adds .pkg)
#   CASK         apple-notes-mcp: the cask in github.com/xiaofeng-han/homebrew-tap, and the command
#   RESOURCES    Resources/Notes: Info.plist (the version), entitlements, icon, installer text
#   TAG_PREFIX   notes-v: releases are tagged notes-v<version>, since both apps release here
#   DOC          docs/notes: the app's documentation (.md and .zh-CN.md)
#   CHANGELOG    CHANGELOG-notes.md: each release's note
#   PERMISSIONS  the release note's line about what the app needs
REPO=xiaofeng-han/apple-mcp

case "${APP_ID:-}" in
  notes)
    APP=AppleNotesMCP
    TITLE="Apple Notes MCP"
    CASK=apple-notes-mcp
    RESOURCES=Resources/Notes
    PERMISSIONS="Full Disk Access (to read the Notes database) and Automation → Notes"
    ;;
  reminders)
    APP=AppleRemindersMCP
    TITLE="Apple Reminders MCP"
    CASK=apple-reminders-mcp
    RESOURCES=Resources/Reminders
    PERMISSIONS="Reminders. Full Disk Access is optional, only to list everything in Recently Deleted and to read images on reminders"
    ;;
  journal)
    APP=AppleJournalMCP
    TITLE="Apple Journal MCP"
    CASK=apple-journal-mcp
    RESOURCES=Resources/Journal
    PERMISSIONS="Full Disk Access (to read and write Journal's data). It needs Journal 3.0 (macOS 27.2)"
    ;;
  *)
    echo "usage: $0 notes|reminders|journal …" >&2
    exit 2
    ;;
esac
BUNDLE_ID=com.xiaofeng.$CASK
TAG_PREFIX=$APP_ID-v
DOC=docs/$APP_ID
CHANGELOG=CHANGELOG-$APP_ID.md
