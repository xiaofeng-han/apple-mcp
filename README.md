# Apple MCP

**English** | [简体中文](README.zh-CN.md)

Four Mac apps that let AI agents (Claude Code, Codex, Grok Build, OpenCode, Gemini CLI, pi, …) read and write Apple's own apps natively, through MCP servers or a command line:

| App | What it reaches | Install | Documentation |
|---|---|---|---|
| **Apple Notes MCP** | Notes, with native formatting, edited in place and synced through iCloud | `brew install --cask xiaofeng-han/tap/apple-notes-mcp` | [English](docs/notes.md) · [简体中文](docs/notes.zh-CN.md) |
| **Apple Reminders MCP** | Reminders, with everything Reminders.app has (tags, subtasks, sections, smart lists, …), through its own framework | `brew install --cask xiaofeng-han/tap/apple-reminders-mcp` | [English](docs/reminders.md) · [简体中文](docs/reminders.zh-CN.md) |
| **Apple Journal MCP** | Journal: entries with their formatting, journals, Recently Deleted, photos, videos and recordings added, every attachment's details, and insights, through Journal's own framework and synced by Journal through iCloud | `brew install --cask xiaofeng-han/tap/apple-journal-mcp` | [English](docs/journal.md) · [简体中文](docs/journal.zh-CN.md) |
| **Apple Contacts MCP** | Contacts: every field of a card including notes and photos, linked cards, groups, smart lists, My Card, accounts, vCard import and export, and deleted cards kept 30 days, through Contacts' own frameworks and synced by Contacts through iCloud | `brew install --cask xiaofeng-han/tap/apple-contacts-mcp` (from its first release) | [English](docs/contacts.md) · [简体中文](docs/contacts.zh-CN.md) |

Each app is its own app: its own name, command (`apple-notes-mcp`, `apple-reminders-mcp`, `apple-journal-mcp`, `apple-contacts-mcp`), server (`apple-notes`, `apple-reminders`, `apple-journal`, `apple-contacts`), tools, permissions, settings window and version, so you install only what you want and agents see only its tools. All need Apple silicon: Notes, Reminders and Contacts need macOS 26 or later, and Apple Journal MCP needs Journal 3.0 (macOS 27.2). Each one's documentation says what it does, how to install it and set up your agents, and what it needs.

## One repository, four apps

This repository was `apple-reminders-mcp` (old links redirect here). Apple Notes MCP moved in from [apple-notes-mcp](https://github.com/xiaofeng-han/apple-notes-mcp) with its history, and the apps now share one base: the MCP server, the command line, the settings window and setting up agents are written once. Nothing changed for users: the casks, commands, permissions, settings and agent setups are the same as before.

Apple Journal MCP and Apple Contacts MCP were added later on the same base. Releases come from here, one app at a time, tagged `notes-v<version>`, `reminders-v<version>`, `journal-v<version>` or `contacts-v<version>`. Apple Notes MCP 0.1.0 to 0.3.0 were released from [apple-notes-mcp](https://github.com/xiaofeng-han/apple-notes-mcp/releases) (now archived), and Apple Reminders MCP up to 0.3.0 here as `v<version>`. Each app's changes are in [CHANGELOG-notes.md](CHANGELOG-notes.md), [CHANGELOG-reminders.md](CHANGELOG-reminders.md), [CHANGELOG-journal.md](CHANGELOG-journal.md) and [CHANGELOG-contacts.md](CHANGELOG-contacts.md).

## Layout

- `Sources/Wire`, `Launcher`, `Agents`, `AppCore`: the shared base. MCP over stdio and the choice of tools; holding the app's own privacy permissions; finding, installing and setting up AI agents; and the modes, command line, skill and settings window each app runs.
- `Sources/NotesComponent` (with `NoteModel`, `NotesShim`), `Sources/RemindersComponent` (with `ReminderKitShim`), `Sources/JournalComponent` (with `JournalModel`, `NoteModel`, and the hand-written interfaces to Journal's frameworks in `Interfaces/Journal`) and `Sources/ContactsComponent` (with `ContactsModel`, `ContactsShim`): each app's own code, its data and tools. `Sources/AppleNotesMCP`, `Sources/AppleRemindersMCP`, `Sources/AppleJournalMCP` and `Sources/AppleContactsMCP` are the executables, one line each.
- `Resources/Notes`, `Resources/Reminders`, `Resources/Journal`, `Resources/Contacts`: each app's Info.plist (its version), entitlements, icon and installer text.
- `scripts/`: building, packaging, releasing and checking, each taking `notes`, `reminders`, `journal` or `contacts`.
- `docs/`: each app's documentation, [the plan the two first apps moved together by](docs/MERGE-PLAN.md) (in Chinese), and the reverse-engineering notes [Notes](docs/RE-FINDINGS.md), [Journal](docs/RE-FINDINGS-journal.md) and [Contacts](docs/RE-FINDINGS-contacts.md) started from (in Chinese).

## Build and test

```bash
swift build                                  # every app: .build/debug/AppleNotesMCP, AppleRemindersMCP, AppleJournalMCP, AppleContactsMCP
swift test                                   # the shared base and every app's unit tests
./scripts/build-app.sh notes                 # dist/AppleNotesMCP.app, signed (or: reminders, journal, contacts)
/usr/bin/python3 -I scripts/e2e.py notes     # end to end, against your real notes (or: reminders, journal, contacts)
scripts/release.sh --dry-run notes <version> # a release, up to the package, then undone
```

Every pull request and every push to `main` builds every app on a GitHub-hosted Mac, checks that what users and agents see (help, commands, the skill, the MCP tool lists, agent setup) has not changed against `Tests/Golden` (`scripts/golden.py`), and runs the unit tests. The end-to-end checks need real data and the apps' permissions, so they run on a Mac before a release. Each app's documentation has the details: signing, packaging, releasing, and what its tests cover.
