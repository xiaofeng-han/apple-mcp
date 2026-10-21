import Foundation
import Testing
@testable import Agents

/// A home folder of its own for each test, with an executable to register.
struct Sandbox {
    let home: URL
    let installation: Installation

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-tests-\(UUID().uuidString)", isDirectory: true)
        let command = home.appendingPathComponent("bin/apple-notes-mcp")
        try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: command.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        installation = Installation(method: .homebrew(prefix: "/opt/homebrew"), bundle: nil, command: command.path)
    }

    func write(_ text: String, to target: ConfigTarget) throws {
        let url = target.file(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ target: ConfigTarget) throws -> String {
        try String(contentsOf: target.file(home: home), encoding: .utf8)
    }

    func registration(_ target: ConfigTarget) -> Registration {
        target.registration(for: installation, home: home)
    }

    func register(_ target: ConfigTarget, versions: [String] = []) throws {
        try target.register(installation, versions: versions, home: home)
    }

    var command: String { installation.command }
}

@Suite struct RegistrationTests {
    @Test func claudeDesktopKeepsOtherKeys() throws {
        let box = try Sandbox()
        try box.write("{\n  \"preferences\": {\n    \"x\": true\n  }\n}\n", to: .claudeDesktop)
        #expect(box.registration(.claudeDesktop) == .missing)
        try box.register(.claudeDesktop)
        #expect(box.registration(.claudeDesktop) == .current)
        #expect(try box.read(.claudeDesktop) == """
            {
              "preferences": {
                "x": true
              },
              "mcpServers": {
                "apple-notes": {
                  "command": "\(box.command)",
                  "args": ["--stdio"]
                }
              }
            }

            """)
        // The old file is kept once a day, with its permissions.
        let backups = try FileManager.default.contentsOfDirectory(atPath: ConfigTarget.claudeDesktop.file(home: box.home).deletingLastPathComponent().path)
            .filter { $0.hasSuffix("-apple-notes-mcp") }
        #expect(backups.count == 1)
    }

    @Test func createsMissingFiles() throws {
        let box = try Sandbox()
        for target in [ConfigTarget.claudeDesktop, .codex, .grok, .gemini, .antigravity, .opencode] {
            #expect(box.registration(target) == .missing)
            try box.register(target, versions: ["2.1.1"])
            #expect(box.registration(target) == .current, "\(target)")
            let mode = try FileManager.default.attributesOfItem(atPath: target.file(home: box.home).path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
        #expect(try box.read(.antigravity).contains("\"mcpServers\""))
        #expect(try box.read(.opencode).contains("\"servers\""))
    }

    @Test func judgesExistingEntries() throws {
        let box = try Sandbox()
        try box.write("{\"mcpServers\": {\"apple-notes\": {\"command\": \"/nowhere/apple-notes-mcp\", \"args\": [\"--stdio\"]}}}", to: .gemini)
        #expect(box.registration(.gemini) == .broken(command: "/nowhere/apple-notes-mcp"))
        try box.write("{\"mcpServers\": {\"apple-notes\": {\"command\": \"/bin/sh\", \"args\": []}}}", to: .gemini)
        #expect(box.registration(.gemini) == .different(command: "/bin/sh"))
        try box.write("{\"mcpServers\": {\"apple-notes\": {\"command\": \"\(box.command)\", \"args\": [\"--stdio\"]}}, \"mcp\": {\"excluded\": [\"apple-notes\"]}}",
                      to: .gemini)
        #expect(box.registration(.gemini) == .disabled)
        try box.write("{ broken", to: .gemini)
        if case .unreadable = box.registration(.gemini) {} else { Issue.record("expected unreadable") }
        #expect(throws: ConfigError.self) { try box.register(.gemini) }
        #expect(try box.read(.gemini) == "{ broken")
    }

    @Test func geminiTurnsTheServerOn() throws {
        let box = try Sandbox()
        try box.write("""
            {
              // mine
              "mcpServers": {
                "apple-notes": {"command": "/old", "args": ["--stdio"], "timeout": 600000, "trust": true}
              },
              "mcp": {"excluded": ["apple-notes", "other"], "allowed": ["x"]}
            }
            """, to: .gemini)
        try box.register(.gemini)
        #expect(box.registration(.gemini) == .current)
        let text = try box.read(.gemini)
        #expect(text.contains("// mine") && text.contains("\"timeout\": 600000") && text.contains("\"trust\": true"))
        #expect(text.contains("\"excluded\": [\"other\"]") && text.contains("\"allowed\": [\"x\", \"apple-notes\"]"))
    }

    @Test func opencodeShapes() throws {
        // OpenCode 1 before 1.18.24 only reads servers directly under mcp.
        let box = try Sandbox()
        try box.write("{\n  \"$schema\": \"https://opencode.ai/config.json\"\n}\n", to: .opencode)
        try box.register(.opencode, versions: ["2.1.1", "1.17.0"])
        #expect(try JSONText(box.read(.opencode)).value(at: ["mcp", "apple-notes", "enabled"]) as? Bool == true)
        #expect(box.registration(.opencode) == .current)

        // A file that already uses mcp.servers keeps using it, and an entry turned off is turned on.
        let other = try Sandbox()
        try other.write("{\"mcp\": {\"servers\": {\"apple-notes\": {\"type\": \"local\", \"command\": [\"/x\"], \"disabled\": true}}}}", to: .opencode)
        #expect(other.registration(.opencode) == .broken(command: "/x"))
        try other.register(.opencode, versions: ["1.19.3"])
        let entry = try JSONText(other.read(.opencode)).value(at: ["mcp", "servers", "apple-notes"]) as? [String: Any]
        #expect(entry?["disabled"] as? Bool == false && entry?["enabled"] == nil)
        #expect(entry?["command"] as? [String] == [other.command, "--stdio"])

        // Servers already directly under mcp keep the flat shape.
        let flat = try Sandbox()
        try flat.write("{\"mcp\": {\"other\": {\"type\": \"local\", \"command\": [\"/y\"]}}}", to: .opencode)
        try flat.register(.opencode, versions: ["2.1.1"])
        #expect(try JSONText(flat.read(.opencode)).value(at: ["mcp", "apple-notes"]) != nil)
    }

    @Test func opencodePrefersJSONC() throws {
        let box = try Sandbox()
        let directory = box.home.appendingPathComponent(".config/opencode")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "{}".write(to: directory.appendingPathComponent("opencode.json"), atomically: true, encoding: .utf8)
        try "{ // c\n}".write(to: directory.appendingPathComponent("opencode.jsonc"), atomically: true, encoding: .utf8)
        #expect(ConfigTarget.opencode.file(home: box.home).lastPathComponent == "opencode.jsonc")
    }

    @Test func grokTurnsTheServerOn() throws {
        let box = try Sandbox()
        try box.write("""
            disabled_mcp_servers = ["apple-notes", "x"]

            [mcp_servers.apple-notes]
            command = "\(box.command)"
            args = ["--stdio"]
            enabled = false
            """, to: .grok)
        #expect(box.registration(.grok) == .disabled)
        try box.register(.grok)
        #expect(box.registration(.grok) == .current)
        #expect(try box.read(.grok) == """
            disabled_mcp_servers = ["x"]

            [mcp_servers.apple-notes]
            command = "\(box.command)"
            args = ["--stdio"]
            enabled = true
            """)
    }

    @Test func grokTurnsTheServerOnBesideArraysOfTables() throws {
        let box = try Sandbox()
        try box.write("""
            disabled_mcp_servers = ["apple-notes"]

            [[marketplace.sources]]
            url = "https://example.com"

            [mcp_servers.apple-notes]
            command = "\(box.command)"
            args = ["--stdio"]
            """, to: .grok)
        #expect(box.registration(.grok) == .disabled)
        try box.register(.grok)
        #expect(box.registration(.grok) == .current)
        #expect(try box.read(.grok).hasPrefix("disabled_mcp_servers = []\n\n[[marketplace.sources]]"))
    }

    @Test func geminiSwitchedOffByItsCommand() throws {
        let box = try Sandbox()
        try box.write("{\"mcpServers\": {\"apple-notes\": {\"command\": \"\(box.command)\", \"args\": [\"--stdio\"]}}}", to: .gemini)
        let enablement = ConfigTarget.gemini.geminiEnablementFile(home: box.home)
        try "{\"apple-notes\": {\"enabled\": false}, \"other\": {\"enabled\": false}}".write(to: enablement, atomically: true, encoding: .utf8)
        #expect(box.registration(.gemini) == .disabled)
        try box.register(.gemini)
        #expect(box.registration(.gemini) == .current)
        #expect(try JSONText(String(contentsOf: enablement, encoding: .utf8)).value(at: ["other", "enabled"]) as? Bool == false)
    }

    @Test func inlineTOMLEntries() throws {
        let box = try Sandbox()
        try box.write("[mcp_servers]\napple-notes = { command = \"\(box.command)\", args = [\"--stdio\"], startup_timeout_sec = 20 }\n", to: .codex)
        #expect(box.registration(.codex) == .current)
        try box.write("[mcp_servers]\napple-notes = { command = \"/bin/sh\", args = [\"--stdio\"] }\n", to: .codex)
        if case .notEditable = box.registration(.codex) {} else { Issue.record("expected notEditable") }
    }

    @Test func refusesDanglingLinksAndDuplicateKeys() throws {
        let box = try Sandbox()
        let link = ConfigTarget.codex.file(home: box.home)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: box.home.appendingPathComponent("gone/config.toml").path)
        #expect(throws: ConfigError.self) { try box.register(.codex) }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)

        try box.write("{\"mcpServers\": {\"a\": {}}, \"mcpServers\": {\"b\": {}}}", to: .claudeDesktop)
        #expect(throws: ConfigError.self) { try box.register(.claudeDesktop) }
    }

    @Test func variablesThatMoveFoldersOnlyApplyToTheUsersHome() throws {
        let box = try Sandbox()
        for name in Shell.relocations { setenv(name, "/nonexistent/\(name)", 1) }
        defer { for name in Shell.relocations { unsetenv(name) } }
        for target in ConfigTarget.allCases {
            #expect(target.file(home: box.home).path.hasPrefix(box.home.path), "\(target)")
        }
        #expect(ConfigTarget.codex.file().path == "/nonexistent/CODEX_HOME/config.toml")
    }

    @Test func codexLeavesOtherTablesAlone() throws {
        let box = try Sandbox()
        let before = """
            # my config
            model = "gpt-5.5"

            [mcp_servers.apple-notes]
            command = "/old/AppleNotesMCP"
            args = ["--stdio"]
            startup_timeout_sec = 20

            [mcp_servers.apple-notes.env]
            A = "1"

            [tui]
            theme = "dark"
            """
        try box.write(before, to: .codex)
        try box.register(.codex)
        #expect(try box.read(.codex) == before.replacingOccurrences(of: "/old/AppleNotesMCP", with: box.command))
    }

    @Test func followsSymbolicLinks() throws {
        let box = try Sandbox()
        let real = box.home.appendingPathComponent("dotfiles/config.toml")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"x\"\n".write(to: real, atomically: true, encoding: .utf8)
        let link = ConfigTarget.codex.file(home: box.home)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try box.register(.codex)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == real.path)
        #expect(try String(contentsOf: real, encoding: .utf8).contains("[mcp_servers.apple-notes]"))
    }
}

@Suite struct InstallerChoiceTests {
    func agent(_ id: String) -> Agent { Agent.all.first { $0.id == id }! }

    @Test func followsHowThisAppWasInstalled() {
        let homebrew = Installation(method: .homebrew(prefix: "/opt/homebrew"), bundle: nil, command: "/x")
        let package = Installation(method: .package(allUsers: false), bundle: nil, command: "/x")
        #expect(agent("opencode").installer(for: homebrew)?.summary == "brew install opencode")
        #expect(agent("opencode").installer(for: package)?.summary == "curl -fsSL https://opencode.ai/v2/install | bash")
        #expect(agent("claude").installer(for: homebrew)?.summary == "brew install --cask claude")
        #expect(agent("claude").installer(for: package)?.usesHomebrew == false)
        // Homebrew's gemini-cli is deprecated, so only npm installs it.
        #expect(agent("gemini").installer(for: homebrew).map { $0.usesHomebrew } != true)
        #expect(agent("codex").installer(for: package)?.summary == "curl -fsSL https://chatgpt.com/codex/install.sh | sh")
    }

    @Test func everyAgentHasAnInstallerAndAUniqueID() {
        let package = Installation(method: .package(allUsers: true), bundle: nil, command: "/x")
        for agent in Agent.all where agent.id != "gemini" { #expect(agent.installer(for: package) != nil, "\(agent.id)") }
        #expect(Set(Agent.all.map(\.id)).count == Agent.all.count)
    }

    @Test func stopsWhatRunsTooLong() throws {
        let start = Date()
        let result = try Shell.runSync("/bin/sh", ["-c", "echo started; sleep 30 & sleep 30"], environment: ["PATH": "/usr/bin:/bin"], timeout: 1)
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(!result.succeeded && result.output.contains("started"))
    }

    @Test func runsWithoutATerminal() throws {
        let result = try Shell.runSync("/bin/sh", ["-c", "if : </dev/tty; then echo tty; else echo none; fi"], environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
        #expect(result.output.contains("none"))
    }

    @Test func shortensOnlyTheAccountsOwnHome() throws {
        let home = try #require(Shell.accountHome)
        let saved = ProcessInfo.processInfo.environment["HOME"]
        defer { if let saved { setenv("HOME", saved, 1) } else { unsetenv("HOME") } }
        setenv("HOME", home, 1)
        #expect(Shell.abbreviate(home + "/.opencode/bin/opencode") == "~/.opencode/bin/opencode")
        #expect(Shell.abbreviate("/opt/homebrew/bin/codex") == "/opt/homebrew/bin/codex")
        setenv("HOME", "/tmp/agents-preview", 1)
        #expect(Shell.abbreviate("/tmp/agents-preview/.opencode/bin/opencode") == "/tmp/agents-preview/.opencode/bin/opencode")
    }

    @Test func versions() {
        #expect(Locator.version(in: "grok 1.0.62 (1474f9cbdd91) [stable]") == "1.0.62")
        #expect(Locator.version(in: "codex-cli 0.163.0") == "0.163.0")
        #expect(Locator.version(in: "2.1.304 (Claude Code)") == "2.1.304")
        #expect(Locator.version(in: "opencode v2.1.1") == "2.1.1")
    }
}
