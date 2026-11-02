# Apple Notes MCP 0.5.0 — changes for the knowledge-base sync (implementation plan)

> 给 Claude Code 的实施计划。背景：一个 Notion 为主库、Apple Notes 为投影的个人知识库同步脚本，会在 Mac mini 上通过这个命令行驱动 Notes。它需要机器可读的输出、按文件夹限定的写保护、按节替换、不等待上传的批量写入。六项改动如下，按顺序做完。Everything below is the spec; the sections "Ground rules" and "Finishing" apply to all of it.

## Ground rules

- Only Apple Notes MCP changes behaviour. The shared base (`Sources/Wire`, `Sources/AppCore`) changes only where a section says so, and in a way that leaves Apple Reminders MCP and Apple Journal MCP working as before (their golden outputs may change only by the new `--format` line in help; see Finishing).
- Keep the repository's style: the comment voice of the existing code, `throws(NotesError)` typed throws, `Schema.*` for tool input, `Input` for reading arguments, files under 800 lines (put new code in a new file rather than growing a large one), no third-party dependencies.
- The MCP tool list changes (new optional fields on `create_note`, `edit_note`, `move_note`). The MCP *answers* stay text only: do **not** add `structuredContent` to MCP results. JSON output is a command-line feature.
- Every new field is optional with the old behaviour as its default, so existing agents and the skill keep working.
- Work on a new branch `kb-sync-0.5.0` from `main`. Commit when everything builds and passes, then push the branch and open a pull request (see Finishing).

## 1. `--list-json`: add `version` and `description`

`Sources/NotesComponent/ListJSON.swift`, tests in `Tests/NotesComponentTests/ListJSONTests.swift`.

- `ListJSON.Row` gains `version: String` (the same hash `read_note` gives, from `NotesStore.versions(_:)`; `"?"` when a note cannot be read, `"locked"` for a locked one) and `description: String?` (the saved one-line description from `Descriptions`, whether or not the note changed since it was written; omitted when none is saved — the synthesized `Encodable` already leaves nil out).
- Field order in `Row`: `id, title, folder, modified, version, description, snippet`.
- `NoteListing` gains `func versions(_ ids: [String]) -> [String: String]` (NotesStore already has it). `ListJSON.rows(_:from:)` and `run(...)` take a `descriptions: [String: Descriptions.Entry]` argument (default `[:]`); `NotesComponent.listJSON` passes `Descriptions().all()`.
- Both the no-query listing and the search listing fill the two fields.
- Update `ListJSONTests`: the stand-in `Listing` implements `versions` from a `var versions: [String: String]` (missing ids → `"?"`); every `Row(...)` and every `object(line) == [...]` expectation includes `"version"`, and `description` where one is set; add one test that a saved description shows up and an unsaved one is left out.
- Documentation: the `--list-json` paragraph in `docs/notes.md` and `docs/notes.zh-CN.md` lists the new fields and says the listing now reads every note for its version, so it is a little slower than before.

## 2. JSON answers on the command line: `--format json`

### Wire (shared)

`Sources/Wire/Service.swift`: `ToolAnswer` gains `public var data: JSON?` — a machine-readable form of the answer, nil when the tool gives none. Both inits take `data: JSON? = nil` (keep the parameter order `(_ text:, data:, failed:)` and `(content:, data:, failed:)`). `Service.call` ignores `data` (MCP answers are unchanged).

### Commands (shared)

`Sources/AppCore/CLI/Commands.swift`:

- Every tool command and `call` also take `--format text|json` (also `--format=json`), read and removed from the words before the tool's flags are parsed, like the route's output flag is. Default `text`. A value other than `text` or `json` is a usage error (exit 2).
- With `json`: on success, print `answer.data?.text` when the tool gave data, otherwise one JSON object `{"text": "<the answer's text>"}` (so every command prints a JSON object); on failure (`answer.failed`), write `{"error": "<reworded text>"}` to stderr and exit 1. Images, audio and files are still saved as before (the saving functions' lines go into `text`).
- The command tree's footer line becomes: `Every … command also takes --json OBJECT (or --json - for stdin), --format json (the answer as JSON) and --help.` and `Flags.help` (`Sources/Wire/Flags.swift`) adds the row `("--format text|json", "Print the answer as text (default) or JSON")` before the `--json json|-` row.
- Put the flag extraction in a small testable function (e.g. `static func takeFormat(from words: inout [String]) throws -> Format`) and test it in `Tests/AppCoreTests` (present/absent/`=`/bad value/after `--`).

### Data for the Notes tools

All ids in `data` are full UUIDs (never `ShortID`). Dates are ISO 8601 with seconds and offset (`ISO8601DateFormatter` with `[.withInternetDateTime]` in the local time zone). Add a tiny helper for that in `Tools/Output.swift`.

- `overview`
  - folder tree (no arguments): `{"folders": [{"id", "name", "path", "notes": Int, "shared": Bool}], "smart_folders": [{"id", "name", "rule"}]}`.
  - a note list (`noteList`): `{"folder": "<heading>", "total": Int, "showing": Int, "notes": [{"id", "version", "title", "folder", "modified", "created", "pinned", "locked", "chars": Int, "description": String|null, "description_current": Bool}]}`. `description` is the saved description (null when none); `description_current` is `Descriptions.isCurrent`. With `undescribed: true`, add `"opening": String` per note.
  - Recently Deleted (`deletedList`): the same shape plus `"deleted": date` and `"days_left": Int` per note, `"folder": "Recently Deleted"`.
  - Refactor `noteList` / `deletedList` to build an array of row values once and derive both the text lines and the JSON from it, rather than computing things twice.
- `search`: `{"query", "total": Int, "showing": Int, "notes": [{"id", "version", "title", "folder", "modified", "snippet"}]}`.
- `read_note`: `{"notes": [{"id", "version", "title", "folder", "modified", "pinned", "shared", "in_trash", "markdown"}]}` where `markdown` is exactly the text printed after the `---` line for that note (the whole note, one section, or the outline). Refactor `readNote` to return a struct (header line, body text, the values above) and build the text from it. When several ids are read and one fails, its entry is `{"id": "<the reference given>", "error": "<message>"}`.
- `create_note`, `edit_note` (through `report`): `{"id", "title", "version", "uploaded": Bool, "waited": Bool, "mismatch": String|null, "tables_rebuilt": Bool}`.
- `move_note`: one note: `{"id", "title", "version", "from", "to", "restored": Bool, "uploaded": Bool, "waited": Bool}`; several: `{"moved": [{"id", "title", "from", "to", "restored"}], "failed": ["<reference>: <message>"], "not_uploaded": Int, "waited": Bool}`.
- `delete_note`: `{"deleted": [{"id", "title"}], "failed": [String]}` (keep the ids in the loop; it currently keeps titles only).
- `describe_note`: `{"saved": [{"id", "title"}], "failed": [String]}`.
- `manage_folder`, `manage_tag`, `read_attachment`: no data (the `{"text": …}` fallback is fine).

## 3. A folder-scoped write guard: `APPLE_NOTES_MCP_WRITE_FOLDERS`

Today `APPLE_NOTES_MCP_WRITE_GUARD` limits writes by a title and folder-name prefix. Add a second, independent guard by folder.

- `Sources/AppCore/AppMain.swift` reads `<PREFIX>_WRITE_FOLDERS`: a comma-separated list of folder paths as `overview` shows them (`KB/Wiki,KB/Inbox`), each trimmed; unset or empty → nil. `ComponentContext` gains `writeFolders: [String]?` with a default of nil in its init, so the other apps are untouched.
- `NotesStore` gains `let writeFolders: [String]?` (init parameter with default nil; `NotesComponent` passes it; `selfCheck` and tests keep passing nil).
- Matching: a folder is *inside* the guard when `FolderPath.join(names)` equals one of the paths or starts with one followed by `/`, comparing case-insensitively. Implement as `nonisolated static func insideGuard(_ names: [String], _ folders: [String]) -> Bool` in a new file `Sources/NotesComponent/Store/FolderGuard.swift`, together with `func guardFolder(names: [String], what: String) throws(NotesError)` that throws `.refused("Refused by the folder guard: only \(what) in \(list) may be changed.")` (`what`: "notes" or "folders"; `list`: the paths joined by ", ").
- Enforce it wherever the title guard is enforced, and on destinations:
  - `checkWritable` (edits, pins, table rebuilds, tag removal): the note's folder.
  - `create(in:)`: the destination folder, the default `Notes` folder when none is given.
  - `duplicate`: the source note's folder and the destination.
  - `delete`: the note's folder.
  - `move`: the source folder (unless restoring from Recently Deleted) and the destination.
  - `renameTag` / `removeTag`: every note with the tag must be inside, else refuse the whole operation (mirror the existing title-guard check there).
  - Folders: `createFolder` (the new path must itself be a listed path or inside one), `renameFolder`, `deleteFolder`, `deleteFolderTree`, `moveFolder` (the folder and the new parent); smart folders cannot be created, renamed or deleted while the guard is set (refused with the same wording, `what` "folders"); `export` is read-only and stays allowed.
- Both guards can be set at once; a write must pass both.
- `--self-check` prints `Write guard: …` for the title guard as today and `Write folders: KB/Wiki, KB/Inbox` when the folder guard is set (`writeGuardDescription` may become two lines; keep the existing line unchanged).
- Tests: `insideGuard` in `Tests/NotesComponentTests` (exact match, child, grandchild, a sibling whose name starts the same — `KB/Wiki2` is outside `KB/Wiki` —, case-insensitivity, a name with an escaped slash, empty list).
- `scripts/e2e.py notes` keeps using `WRITE_GUARD` only; do not change it.

## 4. `edit_note`: `replace_section` and `replace_before`

Two new optional fields, both objects `{heading: String, markdown: String}` (`required: ["heading", "markdown"]`; `markdown` may be empty). On the command line they are `--replace-section JSON` and `--replace-before JSON` (object fields already take JSON).

- `replace_section`: the heading stays; everything under it up to the next heading of the same or a higher level (`Sections.find` / `Sections.range`) is replaced by the parsed Markdown. Blank paragraphs at the end of the old section (the gap before the next heading) are kept, like `insertionPoint` keeps them.
- `replace_before`: everything after the title line and before the heading is replaced; the title stays; blank paragraphs just before the heading are kept.
- Rules: the heading is matched as `Sections.find` matches (case-insensitive, leading `#` ignored, must be unique); naming the title is refused (`use rewrite`); neither can be combined with `rewrite`; both can be combined with `replace`, `insert` and the checklist fields. Order of application inside `store.update`: `replace` pairs → `replace_section` → `replace_before` → `insert` → `check`/`uncheck`/`checklist`.
- Put the two block-level operations in a new file `Sources/NotesComponent/Tools/SectionEdits.swift` as pure functions over `[Block]` (`throws(NotesError)`), and test them in `Tests/NotesComponentTests` from Markdown (`Markdown.parse`/`Markdown.render`): replace a middle section, the last section, with empty Markdown, the gap before the next heading survives, an unknown heading throws `.notFound`, the title throws `.refused`, `replace_before` with and without content before the heading.
- Update the tool summary, the `notes edit` route (`about`, `detail`, `only`, `abouts`), the skill text rule about `notes edit`, and the docs.

## 5. `wait: false` on writes

- `create_note`, `edit_note` and `move_note` gain `"wait": Schema.flag("Wait until iCloud has the change (default true); false returns once it is saved and the upload is requested")`. On the command line that is `--[no-]wait`.
- `report(...)` takes `wait: Bool`: with `false` it still calls `store.upload` (that is what makes Notes upload at all) but with `timeout: 0`, and the answer says `saved on this Mac; upload requested, not waited for` instead of the usual upload text. Skip the table-rebuild and tag-repair retries that depend on waiting when `wait` is false.
- `move_note` with several notes skips `waitForUploads` when `wait` is false (and reports `not_uploaded` as the count of notes whose upload was not waited for, with `waited: false`).
- `data` carries `waited`.
- Docs: a paragraph under Rules explaining that `wait: false` is for batches (hundreds of writes in a row), and that iCloud sync still happens, just not confirmed per call.

## 6. `description` for scripts

Nothing beyond 1 and 2: `description` is in `--list-json` and in `notes list --format json`. In the docs' `--list-json` paragraph add one sentence: a script can keep its own key for a note there with `describe_note`, for example `notion:<page id>`, since the description lives in this app's own file and never touches the note.

## Finishing

1. `swift build` and `swift test` pass.
2. Re-record the golden outputs for all three apps, because the help footer and `Flags.help` changed for every app, and the Notes tools changed:
   ```
   /usr/bin/python3 -I scripts/golden.py record notes .build/debug/AppleNotesMCP Tests/Golden/notes
   /usr/bin/python3 -I scripts/golden.py record reminders .build/debug/AppleRemindersMCP Tests/Golden/reminders
   /usr/bin/python3 -I scripts/golden.py record journal .build/debug/AppleJournalMCP Tests/Golden/journal
   ```
   then `check` each one. Review the diff: Reminders and Journal may differ only in the new `--format` lines; Notes also in the new fields and flags. If `record` is destructive to anything else, say so instead of forcing it.
3. `apple-notes-mcp --help`-style outputs in `docs/notes.md` and `docs/notes.zh-CN.md` (the command tree block, the tools table, Rules, Command line, the `--list-json` paragraph) are updated to match; the Chinese file says the same as the English one.
4. `CHANGELOG-notes.md` gets a `## 0.5.0` section at the top in the existing format (English, `---`, Chinese), covering all six changes, and saying that the MCP tool list gained optional fields so agents see them in their next session without being set up again, and that permissions carry over. Do not bump the version anywhere else (`scripts/release.sh` does that).
5. `git add -A && git commit` on the branch. The commit message: a one-line subject (`Add JSON output, a folder write guard, section edits and wait: false to Apple Notes MCP`), a body that lists the six changes, and these two trailer lines at the end:
   ```
   Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
   Claude-Session: https://claude.ai/code/session_0186fmwtvm14RyNynG16MQQD
   ```
6. `git push -u origin kb-sync-0.5.0`, then open a pull request against `main` with `gh pr create` (the repository is xiaofeng-han/apple-mcp). Title: `Apple Notes MCP 0.5.0: JSON output, folder write guard, section edits, wait: false`. Body: a short paragraph on why (a Notion-to-Apple-Notes knowledge-base sync script drives the command line and needs these), a section per change (the six headings of this plan, one or two sentences each, with the new flags and fields named), a "Checks" section (swift build, swift test with counts, golden re-recorded for all three apps and what differed, e2e not run and why), and a "Not changed" line (MCP answers stay text; the other two apps only gain the --format help line). End the body with exactly these lines:
   ```
   🤖 Generated with [Claude Code](https://claude.com/claude-code)

   https://claude.ai/code/session_0186fmwtvm14RyNynG16MQQD
   ```
   Do not merge the pull request. Do not push to `main`.
7. Print a final summary: the pull request URL, files changed, tests run (with counts), golden diffs, and anything you could not do or had to decide (e.g. the end-to-end checks `scripts/e2e.py` need the app's permissions and real notes, so they are not run here).
