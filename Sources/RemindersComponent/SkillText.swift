import AppCore

/// The skill's own text; the base adds the frontmatter and the command reference (see AppCore's Skill).
extension RemindersComponent {
    nonisolated public static func skill(run: String) -> SkillText {
        SkillText(
            description: "Read and change the user's Apple Reminders on this Mac (reminders, lists, tags, subtasks, sections, groups, smart lists and templates, synced through iCloud to their devices) by running the apple-reminders-mcp command. Use when the user asks about reminders, to-dos, or their Reminders lists.",
            body: """
                # Apple Reminders

                Run `\(run)` followed by a command, by that full path. It prints the answer as JSON, sometimes after a short lead such as `Created.`. Exit status 1 means the request failed (not found, changed since it was read, not allowed); the reason is on stderr. Exit status 2 means the command or a flag was wrong; add `--help` to any command for its flags.

                ```sh
                \(run) reminders find --due-before 2026-10-22
                \(run) reminders create "Buy milk" --list Groceries --due 2026-10-21T09:00 --tag errands
                \(run) reminders update ID --version VERSION --completed
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
                - If Reminders access is missing, ask the user to run `\(run) setup` in a terminal.
                """)
    }
}
