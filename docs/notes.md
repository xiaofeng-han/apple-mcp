# Apple Notes MCP

**English** | [简体中文](notes.zh-CN.md)

Part of [apple-mcp](../README.md), the repository of Apple Notes MCP and [Apple Reminders MCP](reminders.md).

An MCP server that lets AI agents (Claude Code, Codex, Grok Build, OpenCode, Gemini CLI, pi, …) read and edit Apple Notes on macOS, with native formatting. Every tool is also a command-line command, so an agent can use a skill instead of the server. Its settings window finds the agents on your Mac and sets each one up either way with one click, installing the ones you are missing.

- **Reading** goes through Notes' own data model, with its database opened read-only: titles, headings, lists, checklists (ticked or not), tables, links, highlights (with their colors), tags, links to other notes, divider lines and attachments all come out as Markdown. Search also finds the text Notes recognized in images, scans and handwriting, and the transcripts of recordings.
- **Editing** happens in place, through Notes' private NotesShared framework, the way Notes itself edits: only what changed is written, character by character, so everything Markdown cannot show (colors, fonts, alignment) stays as it was, and edits made on other devices merge. Every change is rehearsed on a copy first and read back afterwards.
- **Syncing**: Notes does not upload changes made this way by itself, so after each change the server asks Notes (through AppleScript) to save and upload the note, and waits until iCloud has it. Notes never comes to the front.

Requires macOS 26 or later on Apple silicon; developed and tested on macOS 27.0.1. All code is written for this project, with no third-party dependencies. The permissions it needs are Full Disk Access (to read the Notes database) and Automation → Notes (to upload, move and delete).

## Tools

| Tool | What it does |
|---|---|
| `overview` | The folders with note counts, the smart folders and the tags; or the notes one per line (id, version, title, date, size, attachments, description) of a folder, a smart folder or Recently Deleted, narrowed by dates, tags, groups (`only`: pinned, shared, locked, quick-notes, math-notes, calls, checklists, unchecked, tagged, untagged, mentions) and attachment kinds, sorted by modified, created, last opened or title. `undescribed: true` lists notes that still need a description, with their opening text |
| `search` | Full-text search of titles, text and the text Notes found in attachments (recognized in images and scans, handwriting, recording transcripts), best matches first, with the text around each match; with the same narrowing as `overview` |
| `read_note` | A note as Markdown with its version: by id, several ids, or exact title; one section, or an outline with each section's size. The header says whether it is pinned or shared, and which notes link to it |
| `read_attachment` | An attachment from a `![…](attachment:id)` placeholder: images (scaled), scan pages, drawings, PDFs (text and file), audio (recordings with Notes' transcript and summary), a frame of a video, tables, links and files, with any text Notes recognized in it |
| `describe_note` | Saves one-line descriptions that `overview` shows, many notes per call |
| `create_note` | A new note from Markdown, in any folder, attaching files and link cards; or a copy of a note with everything in it (`copy_of`) |
| `edit_note` | Several changes in one call: exact replacements, Markdown inserted at the start, the end or under a heading (list items join that section's list), or a whole rewrite; ticking or unticking checklist items by their text, ticking or unticking them all, moving ticked items to the bottom or deleting them; pinning |
| `move_note` | Moves a note, or several, to another folder of its account, or back out of Recently Deleted |
| `delete_note` | Moves a note, or several, to Recently Deleted |
| `manage_folder` | Creates, renames, moves (into another folder, or to the top level) or deletes a folder (an empty one, or with `recursive` and `expected_notes` everything in it); creates, renames or deletes a smart folder of the notes with some tags; exports a folder and its folders as Markdown with the original attachments, to a new folder or a `.zip` |
| `manage_tag` | Renames a tag in every note that has it, or takes it out of every note (with `expected_notes`) |

### Markdown

One note paragraph is one Markdown line, so a model can change a line without anything else moving.

| In Notes | In Markdown |
|---|---|
| Title, heading, subheading | `# `, `## `, `### ` |
| Bulleted, dashed, numbered list | `* `, `- `, `1. ` (two spaces per indent level) |
| Checklist | `- [ ] ` / `- [x] ` |
| Block quote | `> ` per level |
| Monospaced | lines between ```` ``` ```` |
| Bold, italic, strikethrough | `**…**`, `*…*`, `~~…~~` |
| Underline, highlight | `<u>…</u>`, `<mark>…</mark>` (purple); `<mark class="pink">…</mark>` for pink, orange, mint, blue |
| Link | `[text](url)` |
| Tag | `#name` (a real Notes tag; literal text that would read as one is written `\#name`) |
| Link to a note | `[text](note:1A2B3C4D)`; empty text takes the note's title |
| Divider line | `---` alone on a line |
| Table | `\| a \| b \|` rows; `<br>` for a line break in a cell |
| Attachment | `![image](attachment:1A2B3C4D)` (a placeholder to keep in place) |
| New file, new link card | `![name](/path/to/file)` (also `~/…` or `file://…`); `![](https://…)` |

### Rules

- Every change to a note (`edit_note`, `move_note`, `delete_note`) needs the `version` that `read_note`, `overview` or `search` gave, a hash of the note as Markdown. If the note changed since it was read (on another device, or by another agent), the change is refused instead of overwriting that change; each write answers with the new version. Before every edit the note's stored body is saved under `~/Library/Application Support/AppleNotesMCP/backups/<note id>/` (the last 20).
- Attachments stay where they are: an edit that would drop a placeholder, or add one that is not in the note, is refused. Tables, tags, links to notes and divider lines are the exception: they can be added and removed, like text. New files and link cards come from `![name](/path)` and `![](https://…)`; a file is taken only from the home folder (not `~/Library` or a hidden folder), a temporary folder or an external drive, because this app can read every file.
- A smart folder holds no notes of its own: `overview` and `search` take it to list or search the notes its rule picks, and no note can be moved into it.
- Locked notes cannot be read or changed. Shared notes can be edited (the edits merge with the other people's), but are not deleted here, and a move into or out of a shared folder needs `allow_shared` (after asking the user).
- `delete_note` and a recursive folder delete only move notes to Recently Deleted, and refuse a note already there (deleting it again would erase it for good). A recursive delete needs `expected_notes`, the number of notes the caller saw, and checks everything before it changes anything.
- An export goes only to a path that does not exist yet, outside `~/Library`.
- Any tool can be turned off for all AI assistants in the settings window (see [Choosing the tools](#choosing-the-tools)).

## Command line

Every tool is also a command, so the app works from a terminal and from an agent's shell, which is what the [skill](#server-or-skill) uses. A command is a noun and a verb. Its flags come from the tool's input fields, so they are the fields of the tools above. `apple-notes-mcp help` prints the whole tree:

```text
apple-notes-mcp
├── --stdio                     Serve MCP on stdin and stdout (what agents start)
├── --settings                  Open the settings window (also what opening the app does)
├── --self-check                Print a diagnosis
├── --version                   Print the version
├── help [COMMAND…]             This tree, or a command's flags (also --help, -h)
├── setup                       Ask to control Notes, and show where to give Full Disk Access
├── skill                       Print the SKILL.md that teaches an agent this command line
├── agents
│   ├── list                    Which agents are here and set up (the default)
│   │       [--skill] [--folder DIR]
│   ├── set-up (ID… | --all)    Register the server with them, or install the skill
│   │       [--restart] [--skill] [--folder DIR]
│   └── install ID…             Install them, then set them up
│           [--dry-run] [--restart] [--skill] [--folder DIR]
├── notes
│   ├── list                    List notes, newest first, one line each (id | version | title | date | size | description) (the default)
│   │       --folder string --tag string… --only string… --attachment string… --modified-after string
│   │       --modified-before string --created-after string --created-before string
│   │       --sort modified|created|title|opened --[no-]undescribed --limit int
│   ├── search QUERY            Full-text search of titles, text and the text Notes found in attachments, best matches first
│   │       --match all|any --folder string --tag string… --only string… --attachment string…
│   │       --modified-after string --modified-before string --created-after string --created-before string
│   │       --sort modified|created|title|opened --limit int
│   ├── read [ID]               Print notes as Markdown, each with the version that notes edit takes
│   │       --id string… --title string --section string --[no-]outline
│   ├── create MARKDOWN         Create a note from Markdown; its first line is the title
│   │       --folder string
│   ├── copy ID                 Copy a note with everything in it, into its own folder or --folder
│   │       --folder string
│   ├── edit ID --version string  Change a note in one go: --replace pairs, --insert Markdown, or --rewrite the whole note; --[no-]pinned
│   │       --replace json --insert string --at string --rewrite string --check string… --uncheck string…
│   │       --checklist check_all|uncheck_all|move_checked_down|delete_checked --[no-]pinned
│   ├── delete [ID]             Move a note to Recently Deleted (notes move brings it back; notes list --folder "Recently Deleted" lists them)
│   │       --notes json --version string
│   ├── move [ID] FOLDER        Move a note to another folder, or back from Recently Deleted
│   │       --[no-]allow-shared --notes json --version string
│   └── describe --descriptions json  Save one-line descriptions of notes, which notes list shows; many notes at once
├── tags
│   ├── rename TAG NAME         Rename a tag in every note that has it
│   └── delete TAG --expected-notes int  Take a tag out of every note that has it (ask the user first); the notes stay
├── attachments
│   └── read ID                 Open an attachment from a ![…](attachment:ID) placeholder: print its text, save its images, audio and files
│           --[no-]text-only --output-dir string
├── folders
│   ├── list                    The folders, with how many notes each holds (the default)
│   │       --depth int
│   ├── create PATH             Create a folder; a path such as Projects/Ideas makes it inside another
│   │       --tag string… --match any|all
│   ├── rename FOLDER NAME      Rename a folder
│   │       --[no-]allow-shared
│   ├── move FOLDER INTO        Move a folder into another, or to the top level with ""
│   │       --[no-]allow-shared
│   ├── delete FOLDER           Delete an empty folder, or with --recursive --expected-notes N everything in it (ask the user first)
│   │       --[no-]recursive --expected-notes int
│   └── export FOLDER TO        Write a folder and its folders as Markdown with the original attachments, to a new folder or .zip
└── call TOOL [JSON | -]        Run any tool on a JSON object of its arguments; call alone lists the tools
```

- **Flag names:** a field's flag has dashes for underscores, so `modified_after` is `--modified-after`.
- **True-or-false fields:** `--outline` turns one on and `--no-outline` turns it off.
- **Lists:** a field that holds a list repeats its flag in the singular: `notes read --id 1A2B3C4D --id 5E6F7A8B`.
- **Objects:** a field of objects takes JSON: `--replace '[{"old":"- [ ] Milk","new":"- [x] Milk"}]'`.
- **Markdown from stdin:** `-` as the Markdown of `notes create`, or as `--insert` or `--rewrite`, reads it from stdin, for notes of many lines.
- **Fields as JSON:** `--json '{…}'` gives fields by their MCP names, and `--json -` reads them from stdin. Flags override them.
- **Any tool:** `call TOOL '{…}'` runs a tool on its MCP arguments.
- **Help:** `--help` after a command lists its flags and what each one takes.

A command prints exactly what the tool answers, which is text, often Markdown.
- **Exit status 1:** the request failed (not found, changed since it was read, not allowed). The reason is on stderr.
- **Exit status 2:** the command or a flag was wrong.

`notes list` without filters lists the newest notes; `folders list` gives the folder tree, which `overview` gives without arguments. `attachments read` prints what can be read from an attachment, and saves its images, audio and files to `--output-dir`, or to the temporary folder, printing where. Only the first word decides what the program does, so you can search for `setup`. Put `--` before a word that starts with `-`.

```bash
apple-notes-mcp notes search "tax return" --folder Finance
apple-notes-mcp notes read 1A2B3C4D
apple-notes-mcp notes edit 1A2B3C4D --version 3f9a0c12b7e4 --insert "- [ ] Call the bank" --at "To do"
apple-notes-mcp notes create - --folder Projects <<'EOF'
# Trip plan
- [ ] Book the train
EOF
```

For editors and scripts, `apple-notes-mcp --list-json [QUERY]` prints one JSON object per line, with the full `id`, `title`, `folder` and `modified`: every note that is not locked, newest first, or with a query the search results, best match first (at most 100), each with a `snippet`. The lists above cut titles and shorten ids; these values are whole.

## Install

Releases are built for Apple silicon and need macOS 26 or later. The default way to install and set up is with Homebrew:

```bash
brew install --cask xiaofeng-han/tap/apple-notes-mcp
apple-notes-mcp setup                  # allow it to control Notes; shows where to give Full Disk Access
apple-notes-mcp agents set-up --all    # register the server with the agents on this Mac
```

To give the agents the skill instead of the server, add `--skill` to the last command (see [Server or skill](#server-or-skill)).

Instead of the last two commands, you can open Apple Notes MCP from Applications: set up your agents in its **AI Assistants** tab, and give it its permissions under **General**. Without Homebrew, install [from the package](#from-the-package).

### With Homebrew

Naming the cask in full, as above, adds the tap [xiaofeng-han/tap](https://github.com/xiaofeng-han/homebrew-tap) and trusts only this cask. Since Homebrew 6, items from taps outside Homebrew have to be trusted before Homebrew loads them. After that, `brew upgrade` picks up new releases.

Homebrew installs the same package described below, but for all users and through the macOS installer. So it asks for an administrator password, and it puts the app in `/Applications`. It also adds the command `apple-notes-mcp` (`/opt/homebrew/bin/apple-notes-mcp`), a small script that starts the app; the steps below use it. `brew uninstall --cask apple-notes-mcp` removes the app. Adding `--zap` also moves its settings, note backups and descriptions to the Trash.

If you installed the package for yourself before, remove that copy and point your agents at the new command (the AI Assistants tab offers **Update** for each). Both copies have the same signature, so the permissions carry over.

```bash
rm -rf ~/Applications/AppleNotesMCP.app
pkgutil --volume ~ --forget com.xiaofeng.apple-notes-mcp.pkg
```

### From the package

Without Homebrew, download `AppleNotesMCP-<version>.pkg` from [Releases](https://github.com/xiaofeng-han/apple-mcp/releases) and open it, or install it from the terminal:

```bash
gh release download notes-v0.4.1 -R xiaofeng-han/apple-mcp -p '*.pkg'
installer -pkg AppleNotesMCP-0.4.1.pkg -target CurrentUserHomeDirectory
```

Installing for yourself only puts the app in `~/Applications` and needs no administrator password; installing for all users puts it in `/Applications`. The package has no Developer ID signature: if macOS refuses to open one downloaded in a browser, allow it under System Settings → Privacy & Security.

### After installing

The examples use the command that Homebrew adds. If you installed the package, use the app's executable in its place: `~/Applications/AppleNotesMCP.app/Contents/MacOS/AppleNotesMCP`, or `/Applications/AppleNotesMCP.app/Contents/MacOS/AppleNotesMCP` if you installed it for all users.

```bash
apple-notes-mcp setup          # asks to control Notes (click OK), and opens the Full Disk Access settings if needed
apple-notes-mcp --self-check   # shows both permissions and counts your notes
```

Full Disk Access has to be turned on by hand: System Settings → Privacy & Security → Full Disk Access, then turn on Apple Notes MCP, adding it with + if it is not listed (it is in `~/Applications` if you installed the package for yourself, and in `/Applications` otherwise).

Opening the app directly (double-clicking it, or starting it with `--settings`) shows the settings window. It opens in front, on the **AI Assistants** tab; the **Tools** tab chooses which tools AI assistants may use; the **General** tab shows both permissions, with buttons to grant them, and the window's language: English or Simplified Chinese, following the system unless you pick one (`defaults write com.xiaofeng.apple-notes-mcp InterfaceLanguage -string zh-Hans`, or `en`; delete it to follow the system). When an agent calls the server without a permission it needs, the server opens this window once and tells the agent so.

### Setting up your agents

The window's **AI Assistants** tab (the first tab, and the one the window opens on) registers this server with your agents. When the window opens, it works out how this copy was installed (with Homebrew, from the package, or neither), and so which command agents should start. It then looks for each agent below and reads its settings file. Next to each agent is a button:
- **Set Up** when the server is not there yet. The button reads **Update** when the agent starts another copy, **Repair** when that copy is gone, and **Turn On** when the server is turned off.
- **Install** for an agent you do not have. It installs the agent the way this copy was installed: with Homebrew after a Homebrew install, otherwise with the vendor's own installer or download. Then it sets the agent up. Hold the pointer over the button to see the command it runs.

**Set Up All** does every installed agent at once.

| Agent | Settings it changes | Installs with (after a Homebrew install / otherwise) |
|---|---|---|
| Claude Code (also the Claude app's Code tab) | `~/.claude.json`, through `claude mcp add-json -s user` | `brew install --cask claude-code` / `curl -fsSL https://claude.ai/install.sh \| bash` |
| Claude app | `~/Library/Application Support/Claude/claude_desktop_config.json`. Claude rewrites this file from memory, so it is quit while the server is added and then opened again | `brew install --cask claude` / the app from Anthropic's update feed |
| Codex CLI and the ChatGPT app (formerly the Codex app) | `~/.codex/config.toml` | `brew install --cask codex` and `chatgpt` / `curl -fsSL https://chatgpt.com/codex/install.sh \| sh` and the app's disk image |
| Grok Build | `~/.grok/config.toml` | `brew install --cask grok-build` / `curl -fsSL https://x.ai/cli/install.sh \| bash` |
| OpenCode and OpenCode Desktop | `~/.config/opencode/opencode.json` (or `opencode.jsonc`) | `brew install opencode` and `--cask opencode-desktop` / `curl -fsSL https://opencode.ai/v2/install \| bash` and the app's disk image |
| Gemini CLI | `~/.gemini/settings.json` | `npm install -g @google/gemini-cli` (Homebrew's formula is deprecated) |
| Antigravity app and CLI | `~/.gemini/config/mcp_config.json` | `brew install --cask antigravity` and `antigravity-cli` / the app's disk image and `curl -fsSL https://antigravity.google/cli/install.sh \| bash` |

Grok Bot and the Gemini app are listed too, but they cannot use this server. Grok Bot runs MCP servers on its cloud computer, and the Gemini app only takes remote servers that are added on gemini.google.com.

Set Up writes the `apple-notes` entry and keeps what you added to it (environment variables, timeouts). If the agent had turned the server off, Set Up turns it back on. The rest of the file stays as it was, comments and formatting included. An entry written in a form the app does not edit, such as a TOML inline table, is left alone and shown as set up by hand. Folders moved by variables such as `CODEX_HOME` or `XDG_CONFIG_HOME` are followed when your login shell sets them. Before the first change of a day, the old file is kept next to it as `<name>.bak-<yyyyMMdd>-apple-notes-mcp`.

Installers and agents' commands run without this app's permissions, in a session of their own with no terminal. The same is available in the terminal:

```bash
apple-notes-mcp agents                     # which agents are installed and set up
apple-notes-mcp agents set-up --all        # or name them: agents set-up codex grok
apple-notes-mcp agents install opencode    # installs, then sets up; --dry-run only shows the command
```

`agents set-up` leaves the Claude app alone while it is open, unless you add `--restart`.

### Server or skill

Above the list, **Set Up As** chooses how agents use this app:
- **MCP Server** (the default): the agent starts `apple-notes-mcp --stdio`, and its 11 tools are always loaded.
- **Skill:** Set Up writes a skill, `apple-notes/SKILL.md`, which teaches the agent the [command line](#command-line).
  - The agent reads the skill only when notes come up, and runs the commands in its shell, so no tool list sits in its context.
  - The skill names this copy's command by its full path.
  - After the app is upgraded, the button reads **Update** if the skill's text has changed.

With no folder chosen, the skill goes in each agent's own skills folder and works in every project. **Choose…** picks a project folder instead, and the skill goes only there. **All Projects** switches back.

| Agent | Skill for every project | Skill in a project folder |
|---|---|---|
| Claude Code, and the Claude app's Code tab | `~/.claude/skills/` (`$CLAUDE_CONFIG_DIR/skills/`) | `.claude/skills/` |
| Codex CLI and the ChatGPT app, OpenCode and OpenCode Desktop, Gemini CLI | `~/.agents/skills/` | `.agents/skills/` |
| Grok Build | `~/.grok/skills/` | `.agents/skills/` |
| Antigravity app | `~/.gemini/config/skills/` | `.agents/skills/` |
| Antigravity CLI | `~/.gemini/antigravity-cli/skills/` | `.agents/skills/` |

- **Shared folders:** agents that read the same folder share one file. pi reads `~/.agents/skills` too.
- **Other skills of the same name:** a skill named `apple-notes` that this app did not write is left alone, and the row shows **Another Skill**.
- **Server and skill together:** setting up one way never changes the other. An agent can have both, and its row says so.
- **Agents that cannot use the skill:** Grok Bot and the Gemini app cannot run commands on this Mac. The skill works in the Claude app's Code tab, but not in its chat.

Some agents run shell commands in a sandbox. Codex does by default, and inside its sandbox macOS keeps every program away from the Notes database and from controlling Notes. When that happens:
1. The command says that it ran inside a sandbox.
2. The skill tells the agent to run the command again outside the sandbox.
3. Codex asks you to approve that.

Agents that start the MCP server do not have this problem.

The same in the terminal:

```bash
apple-notes-mcp agents list --skill                                   # where each agent's skill is, and whether it is current
apple-notes-mcp agents set-up --all --skill                           # every installed agent, for every project
apple-notes-mcp agents set-up claude-code codex --folder ~/code/app   # one project (--folder implies --skill)
apple-notes-mcp skill                                                 # print the skill, to install it by hand anywhere
```

### Choosing the tools

The window's **Tools** tab lists the 11 tools by name, each with what it does and a label: **Read-only**, **Writes**, or **Can delete**. Tick the ones AI assistants may use. **All**, **None**, **Invert** and **Read-Only** (only the tools labelled Read-only) change them all at once. The choice is saved as soon as you make it, in `~/Library/Application Support/AppleNotesMCP/tools.json`, outside the app, so restarts, updates and reinstalls keep it:

```json
{
  "tools" : {
    "create_note" : true,
    "delete_note" : false,
    …
  }
}
```

It applies at once. A turned-off tool is left out of the tool list, and calling it anyway is refused with a message that tells the assistant where you can turn it back on. Its [command](#command-line) is refused too (exit status 1), so the choice also holds for agents set up with the skill, and in your own terminal. Running assistants are told with `notifications/tools/list_changed`: clients of the 2026-07-28 protocol (Claude Code, Grok Build) on the `subscriptions/listen` stream they open, older ones after they initialize. Claude Code lists the tools again and the change shows up in the same session; a client that ignores the notice sees it in its next session. Servers started by a version before this one don't read the file, so restart those assistants once after updating.

A tool that a later version adds, and that the file therefore doesn't name yet, starts on, unless you turned off another tool with the same label: after Read-Only, new tools that write stay off. If the file can't be read (after a hand edit that broke it, say), no tools are offered until it is fixed; choosing again in the tab replaces it and keeps the broken one as `tools.json.bak-<date>-<time>`. `apple-notes-mcp --self-check` prints how many tools are offered. With no file, every tool is.

### Build from source

```bash
./scripts/build-app.sh notes
ditto dist/AppleNotesMCP.app ~/Applications/AppleNotesMCP.app
```

`./scripts/build-pkg.sh notes` builds the release package, `dist/AppleNotesMCP-<version>.pkg`, and its SHA-256 checksum. To publish a release, write its note as a `## <version>` section of [`CHANGELOG-notes.md`](../CHANGELOG-notes.md), run `scripts/e2e.py notes` (and `scripts/e2e.py reminders` too when the shared code changed), and then, on `main`:

```bash
scripts/release.sh notes 0.4.0       # or first: scripts/release.sh --dry-run notes 0.4.0
```

- **What it does:** it sets the version (the build number goes up by one by itself) and runs `swift test`. It builds the package and checks that it is signed with your certificate, then commits `Release Apple Notes MCP <version>`, tags `notes-v<version>` and pushes both. It publishes the GitHub release with the package and the note from `CHANGELOG-notes.md`, adding the install commands for that version. Last, it points the Homebrew cask at the release with `./scripts/update-cask.sh notes`, in a checkout of [homebrew-tap](https://github.com/xiaofeng-han/homebrew-tap) (`../homebrew-tap` unless `TAP=<path>`). Apple Reminders MCP keeps its own version and is released on its own.
- **If a step fails:** it says what is already done and how to finish by hand.
- **`--dry-run`:** does everything up to the package, then undoes the version change; nothing is committed, pushed or published.

Every pull request and every push to `main` is built and unit-tested on a GitHub-hosted Mac with the newest Xcode (`.github/workflows/check.yml`). That workflow holds no secrets: signing happens only on your Mac, in `scripts/release.sh`.

The icon's source is the Icon Composer document `Resources/Notes/AppIcon.icon`, whose artwork `scripts/compose-icon.swift` makes from the Apple Reminders MCP icon, so the two look like a pair. After changing it, run `./scripts/build-icon.sh notes` (it needs Xcode for `actool`) and commit `Resources/Notes/AppIcon-compiled`; ordinary builds only copy that folder.

### Why the permissions belong to this app

macOS charges a child process's privacy permissions to its "responsible process": without help, Full Disk Access and Automation would have to be granted to every agent that starts the server (a terminal, Claude, Codex…). The app therefore gives up that responsibility as soon as it starts and launches itself again under its own identity (`Sources/Launcher`), passing stdin and stdout through unchanged. So the permissions are granted once, to "Apple Notes MCP", whatever starts it.

Start it by its real path, or through a script that `exec`s it, as Homebrew's `apple-notes-mcp` does; not through a symbolic link, from which macOS cannot find the app bundle.

### Signing

`build-app.sh` signs with the self-signed certificate "Xiaofeng Local Code Signing" from the login keychain by default (`SIGNING_IDENTITY` picks another). The designated requirement is "bundle id + certificate", so permissions survive rebuilds; with ad-hoc signing every rebuild has to be granted again. The [Apple Reminders MCP documentation](reminders.md#signing) shows how to create the certificate on a new Mac.

## Registering with clients

The app's AI Assistants tab, or `apple-notes-mcp agents set-up`, does this for you. To do it by hand: the command is `/opt/homebrew/bin/apple-notes-mcp` after a Homebrew install, and `~/Applications/AppleNotesMCP.app/Contents/MacOS/AppleNotesMCP` after installing the package for yourself (`/Applications/…` for all users), run with `--stdio`. Give the full path. The server name is `apple-notes`. The server supports MCP's session protocol (2024-11-05 to 2025-11-25) and the stateless 2026-07-28 protocol.

- Claude Code: `claude mcp add -s user apple-notes -- <command> --stdio`
- Codex (`~/.codex/config.toml`, shared with the ChatGPT app) and Grok Build (`~/.grok/config.toml`, plus `enabled = true`):

  ```toml
  [mcp_servers.apple-notes]
  command = "/opt/homebrew/bin/apple-notes-mcp"
  args = ["--stdio"]
  ```

- Claude app, Gemini CLI and Antigravity: `"mcpServers": {"apple-notes": {"command": "<command>", "args": ["--stdio"]}}`
- OpenCode (`~/.config/opencode/opencode.json`): `"mcp": {"servers": {"apple-notes": {"type": "local", "command": ["<command>", "--stdio"]}}}`
- pi (`mcpServers` in `~/.pi/agent/mcp.json`): `{"type": "stdio", "command": "<command>", "args": ["--stdio"]}`

To install the skill by hand, save what `apple-notes-mcp skill` prints as `apple-notes/SKILL.md` in the agent's skills folder (see [Server or skill](#server-or-skill)).

For debugging, set `APPLE_NOTES_MCP_WIRE_LOG=<file>` to log every message sent and received.

## Tests

```bash
/usr/bin/python3 -I scripts/e2e.py notes                          # the installed app, against your real notes
/usr/bin/python3 -I scripts/e2e.py notes dist/AppleNotesMCP.app/Contents/MacOS/AppleNotesMCP   # this checkout, after scripts/build-app.sh notes
swift test
apple-notes-mcp --check-markdown                            # every note read back from its Markdown, unchanged (reads only)
```

A build in `dist/` is signed like a release, so it holds the permissions you gave the installed app; a bare `.build/debug/AppleNotesMCP` has only those of the app that starts it (your terminal), and the checks stop at once without them. `e2e.py notes` runs every tool over stdio, and the main command-line commands, 147 checks in all, with the write guard on (`APPLE_NOTES_MCP_WRITE_GUARD=agent test`: only notes titled, and folders named, "agent test…" can change). It works in a folder "agent test" that it creates and finally deletes with everything in it, so only Recently Deleted keeps its notes. It reads one of your images to check `read_attachment` and search in the text Notes recognized in it, and, if you have one, a recording with its transcript. The choice of tools comes from a throwaway file (`APPLE_NOTES_MCP_TOOLS_FILE`), so yours is neither used nor changed. `swift test` checks, in throwaway folders where files are involved:
- the Markdown conversion, including that every kind of line reads back the same;
- the planning of edits, and the stored-body decoder;
- the agent setup: the JSON and TOML editing that keeps the rest of a file as it was, how each agent's settings are read and written, and where each agent's skill goes;
- how command-line flags are read from the tools' input schemas;
- `--list-json`: which notes it lists and in what order, what it asks the search for, one JSON object per line, and its exit status;
- the choice of tools: the rule for tools the file doesn't name, saving, reading and watching the file, and what the server lists, refuses and announces.

## Compared with other servers

About fifty MCP servers for Apple Notes are on GitHub and npm. The table has the six with the most features, and disco-trooper for its semantic search. Each column says what that project's README said on 2026-10-22; none of them was installed and tested for this table, so read a cell as that project's claim. ✅ has it · ⚠️ partly, or with conditions · ❌ no · – its README does not say.

| | **This server (0.4)** | [sweetrb](https://github.com/sweetrb/apple-notes-mcp) | [ailenshen](https://github.com/ailenshen/apple-notes-mcp) v2 | [PsychQuant](https://github.com/PsychQuant/che-apple-notes-mcp) | [notebridge](https://github.com/mqingcs/notebridge-Apple-Notes-MCP) | [evg4b](https://github.com/evg4b/apple-notes-mcp) | [TheInkedEngineer](https://github.com/TheInkedEngineer/apple-notes-mcp) | [disco-trooper](https://github.com/disco-trooper/apple-notes-mcp) |
|---|---|---|---|---|---|---|---|---|
| Reads notes as | Markdown with every structure, tags, links to notes, divider lines and highlight colors | HTML, plain text or Markdown | Markdown | text and HTML | plain text, or exported HTML | plain text (HTML on request) | plain text, Markdown or HTML | Markdown or HTML |
| Checklist state when reading | ✅ | ✅ with Full Disk Access | ✅ | – | ❌ | ❌ | ❌ | ❌ |
| Edits in place (one line changes, the rest stays) | ✅ character by character | ⚠️ append and prepend only; an update replaces the whole body and refuses rich notes | ✅ | ⚠️ whole body | ⚠️ append, edit, rename, move; no whole-body replace on notes with attachments | ⚠️ whole body, or append | ⚠️ whole body | ⚠️ whole body |
| Keeps formatting Markdown cannot show | ✅ colors, fonts and alignment stay; merges with edits from other devices | ⚠️ kept on append, not on update | ✅ | ❌ | – | ❌ | ❌ | ❌ |
| Writes checklists and tables | ✅ ticks items by text, ticks or unticks all, moves or deletes ticked items; edits table cells | ⚠️ adds unticked items only (through Shortcuts), cannot tick; only appends new tables | ✅ one replacement per item; tables ✅ | ❌ | ❌ | ❌ | ❌ | ❌ (reads tables, with bold and such) |
| Attachments: read / add | reads ✅ images, scans, drawings, PDFs, audio (with transcript and summary), a video frame, and the text Notes recognized; adds ✅ files and link cards; removes ❌ | reads ✅ lists, exports, transcribes audio, drawings to SVG; adds ✅ | reads ✅; adds ❌ | ❌ | reads ✅ original bytes with SHA-256 and previews; adds ⚠️ up to 256 KiB | reads ⚠️ lists only | ❌ | ❌ |
| Search | full text and the text recognized in attachments; narrowed by tag, group and attachment kind; sorted by last opened | title or body, and a boolean query language (needs Full Disk Access) | full text | SQL LIKE | titles only | keywords | title or body substring, pages, dates | ✅ hybrid: vectors and keywords with RRF, long notes chunked, incremental and background indexing; OpenRouter embeddings optional; related notes by #tag text and links |
| Folders | ✅ create, rename, move, delete; smart folders | create, rename, delete | create, rename, delete | create, rename, delete; batch create, move and delete of notes | ❌ | create, delete | ✅ create, rename, delete, move; batch read and delete | lists only; notes can be moved |
| Export | a folder as Markdown with the original attachments, or a .zip | Markdown with templates, HTML, JSON | same as this server | ❌ | ❌ | ❌ | ❌ | ❌ |
| Accounts, tags, pinning | accounts told apart in paths, moves within one account; tags read and written, renamed or removed everywhere; pinning; backlinks; Recently Deleted | account parameter; tags and pinning through Shortcuts | – | account parameter; pinned and locked filters; share sheet | – | account parameter | account parameter | – |
| Conflicts and backups | ✅ every change names a version; 20 backups; rehearsed on a copy and read back | ✅ contentHash; backups – | ✅ a rewrite needs the version; backups | ⚠️ in-process undo and redo | ✅ expected_version, backups, restore | ❌ | ❌ | ❌ |
| Choosing tools, read-only | ✅ settings window and tools.json, live list_changed, holds for the command line too | ⚠️ not itself; a derivative has it | ❌ | ❌ | ✅ folder allow-list; writes opt-in | ✅ --scopes, read-only by default | ⚠️ folder deletes need confirmation | ✅ READONLY_MODE |
| Command line, skill, agent setup | ✅ a command per tool; JSON lines for editors (`--list-json`); a skill; finds, sets up and installs 7 agents | ⚠️ setup subcommands; plugins with a skill; Broker.app | ❌ | ✅ --cli; plugin with slash commands and a skill | ❌ | ❌ | ❌ | ⚠️ a wizard that writes Claude Code's config and picks the embedding model |
| Install | Homebrew cask or package | npx, plugin marketplaces | npx | .mcpb, binary, plugin marketplace | clone and pip | Homebrew or binary (Intel too) | Homebrew | npm, needs Bun |

What some of them have and this server does not: semantic search, removing an attachment already in a note, moving notes between accounts, an HTTP transport, Intel Macs and macOS before 26.

## Limits

- An attachment already in a note cannot be removed, except tables, tags, links to notes and divider lines. New files and link cards can be added.
- Locked notes cannot be read (their text is encrypted with the user's password).
- A table that was edited in Notes itself during the current Notes session does not upload when changed in place; the server then makes it again with the same content, which resets formatting inside its cells.
- Notes saves its own changes to the database lazily, so the server remembers notes and folders it deleted or renamed until the database catches up.

`docs/RE-FINDINGS.md` has the reverse-engineering notes this project started from (in Chinese).
