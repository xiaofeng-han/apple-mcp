# Apple Reminders MCP

**English** | [简体中文](README.zh-CN.md)

> **This repository is now `apple-mcp`** (formerly `apple-reminders-mcp`; old links redirect here), becoming the home of both Apple Reminders MCP and [Apple Notes MCP](https://github.com/xiaofeng-han/apple-notes-mcp) on one shared base ([plan](docs/MERGE-PLAN.md), in Chinese). Nothing changes for users: each app keeps its name, command, cask and permissions. During the move, Notes' code sits under `incoming/notes/` and Apple Notes MCP is still released from its own repository.

An MCP server that lets AI agents (Claude Code, Codex, Grok Build, OpenCode, Gemini CLI, pi, …) fully read and write Reminders on macOS. Every tool is also a command-line command, so an agent can use a skill instead of the server. Its settings window finds the agents on your Mac and sets each one up either way with one click, installing the ones you are missing.

Writes go through Apple's private ReminderKit framework, the same path Reminders.app itself uses. So everything below is native and shows up correctly on iPhone too:
- Reminders: flags, real tags, subtasks, Urgent (rings like an alarm), repeats, early reminders, location and getting in or out of the car, "when messaging a person", links, images, assignment in shared lists, and ordering;
- Lists: sections, groups, color and icon, pinning, grocery lists, sort order, templates, and smart lists.

Once saved, the system's remindd syncs changes to iCloud on its own. The only privacy permission needed is Reminders. Full Disk Access is optional and only used for reading: to list everything in Recently Deleted, and to read images on reminders.

Requires macOS 26 or later; developed and tested on macOS 27.0.1. All code is written for this project, with no third-party dependencies.

## Comparison

Checked on 2026-10-20 against each project's source code and Apple's documentation; star counts are from that day. ✅ verified · 🟡 partial or workaround · ❌ not supported · ❓ not verified · — not applicable

| Tool | Stars | Approach | Tags | Subtasks | Sections | Smart lists | Location alerts | Urgent | Groups / colors | Recurrence | Shared-list assign | Restore deleted | Conflict protection |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **MCP servers** | | | | | | | | | | | | | |
| **xiaofeng-han/apple-reminders-mcp** (this project) | new | ReminderKit (private framework used by Reminders.app) | ✅ native | ✅ native | ✅ | ✅ | ✅ + car + “when messaging” | ✅ | ✅ | ✅ | ✅ | ✅ to original list | ✅ version hash |
| [supermemoryai/apple-mcp](https://github.com/supermemoryai/apple-mcp) | 3,120 | AppleScript (`tell application "Reminders"`) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| [FradSer/mcp-server-apple-events](https://github.com/FradSer/mcp-server-apple-events) | 224 | EventKit (Swift CLI) | 🟡 `[#tag]` text in notes | 🟡 text block in notes | ❌ | ❌ | 🟡 read-only | ❌ | 🟡 list color, read-only | 🟡 read-only | ❌ | ❌ | ❌ |
| [omarshahine/apple-pim](https://github.com/omarshahine/apple-pim) | 65 | EventKit (Swift CLI) | ❌ | ❌ | ❌ | ❌ | ✅ arrive/leave | ❌ | 🟡 list color, read-only | ✅ | ❌ | ❌ | ❌ |
| [PsychQuant/che-ical-mcp](https://github.com/PsychQuant/che-ical-mcp) | 41 | EventKit (Swift) | 🟡 hashtags in notes (“MCP-level”) | ❌ | ❌ | ❌ | ✅ | ❌ | 🟡 list color, read/write | ✅ | ❌ | 🟡 undo recreates (new item) | 🟡 undo won’t overwrite user edits |
| [shadowfax92/apple-reminders-mcp](https://github.com/shadowfax92/apple-reminders-mcp) | 39 | JXA via node-reminders (osascript) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| [dbmcco/apple-reminders-mcp](https://github.com/dbmcco/apple-reminders-mcp) | 29 | AppleScript (osascript) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Apple built-in** | | | | | | | | | | | | | |
| Siri / Apple Intelligence | — | Built-in voice / system | ❓ | ❌ | ❓ | ❌ | ✅ “remind me when I get home” | ❓ | ❌ | ✅ | ❌ | ❌ | — |
| Shortcuts “New Reminder” etc. (iOS / macOS 27) | — | Built-in actions | ❓ | ❓ | 🟡 create/delete sections; can’t put a reminder in one | ❌ | ❓ | ✅ iOS 27 | 🟡 create/delete groups (iOS 27) | ❓ | ❓ | ❌ | ❌ |

## Tools

| Tool | What it does |
|---|---|
| `list_lists` | Lists (open and total counts, default, pinned, kind, group, color, icon, sort order, sections, members of shared lists), groups, smart lists (with their filters), and templates |
| `find_reminders` | Searches across lists: by list, smart list (what it shows, as Reminders computes it), section, keyword, completed, flagged, urgent, repeating, has a location alert, assignee, tags, and due window (`due_before` excludes that day). Each reminder appears once and names the smart lists that show it |
| `get_reminder` | Everything about one reminder: alarms, early reminders, images, subtasks |
| `read_image` | Returns an image on a reminder to the model (needs Full Disk Access) |
| `list_tags` | All tags and how many reminders use each |
| `list_deleted` | Reminders in Recently Deleted that can be restored |
| `create_reminder` | Creates a reminder; the fields it takes are in the table below |
| `update_reminder` | Changes only the fields given, `null` clears one; also `completed` to check it off, `list` to move it to another list, and `remove_images` |
| `delete_reminder` | Moves it, with its subtasks, to Recently Deleted |
| `restore_reminder` | Restores it from Recently Deleted (with the subtasks deleted along with it), back to its original list by default |
| `manage_list` | Creates a list; changes its name, color, icon, group, pinning, kind (standard or groceries), sort order, or sidebar position; clears completed reminders; deletes it (a list that still has reminders needs `confirm_delete_reminders: true`, and those reminders go to Recently Deleted) |
| `manage_group` | Creates, renames, or deletes an empty group |
| `manage_section` | Creates, renames, reorders, or deletes a section (deleting a section keeps its reminders) |
| `manage_smart_list` | Creates, changes, or deletes a smart list: match all or any, filtering on tags, date (including date ranges and relative ranges), time of day, priority, flag, lists, and location (including getting in or out of the car) |
| `manage_tag` | Renames a tag on every reminder that has it (merging if the new name is already in use), or deletes it |
| `manage_template` | Saves a list as a template, creates a list from a template, or deletes a template |

Reminder fields:

| Field | Format |
|---|---|
| `due` / `start` | `2026-10-21` (all day) or `2026-10-21T09:00` (local time); a due time alerts at that time |
| `repeat` | `{frequency: hourly/daily/weekly/monthly/yearly, interval, days_of_week: [mon, 1mon, -1fri], days_of_month: [1, -1], months: [1..12], until or count}` |
| `early_alerts` | `[{before: 15, unit: minutes/hours/days/weeks/months}]` |
| `location` | `{title, latitude, longitude, radius, address, when: arriving/leaving}`, or `getting-in-car` / `getting-out-of-car` |
| `when_messaging` | `{phones: [...], emails: [...]}` |
| `url`, `add_images` | A link; paths of local images |
| `priority`, `flagged`, `urgent`, `tags`, `notes` | Priority is none/low/medium/high; tags are written without # |
| `parent_id`, `section`, `position` | Subtask; section; `{after/before: reminder id}` |
| `assigned_to` | The name of a member of a shared list, or `me` |

Rules:

- Updates and deletes must pass the `version` that was read. It is a hash of the visible fields, so if the user changed the reminder on another device the write is refused rather than overwriting their change.
- Urgent needs a due date with a time; changing the due date to all day or clearing it turns Urgent off. Repeats and early reminders need a due date.
- Subtasks are one level deep and must be in the same list as their parent; a reminder with subtasks cannot be moved to another list.
- Completing a repeating reminder works as it does in the app: a completed copy is left behind and the reminder moves on to its next occurrence. This can be turned off in the settings.
- Colors: red, orange, yellow, green, light-blue, blue, indigo, pink, purple, brown, gray, rose, or `#RRGGBB`. An icon is an emoji or a Reminders icon name (such as `nature2`).
- Other people can see shared lists, so agents should ask the user before changing them.
- Any tool can be turned off for all AI assistants in the settings window (see [Choosing the tools](#choosing-the-tools)).

## Command line

Every tool is also a command, so the app works from a terminal and from an agent's shell, which is what the [skill](#server-or-skill) uses. A command is a noun and a verb. Its flags come from the tool's input fields, so they are the fields in the tables above. `apple-reminders-mcp help` prints the whole tree:

```text
apple-reminders-mcp
├── --stdio                     Serve MCP on stdin and stdout (what agents start)
├── --settings                  Open the settings window (also what opening the app does)
├── --self-check                Print a diagnosis
├── --version                   Print the version
├── help [COMMAND…]             This tree, or a command's flags (also --help, -h)
├── setup                       Ask for access to Reminders (alias: authorize)
├── skill                       Print the SKILL.md that teaches an agent this command line
├── agents
│   ├── list                    Which agents are here and set up (the default)
│   │       [--skill] [--folder DIR]
│   ├── set-up (ID… | --all)    Register the server with them, or install the skill
│   │       [--restart] [--skill] [--folder DIR]
│   └── install ID…             Install them, then set them up
│           [--dry-run] [--restart] [--skill] [--folder DIR]
├── reminders
│   ├── find [QUERY]            Find reminders across lists, open ones first by due date; QUERY matches the title or notes
│   │       --assigned-to string --due-after string --due-before string --[no-]flagged --[no-]has-location
│   │       --[no-]include-completed --limit int --list string --[no-]repeating --section string
│   │       --smart-list string --tag string --[no-]urgent
│   ├── get ID                  Read one reminder in full: alarms, early alerts, images, subtasks, and its current version
│   ├── create TITLE            Create a reminder; without --list it goes to the default list (or the parent's list)
│   │       --add-image string… --after string --assigned-to string --before string --due string
│   │       --early-alerts json --[no-]flagged --list string --location json|string --notes string
│   │       --parent-id string --priority none|low|medium|high --repeat json --section string --start string
│   │       --tag string… --[no-]urgent --url string --when-messaging json
│   ├── update ID --version string  Change only the fields given; --no-FIELD clears one
│   │       --add-image string… --after string --assigned-to string --before string --[no-]completed
│   │       --due string --early-alerts json --[no-]flagged --list string --location json|string
│   │       --notes string --parent-id string --priority none|low|medium|high --remove-image string…
│   │       --repeat json --section string --start string --tag string… --title string --[no-]urgent
│   │       --url string --when-messaging json
│   ├── delete ID --version string  Move a reminder and its subtasks to Recently Deleted
│   ├── deleted                 List reminders in Recently Deleted that restore can bring back, newest first
│   ├── restore ID              Bring a reminder back from Recently Deleted, with the subtasks deleted along with it
│   │       --list string
│   └── image REMINDER_ID IMAGE_ID  Save an image on a reminder (ids from get) and print where; needs Full Disk Access
│           --output string
├── lists
│   ├── list                    The lists (with counts, sections and the people on shared ones), groups, smart lists and templates (the default)
│   ├── create NAME             Create a list
│   │       --color string --icon string --group string --[no-]pinned --type standard|groceries --sort string
│   │       --after string --before string
│   ├── update LIST             Change a list's name, color, icon, group, pin, type, sort order or place in the sidebar
│   │       --new-name string --color string --icon string --group string --[no-]pinned
│   │       --type standard|groceries --sort string --after string --before string
│   ├── clear-completed LIST    Move a list's completed reminders to Recently Deleted
│   └── delete LIST             Delete a list; one with reminders needs --confirm-delete-reminders (ask the user first)
│           --[no-]confirm-delete-reminders
├── groups
│   ├── create NAME             Create a group, which holds lists in the sidebar (put lists in it with lists update --group)
│   ├── rename GROUP NEW_NAME   Rename a group
│   └── delete GROUP            Delete an empty group
├── sections
│   ├── create LIST NAME        Create a section in a list (put reminders in it with --section)
│   ├── rename LIST SECTION NEW_NAME  Rename a section
│   ├── move LIST SECTION (--after string | --before string)  Move a section next to another one
│   └── delete LIST SECTION     Delete a section; its reminders stay in the list
├── smart-lists
│   ├── create NAME --filters json  Create a smart list, which shows the reminders matching its filters
│   │       --match all|any --color string --icon string
│   ├── update SMART_LIST       Change a smart list's name, color, icon, match or filters (--filters replaces them all)
│   │       --new-name string --filters json --match all|any --color string --icon string
│   └── delete SMART_LIST       Delete a smart list; no reminders are deleted
├── tags
│   ├── list                    Every tag in use, with how many open and how many reminders in all have it (the default)
│   ├── rename TAG NEW_NAME     Rename a tag on every reminder that has it, merging into a tag of that name if there is one
│   └── delete TAG              Remove a tag from every reminder
├── templates
│   ├── create NAME --list string  Save a list as a template (Reminders copies its reminders in the background)
│   │       --[no-]include-completed
│   ├── use TEMPLATE            Make a new list from a template
│   │       --list string
│   └── delete TEMPLATE         Delete a template
└── call TOOL [JSON | -]        Run any tool on a JSON object of its arguments; call alone lists the tools
```

- **Flag names:** a field's flag has dashes for underscores, so `due_before` is `--due-before`.
- **True-or-false fields:** `--flagged` turns one on and `--no-flagged` turns it off.
- **Clearing a field:** on an update, `--no-due` and the like clear a field (what `null` does in MCP).
- **Lists:** a field that holds a list repeats its flag in the singular: `--tag work --tag home`.
- **Objects:** an object field takes JSON: `--repeat '{"frequency":"weekly","days_of_week":["mon"]}'`. `--location` also takes `getting-in-car` or `getting-out-of-car`, and `--after ID` / `--before ID` set `position`.
- **Fields as JSON:** `--json '{…}'` gives fields by their MCP names, and `--json -` reads them from stdin. Flags override them.
- **Any tool:** `call TOOL '{…}'` runs a tool on its MCP arguments.
- **Help:** `--help` after a command lists its flags and what each one takes.

A command prints exactly what the tool answers: JSON, sometimes after a short lead such as `Created.`.
- **Exit status 1:** the request failed (not found, changed since it was read, not allowed). The reason is on stderr.
- **Exit status 2:** the command or a flag was wrong.

`reminders image` saves the image to `--output`, or to a file in the temporary folder, and prints where. Only the first word decides what the program does, so a reminder may be called `setup`. Put `--` before a title that starts with `-`.

```bash
apple-reminders-mcp reminders find --due-before 2026-10-22
apple-reminders-mcp reminders create "Buy milk" --list Groceries --due 2026-10-22T09:00 --tag errands
apple-reminders-mcp reminders update <id> --version <version> --completed
apple-reminders-mcp lists create Trips --color blue
```

## Install

Releases are built for Apple silicon and need macOS 26 or later. The default way to install and set up is with Homebrew:

```bash
brew install --cask xiaofeng-han/tap/apple-reminders-mcp
apple-reminders-mcp setup                  # allow access to Reminders
apple-reminders-mcp agents set-up --all    # register the server with the agents on this Mac
```

To give the agents the skill instead of the server, add `--skill` to the last command (see [Server or skill](#server-or-skill)).

Instead of the last two commands, you can open Apple Reminders MCP from Applications: set up your agents in its **AI Assistants** tab, and allow access to Reminders under **General**. Without Homebrew, install [from the package](#from-the-package).

### With Homebrew

Naming the cask in full, as above, adds the tap [xiaofeng-han/tap](https://github.com/xiaofeng-han/homebrew-tap) and trusts only this cask. Since Homebrew 6, items from taps outside Homebrew have to be trusted before Homebrew loads them. After that, `brew upgrade` picks up new releases.

Homebrew installs the same package described below, but for all users and through the macOS installer. So it asks for an administrator password, and it puts the app in `/Applications`. It also adds the command `apple-reminders-mcp` (`/opt/homebrew/bin/apple-reminders-mcp`), a small script that starts the app; the steps below use it. `brew uninstall --cask apple-reminders-mcp` removes the app. Adding `--zap` also moves its settings and its record of deleted reminders to the Trash.

If you installed the package for yourself before, remove that copy and point your agents at the new command (see [Registering with clients](#registering-with-clients)). Claude Code will not add a server name that already exists, so run `claude mcp remove -s user apple-reminders` before adding it again; in the other clients, change `command`. Both copies have the same signature, so the Reminders permission carries over.

```bash
rm -rf ~/Applications/AppleRemindersMCP.app
pkgutil --volume ~ --forget com.xiaofeng.apple-reminders-mcp.pkg
```

### From the package

Without Homebrew, download `AppleRemindersMCP-<version>.pkg` from [Releases](https://github.com/xiaofeng-han/apple-reminders-mcp/releases) and open it, or install it from the terminal:

```bash
gh release download v0.3.0 -R xiaofeng-han/apple-reminders-mcp -p '*.pkg'
installer -pkg AppleRemindersMCP-0.3.0.pkg -target CurrentUserHomeDirectory
```

Installing for yourself only puts the app in `~/Applications` and needs no administrator password; installing for all users puts it in `/Applications`. The package has no Developer ID signature: if macOS refuses to open one downloaded in a browser, allow it under System Settings → Privacy & Security.

### After installing

The examples use the command that Homebrew adds. If you installed the package, use the app's executable in its place: `~/Applications/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP`, or `/Applications/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP` if you installed it for all users.

Allow access to Reminders:

```bash
apple-reminders-mcp setup
```

`setup` shows a permission dialog (it may be hidden behind other windows); click Allow. To check the status:

```bash
apple-reminders-mcp --self-check
```

Opening the app directly (double-clicking it, or starting it with `--settings`) shows the settings window. Its **General** tab shows the status of both permissions, a switch (on by default) that allows AI assistants to complete repeating reminders, and the window's language: English or Simplified Chinese, following the system unless you pick one. Both settings can also be set from the command line:

```bash
defaults write com.xiaofeng.apple-reminders-mcp AllowCompletingRecurringReminders -bool NO
defaults write com.xiaofeng.apple-reminders-mcp InterfaceLanguage -string zh-Hans   # or en; delete it to follow the system
```

The permission dialog itself comes from macOS and always uses the system language.

Full Disk Access has to be added by hand: System Settings → Privacy & Security → Full Disk Access, click +, and choose `AppleRemindersMCP.app`. It is in `~/Applications` if you installed the package for yourself, and in `/Applications` otherwise.

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

Set Up writes the `apple-reminders` entry and keeps what you added to it (environment variables, timeouts). If the agent had turned the server off, Set Up turns it back on: it takes it out of Grok's `disabled_mcp_servers` and Gemini CLI's `mcp.excluded`, `mcp-server-enablement.json` and (when you keep one) `mcp.allowed`. The rest of the file stays as it was, comments and formatting included. An entry that you wrote in a form the app does not edit, such as a TOML inline table, is left alone and shown as set up by hand. Folders moved by variables such as `CODEX_HOME` or `XDG_CONFIG_HOME` are followed when your login shell sets them. Before the first change of a day, the old file is kept next to it as `<name>.bak-<yyyyMMdd>-apple-reminders-mcp`.

Installers and agents' commands run without this app's permissions (Reminders, Full Disk Access), in a session of their own with no terminal. A downloaded app is installed only if Gatekeeper accepts it and, for vendors whose team is built in (all but OpenCode and Antigravity), it is signed by that team. Without npm, Gemini CLI cannot be installed from the app.

The same is available in the terminal:

```bash
apple-reminders-mcp agents                     # which agents are installed and set up
apple-reminders-mcp agents set-up --all        # or name them: agents set-up codex grok
apple-reminders-mcp agents install opencode    # installs, then sets up; --dry-run only shows the command
```

`agents set-up` leaves the Claude app alone while it is open, unless you add `--restart`.

### Server or skill

Above the list, **Set Up As** chooses how agents use this app:
- **MCP Server** (the default): the agent starts `apple-reminders-mcp --stdio`, and its 16 tools are always loaded.
- **Skill:** Set Up writes a skill, `apple-reminders/SKILL.md`, which teaches the agent the [command line](#command-line).
  - The agent reads the skill only when reminders come up, and runs the commands in its shell, so no tool list sits in its context.
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
- **Other skills of the same name:** a skill named `apple-reminders` that this app did not write is left alone, and the row shows **Another Skill**.
- **Server and skill together:** setting up one way never changes the other. An agent can have both, and its row says so.
- **Agents that cannot use the skill:** Grok Bot and the Gemini app cannot run commands on this Mac. The skill works in the Claude app's Code tab, but not in its chat.

Some agents run shell commands in a sandbox. Codex does by default, and inside its sandbox macOS keeps every program away from Reminders. When that happens:
1. The command says that it ran inside a sandbox.
2. The skill tells the agent to run the command again outside the sandbox.
3. Codex asks you to approve that.

Agents that start the MCP server do not have this problem.

The same in the terminal:

```bash
apple-reminders-mcp agents list --skill                                   # where each agent's skill is, and whether it is current
apple-reminders-mcp agents set-up --all --skill                           # every installed agent, for every project
apple-reminders-mcp agents set-up claude-code codex --folder ~/code/app   # one project (--folder implies --skill)
apple-reminders-mcp skill                                                 # print the skill, to install it by hand anywhere
```

### Choosing the tools

The window's **Tools** tab lists the 16 tools by name, each with what it does and a label: **Read-only**, **Writes**, or **Can delete**. Tick the ones AI assistants may use. **All**, **None**, **Invert** and **Read-Only** (only the tools labelled Read-only) change them all at once. The choice is saved as soon as you make it, in `~/Library/Application Support/AppleRemindersMCP/tools.json`, outside the app, so restarts, updates and reinstalls keep it:

```json
{
  "tools" : {
    "create_reminder" : true,
    "delete_reminder" : false,
    …
  }
}
```

It applies at once. A turned-off tool is left out of the tool list, and calling it anyway is refused with a message that tells the assistant where you can turn it back on. Its [command](#command-line) is refused too (exit status 1), so the choice also holds for agents set up with the skill, and in your own terminal. Running assistants are told with `notifications/tools/list_changed`: clients of the 2026-07-28 protocol (Claude Code, Grok Build) on the `subscriptions/listen` stream they open, older ones after they initialize. Claude Code lists the tools again and the change shows up in the same session; a client that ignores the notice sees it in its next session. Servers started by a version before this one don't read the file, so restart those assistants once after updating.

A tool that a later version adds, and that the file therefore doesn't name yet, starts on, unless you turned off another tool with the same label: after Read-Only, new tools that write stay off. If the file can't be read (after a hand edit that broke it, say), no tools are offered until it is fixed; choosing again in the tab replaces it and keeps the broken one as `tools.json.bak-<date>-<time>`. `apple-reminders-mcp --self-check` prints how many tools are offered. With no file, every tool is.

### Build from source

```bash
./scripts/build-app.sh
ditto dist/AppleRemindersMCP.app ~/Applications/AppleRemindersMCP.app
```

`./scripts/build-pkg.sh` builds the release package, `dist/AppleRemindersMCP-<version>.pkg`, and its SHA-256 checksum. To publish a release:
1. Upload the package with `gh release create v<version> dist/AppleRemindersMCP-<version>.pkg dist/AppleRemindersMCP-<version>.pkg.sha256`.
2. Run `./scripts/update-cask.sh`. It checks that GitHub serves the same file. It then sets the new version and checksum in the Homebrew cask, in a checkout of [homebrew-tap](https://github.com/xiaofeng-han/homebrew-tap) (`../homebrew-tap` unless given another path), and commits and pushes.

The icon's source is the Icon Composer document `Resources/AppIcon.icon`. After changing it, run `./scripts/build-icon.sh` (it needs Xcode for `actool`) and commit `Resources/AppIcon-compiled`; ordinary builds only copy that folder. Draw the artwork as a full-bleed square, which macOS masks to its rounded shape: an icon that is transparent around its own shape is shown shrunk inside a grey tile. `swift scripts/flatten-icon.swift <icon.png> Resources/AppIcon.icon/Assets/artwork.png` turns an icon drawn as a rounded square on a transparent background into that artwork.

### Why the permission belongs to this app

macOS charges a child process's privacy permissions to its "responsible process". Claude Code and Claude Desktop have no Reminders usage description in their Info.plist, so programs they start directly are silently denied access to Reminders. The app therefore gives up that responsibility as soon as it starts and launches itself again under its own identity (`Sources/Launcher`), passing stdin and stdout through unchanged. That way the permission is granted once, to "Apple Reminders MCP", no matter what starts it.

So start it by its real path, or through a script that `exec`s it, as Homebrew's `apple-reminders-mcp` does. Do not start it through a symbolic link. From a link, macOS cannot find the app bundle, so the app does not launch itself again and the permission is charged to whatever started it.

### Recently Deleted

ReminderKit can restore a deleted reminder by id but cannot list deleted reminders, and once a reminder is deleted there is no way to find out which list it was in. So on every delete this tool writes a record to `~/Library/Application Support/AppleRemindersMCP/deleted.json` (id, title, original list; kept for 31 days), and `restore_reminder` uses it to restore to the original list by default. With Full Disk Access, `list_deleted` reads the Reminders database read-only and lists everything in Recently Deleted, including reminders deleted on other devices; restoring still goes through ReminderKit.

### Signing

`build-app.sh` signs with the self-signed certificate "Xiaofeng Local Code Signing" from the login keychain by default. The designated requirement is "bundle id + certificate", so permissions survive rebuilds; with ad-hoc signing every rebuild has to be granted again. Set `SIGNING_IDENTITY` to use a different certificate. To create this certificate on a new Mac:

```bash
/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -keyout key.pem -out cert.pem \
  -subj "/CN=Xiaofeng Local Code Signing" -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "Xiaofeng Local Code Signing" -out id.p12 -passout pass:temp
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P temp -T /usr/bin/codesign
rm key.pem id.p12
```

Use the system's `/usr/bin/openssl`. Homebrew's OpenSSL 3 exports p12 files with newer algorithms by default, which `security import` may fail to import (not tried here). It is normal for `security find-identity -p codesigning` to show `CSSMERR_TP_NOT_TRUSTED`; codesign can still sign with the certificate.

## Registering with clients

The app's AI Assistants tab, or `apple-reminders-mcp agents set-up`, does this for you (see [Setting up your agents](#setting-up-your-agents)). To do it by hand:

The command is `/opt/homebrew/bin/apple-reminders-mcp` after a Homebrew install, and `~/Applications/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP` after installing the package for yourself (`/Applications/…` for all users). Run it with `--stdio`. Give the full path: apps started from the Dock usually do not have `/opt/homebrew/bin` in their `PATH`. The server name is `apple-reminders`. The server supports MCP's session protocol (2024-11-05 to 2025-11-25) and the stateless 2026-07-28 protocol.

- Claude Code: `claude mcp add -s user apple-reminders -- <command> --stdio`
- Codex (`~/.codex/config.toml`, shared with the Codex app) and Grok Build (`~/.grok/config.toml`, plus `enabled = true`):

  ```toml
  [mcp_servers.apple-reminders]
  command = "/opt/homebrew/bin/apple-reminders-mcp"   # or "/Users/<you>/Applications/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP"
  args = ["--stdio"]
  ```

- Claude app (`~/Library/Application Support/Claude/claude_desktop_config.json`; quit Claude first), Gemini CLI (`~/.gemini/settings.json`) and Antigravity (`~/.gemini/config/mcp_config.json`): `"mcpServers": {"apple-reminders": {"command": "<command>", "args": ["--stdio"]}}`
- OpenCode (`~/.config/opencode/opencode.json`): `"mcp": {"servers": {"apple-reminders": {"type": "local", "command": ["<command>", "--stdio"]}}}`. OpenCode 1 before 1.18.24 only reads servers written directly under `mcp`, with `"enabled": true`.
- pi (`mcpServers` in `~/.pi/agent/mcp.json`): `{"type": "stdio", "command": "<command>", "args": ["--stdio"]}`

To install the skill by hand, save what `apple-reminders-mcp skill` prints as `apple-reminders/SKILL.md` in the agent's skills folder (see [Server or skill](#server-or-skill)).

To check: `claude mcp list`, `grok mcp doctor`, `pi mcp list`. For debugging, set `APPLE_REMINDERS_MCP_WIRE_LOG=<file>` to log every message sent and received.

## Tests

```bash
/usr/bin/python3 -I scripts/e2e.py
```

Runs every tool and rule over stdio, and the main command-line commands, 167 checks in all. The write guard (`APPLE_REMINDERS_MCP_WRITE_GUARD`, several names separated by commas; lists, groups, smart lists and templates all count) limits writes to a few throwaway names (`agent test`, `agent test 2`, …). The test first clears anything an interrupted run left behind, and at the end deletes what it created; its items remain in Recently Deleted. It temporarily changes the "complete repeating reminders" setting and restores the default when it finishes. The choice of tools comes from a throwaway file (`APPLE_REMINDERS_MCP_TOOLS_FILE`), so yours is neither used nor changed.

`swift test` checks the agent setup and the command line, in throwaway folders:
- the JSON and TOML editing that keeps the rest of a file as it was;
- how each agent's settings are read and written;
- where each agent's skill goes;
- how command-line flags are read from the tools' input schemas;
- the choice of tools: the rule for tools the file doesn't name, saving, reading and watching the file, and what the server lists, refuses and announces.

## Not possible

- Inviting people to a shared list: that needs iCloud's sharing interface, which a program cannot complete on the user's behalf.
- Reading a reminder's manual order in its list: the order can be changed, but reminders are read back without it.
- Smart list conditions this tool does not know (for example ones the system adds later): `list_lists` returns them unchanged in `filters.other`, but the tools cannot change them.
