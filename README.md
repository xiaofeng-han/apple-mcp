# Apple Notes MCP

**English** | [简体中文](README.zh-CN.md)

An MCP server that lets AI agents (Claude Code, Codex, Grok Build, OpenCode, Gemini CLI, pi, …) read and edit Apple Notes on macOS, with native formatting. Its settings window finds the agents on your Mac and sets each one up with one click, installing the ones you are missing.

- **Reading** goes through Notes' own data model, with its database opened read-only: titles, headings, lists, checklists (ticked or not), tables, links, highlights and attachments all come out as Markdown.
- **Editing** happens in place, through Notes' private NotesShared framework, the way Notes itself edits: only what changed is written, character by character, so everything Markdown cannot show (colors, fonts, alignment) stays as it was, and edits made on other devices merge. Every change is rehearsed on a copy first and read back afterwards.
- **Syncing**: Notes does not upload changes made this way by itself, so after each change the server asks Notes (through AppleScript) to save and upload the note, and waits until iCloud has it. Notes never comes to the front.

Requires macOS 26 or later on Apple silicon; developed and tested on macOS 27.0.1. All code is written for this project, with no third-party dependencies. The permissions it needs are Full Disk Access (to read the Notes database) and Automation → Notes (to upload, move and delete).

## Tools

| Tool | What it does |
|---|---|
| `overview` | The folders with note counts; or, for a folder, a date range or a sort order, the notes one per line (id, title, date, size, attachments, description). `undescribed: true` lists notes that still need a description, with their opening text |
| `search` | Full-text search of titles and text, best matches first, with the text around each match; by folder, dates, all or any words |
| `read_note` | A note as Markdown with its version: by id, several ids, or exact title; one section, or an outline with each section's size |
| `read_attachment` | An attachment from a `![…](attachment:id)` placeholder: images (scaled), scan pages, drawings, PDFs (text and file), audio, a frame of a video, tables, links and files, with any text Notes recognized in it |
| `describe_note` | Saves one-line descriptions that `overview` shows, many notes per call |
| `create_note` | A new note from Markdown, in any folder |
| `edit_note` | Several changes in one call: exact replacements, Markdown inserted at the start, the end or under a heading (list items join that section's list), or a whole rewrite |
| `move_note` | Moves a note to another folder of its account, or back out of Recently Deleted |
| `delete_note` | Moves a note to Recently Deleted |
| `manage_folder` | Creates, renames or deletes a folder (an empty one, or with `recursive` and `expected_notes` everything in it); exports a folder and its folders as Markdown with the original attachments, to a new folder or a `.zip` |

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
| Underline, highlight | `<u>…</u>`, `<mark>…</mark>` |
| Link | `[text](url)` |
| Table | `\| a \| b \|` rows; `<br>` for a line break in a cell |
| Attachment | `![image](attachment:1A2B3C4D)` (a placeholder to keep in place) |

### Rules

- `edit_note` with `rewrite` needs the `version` from `read_note`, a hash of the note as Markdown. If the note changed since it was read (on another device, say), the write is refused instead of overwriting that change. Before every write the note's stored body is saved under `~/Library/Application Support/AppleNotesMCP/backups/<note id>/` (the last 20).
- Attachments stay where they are: an edit that would drop a placeholder, or add one that is not in the note, is refused. Tables are the exception: they can be added, changed (cell by cell, in place) and removed.
- Locked notes cannot be read or changed. Shared notes can be edited (the edits merge with the other people's), but are not deleted here, and a move into or out of a shared folder needs `allow_shared` (after asking the user).
- `delete_note` and a recursive folder delete only move notes to Recently Deleted, and refuse a note already there (deleting it again would erase it for good). A recursive delete needs `expected_notes`, the number of notes the caller saw, and checks everything before it changes anything.
- An export goes only to a path that does not exist yet, outside `~/Library`.

## Install

Releases are built for Apple silicon and need macOS 26 or later. The default way to install and set up is with Homebrew:

```bash
brew install --cask xiaofeng-han/tap/apple-notes-mcp
apple-notes-mcp setup                  # allow it to control Notes; shows where to give Full Disk Access
apple-notes-mcp agents set-up --all    # register the server with the agents on this Mac
```

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

Without Homebrew, download `AppleNotesMCP-<version>.pkg` from [Releases](https://github.com/xiaofeng-han/apple-notes-mcp/releases) and open it, or install it from the terminal:

```bash
gh release download v0.1.0 -R xiaofeng-han/apple-notes-mcp -p '*.pkg'
installer -pkg AppleNotesMCP-0.1.0.pkg -target CurrentUserHomeDirectory
```

Installing for yourself only puts the app in `~/Applications` and needs no administrator password; installing for all users puts it in `/Applications`. The package has no Developer ID signature: if macOS refuses to open one downloaded in a browser, allow it under System Settings → Privacy & Security.

### After installing

The examples use the command that Homebrew adds. If you installed the package, use the app's executable in its place: `~/Applications/AppleNotesMCP.app/Contents/MacOS/AppleNotesMCP`, or `/Applications/AppleNotesMCP.app/Contents/MacOS/AppleNotesMCP` if you installed it for all users.

```bash
apple-notes-mcp setup          # asks to control Notes (click OK), and opens the Full Disk Access settings if needed
apple-notes-mcp --self-check   # shows both permissions and counts your notes
```

Full Disk Access has to be turned on by hand: System Settings → Privacy & Security → Full Disk Access, then turn on Apple Notes MCP, adding it with + if it is not listed (it is in `~/Applications` if you installed the package for yourself, and in `/Applications` otherwise).

Opening the app directly (double-clicking it, or starting it with `--settings`) shows the settings window. It opens in front, on the **AI Assistants** tab; the **General** tab shows both permissions, with buttons to grant them, and the window's language: English or Simplified Chinese, following the system unless you pick one (`defaults write com.xiaofeng.apple-notes-mcp InterfaceLanguage -string zh-Hans`, or `en`; delete it to follow the system). When an agent calls the server without a permission it needs, the server opens this window once and tells the agent so.

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

### Build from source

```bash
./scripts/build-app.sh
ditto dist/AppleNotesMCP.app ~/Applications/AppleNotesMCP.app
```

`./scripts/build-pkg.sh` builds the release package, `dist/AppleNotesMCP-<version>.pkg`, and its SHA-256 checksum. To publish a release:
1. Upload the package with `gh release create v<version> dist/AppleNotesMCP-<version>.pkg dist/AppleNotesMCP-<version>.pkg.sha256`.
2. Run `./scripts/update-cask.sh`. It checks that GitHub serves the same file, then sets the new version and checksum in the Homebrew cask in a checkout of [homebrew-tap](https://github.com/xiaofeng-han/homebrew-tap) (`../homebrew-tap` unless given another path), and commits and pushes.

The icon's source is the Icon Composer document `Resources/AppIcon.icon`, whose artwork `scripts/compose-icon.swift` makes from the Apple Reminders MCP icon, so the two look like a pair. After changing it, run `./scripts/build-icon.sh` (it needs Xcode for `actool`) and commit `Resources/AppIcon-compiled`; ordinary builds only copy that folder.

### Why the permissions belong to this app

macOS charges a child process's privacy permissions to its "responsible process": without help, Full Disk Access and Automation would have to be granted to every agent that starts the server (a terminal, Claude, Codex…). The app therefore gives up that responsibility as soon as it starts and launches itself again under its own identity (`Sources/Launcher`), passing stdin and stdout through unchanged. So the permissions are granted once, to "Apple Notes MCP", whatever starts it.

Start it by its real path, or through a script that `exec`s it, as Homebrew's `apple-notes-mcp` does; not through a symbolic link, from which macOS cannot find the app bundle.

### Signing

`build-app.sh` signs with the self-signed certificate "Xiaofeng Local Code Signing" from the login keychain by default (`SIGNING_IDENTITY` picks another). The designated requirement is "bundle id + certificate", so permissions survive rebuilds; with ad-hoc signing every rebuild has to be granted again. The [Apple Reminders MCP README](https://github.com/xiaofeng-han/apple-reminders-mcp#signing) shows how to create the certificate on a new Mac.

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

For debugging, set `APPLE_NOTES_MCP_WIRE_LOG=<file>` to log every message sent and received.

## Tests

```bash
/usr/bin/python3 -I scripts/e2e.py                          # the installed app, against your real notes
/usr/bin/python3 -I scripts/e2e.py .build/debug/AppleNotesMCP   # a development build (uses its parent's permissions)
swift test
```

`e2e.py` runs every tool over stdio, 52 checks in all, with the write guard on (`APPLE_NOTES_MCP_WRITE_GUARD=agent test`: only notes titled, and folders named, "agent test…" can change). It works in a folder "agent test" that it creates and finally deletes with everything in it, so only Recently Deleted keeps its notes. It reads one of your images to check `read_attachment`. `swift test` checks the Markdown conversion (including that every kind of line reads back the same), the planning of edits, the stored-body decoder, and the agent setup.

## Limits

- Attachments can be read, not added or removed (except tables).
- Folders cannot be moved: Notes' AppleScript `move folder` reports success and deletes the folder, so it is never used.
- Locked notes cannot be read (their text is encrypted with the user's password).
- A table that was edited in Notes itself during the current Notes session does not upload when changed in place; the server then makes it again with the same content, which resets formatting inside its cells.
- Notes saves its own changes to the database lazily, so the server remembers notes and folders it deleted or renamed until the database catches up.

`docs/RE-FINDINGS.md` has the reverse-engineering notes this project started from (in Chinese).
