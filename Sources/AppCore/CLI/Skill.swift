import Agents
import Foundation
import Wire

/// What an app writes in its skill: the description agents match requests against, and the text
/// before the command reference (title, how to run the command, examples, rules).
public struct SkillText: Sendable {
    public let description: String
    public let body: String

    public init(description: String, body: String) {
        self.description = description
        self.body = body
    }
}

/// The Agent Skill that teaches an agent the command line, for agents set up with a skill instead
/// of the server. It names this copy's command by its full path (apps started from the Dock lack
/// /opt/homebrew/bin in PATH) and lists the commands with their flags, made from the same routes
/// and schemas as the commands themselves. It holds no version number, so a newer app marks it out
/// of date only when the text changes.
enum Skill {
    static func text(for installation: Installation, cli: CLI, tools: [Tool], text: (_ run: String) -> SkillText) -> String {
        let command = installation.command
        let run = command.contains(" ") ? "\"\(command)\"" : command
        var reference: [String] = []
        for noun in cli.nouns {
            reference.append("")
            reference.append("### \(noun)")
            for route in cli.routes where route.noun == noun {
                guard let tool = tools.first(where: { $0.name == route.tool }) else { continue }
                let flags = route.flags(tool)
                let usage = [route.command, flags.requiredUsage].filter { !$0.isEmpty }.joined(separator: " ")
                reference.append("")
                reference.append("- `\(usage)`: \(route.about)." + (route.detail.map { " \($0)" } ?? ""))
                // update takes create's flags too; only the others are listed, and which fields clear.
                var listed = cli.skillListsRequired ? flags.options : flags.optional
                if route.verb == "update", let create = cli.routes.first(where: { $0.noun == noun && $0.verb == "create" }),
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
        let skill = text(run)
        return """
            ---
            name: \(SkillTarget.name)
            description: \(skill.description)
            metadata:
              \(SkillTarget.marker)
              command: \(JSON.string(command).text)
            ---

            \(skill.body)

            ## Commands
            \(reference.joined(separator: "\n"))

            """
    }
}
