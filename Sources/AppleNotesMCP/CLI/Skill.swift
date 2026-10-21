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
                let options = flags.optional.map { option -> String in
                    var line = "`\(option.usage)`"
                    if !option.about.isEmpty { line += " \(option.about)" }
                    if !option.fields.isEmpty { line += " {" + option.fields.map { "\($0.name): \($0.about)" }.joined(separator: "; ") + "}" }
                    return line
                } + route.extra.map { "`\($0.0)` \($0.1)" }
                for option in options { reference.append("  - \(option)") }
            }
        }
        return """
            ---
            name: \(SkillTarget.name)
            description: Read and change the user's Apple Notes on this Mac (notes, folders and attachments, synced through iCloud to their devices) by running the apple-notes-mcp command. Use when the user asks about their notes or Apple Notes.
            metadata:
              \(SkillTarget.marker)
              command: \(JSON.string(command).text)
            ---

            # Apple Notes

            Run `\(run)` followed by a command, by that full path. It prints the answer as text, often Markdown. Exit status 1 means the request failed (not found, changed since it was read, not allowed); the reason is on stderr. Exit status 2 means the command or a flag was wrong; add `--help` to any command for its flags.

            ```sh
            \(run) notes search "tax return"
            \(run) notes read ID
            \(run) notes edit ID --insert "- [ ] Call the bank" --at "To do"
            \(run) notes create - --folder Projects <<'EOF'
            # Trip plan
            - [ ] Book the train
            EOF
            ```

            ## Rules

            - Find notes with `notes list` (newest first; `--folder`, dates) or `notes search QUERY`, then `notes read ID`, which prints each note as Markdown with its `version`. `folders list` shows the folders.
            - Make all changes to one note in a single `notes edit ID` call: `--replace '[{"old":"…","new":"…"}]'` takes exact Markdown from `notes read`, `--insert` adds Markdown (`--at` start, end or a heading's text), and `--rewrite` replaces the whole note and needs `--version`. A note changed elsewhere since it was read is refused; read it again.
            - Each paragraph is one Markdown line: `# title`, `## heading`, `### subheading`, `*` and `-` lists, `1.` numbered, `- [ ]` / `- [x]` checkboxes, `>` quote, two spaces per indent level, ``` monospaced, `**bold**`, `*italic*`, `~~strike~~`, `<u>underline</u>`, `<mark>highlight</mark>`, `[link](url)`, `| tables |`. The first line of a new note is its title.
            - Keep `![…](attachment:…)` placeholders where they are. `attachments read ID` prints what can be read from one and saves its images, audio and files, printing where.
            - `-` as the Markdown of `notes create`, or as `--insert` or `--rewrite`, reads it from stdin: use a quoted heredoc for notes of several lines.
            - Moving a note into or out of a shared folder, or renaming a shared folder, changes who sees it: ask the user, then add `--allow-shared`.
            - Deleting moves notes to Recently Deleted, and `notes move ID FOLDER` brings one back. Ask the user before deleting a folder with what is in it (`folders delete FOLDER --recursive --expected-notes N`); `folders export` keeps a copy first.
            - To describe many notes: `notes list --undescribed`, then one `notes describe --descriptions '[{"id":"…","description":"…"}]'`.
            - Every command also takes `--json '{...}'` (or `--json -` to read it from stdin) with the fields by their snake_case names; flags override it.
            - Agents that run commands in a sandbox (Codex does) cannot reach Notes from it: when the command says it ran inside a sandbox, run it again outside the sandbox, which the user may have to approve.
            - If the command says it lacks Full Disk Access or may not control Notes, ask the user to run `\(run) setup` in a terminal.

            ## Commands
            \(reference.joined(separator: "\n"))

            """
    }
}
