import Foundation

/// Where an agent looks for Agent Skills: a folder of its own that every project sees, or one
/// inside a project. This app's skill is `apple-reminders/SKILL.md` there. Several agents can
/// share a folder (most read ~/.agents/skills).
public enum SkillTarget: String, Sendable, CaseIterable {
    /// Claude Code and the Code tab of the Claude app: ~/.claude/skills (CLAUDE_CONFIG_DIR moves
    /// it), and .claude/skills in a project.
    case claude
    /// ~/.agents/skills, which Codex (and the ChatGPT app), OpenCode and pi read.
    case agents
    /// Gemini CLI: ~/.agents/skills, under GEMINI_CLI_HOME when that is set.
    case gemini
    /// Grok Build: ~/.grok/skills (GROK_HOME moves it). It also reads .agents/skills in projects.
    case grok
    /// The Antigravity app: ~/.gemini/config/skills.
    case antigravity
    /// The Antigravity CLI: ~/.gemini/antigravity-cli/skills.
    case antigravityCLI

    public static let name = "apple-reminders"
    /// In the skill's frontmatter: a skill without it is someone else's, and is left alone.
    public static let marker = "generated-by: apple-reminders-mcp"

    /// The skill's file, in the agent's own folder or, with `project`, in that project.
    public func file(project: URL? = nil, home: URL = Shell.home) -> URL {
        folder(project: project, home: home).appendingPathComponent(Self.name, isDirectory: true).appendingPathComponent("SKILL.md")
    }

    func folder(project: URL?, home: URL) -> URL {
        if let project { return project.appendingPathComponent(self == .claude ? ".claude/skills" : ".agents/skills", isDirectory: true) }
        func folder(_ variable: String, _ fallback: String) -> URL {
            Shell.relocated(variable, home: home) ?? home.appendingPathComponent(fallback, isDirectory: true)
        }
        switch self {
        case .claude: return folder("CLAUDE_CONFIG_DIR", ".claude").appendingPathComponent("skills", isDirectory: true)
        case .agents: return home.appendingPathComponent(".agents/skills", isDirectory: true)
        case .gemini: return (Shell.relocated("GEMINI_CLI_HOME", home: home) ?? home).appendingPathComponent(".agents/skills", isDirectory: true)
        case .grok: return folder("GROK_HOME", ".grok").appendingPathComponent("skills", isDirectory: true)
        case .antigravity: return home.appendingPathComponent(".gemini/config/skills", isDirectory: true)
        case .antigravityCLI: return home.appendingPathComponent(".gemini/antigravity-cli/skills", isDirectory: true)
        }
    }

    /// Whether the skill there is `skill`. One this app wrote for another copy or an older
    /// version is `different` (or `broken`, when its command is gone); a skill of the same name
    /// that this app did not write is `notEditable`.
    public func registration(of skill: String, project: URL? = nil, home: URL = Shell.home) -> Registration {
        let url = file(project: project, home: home)
        do {
            guard let text = try ConfigFile.read(url) else { return .missing }
            if text == skill { return .current }
            guard Self.frontmatter(text).contains(Self.marker) else {
                return .notEditable("\(url.path) is another skill named \(Self.name)")
            }
            let command = Self.command(in: text) ?? ""
            if command.hasPrefix("/"), !FileManager.default.isExecutableFile(atPath: command) { return .broken(command: command) }
            return .different(command: command)
        } catch {
            return .unreadable("\(url.path): \(error)")
        }
    }

    /// Writes the skill, replacing one this app wrote before. Returns where.
    @discardableResult
    public func install(_ skill: String, project: URL? = nil, home: URL = Shell.home) throws -> URL {
        if let project {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isFolder), isFolder.boolValue else {
                throw ConfigError("\(project.path) is not a folder")
            }
        }
        if case .notEditable(let reason) = registration(of: skill, project: project, home: home) { throw ConfigError(reason) }
        let url = file(project: project, home: home)
        try ConfigFile.update(url, backUp: false) { _ in skill }
        return url
    }

    /// The lines between the opening and closing `---`.
    static func frontmatter(_ text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [] }
        return Array(lines[1..<end])
    }

    /// The command a skill this app wrote runs: `command: "/path"` in its frontmatter.
    static func command(in text: String) -> String? {
        guard let line = frontmatter(text).first(where: { $0.hasPrefix("command:") }) else { return nil }
        let value = line.dropFirst("command:".count).trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("\"") ? (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)) as? String : value
    }
}
