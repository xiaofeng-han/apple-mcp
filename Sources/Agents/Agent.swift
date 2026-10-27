import Foundation

/// An AI agent this app can find, install, and register its server with.
public struct Agent: Sendable, Identifiable {
    public enum Kind: Sendable { case commandLine, app }

    /// When a change to its config takes effect.
    public enum Reload: Sendable {
        /// In sessions started afterwards.
        case newSession
        /// After the app is restarted.
        case restart
        /// After a restart, and the app must not be running while its config changes: it writes
        /// its own copy of the file back.
        case quitFirst
    }

    public let id: String
    public let name: String
    public let vendor: String
    public let kind: Kind
    /// Where it reads MCP servers from; nil when it cannot start a server on this Mac.
    public let target: ConfigTarget?
    /// Why there is no target, or something the user should know (English, Chinese).
    public let note: (String, String)?
    /// Command names, and folders to look in besides PATH (relative ones are in the home folder).
    let commands: [String]
    let folders: [String]
    /// Arguments that make a command identify itself, and what its output must contain, when
    /// another program goes by the same name.
    let identify: (arguments: [String], marker: String)?
    let bundleIDs: [String]
    let appNames: [String]
    /// Ways to install it, best first.
    let installers: [Installer]
    /// Whether to prefer Homebrew when this app came from Homebrew (false when Homebrew's package
    /// is deprecated).
    let homebrewFirst: Bool
    public let reload: Reload
    /// Where it reads skills from; nil when it cannot run this Mac's commands.
    public internal(set) var skills: SkillTarget? = nil
    /// Something the user should know about it as a skill, when its `note` does not fit (English,
    /// Chinese).
    public internal(set) var skillNote: (String, String)? = nil

    /// Finds it on this Mac.
    public func locate(home: URL = Shell.home) -> Presence {
        switch kind {
        case .app:
            return Locator.app(bundleIDs, names: appNames, home: home)
        case .commandLine:
            let folders = folders.map { $0.hasPrefix("/") ? $0 : home.appendingPathComponent($0).path }
            return Locator.command(commands, folders: folders, identify: identify)
        }
    }

    /// The installer to offer: Homebrew's package when this app came from Homebrew, otherwise the
    /// vendor's own installer, among those whose tools are here.
    public func installer(for installation: Installation) -> Installer? {
        let available = installers.filter(\.isAvailable)
        if homebrewFirst, installation.homebrewPrefix != nil, let homebrew = available.first(where: \.usesHomebrew) { return homebrew }
        return available.first { !$0.usesHomebrew } ?? available.first
    }

    /// Whether its app is open now.
    public var isOpen: Bool { RunningApp.isRunning(bundleIDs) }

    /// Whether setting it up has to quit its app first (and open it again afterwards).
    public var mustQuit: Bool { reload == .quitFirst && isOpen }

    /// Registers the server. An app that must not run while its config changes is quit and
    /// opened again, if `mayQuit`; otherwise this throws.
    public func setUp(_ installation: Installation, presence: Presence, mayQuit: Bool, home: URL = Shell.home) async throws {
        guard mustQuit else {
            try await register(installation, presence: presence, home: home)
            return
        }
        guard mayQuit else { throw ConfigError("\(name) is open and writes its own settings back; quit it first") }
        let location = try await RunningApp.quit(bundleIDs, name: name)
        do {
            try await register(installation, presence: presence, home: home)
        } catch {
            if let location { await RunningApp.open(location) }
            throw error
        }
        if let location { await RunningApp.open(location) }
    }

    /// Writes this copy's entry into the agent's config. Claude Code goes through its own command,
    /// which takes the lock Claude Code uses for ~/.claude.json. Returns the backup of the old
    /// file, if one was made.
    @discardableResult
    public func register(_ installation: Installation, presence: Presence, home: URL = Shell.home) async throws -> URL? {
        guard let target else { throw ConfigError("\(name) cannot start servers on this Mac") }
        guard target == .claudeCode else {
            // The format of OpenCode's file depends on the versions of every OpenCode found.
            var versions = [presence.version].compactMap { $0 }
            if target == .opencode {
                versions += Agent.all.filter { $0.target == target && $0.id != id }.compactMap { $0.locate(home: home).version }
            }
            return try target.register(installation, versions: versions, home: home)
        }
        guard let claude = presence.path else { throw ConfigError("Claude Code is not installed") }
        let name = Registration.serverName
        let file = target.file(home: home)
        var environment = Shell.environment
        environment["HOME"] = home.path
        if home.standardizedFileURL.path != Shell.home.standardizedFileURL.path { environment.removeValue(forKey: "CLAUDE_CONFIG_DIR") }
        // `claude mcp add` will not replace an entry, so the old one is removed first. What the user
        // added to it (env, timeouts) is kept; only what starts the server changes.
        let old = try JSONText(ConfigFile.read(file) ?? "").value(at: ["mcpServers", name]) as? [String: Any]
        var entry = old ?? ["env": [String: String]()]
        entry["type"] = "stdio"
        entry["command"] = installation.command
        entry["args"] = installation.arguments
        func add(_ entry: [String: Any]) async throws -> Shell.Result {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            return try await Shell.run(claude, ["mcp", "add-json", "--scope", "user", name, json], environment: environment, timeout: 60)
        }
        let backup = try ConfigFile.backUp(file)
        if old != nil {
            let removed = try await Shell.run(claude, ["mcp", "remove", "--scope", "user", name], environment: environment, timeout: 60)
            guard removed.succeeded else { throw ConfigError(Installer.tail(removed.output)) }
        }
        let added = try await add(entry)
        guard added.succeeded else {
            if let old { _ = try? await add(old) }
            throw ConfigError(Installer.tail(added.output))
        }
        guard target.registration(for: installation, home: home) == .current else {
            throw ConfigError("claude mcp add-json succeeded, but \(file.path) does not have the server")
        }
        return backup
    }

    /// What installing it needs, when none of its installers can run here.
    public var installRequirement: (String, String) {
        installers.allSatisfy { if case .npm = $0 { true } else { false } }
            ? ("Installing it needs Node.js (npm)", "安装它需要 Node.js（npm）")
            : ("Installing it needs Homebrew", "安装它需要 Homebrew")
    }
}

extension Presence {
    var version: String? {
        if case .installed(_, let version) = self { return version }
        return nil
    }
}

extension Agent {
    /// Every agent, grouped by vendor in the order they are shown.
    public static let all: [Agent] = [
        Agent(id: "claude-code", name: "Claude Code", vendor: "Anthropic", kind: .commandLine, target: .claudeCode,
              note: ("Also used by the Code tab of the Claude app.", "Claude App 的 Code 标签页也用这里的配置。"),
              commands: ["claude"], folders: [".local/bin", ".claude/local"], identify: nil, bundleIDs: [], appNames: [],
              installers: [.cask("claude-code"), .script(URL(string: "https://claude.ai/install.sh")!), .npm("@anthropic-ai/claude-code")],
              homebrewFirst: true, reload: .newSession, skills: .claude),
        Agent(id: "claude", name: "Claude", vendor: "Anthropic", kind: .app, target: .claudeDesktop,
              note: ("Chat and the Code tab. Claude is restarted to load the server.", "聊天和 Code 标签页。配置时会重启 Claude 来加载。"),
              commands: [], folders: [], identify: nil, bundleIDs: ["com.anthropic.claudefordesktop"], appNames: ["Claude"],
              installers: [.cask("claude"), .app(bundleID: "com.anthropic.claudefordesktop", team: "Q6L2SF6YDW", site: "downloads.claude.ai", latest: Feeds.claude)],
              homebrewFirst: true, reload: .quitFirst, skills: .claude,
              skillNote: ("The skill works in the Code tab, which shares Claude Code's skills; chat cannot run commands.",
                          "技能在 Code 标签页里可用（和 Claude Code 共用技能）；聊天里不能运行命令。")),
        Agent(id: "codex", name: "Codex CLI", vendor: "OpenAI", kind: .commandLine, target: .codex, note: nil,
              commands: ["codex"], folders: [".local/bin"], identify: nil, bundleIDs: [], appNames: [],
              installers: [.cask("codex"), .script(URL(string: "https://chatgpt.com/codex/install.sh")!, shell: "/bin/sh"), .npm("@openai/codex")],
              homebrewFirst: true, reload: .newSession, skills: .agents),
        Agent(id: "chatgpt", name: "ChatGPT (Codex)", vendor: "OpenAI", kind: .app, target: .codex,
              note: ("The desktop app that Codex became; shares the Codex CLI's settings.", "Codex 并入后的桌面 App，和 Codex CLI 共用设置。"),
              commands: [], folders: [], identify: nil, bundleIDs: ["com.openai.codex"], appNames: ["ChatGPT", "Codex"],
              installers: [.cask("chatgpt"), .app(bundleID: "com.openai.codex", team: "2DC432GLL2", site: "persistent.oaistatic.com",
                                                  latest: Feeds.fixed("https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"))],
              homebrewFirst: true, reload: .restart, skills: .agents),
        Agent(id: "grok", name: "Grok Build", vendor: "xAI", kind: .commandLine, target: .grok, note: nil,
              // Homebrew's formula "grok" is an unrelated pattern matcher.
              commands: ["grok"], folders: [".grok/bin", ".local/bin"], identify: (["--help"], "Grok Build"), bundleIDs: [], appNames: [],
              installers: [.cask("grok-build"), .script(URL(string: "https://x.ai/cli/install.sh")!), .npm("@xai-official/grok")],
              homebrewFirst: true, reload: .newSession, skills: .grok),
        Agent(id: "grok-bot", name: "Grok Bot", vendor: "xAI", kind: .app, target: nil,
              note: ("Its MCP servers run on its cloud computer, so it cannot start this Mac's \(Product.current.subject) server.",
                     "它的 MCP 服务器跑在云端电脑上，没法启动这台 Mac 上的\(Product.current.chineseSubject)服务器。"),
              commands: [], folders: [], identify: nil, bundleIDs: ["com.anysphere.sand"], appNames: ["Grok Bot"],
              installers: [.cask("grok-bot"), .app(bundleID: "com.anysphere.sand", team: "DCNK4UB866", site: "downloads.cursor.com", latest: Feeds.grokBot)],
              homebrewFirst: true, reload: .restart),
        Agent(id: "opencode", name: "OpenCode", vendor: "OpenCode", kind: .commandLine, target: .opencode, note: nil,
              commands: ["opencode"], folders: [".opencode/bin", ".bun/bin"], identify: nil, bundleIDs: [], appNames: [],
              installers: [.formula("opencode"), .script(URL(string: "https://opencode.ai/v2/install")!), .npm("@opencode/cli")],
              homebrewFirst: true, reload: .newSession, skills: .agents),
        Agent(id: "opencode-desktop", name: "OpenCode Desktop", vendor: "OpenCode", kind: .app, target: .opencode,
              note: ("Shares the OpenCode command's settings.", "和 OpenCode 命令行共用设置。"),
              commands: [], folders: [], identify: nil, bundleIDs: ["ai.opencode.desktop"], appNames: ["OpenCode"],
              installers: [.cask("opencode-desktop"), .app(bundleID: "ai.opencode.desktop", team: nil, site: "opencode.ai",
                                                           latest: Feeds.fixed("https://opencode.ai/download/stable/darwin-aarch64-dmg"))],
              homebrewFirst: true, reload: .restart, skills: .agents),
        Agent(id: "gemini", name: "Gemini CLI", vendor: "Google", kind: .commandLine, target: .gemini,
              note: ("Google no longer serves personal accounts in Gemini CLI; it needs an API key or a Code Assist license.",
                     "Gemini CLI 已不再支持个人账号登录，需要 API 密钥或 Code Assist 许可。"),
              commands: ["gemini"], folders: [], identify: nil, bundleIDs: [], appNames: [],
              // Homebrew's formula is deprecated and will be disabled.
              installers: [.npm("@google/gemini-cli")],
              homebrewFirst: false, reload: .newSession, skills: .gemini),
        Agent(id: "gemini-app", name: "Gemini", vendor: "Google", kind: .app, target: nil,
              note: ("Takes only remote MCP servers, added by URL on gemini.google.com. Antigravity, below, runs local ones.",
                     "只能用远程 MCP 服务器（在 gemini.google.com 按网址添加）。本地服务器请用下面的 Antigravity。"),
              commands: [], folders: [], identify: nil, bundleIDs: ["com.google.GeminiMacOS"], appNames: ["Gemini"],
              installers: [.cask("google-gemini"), .app(bundleID: "com.google.GeminiMacOS", team: "EQHXZ8M8AV", site: "gemini.google",
                                                        latest: Feeds.fixed("https://gemini.google/download/mac/"))],
              homebrewFirst: true, reload: .restart),
        Agent(id: "antigravity", name: "Antigravity", vendor: "Google", kind: .app, target: .antigravity,
              note: ("Google's agent app; shares its servers with the Antigravity CLI and IDE.", "Google 的智能体 App，和 Antigravity CLI、IDE 共用服务器设置。"),
              commands: [], folders: [], identify: nil, bundleIDs: ["com.google.antigravity"], appNames: ["Antigravity"],
              installers: [.cask("antigravity"), .app(bundleID: "com.google.antigravity", team: nil, site: "storage.googleapis.com",
                                                      latest: Feeds.homebrewCask("antigravity"))],
              homebrewFirst: true, reload: .restart, skills: .antigravity),
        Agent(id: "agy", name: "Antigravity CLI", vendor: "Google", kind: .commandLine, target: .antigravity,
              note: ("The successor to Gemini CLI.", "Gemini CLI 的后继。"),
              commands: ["agy"], folders: [".local/bin"], identify: nil, bundleIDs: [], appNames: [],
              installers: [.cask("antigravity-cli"), .script(URL(string: "https://antigravity.google/cli/install.sh")!)],
              homebrewFirst: true, reload: .newSession, skills: .antigravityCLI),
    ]
}

/// Where vendors publish the address of their latest app.
enum Feeds {
    static func fixed(_ address: String) -> @Sendable () async throws -> URL {
        { URL(string: address)! }
    }

    /// Claude's update feed lists the current release's zip.
    static let claude: @Sendable () async throws -> URL = {
        let feed = try await json(URL(string: "https://downloads.claude.ai/releases/darwin/universal/RELEASES.json")!)
        let releases = feed["releases"] as? [[String: Any]] ?? []
        let current = feed["currentRelease"] as? String
        let release = releases.first { $0["version"] as? String == current } ?? releases.first
        guard let address = (release?["updateTo"] as? [String: Any])?["url"] as? String, let url = URL(string: address)
        else { throw ConfigError("Claude's download feed has no release") }
        return url
    }

    /// Grok Bot's update server answers with the latest build's zip.
    static let grokBot: @Sendable () async throws -> URL = {
        let feed = try await json(URL(string: "https://api2.cursor.sh/updates/api/update/darwin-arm64/sand/0.0.0/stable")!)
        guard let address = feed["url"] as? String, let url = URL(string: address) else { throw ConfigError("Grok Bot's download feed has no release") }
        return url
    }

    /// The download Homebrew's cask points at, for vendors without a fixed address.
    static func homebrewCask(_ name: String) -> @Sendable () async throws -> URL {
        {
            let cask = try await json(URL(string: "https://formulae.brew.sh/api/cask/\(name).json")!)
            guard let address = cask["url"] as? String, let url = URL(string: address) else { throw ConfigError("no download for \(name)") }
            return url
        }
    }

    static func json(_ url: URL) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ConfigError("\(url.absoluteString) answered HTTP \(http.statusCode)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConfigError("\(url.absoluteString) is not JSON") }
        return object
    }
}
