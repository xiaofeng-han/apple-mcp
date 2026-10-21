import Foundation

/// One way to install an agent.
public enum Installer: Sendable {
    /// `brew install --cask NAME`.
    case cask(String)
    /// `brew install NAME`.
    case formula(String)
    /// The vendor's install script, fetched and run with `shell`.
    case script(URL, shell: String = "/bin/bash")
    /// `npm install -g PACKAGE`.
    case npm(String)
    /// A disk image or zip archive from `site` with the app (`bundleID`) at its top level, signed
    /// by `team` (or, when the team is not known, by any developer Apple notarized). `latest` finds
    /// the download's address (some vendors only publish it in an update feed).
    case app(bundleID: String, team: String?, site: String, latest: @Sendable () async throws -> URL)

    public var usesHomebrew: Bool {
        switch self {
        case .cask, .formula: true
        default: false
        }
    }

    /// What it runs, for showing to the user.
    public var summary: String {
        switch self {
        case .cask(let name): "brew install --cask \(name)"
        case .formula(let name): "brew install \(name)"
        case .script(let url, let shell): "curl -fsSL \(url.absoluteString) | \((shell as NSString).lastPathComponent)"
        case .npm(let package): "npm install -g \(package)"
        case .app(_, _, let site, _): "download the app from \(site) into Applications"
        }
    }

    /// Whether the tools it needs are here.
    var isAvailable: Bool {
        switch self {
        case .cask, .formula: Self.brew != nil
        case .npm: Shell.which("npm") != nil
        case .script, .app: true
        }
    }

    static var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile(atPath:)) ?? Shell.which("brew")
    }

    /// Installs, passing output on as it comes. Throws with the output's last lines on failure.
    public func run(home: URL = Shell.home, onOutput: @escaping @Sendable (String) -> Void) async throws {
        var environment = Shell.environment
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["NONINTERACTIVE"] = "1"
        environment["CODEX_NON_INTERACTIVE"] = "1"
        let result: Shell.Result
        switch self {
        case .cask(let name):
            guard let brew = Self.brew else { throw ConfigError("Homebrew is not installed") }
            result = try await Shell.run(brew, ["install", "--cask", name], environment: environment, timeout: 1800, onOutput: onOutput)
        case .formula(let name):
            guard let brew = Self.brew else { throw ConfigError("Homebrew is not installed") }
            result = try await Shell.run(brew, ["install", name], environment: environment, timeout: 1800, onOutput: onOutput)
        case .npm(let package):
            guard let npm = Shell.which("npm") else { throw ConfigError("npm is not installed") }
            result = try await Shell.run(npm, ["install", "-g", package], environment: environment, timeout: 1800, onOutput: onOutput)
        case .script(let url, let shell):
            onOutput("Downloading \(url.absoluteString)\n")
            let script = try await Self.download(url)
            defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
            // The user's own PATH, so the script adds its folder to the shell's PATH when it is missing there.
            environment["PATH"] = Shell.scriptEnvironment["PATH"]
            result = try await Shell.run(shell, [script.path], environment: environment, timeout: 1800, onOutput: onOutput)
        case .app(let bundleID, let team, _, let latest):
            try await Self.installApp(bundleID: bundleID, team: team, from: try await latest(), home: home, onOutput: onOutput)
            return
        }
        guard result.succeeded else { throw ConfigError(Self.tail(result.output)) }
    }

    static func tail(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).suffix(6)
        return lines.isEmpty ? "the installer failed" : lines.joined(separator: "\n")
    }

    /// Downloads to a temporary file named like the address's last part.
    static func download(_ url: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ConfigError("downloading \(url.absoluteString) failed: HTTP \(http.statusCode)")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = (response.url ?? url).lastPathComponent
        let destination = folder.appendingPathComponent(name.isEmpty ? "download" : name)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    /// Downloads a disk image or zip, checks the app's signature, and copies it to /Applications
    /// (or ~/Applications when /Applications is not writable).
    static func installApp(bundleID: String, team: String?, from url: URL, home: URL, onOutput: @escaping @Sendable (String) -> Void) async throws {
        let manager = FileManager.default
        onOutput("Downloading \(url.absoluteString)\n")
        let archive = try await download(url)
        let work = archive.deletingLastPathComponent()
        defer { try? manager.removeItem(at: work) }
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        let environment = Shell.environment
        var mounted = false
        if archive.pathExtension.lowercased() == "zip" {
            onOutput("Unpacking\n")
            let result = try await Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path], environment: environment, timeout: 600)
            guard result.succeeded else { throw ConfigError(tail(result.output)) }
        } else {
            onOutput("Opening the disk image\n")
            try manager.createDirectory(at: unpacked, withIntermediateDirectories: true)
            let result = try await Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", unpacked.path, archive.path],
                                             environment: environment, timeout: 600)
            guard result.succeeded else { throw ConfigError(tail(result.output)) }
            mounted = true
        }
        func detach() async {
            if mounted { _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", "-force", unpacked.path], environment: environment, timeout: 60) }
        }
        do {
            let apps = (try? manager.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? []
            guard let app = apps.first(where: { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == bundleID }) else {
                throw ConfigError("the download has no app with the bundle id \(bundleID)")
            }
            onOutput("Checking the signature\n")
            // Signed through Apple's certificate authority, by the vendor's team.
            var requirement = "anchor apple generic"
            if let team { requirement += " and certificate leaf[subject.OU] = \"\(team)\"" }
            let verify = try await Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", app.path],
                                             environment: environment, timeout: 600)
            guard verify.succeeded else {
                throw ConfigError("\(app.lastPathComponent) is not signed by its developer:\n\(tail(verify.output))")
            }
            // Gatekeeper: a Developer ID that Apple notarized and has not revoked.
            let assessment = try await Shell.run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], environment: environment, timeout: 600)
            guard assessment.succeeded else { throw ConfigError("\(app.lastPathComponent) is not notarized by Apple:\n\(tail(assessment.output))") }
            var folder = URL(fileURLWithPath: "/Applications", isDirectory: true)
            if !manager.isWritableFile(atPath: folder.path) {
                folder = home.appendingPathComponent("Applications", isDirectory: true)
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let destination = folder.appendingPathComponent(app.lastPathComponent)
            guard !manager.fileExists(atPath: destination.path) else { throw ConfigError("\(destination.path) already exists") }
            onOutput("Copying to \(destination.path)\n")
            // Copied next to it under another name first, so a copy cut short never looks installed.
            let partial = folder.appendingPathComponent(".\(app.lastPathComponent).partial-\(UUID().uuidString)")
            let copy = try await Shell.run("/usr/bin/ditto", [app.path, partial.path], environment: environment, timeout: 600)
            guard copy.succeeded else {
                try? manager.removeItem(at: partial)
                throw ConfigError(tail(copy.output))
            }
            do {
                try manager.moveItem(at: partial, to: destination)
            } catch {
                try? manager.removeItem(at: partial)
                throw error
            }
            await detach()
        } catch {
            await detach()
            throw error
        }
    }
}
