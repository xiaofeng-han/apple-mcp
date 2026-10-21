import Foundation

/// Whether an agent's config has this server, as the name `apple-reminders`.
public enum Registration: Sendable, Equatable {
    /// Not there.
    case missing
    /// There, starting this copy with --stdio.
    case current
    /// There, but with another command or other arguments (an older install, say).
    case different(command: String)
    /// There, but its command does not exist any more.
    case broken(command: String)
    /// There, but turned off.
    case disabled
    /// The config file could not be read.
    case unreadable(String)
    /// There, but written in a form this app does not change (a TOML inline table, say).
    case notEditable(String)

    public static let serverName = "apple-reminders"

    /// Judges an entry's command and arguments against what this copy needs.
    static func judge(command: String?, arguments: [String]?, enabled: Bool = true, for installation: Installation) -> Registration {
        guard let command, !command.isEmpty else { return .different(command: "") }
        if command == installation.command, arguments ?? [] == installation.arguments {
            return enabled ? .current : .disabled
        }
        let path = (command as NSString).expandingTildeInPath
        if path.hasPrefix("/"), !FileManager.default.isExecutableFile(atPath: path) { return .broken(command: command) }
        return .different(command: ([command] + (arguments ?? [])).joined(separator: " "))
    }
}

/// Where and how an agent keeps its MCP servers. Several agents can share one (an agent's app and
/// its command-line tool, say).
public enum ConfigTarget: String, Sendable, CaseIterable {
    case claudeCode, claudeDesktop, codex, grok, opencode, gemini, antigravity

    /// The file that holds the servers. Variables that move config folders are followed when set
    /// here or in the login shell, unless `home` is another folder than the user's (a test's).
    public func file(home: URL = Shell.home) -> URL {
        let manager = FileManager.default
        func variable(_ name: String) -> URL? { Shell.relocated(name, home: home) }
        func folder(_ name: String, _ fallback: String) -> URL {
            variable(name) ?? home.appendingPathComponent(fallback, isDirectory: true)
        }
        switch self {
        case .claudeCode:
            // A non-empty .config.json from older versions takes precedence over .claude.json.
            let directory = variable("CLAUDE_CONFIG_DIR")
            let legacy = (directory ?? home.appendingPathComponent(".claude", isDirectory: true)).appendingPathComponent(".config.json")
            if let size = (try? manager.attributesOfItem(atPath: legacy.path))?[.size] as? Int, size > 0 { return legacy }
            return (directory ?? home).appendingPathComponent(".claude.json")
        case .claudeDesktop:
            // Third-party deployments of Claude keep their data in Claude-3p.
            let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
            let thirdParty = support.appendingPathComponent("Claude-3p/claude_desktop_config.json")
            let standard = support.appendingPathComponent("Claude/claude_desktop_config.json")
            return manager.fileExists(atPath: thirdParty.path) && !manager.fileExists(atPath: standard.path) ? thirdParty : standard
        case .codex:
            return folder("CODEX_HOME", ".codex").appendingPathComponent("config.toml")
        case .grok:
            return folder("GROK_HOME", ".grok").appendingPathComponent("config.toml")
        case .opencode:
            let directory = variable("OPENCODE_CONFIG_DIR") ?? folder("XDG_CONFIG_HOME", ".config").appendingPathComponent("opencode", isDirectory: true)
            // opencode.jsonc overrides opencode.json, so an entry there wins.
            let jsonc = directory.appendingPathComponent("opencode.jsonc")
            return manager.fileExists(atPath: jsonc.path) ? jsonc : directory.appendingPathComponent("opencode.json")
        case .gemini:
            return folder("GEMINI_CLI_HOME", "").appendingPathComponent(".gemini/settings.json")
        case .antigravity:
            return home.appendingPathComponent(".gemini/config/mcp_config.json")
        }
    }

    /// Where Gemini CLI records servers turned off with `gemini mcp disable`.
    func geminiEnablementFile(home: URL) -> URL {
        file(home: home).deletingLastPathComponent().appendingPathComponent("mcp-server-enablement.json")
    }

    var isTOML: Bool { self == .codex || self == .grok }

    var tomlTable: [String] { ["mcp_servers", Registration.serverName] }

    /// Where the entry is in a JSON file. OpenCode 2 keeps servers under mcp.servers; OpenCode 1
    /// keeps them directly under mcp (and reads mcp.servers too from 1.18.24).
    var jsonPaths: [[String]] {
        switch self {
        case .opencode: [["mcp", "servers", Registration.serverName], ["mcp", Registration.serverName]]
        default: [["mcpServers", Registration.serverName]]
        }
    }

    /// The entry for this copy, in the file's format.
    func entry(for installation: Installation, at path: [String] = []) -> ConfigValue {
        let command = ConfigValue.string(installation.command)
        let arguments = ConfigValue.array(installation.arguments.map(ConfigValue.string))
        switch self {
        case .claudeCode:
            return .object([("type", .string("stdio")), ("command", command), ("args", arguments), ("env", .object([]))])
        case .opencode:
            var fields: [(String, ConfigValue)] = [("type", .string("local")),
                                                   ("command", .array(([installation.command] + installation.arguments).map(ConfigValue.string)))]
            if path.count == 2 { fields.append(("enabled", .bool(true))) }
            return .object(fields)
        default:
            return .object([("command", command), ("args", arguments)])
        }
    }

    /// Reads the entry and judges it.
    public func registration(for installation: Installation, home: URL = Shell.home) -> Registration {
        let url = file(home: home)
        do {
            guard let text = try ConfigFile.read(url) else { return .missing }
            if isTOML {
                let document = try TOMLText(text)
                // Grok also turns servers off by listing them at the top of the file.
                let listedOff = (document.value("disabled_mcp_servers", in: []) as? [String])?.contains(Registration.serverName) == true
                guard document.hasTable(tomlTable) else {
                    guard document.isWrittenInline(tomlTable) else { return .missing }
                    let inline = document.inlineTable(tomlTable)
                    let judged = Registration.judge(command: inline?["command"] as? String, arguments: inline?["args"] as? [String],
                                                    enabled: inline?["enabled"] as? Bool ?? true && !listedOff, for: installation)
                    return judged == .current ? .current : .notEditable("\(url.path) writes [\(TOMLText.header(tomlTable))] in a form this app does not change")
                }
                return Registration.judge(command: document.value("command", in: tomlTable) as? String,
                                          arguments: document.value("args", in: tomlTable) as? [String],
                                          enabled: document.value("enabled", in: tomlTable) as? Bool ?? true && !listedOff, for: installation)
            }
            let document = JSONText(text)
            guard let path = try jsonPaths.first(where: { try document.value(at: $0) != nil }),
                let entry = try document.value(at: path) as? [String: Any]
            else { return .missing }
            switch self {
            case .opencode:
                let command = entry["command"] as? [String] ?? []
                let enabled = entry["enabled"] as? Bool ?? true && !(entry["disabled"] as? Bool ?? false)
                return Registration.judge(command: command.first, arguments: Array(command.dropFirst()), enabled: enabled, for: installation)
            case .gemini:
                let excluded = (try document.value(at: ["mcp", "excluded"]) as? [String])?.contains(Registration.serverName) == true
                let allowed = (try document.value(at: ["mcp", "allowed"]) as? [String])?.contains(Registration.serverName) ?? true
                let switchedOff = try geminiSwitchedOff(home: home)
                return Registration.judge(command: entry["command"] as? String, arguments: entry["args"] as? [String],
                                          enabled: !excluded && allowed && !switchedOff, for: installation)
            default:
                return Registration.judge(command: entry["command"] as? String, arguments: entry["args"] as? [String],
                                          enabled: !(entry["disabled"] as? Bool ?? false), for: installation)
            }
        } catch {
            return .unreadable("\(url.path): \(error)")
        }
    }

    /// Whether `gemini mcp disable` turned the server off.
    func geminiSwitchedOff(home: URL) throws -> Bool {
        guard let text = try ConfigFile.read(geminiEnablementFile(home: home)) else { return false }
        return try JSONText(text).value(at: [Registration.serverName, "enabled"]) as? Bool == false
    }

    /// Writes this copy's entry into the file, and turns the server on where the agent had turned it
    /// off; everything else in the file stays. `versions` are those of the agents found that read
    /// this file, where the format depends on them (OpenCode). Returns the backup of the old file,
    /// if one was made.
    @discardableResult
    public func register(_ installation: Installation, versions: [String] = [], home: URL = Shell.home) throws -> URL? {
        if self == .gemini, try geminiSwitchedOff(home: home) {
            try ConfigFile.update(geminiEnablementFile(home: home)) { text in
                var document = JSONText(text)
                try document.set([Registration.serverName, "enabled"], to: .bool(true))
                return document.text
            }
        }
        return try ConfigFile.update(file(home: home)) { text in
            if isTOML {
                var document = try TOMLText(text)
                var pairs: [(String, ConfigValue)] = [("command", .string(installation.command)),
                                                      ("args", .array(installation.arguments.map(ConfigValue.string)))]
                if document.value("enabled", in: tomlTable) != nil { pairs.append(("enabled", .bool(true))) }
                try document.set(pairs, in: tomlTable)
                if let off = document.value("disabled_mcp_servers", in: []) as? [String], off.contains(Registration.serverName) {
                    try document.set([("disabled_mcp_servers", .array(off.filter { $0 != Registration.serverName }.map(ConfigValue.string)))], in: [])
                }
                return document.text
            }
            var document = JSONText(text)
            let existing = try jsonPaths.filter { try document.value(at: $0) is [String: Any] }
            if existing.isEmpty {
                let path = newEntryPath(in: document, versions: versions)
                try document.set(path, to: entry(for: installation, at: path))
            }
            // Both OpenCode shapes may be there; each version reads one of them, so update both. Only
            // the fields this server needs change, so what the user added (environment, timeouts) stays.
            for path in existing {
                guard case .object(let fields) = entry(for: installation, at: path) else { continue }
                for (key, value) in fields { try document.set(path + [key], to: value) }
                if try document.value(at: path + ["disabled"]) as? Bool == true { try document.set(path + ["disabled"], to: .bool(false)) }
            }
            if self == .gemini {
                // Gemini's own lists of servers to leave out or to allow.
                let name = Registration.serverName
                if let excluded = try document.value(at: ["mcp", "excluded"]) as? [String], excluded.contains(name) {
                    try document.set(["mcp", "excluded"], to: .array(excluded.filter { $0 != name }.map(ConfigValue.string)))
                }
                if let allowed = try document.value(at: ["mcp", "allowed"]) as? [String], !allowed.contains(name) {
                    try document.set(["mcp", "allowed"], to: .array((allowed + [name]).map(ConfigValue.string)))
                }
            }
            return document.text
        }
    }

    /// Where a new entry goes. For OpenCode that is mcp.servers, which every current version
    /// reads, unless the file keeps its servers directly under mcp or an OpenCode found here is
    /// older than 1.18.24.
    func newEntryPath(in document: JSONText, versions: [String]) -> [String] {
        guard self == .opencode else { return jsonPaths[0] }
        let flat = jsonPaths[1]
        if (try? document.value(at: ["mcp", "servers"])) != nil { return jsonPaths[0] }
        if let servers = (try? document.value(at: ["mcp"])) as? [String: Any], !servers.isEmpty { return flat }
        if versions.contains(where: { $0.compare("1.18.24", options: .numeric) == .orderedAscending }) { return flat }
        return jsonPaths[0]
    }
}

