---
name: apple-reminders
description: Read and change the user's Apple Reminders on this Mac (reminders, lists, tags, subtasks, sections, groups, smart lists and templates, synced through iCloud to their devices) by running the apple-reminders-mcp command. Use when the user asks about reminders, to-dos, or their Reminders lists.
metadata:
  generated-by: apple-reminders-mcp
  command: "<EXECUTABLE>"
---

# Apple Reminders

Run `<EXECUTABLE>` followed by a command, by that full path. It prints the answer as JSON, sometimes after a short lead such as `Created.`. Exit status 1 means the request failed (not found, changed since it was read, not allowed); the reason is on stderr. Exit status 2 means the command or a flag was wrong; add `--help` to any command for its flags.

```sh
<EXECUTABLE> reminders find --due-before 2026-10-22
<EXECUTABLE> reminders create "Buy milk" --list Groceries --due 2026-10-21T09:00 --tag errands
<EXECUTABLE> reminders update ID --version VERSION --completed
```

## Rules

- Read before you change: `reminders find` or `reminders get ID` gives each reminder's `id` and `version`. `reminders update` and `reminders delete` need both, and refuse a reminder that was changed elsewhere since it was read; read it again.
- Times are the Mac's local time: `--due 2026-10-21` is all day, `--due 2026-10-21T09:00` adds an alert then. `reminders find` gives `now` and `time_zone`; `--due-before` is exclusive.
- `--urgent` makes the alert ring like an alarm and needs a due time; `--repeat` and `--early-alerts` need a due date.
- Tags are native, written without `#`; `--tag` repeats, and on update replaces all tags. Subtasks are one level deep (`--parent-id`). Sections divide a list.
- On `reminders update`, `--no-FIELD` clears a field (`--no-due`) and `--no-completed` reopens a reminder.
- JSON values go in single quotes: `--repeat '{"frequency":"weekly","days_of_week":["mon"]}'`, `--early-alerts '[{"before":15,"unit":"minutes"}]'`, `--location getting-in-car`.
- Lists marked `"shared": true` are seen by other people: confirm with the user before adding to or changing them; assign with `--assigned-to`.
- Deleting moves reminders to Recently Deleted: `reminders deleted` lists them, `reminders restore ID` brings one back. Ask the user before deleting a list.
- Every command also takes `--json '{...}'` (or `--json -` to read it from stdin) with the fields by their snake_case names; flags override it.
- Agents that run commands in a sandbox (Codex does) cannot reach Reminders from it: when the command says it ran inside a sandbox, run it again outside the sandbox, which the user may have to approve.
- If Reminders access is missing, ask the user to run `<EXECUTABLE> setup` in a terminal.

## Commands

### reminders

- `reminders find [QUERY]`: Find reminders across lists, open ones first by due date; QUERY matches the title or notes. Filters combine. --due-before is exclusive: --due-before with tomorrow's date gives everything due today or overdue. Each reminder appears once, with smart_lists naming the smart lists that show it. The answer also gives now and time_zone.
  - `--assigned-to string` Only reminders assigned to this person (name, or me)
  - `--due-after string` 2026-10-21 or 2026-10-21T09:00, inclusive
  - `--due-before string` 2026-10-21 or 2026-10-21T09:00, exclusive
  - `--[no-]flagged` Only flagged
  - `--[no-]has-location` Only reminders with a place or car alert
  - `--[no-]include-completed` Default false
  - `--limit int` Default 100, at most 500
  - `--list string` List name or id; default all lists
  - `--[no-]repeating` Only repeating
  - `--section string` Only this section
  - `--smart-list string` Only what this smart list shows (name or id), as Reminders computes it
  - `--tag string` Only this tag (without #)
  - `--[no-]urgent` Only urgent

- `reminders get ID`: Read one reminder in full: alarms, early alerts, images, subtasks, and its current version.

- `reminders create TITLE`: Create a reminder; without --list it goes to the default list (or the parent's list).
  - `--add-image string…` Image files on this Mac to attach
  - `--after string` Put it after this: Reminder id
  - `--assigned-to string` On a shared list: a person's name (or me)
  - `--before string` Put it before this: Reminder id
  - `--due string` 2026-10-21 (all day) or 2026-10-21T09:00 (local time); a time adds an alert then
  - `--early-alerts json` Early reminders, replacing any there are {before: How long before the due date; unit: minutes|hours|days|weeks|months. Default minutes}
  - `--[no-]flagged` Flag
  - `--list string` List name or id
  - `--location json|string` Alert at a place, {title, latitude, longitude, radius (meters, default 100), address, when: arriving|leaving}, or getting-in-car, getting-out-of-car; replaces any place alert
  - `--notes string` Plain text
  - `--parent-id string` Makes it a subtask of this top-level reminder in the same list
  - `--priority none|low|medium|high` Priority
  - `--repeat json` Repeats from the due date {count: Number of times, instead of until; days_of_month: 1 … 31, or -1 for the last day; days_of_week: mon … sun; for monthly or yearly, 1mon is the first Monday and -1fri the last Friday; frequency: daily|weekly|monthly|yearly|hourly. How often; interval: Every n periods; default 1; months: 1 … 12, for yearly; until: Last date, 2026-12-31}
  - `--section string` Section name or id in the reminder's list
  - `--start string` Start date, same format as due
  - `--tag string…` Native tags without #; replaces all tags
  - `--[no-]urgent` Alarm-style alert that rings like an alarm on the user's devices; needs a due time
  - `--url string` A link shown on the reminder
  - `--when-messaging json` A JSON object {emails: Email addresses; phones: Phone numbers}

- `reminders update ID --version string`: Change only the fields given; --no-FIELD clears one. Pass the --version that find or get gave; a reminder changed elsewhere since then is refused, so read it again. --completed checks it off: a repeating reminder leaves a completed copy and moves to its next date (unless that is turned off in the app's settings). --list moves it to another list.
  - Every flag of `reminders create`; to clear a field: `--no-assigned-to`, `--no-due`, `--no-early-alerts`, `--no-location`, `--no-parent-id`, `--no-repeat`, `--no-section`, `--no-start`, `--no-url`, `--no-when-messaging`
  - `--version string` Version you read (required)
  - `--[no-]completed` Check off or reopen
  - `--remove-image string…` Image ids to remove
  - `--title string` New title

- `reminders delete ID --version string`: Move a reminder and its subtasks to Recently Deleted.
  - `--version string` Version you read (required)

- `reminders deleted`: List reminders in Recently Deleted that restore can bring back, newest first. With Full Disk Access for the app this is everything in Recently Deleted; without it, what this app deleted.

- `reminders restore ID`: Bring a reminder back from Recently Deleted, with the subtasks deleted along with it. Without --list it returns to the list it was deleted from, or the default list.
  - `--list string` List name or id to restore into

- `reminders image REMINDER_ID IMAGE_ID`: Save an image on a reminder (ids from get) and print where; needs Full Disk Access.
  - `--output string` Where to save the image; default a file in the temporary folder

### lists

- `lists list`: The lists (with counts, sections and the people on shared ones), groups, smart lists and templates.

- `lists create NAME`: Create a list.
  - `--color string` red, orange, yellow, green, light-blue, blue, indigo, pink, purple, brown, gray, rose, or #RRGGBB
  - `--icon string` An emoji, or an emblem name such as nature2; empty for the default
  - `--group string` Group name or id to put it in
  - `--[no-]pinned` Pin to the top of the sidebar
  - `--type standard|groceries` List type
  - `--sort string` How Reminders sorts the list
  - `--after string` Put it after this: List name or id
  - `--before string` Put it before this: List name or id

- `lists update LIST`: Change a list's name, color, icon, group, pin, type, sort order or place in the sidebar. A groceries list sorts its items into aisles.
  - Every flag of `lists create`; to clear a field: `--no-group`
  - `--new-name string` New name

- `lists clear-completed LIST`: Move a list's completed reminders to Recently Deleted.

- `lists delete LIST`: Delete a list; one with reminders needs --confirm-delete-reminders (ask the user first). Its reminders go to Recently Deleted.
  - `--[no-]confirm-delete-reminders` Delete a list that still has reminders

### groups

- `groups create NAME`: Create a group, which holds lists in the sidebar (put lists in it with lists update --group).

- `groups rename GROUP NEW_NAME`: Rename a group.

- `groups delete GROUP`: Delete an empty group.

### sections

- `sections create LIST NAME`: Create a section in a list (put reminders in it with --section).

- `sections rename LIST SECTION NEW_NAME`: Rename a section.

- `sections move LIST SECTION (--after string | --before string)`: Move a section next to another one.
  - `--after string` Put it after this: Section name (required)
  - `--before string` Put it before this: Section name (required)

- `sections delete LIST SECTION`: Delete a section; its reminders stay in the list.

### smart-lists

- `smart-lists create NAME --filters json`: Create a smart list, which shows the reminders matching its filters.
  - `--filters json` A JSON object (required) {date: today, none, {before|on|after: "2026-10-21"}, {from: date, until: date}, or {next|past: 10, unit: hour|day|week|month|year, include_past_due: bool}; flagged: Flagged or not flagged; lists: {include: [list names or ids]} or {exclude: [...]}; location: none, getting-in-car, getting-out-of-car, or {latitude, longitude, radius, title, when: arriving|leaving}; priorities: low|medium|high. Any of these priorities; tags: any, untagged, or {include: [tags], exclude: [tags], match: all|any}; time: morning|afternoon|evening|night|none. Time of day of the due time}
  - `--match all|any` Whether a reminder must match all filters or any; default all
  - `--color string` red, orange, yellow, green, light-blue, blue, indigo, pink, purple, brown, gray, rose, or #RRGGBB
  - `--icon string` An emoji, or an emblem name such as nature2; empty for the default

- `smart-lists update SMART_LIST`: Change a smart list's name, color, icon, match or filters (--filters replaces them all).
  - Every flag of `smart-lists create`
  - `--new-name string` New name

- `smart-lists delete SMART_LIST`: Delete a smart list; no reminders are deleted.

### tags

- `tags list`: Every tag in use, with how many open and how many reminders in all have it.

- `tags rename TAG NEW_NAME`: Rename a tag on every reminder that has it, merging into a tag of that name if there is one.

- `tags delete TAG`: Remove a tag from every reminder.

### templates

- `templates create NAME --list string`: Save a list as a template (Reminders copies its reminders in the background).
  - `--list string` The list to save (name or id) (required)
  - `--[no-]include-completed` Keep completed reminders too; default false

- `templates use TEMPLATE`: Make a new list from a template.
  - `--list string` The new list's name; default the template's

- `templates delete TEMPLATE`: Delete a template.
