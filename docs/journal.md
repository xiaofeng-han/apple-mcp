# Apple Journal MCP

**English** | [简体中文](journal.zh-CN.md)

Part of [apple-mcp](../README.md), the repository of Apple Journal MCP, [Apple Notes MCP](notes.md) and [Apple Reminders MCP](reminders.md).

An MCP server that lets AI agents (Claude Code, Codex, Grok Build, OpenCode, Gemini CLI, pi, …) read and write Apple's Journal app on the Mac. Every tool is also a command-line command, so an agent can use a skill instead of the server. Its settings window finds the agents on your Mac and sets each one up either way with one click.

Journal has no AppleScript and only a few Shortcuts actions (make an entry, search, open one), so this app works through Journal's own data model: its private framework JournalShared, which Journal, its share sheet and its widgets all use. Reads and writes go to Journal's data on this Mac in place, the way Journal's share sheet writes an entry, and Journal itself then uploads the changes to iCloud. What an agent writes is ordinary Journal data, on every device:
- entries: title, text with Journal's own formatting (bold, italic, underline, strikethrough, lists, block quotes), date, bookmark, the journal they are in, Recently Deleted, duplicates;
- journals: name, color and icon; deleting one with its entries moved, kept or deleted;
- attachments: photos, videos and audio recordings added from files, and attachments taken off; every kind read with its details: photos, videos, recordings with their transcripts, places and visits, State of Mind, workouts, activity, music and podcasts, books, contacts, links, reflections, drawings' handwriting;
- Journal's insights: days journaled and streaks.

The only permission it needs is Full Disk Access, since Journal's data sits in a container macOS protects.

Requires Journal 3.0, which comes with macOS 27.2, on Apple silicon. The app calls Journal's frameworks through interfaces written for that version; on another one it says so and changes nothing (see [How it works](#how-it-works)). All code is written for this project, with no third-party dependencies.

## What it covers

| Journal | Here |
|---|---|
| Write, edit and format entries (title, text, date) | ✅ `create_entry`, `edit_entry`; text as Markdown |
| Bookmarks | ✅ `bookmarked` |
| Journals: create, rename, color, icon, delete (move, keep or delete the entries), move entries between them | ✅ `manage_journal`, `edit_entry` `journal` |
| Recently Deleted: delete, recover, delete for good | ✅ `delete_entry`, `restore_entry` |
| Duplicate an entry | ✅ `duplicate_entry` |
| Search, filter by journal, bookmark, date and kind of attachment | ✅ `find_entries` |
| Photos, videos, recordings and their transcripts, places, State of Mind, workouts, music, books, contacts, links, reflections, drawings | ✅ read: `read_entry` details, `read_attachment` opens them |
| Add photos, videos and audio recordings to an entry; take attachments off | ✅ `create_entry` and `edit_entry` `attach`; `edit_entry` `detach` |
| Insights: days journaled, streaks | ✅ `overview` |
| Export | ✅ `export_entries` as Markdown with the attachments (Journal's own export makes an archive only Journal opens) |
| Adding drawings, Live Photos, places, State of Mind or other kinds of attachment; placing one in the text | ❌ see [Not possible](#not-possible) |
| Journaling Suggestions, writing prompts made on the device | ❌ |
| Lock Journal, the writing schedule and its notifications, print | ❌ |

## Tools

| Tool | What it does |
|---|---|
| `overview` | The journals (color, icon, how many entries), how many entries in all, bookmarked and in Recently Deleted, and the insights: days journaled, this year's days and entries, daily and weekly streaks, first and last entry. They are worked out from the entries' dates, so they can differ from Journal's Insights, which also count the days of entries deleted since |
| `find_entries` | Entries, newest first (or oldest, or last edited): by words (in the title, text, writing prompt, and in attachments' places, people, songs, transcripts and handwriting), journal, bookmark, date (`after` inclusive, `before` exclusive) and kind of attachment; or those in Recently Deleted. Each with its id, version, a snippet and its attachments by kind; pages with `offset` |
| `read_entry` | Entries in full (up to 20): the text as Markdown, the date, created and edited times, journal, bookmark, writing prompt, and each attachment's details |
| `read_attachment` | One attachment: photos as JPEG, a frame of a video, recordings as audio, with their details |
| `create_entry` | An entry with a title and text, dated now or on `date`, in a journal, bookmarked, with photos, videos and recordings attached (`attach`) |
| `edit_entry` | Changes an entry in one call: title, text (`body` rewrites it, `replace` swaps exact Markdown, `append` adds to the end), date, bookmark, journal (`""` takes it out of its journal), attachments (`attach` adds files, `detach` takes attachments off by id). Only what changes is written |
| `delete_entry` | Moves an entry to Recently Deleted, where Journal keeps it 30 days; `permanently` deletes one already there for good |
| `restore_entry` | Brings an entry back from Recently Deleted |
| `duplicate_entry` | Copies an entry with its text, date, journal and attachments, as Journal's Duplicate does |
| `manage_journal` | Creates a journal, changes its name, color or icon, or deletes it: its entries move to another journal (`move_entries_to`), stay in All Entries, or go to Recently Deleted (`delete_entries` with `expected_entries`, the number it holds) |
| `export_entries` | Writes entries as Markdown files, one per entry, with their photos, videos and recordings, into a new folder; filtered by journal, bookmark and date |

Every change to an entry passes back the `version` that `read_entry` or `find_entries` gave, and an entry changed since (in Journal, on another device) is refused, so an agent never overwrites what it has not read. Each write answers with `"uploaded": true` once Journal has uploaded it to iCloud, usually within seconds; if Journal is quit, the app starts it hidden.

Dates are local: `2026-10-21T09:30`, or `2026-10-21`, which means noon that day, so the entry stays on that day in every time zone.

### Entry text

Entry text is Markdown, one paragraph per line, mapped onto what Journal's editor has:

| Markdown | In Journal |
|---|---|
| `**bold**`, `*italic*`, `<u>underline</u>`, `~~strike~~` | the same |
| `* item` or `- item`, two spaces per indent level | bulleted or dashed list, nested |
| `1. item` | numbered list |
| `> text` | block quote |
| `# heading` | bold text: Journal has no headings |
| `- [ ] item` | bulleted item: Journal has no checklists |
| `[text](url)` | `text (url)`: Journal keeps no links in text |
| a table | refused: Journal has no tables |

Changing an entry writes only the span that differs, into Journal's own mergeable text, so the rest keeps its formatting (colors, alignment and anything else Markdown does not show) and its history for merging with edits made on other devices. Photos, Genmoji and follow-up prompts placed in the text read as `![asset](attachment:ID)` placeholders; keep them where they are. Entries written before Journal 3.0 keep their text as RTF, and edits to them are written as RTF too.

### Attachments

`read_entry` lists an entry's attachments with what Journal knows about them; `find_entries` and `export_entries` filter by their kind:

| Kind | Details |
|---|---|
| `photo`, `video` | when and where it was taken |
| `audio` | when it was recorded, how long, Journal's transcript |
| `place` | places and visits: name, city, kind of place, from and to, coordinates |
| `state_of_mind` | momentary emotion or daily mood, how it felt, what describes it, what it is about |
| `workout`, `activity` | kind, start, end, duration, calories, distance; steps |
| `music`, `podcast`, `book` | title, artist or author, album, app, when played |
| `contact` | who, when, how long |
| `link`, `reflection`, `drawing`, `event` | the address; the reflection's prompt; the handwriting Journal read in a drawing; the event's place and time |

`attach` takes the absolute paths of up to 20 files, each at most 250 MB, and adds them after the attachments the entry shows above its text, as Journal's photo picker does:

| File | Kept as |
|---|---|
| an image macOS reads (JPEG, HEIC, PNG, TIFF, RAW, …) | a photo, saved as HEIC of at most 6 megapixels like Journal's own, with the date and place from its Exif |
| a video macOS plays (MOV, MP4, M4V) | a video, the file as it is with a still for Journal to show, its date and place |
| audio macOS plays (M4A, MP3, WAV, AIFF, CAF, …) | a recording, the file as it is with its length and the waveform Journal draws (worked out by Journal's own code) |

The answer lists each new attachment's id. `detach` takes attachments off by those ids (from `read_entry`); Journal then deletes them from iCloud and from the Mac. One placed in the entry's text is refused: only Journal can take it out of the text.

## Command line

Every tool is a command: `apple-journal-mcp help` prints the tree, and any command takes `--help`.

```bash
apple-journal-mcp journals list                                   # journals, counts and insights
apple-journal-mcp entries search "lake trip"                       # words in text, title, places, transcripts
apple-journal-mcp entries list --journal Travel --after 2026-10-01 --attachment photo
apple-journal-mcp entries read ID
apple-journal-mcp entries create - --title "A good day" --journal Travel <<'EOF'
We walked to the **lighthouse**.
EOF
apple-journal-mcp entries edit ID --version VERSION --append "- Swam before breakfast" --bookmarked
apple-journal-mcp entries edit ID --version VERSION --attach ~/Pictures/lake.heic --attach ~/Movies/swim.mov
apple-journal-mcp entries delete ID --version VERSION                # to Recently Deleted
apple-journal-mcp journals create "Gratitude" --color pink --icon "🙏"
apple-journal-mcp attachments read ID --output-dir ~/Desktop        # saves its photos and recordings
apple-journal-mcp entries export ~/Desktop/journal                  # Markdown with the attachments
```

Commands print the tool's JSON answer, sometimes after a short lead such as `Created.`. Exit status 1 means the request failed (not found, changed since it was read, not allowed), with the reason on stderr; 2 means a wrong command or flag. Every command also takes `--json '{...}'` (or `--json -` for stdin) with the fields by their snake_case names.

## Install

Releases are built for Apple silicon; the app works with Journal 3.0, which comes with macOS 27.2. The default way to install and set up is with Homebrew:

```bash
brew install --cask xiaofeng-han/tap/apple-journal-mcp
apple-journal-mcp setup                  # shows where to give Full Disk Access
apple-journal-mcp agents set-up --all    # register the server with the agents on this Mac
```

To give the agents the skill instead of the server, add `--skill` to the last command. Instead of the last two commands, you can open Apple Journal MCP from Applications: set up your agents in its **AI Assistants** tab, and see Full Disk Access under **General**.

Without Homebrew, download `AppleJournalMCP-<version>.pkg` from [Releases](https://github.com/xiaofeng-han/apple-mcp/releases) and open it, or install it from the terminal:

```bash
gh release download journal-v0.1.0 -R xiaofeng-han/apple-mcp -p '*.pkg'
installer -pkg AppleJournalMCP-0.1.0.pkg -target CurrentUserHomeDirectory
```

Installing for yourself puts the app in `~/Applications` and needs no administrator password. The app and package have no Developer ID signature; the cask takes off the quarantine, and a package downloaded in a browser has to be allowed under System Settings → Privacy & Security.

### After installing

Full Disk Access has to be given by hand: System Settings → Privacy & Security → Full Disk Access, click +, and choose `AppleJournalMCP.app` (`setup` and the General tab open both for you). Journal must have been opened once on this Mac, and to see the entries from your other devices, Journal has to sync with iCloud there. To check:

```bash
apple-journal-mcp --self-check
```

It prints Journal's version and whether this app supports it, the permission, how many entries and journals it sees, and whether Journal syncs with iCloud.

The window's **AI Assistants** tab, **Set Up As** (server or skill) and the **Tools** tab work as in the other apps; see [Setting up your agents](reminders.md#setting-up-your-agents), [Server or skill](reminders.md#server-or-skill) and [Choosing the tools](reminders.md#choosing-the-tools), with `apple-journal-mcp`, the server name `apple-journal`, the skill `apple-journal/SKILL.md` and `~/Library/Application Support/AppleJournalMCP/tools.json` in their place. By hand, the command is `/opt/homebrew/bin/apple-journal-mcp --stdio` (or the app's executable, `AppleJournalMCP.app/Contents/MacOS/AppleJournalMCP`); for example `claude mcp add -s user apple-journal -- /opt/homebrew/bin/apple-journal-mcp --stdio`.

### Build from source

```bash
./scripts/build-app.sh journal
ditto dist/AppleJournalMCP.app ~/Applications/AppleJournalMCP.app
```

`./scripts/build-pkg.sh journal` builds the release package, and `scripts/release.sh journal <version>` releases it, as described for [Apple Reminders MCP](reminders.md#build-from-source), with the note from [`CHANGELOG-journal.md`](../CHANGELOG-journal.md) and tags `journal-v<version>`. The icon is `Resources/Journal/AppIcon.icon`: `swift scripts/compose-icon.swift Resources/Reminders/AppIcon.icon/Assets/artwork.png Resources/Journal/AppIcon.icon/Assets/artwork.png journal`, then `./scripts/build-icon.sh journal`.

### Why the permission belongs to this app

As with the other apps, it gives up the responsibility macOS charges to whatever started it and launches itself again under its own identity, so Full Disk Access is granted once, to "Apple Journal MCP", whichever agent starts it. Start it by its real path or through a script that `exec`s it, not through a symbolic link.

## How it works

- **Data.** Journal keeps everything in a Core Data store in its app group, `~/Library/Group Containers/group.com.apple.moments/Library/moments.sqlite`, with photos and recordings in `Attachments/` next to it. The app opens that store with Journal's own model and classes, as Journal opens it (history tracking on, so Journal hears of each save at once), and never migrates it.
- **Text.** Journal 3.0 keeps an entry's text and title, and a journal's name, color and icon, as mergeable values of Apple's private Coherence framework (CRDTs), and older entries as RTF. The app reads and changes them through Journal's own code.
- **Sync.** Journal's sync engine uploads every object marked as not yet uploaded. Writes mark what they change that way, as Journal's own editor does, and Journal uploads it, usually within seconds.
- **Attachments.** An attachment is an asset (its kind and metadata, encoded by Journal's own types) with files in `Attachments/ENTRY/ASSET/`, placed in the entry's layout through Journal's own placement code, which also keeps the older ordering fields that entries from before Journal 3.0 use. Journal uploads the files with the entry; taking one off marks it for Journal to delete from iCloud, after which Journal removes it and its files here.
- **Interfaces.** JournalShared is a Swift framework without a public interface, so `Interfaces/Journal` holds Swift interfaces written by hand for the part this app calls, and the stubs the linker reads in their place (`scripts/journal-stubs.py` writes them from the symbols on the Mac it runs on). The frameworks are linked weakly. When the app starts it checks that each of the functions it calls is on this Mac; if one is missing (another macOS version), every tool says so and nothing is read or changed. `--check-markdown` reads every entry, writes it as Markdown and parses it back, to see that nothing is lost; run it after a macOS update.
- **What needs no Journal** is in its own target, `JournalModel`: the tools as agents see them (names, descriptions, inputs), the commands, the text's Markdown form, the insights and the attachments' details. `JournalComponent` gives each tool what it does. The unit tests (`JournalModelTests`) build against `JournalModel` only, so they need neither the interfaces nor Journal.
- The reverse-engineering notes are in [RE-FINDINGS-journal.md](RE-FINDINGS-journal.md) (in Chinese).

## Tests

```bash
/usr/bin/python3 -I scripts/e2e.py journal                              # the installed app, against your real journal
/usr/bin/python3 -I scripts/e2e.py journal .build/debug/AppleJournalMCP # a bare build, with your terminal's Full Disk Access
```

The checks run every tool over stdio and the main commands, 79 checks in all, with the write guard (`APPLE_JOURNAL_MCP_WRITE_GUARD=agent test`) limiting writes to entries titled `agent test…` and journals named `agent test…`. They make a throwaway journal and entries, attach a photo and a recording they make (and a video, when `ffmpeg` is installed), check that Journal uploads each change, and at the end delete all of it for good, so the overview counts are back where they were; your other devices see the test entries come and go. Journal keeps a streak record (an attachment of kind `streakEvent`, with no entry) for every entry deleted for good, so that deleting never breaks a streak: after a run, Journal's own Insights count that day as a day you journaled. `swift test` checks the Markdown mapping, the edit span, the insights, the attachment details, and that the commands match the tools.

## Not possible

- **Adding drawings, Live Photos, places, State of Mind, workouts and the other kinds of attachment.** Journal makes these from PencilKit, the Photos library and system services (Journaling Suggestions, HealthKit) in its own editor; only photos, videos and recordings come from plain files. Existing ones of every kind are read in full.
- **Placing an attachment in the text, or a transcript for an attached recording.** Attachments are added to the entry's layout above its text. Journal transcribes the recordings made in its own recorder, not ones added from files.
- **Journaling Suggestions.** They come from a system service (momentsd) that answers only apps with an entitlement this app cannot have.
- **Writing prompts and follow-up prompts made on the device.** Journal makes them with Apple Intelligence under entitlements only it has. Prompts already in entries are read.
- **State of Mind into Health.** Logging one needs HealthKit with Journal's own permission. Those in entries are read.
- **Lock Journal, the writing schedule and its notifications, printing.** These are settings and actions of Journal itself, not data in its store.
- **Journal's own export archive and its import.** `export_entries` writes Markdown instead.
- **Other versions of Journal.** The interfaces are written for Journal 3.0 on macOS 27.2.
