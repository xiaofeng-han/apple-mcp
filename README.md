# Apple Reminders MCP

**English** | [简体中文](README.zh-CN.md)

An MCP server that lets AI agents (Claude Code, Codex, Grok Build, pi, …) fully read and write Reminders on macOS.

Writes go through Apple's private ReminderKit framework, the same path Reminders.app itself uses. So everything below is native and shows up correctly on iPhone too:
- Reminders: flags, real tags, subtasks, Urgent (rings like an alarm), repeats, early reminders, location and getting in or out of the car, "when messaging a person", links, images, assignment in shared lists, and ordering;
- Lists: sections, groups, color and icon, pinning, grocery lists, sort order, templates, and smart lists.

Once saved, the system's remindd syncs changes to iCloud on its own. The only privacy permission needed is Reminders. Full Disk Access is optional and only used for reading: to list everything in Recently Deleted, and to read images on reminders.

Requires macOS 26 or later; developed and tested on macOS 27.0.1. All code is written for this project, with no third-party dependencies.

## Tools

| Tool | What it does |
|---|---|
| `list_lists` | Lists (open and total counts, default, pinned, kind, group, color, icon, sort order, sections, members of shared lists), groups, smart lists (with their filters), and templates |
| `find_reminders` | Searches across lists: by list, section, keyword, completed, flagged, urgent, repeating, has a location alert, assignee, tags, and due window (`due_before` excludes that day) |
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

## Install

Download `AppleRemindersMCP-<version>.pkg` from [Releases](https://github.com/xiaofeng-han/apple-reminders-mcp/releases) and open it, or install it from the terminal:

```bash
gh release download v0.1.0 -R xiaofeng-han/apple-reminders-mcp -p '*.pkg'
installer -pkg AppleRemindersMCP-0.1.0.pkg -target CurrentUserHomeDirectory
```

Installing for yourself only puts the app in `~/Applications` without an administrator password, and the commands below assume it is there. Releases are built for Apple silicon. The package has no Developer ID signature: if macOS refuses to open one downloaded in a browser, allow it under System Settings → Privacy & Security.

Then allow access to Reminders:

```bash
~/Applications/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP setup
```

`setup` shows a permission dialog (it may be hidden behind other windows); click Allow. To check the status:

```bash
~/Applications/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP --self-check
```

Opening the app directly (double-clicking it, or starting it with `--settings`) shows the settings window. It shows the status of both permissions and a switch, on by default, that allows AI assistants to complete repeating reminders (the window's labels are in Chinese). The switch can also be set from the command line:

```bash
defaults write com.xiaofeng.apple-reminders-mcp AllowCompletingRecurringReminders -bool NO
```

Full Disk Access has to be added by hand: System Settings → Privacy & Security → Full Disk Access, click +, and choose `~/Applications/AppleRemindersMCP.app`.

### Build from source

```bash
./scripts/build-app.sh
ditto dist/AppleRemindersMCP.app ~/Applications/AppleRemindersMCP.app
```

`./scripts/build-pkg.sh` builds the release package, `dist/AppleRemindersMCP-<version>.pkg`, and its SHA-256 checksum.

### Why the permission belongs to this app

macOS charges a child process's privacy permissions to its "responsible process". Claude Code and Claude Desktop have no Reminders usage description in their Info.plist, so programs they start directly are silently denied access to Reminders. The app therefore gives up that responsibility as soon as it starts and launches itself again under its own identity (`Sources/Launcher`), passing stdin and stdout through unchanged. That way the permission is granted once, to "Apple Reminders MCP", no matter what starts it.

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

The command is always `~/Applications/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP --stdio`, and the server name is `apple-reminders`. The server supports MCP's session protocol (2024-11-05 to 2025-11-25) and the stateless 2026-07-28 protocol.

- Claude Code: `claude mcp add -s user apple-reminders -- <command> --stdio`
- Codex (`~/.codex/config.toml`, shared with the Codex app) and Grok Build (`~/.grok/config.toml`, plus `enabled = true`):

  ```toml
  [mcp_servers.apple-reminders]
  command = "/Users/<you>/Applications/AppleRemindersMCP.app/Contents/MacOS/AppleRemindersMCP"
  args = ["--stdio"]
  ```

- pi (`mcpServers` in `~/.pi/agent/mcp.json`): `{"type": "stdio", "command": "<command>", "args": ["--stdio"]}`

To check: `claude mcp list`, `grok mcp doctor`, `pi mcp list`. For debugging, set `APPLE_REMINDERS_MCP_WIRE_LOG=<file>` to log every message sent and received.

## Tests

```bash
/usr/bin/python3 -I scripts/e2e.py
```

Runs every tool and rule over stdio, 121 checks in all. The write guard (`APPLE_REMINDERS_MCP_WRITE_GUARD`, several names separated by commas; lists, groups, smart lists and templates all count) limits writes to a few throwaway names (`agent test`, `agent test 2`, …). The test first clears anything an interrupted run left behind, and at the end deletes what it created; its items remain in Recently Deleted. It temporarily changes the "complete repeating reminders" setting and restores the default when it finishes.

## Not possible

- Inviting people to a shared list: that needs iCloud's sharing interface, which a program cannot complete on the user's behalf.
- Reading a reminder's manual order in its list: the order can be changed, but reminders are read back without it.
- Smart list conditions this tool does not know (for example ones the system adds later): `list_lists` returns them unchanged in `filters.other`, but the tools cannot change them.
