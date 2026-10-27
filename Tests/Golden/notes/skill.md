---
name: apple-notes
description: Read and change the user's Apple Notes on this Mac (notes, folders and attachments, synced through iCloud to their devices) by running the apple-notes-mcp command. Use when the user asks about their notes or Apple Notes.
metadata:
  generated-by: apple-notes-mcp
  command: "<EXECUTABLE>"
---

# Apple Notes

Run `<EXECUTABLE>` followed by a command, by that full path. It prints the answer as text, often Markdown. Exit status 1 means the request failed (not found, changed since it was read, not allowed); the reason is on stderr. Exit status 2 means the command or a flag was wrong; add `--help` to any command for its flags.

```sh
<EXECUTABLE> notes search "tax return"
<EXECUTABLE> notes read ID
<EXECUTABLE> notes edit ID --version VERSION --insert "- [ ] Call the bank" --at "To do"
<EXECUTABLE> notes create - --folder Projects <<'EOF'
# Trip plan
- [ ] Book the train
EOF
```

## Rules

- Find notes with `notes list` (newest first; `--folder`, `--tag`, `--only pinned|shared|locked|quick-notes|math-notes|calls|checklists|unchecked|tagged|untagged|mentions`, `--attachment KIND`, dates, `--sort opened`) or `notes search QUERY` (it also searches text in images, handwriting and recording transcripts), then `notes read ID`. Each line and each note comes with its `version`. `folders list` shows the folders, smart folders and tags.
- Every change needs `--version` from `notes read`, `list` or `search`: `notes edit`, `notes move`, `notes delete`. A note changed elsewhere since then is refused; read it again. Each change prints the new version.
- Make all changes to one note in a single `notes edit ID --version V` call: `--replace '[{"old":"…","new":"…"}]'` takes exact Markdown from `notes read`, `--insert` adds Markdown (`--at` start, end or a heading's text), `--rewrite` replaces the whole note, `--check TEXT` / `--uncheck TEXT` tick checklist items, `--checklist check_all|uncheck_all|move_checked_down|delete_checked`, `--pinned` / `--no-pinned`.
- Each paragraph is one Markdown line: `# title`, `## heading`, `### subheading`, `*` and `-` lists, `1.` numbered, `- [ ]` / `- [x]` checkboxes, `>` quote, two spaces per indent level, ``` monospaced, `**bold**`, `*italic*`, `~~strike~~`, `<u>underline</u>`, `<mark>highlight</mark>` (`<mark class="pink">` and orange, mint, blue), `[link](url)`, `| tables |`, `#tag`, `[text](note:ID)` a link to a note, `---` a divider. The first line of a new note is its title.
- Keep `![…](attachment:…)` placeholders where they are. `![name](/path/to/file)` attaches a file and `![](https://…)` adds a link card. `attachments read ID` prints what can be read from one (with a recording's transcript) and saves its images, audio and files, printing where.
- `-` as the Markdown of `notes create`, or as `--insert` or `--rewrite`, reads it from stdin: use a quoted heredoc for notes of several lines.
- Moving a note into or out of a shared folder, or renaming a shared folder, changes who sees it: ask the user, then add `--allow-shared`.
- Deleting moves notes to Recently Deleted for 30 days (`notes list --folder "Recently Deleted"` lists them), and `notes move ID FOLDER --version V` brings one back. Ask the user before deleting a folder with what is in it (`folders delete FOLDER --recursive --expected-notes N`) or a tag from every note (`tags delete TAG --expected-notes N`); `folders export` keeps a copy first.
- To describe many notes: `notes list --undescribed`, then one `notes describe --descriptions '[{"id":"…","description":"…"}]'`.
- Every command also takes `--json '{...}'` (or `--json -` to read it from stdin) with the fields by their snake_case names; flags override it.
- Agents that run commands in a sandbox (Codex does) cannot reach Notes from it: when the command says it ran inside a sandbox, run it again outside the sandbox, which the user may have to approve.
- If the command says it lacks Full Disk Access or may not control Notes, ask the user to run `<EXECUTABLE> setup` in a terminal.

## Commands

### notes

- `notes list`: List notes, newest first, one line each (id | version | title | date | size | description). --folder includes its folders, and groups the notes by folder unless --sort is given. Dates are YYYY-MM-DD; the -after ones are inclusive, the -before ones exclusive. --undescribed lists the notes that need a description, with their opening text, for notes describe.
  - `--folder string` Path such as "Projects/Ideas", or id; includes its folders; a smart folder; or Recently Deleted
  - `--tag string…` Only notes with all these tags (# optional)
  - `--only string…` Only notes in all of these groups (unchecked: with unticked checklist items; calls: call recordings)
  - `--attachment string…` Only notes with an attachment of one of these kinds; any, or none
  - `--modified-after string` YYYY-MM-DD, inclusive
  - `--modified-before string` YYYY-MM-DD, exclusive
  - `--created-after string` YYYY-MM-DD, inclusive
  - `--created-before string` YYYY-MM-DD, exclusive
  - `--sort modified|created|title|opened` Newest first by modified (default), created or opened (last opened in Notes), or by title
  - `--[no-]undescribed` Only notes without a current description
  - `--limit int` Notes listed, 1 to 500 (default 30, 50 with undescribed)

- `notes search QUERY`: Full-text search of titles, text and the text Notes found in attachments, best matches first.
  - `--match all|any` Every word (all, default) or any of them
  - `--folder string` Path or id; includes its folders; a smart folder; or Recently Deleted
  - `--tag string…` Only notes with all these tags (# optional)
  - `--only string…` Only notes in all of these groups (unchecked: with unticked checklist items; calls: call recordings)
  - `--attachment string…` Only notes with an attachment of one of these kinds; any, or none
  - `--modified-after string` YYYY-MM-DD, inclusive
  - `--modified-before string` YYYY-MM-DD, exclusive
  - `--created-after string` YYYY-MM-DD, inclusive
  - `--created-before string` YYYY-MM-DD, exclusive
  - `--sort modified|created|title|opened` Instead of best match: newest modified, created or opened first, or by title
  - `--limit int` 1 to 100 (default 10)

- `notes read [ID]`: Print notes as Markdown, each with the version that notes edit takes. By id, several (--id repeats, up to 20), or --title. A long note can be read one --section at a time, or as an --outline first.
  - `--id string…` Up to 20 note ids
  - `--title string` The exact title, instead of an id
  - `--section string` Only the section under this heading
  - `--[no-]outline` Only the headings, with each section's size

- `notes create MARKDOWN`: Create a note from Markdown; its first line is the title. ![name](/path/to/file) in the Markdown attaches a file, ![](https://…) adds a link card.
  - `--folder string` Path or id; default Notes, or for a copy the note's own folder

- `notes copy ID`: Copy a note with everything in it, into its own folder or --folder.
  - `--folder string` Path or id; default Notes, or for a copy the note's own folder

- `notes edit ID --version string`: Change a note in one go: --replace pairs, --insert Markdown, or --rewrite the whole note; --[no-]pinned. --version is the one notes read, list or search gave; a note changed elsewhere since then is refused, so read it again. --replace takes exact Markdown from notes read, applied in order. --insert adds at the end, the start, or under a heading (--at). Only what changes is written; the rest keeps all its formatting.
  - `--replace json` A JSON list of {old, new, all}, applied in order {all: Replace every occurrence; new: Markdown; old: Exact Markdown; must be unique unless all}
  - `--insert string` Markdown to add; - reads it from stdin
  - `--at string` end (default), start, or a heading's text; list items join that section's list
  - `--rewrite string` The whole note as Markdown; - reads it from stdin
  - `--check string…` Tick the checklist items with these texts
  - `--uncheck string…` Untick the checklist items with these texts
  - `--checklist check_all|uncheck_all|move_checked_down|delete_checked` Every checklist item: tick, untick, move the ticked ones to the bottom of their list, or delete them
  - `--[no-]pinned` Pin (true) or unpin (false) the note

- `notes delete [ID]`: Move a note to Recently Deleted (notes move brings it back; notes list --folder "Recently Deleted" lists them). --version is the one notes read, list or search gave; a note changed elsewhere since then is refused.
  - `--notes json` Instead of id and version: up to 100 notes {id: Note id; version: Its version}
  - `--version string` The version read_note, overview or search gave

- `notes move [ID] FOLDER`: Move a note to another folder, or back from Recently Deleted. --version is the one notes read, list or search gave; a note changed elsewhere since then is refused. A move into or out of a shared folder needs --allow-shared, after asking the user. --folder "Recently Deleted" on notes list shows the deleted notes.
  - `--[no-]allow-shared` The user agreed to changing who can see the notes
  - `--notes json` Instead of id and version: up to 100 notes {id: Note id; version: Its version}
  - `--version string` The version read_note, overview or search gave

- `notes describe --descriptions json`: Save one-line descriptions of notes, which notes list shows; many notes at once.

### tags

- `tags rename TAG NAME`: Rename a tag in every note that has it.

- `tags delete TAG --expected-notes int`: Take a tag out of every note that has it (ask the user first); the notes stay. --expected-notes is the number of notes with the tag, which folders list shows.

### attachments

- `attachments read ID`: Open an attachment from a ![…](attachment:ID) placeholder: print its text, save its images, audio and files.
  - `--[no-]text-only` Only the text, no images or files
  - `--output-dir string` Where to save its images, audio and files; default the temporary folder

### folders

- `folders list`: The folders, with how many notes each holds.
  - `--depth int` Folder levels shown when listing folders, 1 to 10 (default 1)

- `folders create PATH`: Create a folder; a path such as Projects/Ideas makes it inside another. With --tag (repeat for more), a smart folder of the notes with any of the tags, or with --match all, all of them.
  - `--tag string…` For create: make a smart folder showing the notes with these tags
  - `--match any|all` For a smart folder: notes with any of the tags (default) or all of them

- `folders rename FOLDER NAME`: Rename a folder. A shared folder needs --allow-shared, after asking the user: the new name changes it for everyone.
  - `--[no-]allow-shared` The user agreed to renaming or moving a shared folder

- `folders move FOLDER INTO`: Move a folder into another, or to the top level with "". A shared folder needs --allow-shared, after asking the user.
  - `--[no-]allow-shared` The user agreed to renaming or moving a shared folder

- `folders delete FOLDER`: Delete an empty folder, or with --recursive --expected-notes N everything in it (ask the user first). The notes go to Recently Deleted. --expected-notes is the number of notes you saw in it and its folders.
  - `--[no-]recursive` Also everything in it
  - `--expected-notes int` With --recursive: the notes you saw in it and its folders

- `folders export FOLDER TO`: Write a folder and its folders as Markdown with the original attachments, to a new folder or .zip.
