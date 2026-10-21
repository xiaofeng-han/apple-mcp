import Agents
import Foundation
import Wire

/// The Agent Skill that teaches an agent the command line, for agents set up with a skill instead
/// of the server. It names this copy's command by its full path (apps started from the Dock lack
/// /opt/homebrew/bin in PATH) and lists the commands with their flags, made from the same routes
/// and schemas as the commands themselves. It holds no version number, so a newer app marks it out
/// of date only when the text changes.
enum Skill {
    static func text(for installation: Installation) -> String {
        let command = installation.command
        let run = command.contains(" ") ? "\"\(command)\"" : command
        var reference: [String] = []
        for noun in Commands.nouns {
            reference.append("")
            reference.append("### \(noun)")
            for route in Commands.routes where route.noun == noun {
                guard let tool = tools.first(where: { $0.name == route.tool }) else { continue }
                let flags = route.flags(tool)
                let usage = [route.command, flags.requiredUsage].filter { !$0.isEmpty }.joined(separator: " ")
                reference.append("")
                reference.append("- `\(usage)`: \(route.about)." + (route.detail.map { " \($0)" } ?? ""))
                // update takes create's flags too; only the others are listed, and which fields clear.
                var listed = flags.options
                if route.verb == "update", let create = Commands.routes.first(where: { $0.noun == noun && $0.verb == "create" }),
                    let createTool = tools.first(where: { $0.name == create.tool })
                {
                    let shared = Set(create.flags(createTool).options.map(\.name))
                    let clearing = listed.filter { $0.clearable && $0.kind != .flag }.map { "--no-\($0.name)" }
                    listed.removeAll { shared.contains($0.name) }
                    reference.append("  - Every flag of `\(create.command)`" + (clearing.isEmpty ? "" : "; to clear a field: " + clearing.map { "`\($0)`" }.joined(separator: ", ")))
                }
                let options = listed.map { option -> String in
                    var line = "`\(option.usage)`"
                    if !option.about.isEmpty { line += " \(option.about)" }
                    if option.required { line += " (required)" }
                    if !option.fields.isEmpty { line += " {" + option.fields.map { "\($0.name): \($0.about)" }.joined(separator: "; ") + "}" }
                    return line
                } + route.extra.map { "`\($0.0)` \($0.1)" }
                for option in options { reference.append("  - \(option)") }
            }
        }
        return """
            ---
            name: \(SkillTarget.name)
            description: Read and change the user's Apple Reminders on this Mac (reminders, lists, tags, subtasks, sections, groups, smart lists and templates, synced through iCloud to their devices) by running the apple-reminders-mcp command. Use when the user asks about reminders, to-dos, or their Reminders lists.
            metadata:
              \(SkillTarget.marker)
              command: \(JSON.string(command).text)
            ---

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

            ## Commands
            \(reference.joined(separator: "\n"))

            """
    }
}
