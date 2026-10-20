import Foundation
import Launcher

/// Running other programs from an app that macOS started with a bare PATH.
public enum Shell {
    public struct Result: Sendable {
        public let status: Int32
        /// stdout and stderr together, in the order they were written.
        public let output: String
        public var succeeded: Bool { status == 0 }
    }

    /// The user's home folder: $HOME, so a test can point everything at another folder.
    public static var home: URL {
        ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Folders where installers put programs, which a GUI app's PATH lacks.
    static func usualFolders(home: URL) -> [String] {
        var folders = [".local/bin", ".opencode/bin", ".grok/bin", ".bun/bin", ".npm-global/bin", ".volta/bin", "Library/pnpm/bin", "Library/pnpm",
                       ".cargo/bin"]
            .map { home.appendingPathComponent($0).path }
        folders += ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        // Node from nvm, newest version first.
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? []
        folders += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { nvm.appendingPathComponent($0).appendingPathComponent("bin").path }
        return folders
    }

    /// The environment a terminal would have: what the login shell sets up, read once. Apps that
    /// macOS starts do not get it, but agents' apps read it at launch (ChatGPT, OpenCode), so
    /// variables that move their config folders are taken from here too.
    static let loginEnvironment: [String: String] = {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__apple_reminders_mcp_environment__"
        // -i reads ~/.zshrc as well, where nvm and similar tools set PATH; give up after a few seconds.
        guard let result = try? runSync(shell, ["-i", "-l", "-c", "printf '\(marker)'; /usr/bin/env -0"],
                                        environment: ["HOME": home.path, "TERM": "dumb", "USER": NSUserName()], timeout: 5),
            let listing = result.output.components(separatedBy: marker).dropFirst().first
        else { return [:] }
        var environment: [String: String] = [:]
        for entry in listing.split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return environment
    }()

    /// A variable from this process's environment, or else from the login shell's.
    public static func variable(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name] ?? loginEnvironment[name]
        return value?.isEmpty == false ? value : nil
    }

    /// The login shell's PATH, followed by the usual install folders and the system folders.
    public static let path: String = {
        var folders = (loginEnvironment["PATH"] ?? "").split(separator: ":").map(String.init)
        folders += usualFolders(home: home) + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return folders.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }()

    /// Variables that move agents' config folders. Agents' commands get them from the login shell
    /// too, so they change the files this app reads.
    static let relocations = ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "GROK_HOME", "XDG_CONFIG_HOME", "OPENCODE_CONFIG_DIR", "GEMINI_CLI_HOME"]

    /// The environment for programs this app starts: its own, with `path` and the login shell's
    /// config-folder variables.
    public static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        environment.removeValue(forKey: "APPLE_REMINDERS_MCP_RELAUNCHED")
        for name in relocations where environment[name] == nil { environment[name] = loginEnvironment[name] }
        return environment
    }

    /// The environment for vendors' install scripts: like `environment`, but with the login shell's
    /// own PATH, so a script that adds its folder to the user's PATH sees that it is missing.
    static var scriptEnvironment: [String: String] {
        var environment = Self.environment
        var folders = (loginEnvironment["PATH"] ?? "").split(separator: ":").map(String.init)
        folders += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].filter { !folders.contains($0) }
        environment["PATH"] = folders.joined(separator: ":")
        return environment
    }

    /// The first executable named `name` in `path`.
    public static func which(_ name: String) -> String? {
        path.split(separator: ":").lazy.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a program to its end (or until `timeout`, when it is stopped) and returns its output.
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                           timeout: TimeInterval = 60, onOutput: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        try await Task.detached {
            try runSync(executable, arguments, environment: environment ?? Self.environment, timeout: timeout, onOutput: onOutput)
        }.value
    }

    /// Runs a program and waits for it. The program gets none of this app's privacy permissions
    /// (Reminders, Full Disk Access) and no terminal; at `timeout`, it and whatever it started are
    /// stopped.
    static func runSync(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval,
                        onOutput: (@Sendable (String) -> Void)? = nil) throws -> Result {
        let pipe = Pipe()
        let collected = Collected()
        let drained = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                drained.signal()
                return
            }
            collected.append(data)
            onOutput?(String(decoding: data, as: UTF8.self))
        }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let error = launcher_spawn_disclaimed(executable, argv, envp, home.path, pipe.fileHandleForWriting.fileDescriptor, &pid)
        try? pipe.fileHandleForWriting.close()
        guard error == 0 else {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw ConfigError("cannot start \(executable): \(String(cString: strerror(error)))")
        }
        let finished = DispatchSemaphore(value: 0)
        let status = Status()
        let child = pid
        DispatchQueue.global().async {
            var code: Int32 = 0
            while waitpid(child, &code, 0) < 0, errno == EINTR {}
            status.code = code
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            // The program leads its own process group (its own session); stop all of it.
            killpg(pid, SIGTERM)
            if finished.wait(timeout: .now() + 5) == .timedOut {
                killpg(pid, SIGKILL)
                finished.wait()
            }
        }
        // Output still in the pipe arrives shortly; a background process the program left running
        // may keep the pipe open, so do not wait for it long.
        _ = drained.wait(timeout: .now() + 2)
        pipe.fileHandleForReading.readabilityHandler = nil
        let code = status.code
        let exit: Int32 = (code & 0x7F) == 0 ? (code >> 8) & 0xFF : 128 + (code & 0x7F)
        return Result(status: exit, output: collected.text)
    }

    private final class Status: @unchecked Sendable {
        var code: Int32 = 0
    }

    private final class Collected: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()

        func append(_ more: Data) {
            lock.lock()
            data.append(more)
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
