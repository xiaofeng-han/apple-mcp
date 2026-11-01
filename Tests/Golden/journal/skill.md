---
name: apple-journal
description: Read and change the user's entries in Apple's Journal app on this Mac (entries, journals, attachments such as photos, places and State of Mind, and insights such as streaks, synced through iCloud to their devices) by running the apple-journal-mcp command. Use when the user asks about their journal or diary, or wants to write in it.
metadata:
  generated-by: apple-journal-mcp
  command: "<EXECUTABLE>"
---

# Apple Journal

Run `<EXECUTABLE>` followed by a command, by that full path. It prints the answer as JSON, sometimes after a short lead such as `Created.`. Exit status 1 means the request failed (not found, changed since it was read, not allowed); the reason is on stderr. Exit status 2 means the command or a flag was wrong; add `--help` to any command for its flags.

```sh
<EXECUTABLE> entries search "lake trip"
<EXECUTABLE> entries read ID
<EXECUTABLE> entries edit ID --version VERSION --append "- Swam before breakfast"
<EXECUTABLE> entries create - --title "A good day" --journal Travel <<'EOF'
We walked to the **lighthouse**.
EOF
```

## Rules

- Journal entries are private. Read only what the user's request needs, and share what they say only as the user asks.
- Find entries with `entries list` (newest first; `--journal`, `--bookmarked`, `--after`/`--before` YYYY-MM-DD, `--attachment photo|video|audio|place|state_of_mind|workout|activity|music|podcast|book|contact|link|reflection|drawing|event|any|none`) or `entries search WORDS`, then `entries read ID`. Each comes with its `version`. `journals list` shows the journals and Journal's insights (days journaled, streaks).
- Every change to an entry needs `--version` from `entries read`, `list` or `search`: `entries edit`, `entries delete`. An entry changed elsewhere since then is refused; read it again. Each change prints the new version.
- Make all changes to one entry in a single `entries edit ID --version V` call: `--title`, `--body` (the whole text), `--replace '[{"old":"…","new":"…"}]'` (exact Markdown from `entries read`), `--append` (Markdown at the end), `--date 2026-10-21T09:30`, `--bookmarked` / `--no-bookmarked`, `--journal NAME` (`""` takes it out of its journal), `--attach FILE` (a photo, video or audio recording, by absolute path; repeat for more; `entries create` takes it too), `--detach ATTACHMENT_ID` (from `entries read`).
- Entry text is Markdown, one paragraph per line: `**bold**`, `*italic*`, `<u>underline</u>`, `~~strike~~`, `*` and `-` lists, `1.` numbered, two spaces per indent level, `>` quote. Journal has no headings, tables or checklists: headings become bold text, checklist items bullets, and tables are refused.
- Keep `![…](attachment:…)` placeholders where they are: they are photos, prompts and Genmoji placed in the text. `attachments read ID` prints an attachment's details and saves its photos, video frames and recordings, printing where.
- `-` as the Markdown of `entries create`, or as `--body` or `--append`, reads it from stdin: use a quoted heredoc for text of several lines.
- Deleting moves entries to Recently Deleted for 30 days (`entries list --deleted` lists them) and `entries restore ID` brings one back. Ask the user before `entries delete ID --version V --permanently` (only for an entry already there), and before `journals delete JOURNAL --delete-entries --expected-entries N`.
- Journal uploads each change to iCloud; the answer says `"uploaded": true` once it has.
- Every command also takes `--json '{...}'` (or `--json -` to read it from stdin) with the fields by their snake_case names; flags override it.
- Agents that run commands in a sandbox (Codex does) cannot reach Journal from it: when the command says it ran inside a sandbox, run it again outside the sandbox, which the user may have to approve.
- If the command says it lacks Full Disk Access, ask the user to run `<EXECUTABLE> setup` in a terminal.

## Commands

### entries

- `entries list`: List entries, newest first, with their ids and versions. Filters combine: --journal, --bookmarked, --after (inclusive) and --before (exclusive) dates as YYYY-MM-DD, --attachment KIND (repeat for more; any, none), --deleted for Recently Deleted. --offset gives the next page.
  - `--journal string` Only entries in this journal (name or id)
  - `--[no-]bookmarked` Only bookmarked entries
  - `--after string` 2026-10-21: entries dated that day or later
  - `--before string` 2026-10-21: entries dated before that day
  - `--attachment string…` Only entries with an attachment of one of these kinds; any, or none
  - `--[no-]deleted` Look in Recently Deleted instead
  - `--sort newest|oldest|edited` Default newest (by the entry's date); edited: most recently changed first
  - `--limit int` Default 50, at most 500
  - `--offset int` Skip this many, for the next page

- `entries search [QUERY]`: Find entries with all these words: in the text, title, prompt, and attachments' places, songs, transcripts.
  - `--after string` 2026-10-21: entries dated that day or later
  - `--attachment string…` Only entries with an attachment of one of these kinds; any, or none
  - `--before string` 2026-10-21: entries dated before that day
  - `--[no-]bookmarked` Only bookmarked entries
  - `--[no-]deleted` Look in Recently Deleted instead
  - `--journal string` Only entries in this journal (name or id)
  - `--limit int` Default 50, at most 500
  - `--offset int` Skip this many, for the next page
  - `--sort newest|oldest|edited` Default newest (by the entry's date); edited: most recently changed first

- `entries read [ID]`: Print entries in full, the text as Markdown, each with the version entries edit takes. By id, or several (--ids repeats, up to 20).
  - `--id string…` Several entries, up to 20

- `entries create [MARKDOWN]`: Create an entry from Markdown, with --title, --date, --journal, --bookmarked, --attach FILE.
  - `--attach string…` A photo, video or audio recording to add
  - `--[no-]bookmarked` Bookmark it
  - `--date string` 2026-10-21T09:30, or 2026-10-21; default now
  - `--journal string` The journal to put it in (name or id); default none, so only All Entries shows it
  - `--title string` The title; default none

- `entries edit ID --version string`: Change an entry in one go: --title, --body, --replace pairs, --append, --date, --[no-]bookmarked, --journal, --attach, --detach. --version is the one entries read, list or search gave; an entry changed elsewhere since then is refused, so read it again. --replace takes exact Markdown from entries read, applied in order. --journal "" takes it out of its journal. Only what changes is written; the rest keeps its formatting.
  - `--append string` Markdown to add at the end; - reads it from stdin
  - `--attach string…` A photo, video or audio recording to add
  - `--body string` The whole text as Markdown; - reads it from stdin
  - `--[no-]bookmarked` Bookmark (true) or not (false)
  - `--date string` 2026-10-21T09:30, or 2026-10-21
  - `--detach string…` An attachment's id, from entries read, to take off
  - `--journal string` Move it to this journal (name or id); "" takes it out of its journal
  - `--replace json` A JSON list of {old, new, all}, applied in order {all: Replace every occurrence; new: Markdown; old: Exact Markdown; must be unique unless all}
  - `--title string` The new title; "" for none

- `entries delete ID --version string`: Move an entry to Recently Deleted; --permanently deletes one there for good (ask the user first). --version is the one entries read, list or search gave; an entry changed elsewhere since then is refused.
  - `--[no-]permanently` Delete an entry in Recently Deleted for good

- `entries restore ID`: Bring an entry back from Recently Deleted (entries list --deleted lists them).

- `entries duplicate ID`: Copy an entry with its text, date, journal and attachments.

- `entries export FOLDER`: Write entries as Markdown files with their photos, videos and recordings into a new folder.
  - `--after string` 2026-10-21: entries dated that day or later
  - `--before string` 2026-10-21: entries dated before that day
  - `--[no-]bookmarked` Only bookmarked entries
  - `--journal string` Only this journal (name or id)

### journals

- `journals list`: The journals with their entries, colors and icons, the counts, and Journal's insights (streaks, days journaled).

- `journals create NAME`: Create a journal, with --color and --icon.
  - `--color string` #RRGGBB, or red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray
  - `--icon string` An emoji, or an SF Symbol name such as book.closed

- `journals update JOURNAL`: Change a journal's name, color or icon.
  - Every flag of `journals create`
  - `--new-name string` New name

- `journals delete JOURNAL`: Delete a journal; its entries stay in All Entries, move (--move-entries-to), or go too (--delete-entries --expected-entries N; ask the user first).
  - `--move-entries-to string` The journal to move its entries to
  - `--[no-]delete-entries` Move its entries to Recently Deleted too
  - `--expected-entries int` With --delete-entries: how many entries it holds

### attachments

- `attachments read ID`: Open an entry's attachment (ids from entries read): print its details, save its photos, video frames and recordings.
  - `--[no-]text-only` Only the details, no images or audio
  - `--output-dir string` Where to save its images, audio and files; default the temporary folder
