import Agents
import Foundation

/// `agents`: the settings window's list of AI assistants, in the terminal.
///
///     apple-reminders-mcp agents                    which agents are here and set up
///     apple-reminders-mcp agents set-up ID… | --all registers the server with them
///     apple-reminders-mcp agents install ID…        installs them, then registers the server
///
/// `--restart` lets set-up quit and reopen an app that must be closed while its settings change
/// (Claude); `--dry-run` makes install only say what it would do.
enum AgentsCommand {
    static func run(_ arguments: [String]) async -> Int32 {
        let options = Set(arguments.filter { $0.hasPrefix("-") })
        let words = arguments.filter { !$0.hasPrefix("-") }
        let known: Set<String> = ["--all", "--restart", "--dry-run"]
        guard options.isSubset(of: known), words.first != "help" else { return usage() }
        let installation = Installation.detect()
        switch words.first {
        case nil, "list":
            guard options.isEmpty, words.count <= 1 else { return usage() }
            list(installation)
            return 0
        case "set-up", "setup":
            let all = options.contains("--all")
            guard let agents = all ? Agent.all : pick(Array(words.dropFirst())), !agents.isEmpty, !all || words.count == 1 else { return usage() }
            return await setUp(agents, installation, all: all, mayQuit: options.contains("--restart"))
        case "install":
            guard let agents = pick(Array(words.dropFirst())), !agents.isEmpty, !options.contains("--all") else { return usage() }
            return await install(agents, installation, dryRun: options.contains("--dry-run"), mayQuit: options.contains("--restart"))
        default:
            return usage()
        }
    }

    static func usage() -> Int32 {
        print("""
            usage: apple-reminders-mcp agents [list]
                   apple-reminders-mcp agents set-up (ID... | --all) [--restart]
                   apple-reminders-mcp agents install ID... [--dry-run] [--restart]
            IDs: \(Agent.all.map(\.id).joined(separator: ", "))
            """)
        return 2
    }

    static func pick(_ ids: [String]) -> [Agent]? {
        var agents: [Agent] = []
        for id in ids {
            guard let agent = Agent.all.first(where: { $0.id == id }) else {
                print("No agent \"\(id)\".")
                return nil
            }
            agents.append(agent)
        }
        return agents
    }

    static func describe(_ installation: Installation) -> String {
        switch installation.method {
        case .homebrew: "installed with Homebrew"
        case .package(let allUsers): allUsers ? "installed from the package for all users" : "installed from the package for this user"
        case .other: installation.bundle == nil ? "not an app bundle (a development build)" : "not installed from a release"
        }
    }

    static func list(_ installation: Installation) {
        print("Apple Reminders MCP \(version), \(describe(installation)).")
        print("Agents start: \(installation.command) \(installation.arguments.joined(separator: " "))\n")
        let home = Shell.home.path
        for agent in Agent.all {
            let id = agent.id.padding(toLength: 17, withPad: " ", startingAt: 0)
            switch agent.locate() {
            case .absent:
                let install = agent.installer(for: installation).map { "install: \($0.summary)" } ?? agent.installRequirement.0
                print("\(id)\(agent.name): not installed. \(install)")
            case .installed(let path, let version):
                let place = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
                print("\(id)\(agent.name)\(version.map { " " + $0 } ?? "") (\(place)): \(status(agent, installation))")
            }
        }
    }

    static func status(_ agent: Agent, _ installation: Installation) -> String {
        guard let target = agent.target else { return "cannot use local servers" }
        switch target.registration(for: installation) {
        case .current: return "set up"
        case .missing: return "not set up"
        case .different(let command): return "set up with another command: \(command)"
        case .broken(let command): return "set up with a missing command: \(command)"
        case .disabled: return "set up but turned off"
        case .unreadable(let error): return "cannot read its settings: \(error)"
        case .notEditable(let reason): return "set up by hand (\(reason))"
        }
    }

    static func setUp(_ agents: [Agent], _ installation: Installation, all: Bool, mayQuit: Bool) async -> Int32 {
        var failed = false
        var done = Set<ConfigTarget>()
        for agent in agents {
            guard let target = agent.target else {
                if !all {
                    print("\(agent.name): cannot use local servers.")
                    failed = true
                }
                continue
            }
            let presence = agent.locate()
            guard presence != .absent else {
                if !all {
                    print("\(agent.name): not installed.")
                    failed = true
                }
                continue
            }
            guard !done.contains(target) else { continue }
            switch target.registration(for: installation) {
            case .current:
                print("\(agent.name): already set up.")
                done.insert(target)
                continue
            case .notEditable(let reason):
                print("\(agent.name): \(reason); change it by hand.")
                failed = true
                continue
            default:
                break
            }
            let restarted = mayQuit && agent.mustQuit
            do {
                try await agent.setUp(installation, presence: presence, mayQuit: mayQuit)
                done.insert(target)
                print("\(agent.name): set up in \(target.file().path). \(hint(agent, restarted: restarted))")
            } catch {
                print("\(agent.name): \(error)\(agent.mustQuit ? " (or pass --restart)" : "")")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    static func hint(_ agent: Agent, restarted: Bool) -> String {
        switch agent.reload {
        case .newSession: "New sessions will have it."
        case .restart where agent.isOpen: "Restart \(agent.name) to load it."
        case .restart, .quitFirst: restarted ? "\(agent.name) was restarted with it." : "\(agent.name) loads it when it opens."
        }
    }

    static func install(_ agents: [Agent], _ installation: Installation, dryRun: Bool, mayQuit: Bool) async -> Int32 {
        var failed = false
        for agent in agents {
            if case .installed(let path, _) = agent.locate() {
                print("\(agent.name): already installed at \(path).")
                continue
            }
            guard let installer = agent.installer(for: installation) else {
                print("\(agent.name): \(agent.installRequirement.0).")
                failed = true
                continue
            }
            if dryRun {
                if case .app = installer { print("\(agent.name): would \(installer.summary)") } else { print("\(agent.name): would run \(installer.summary)") }
                continue
            }
            print("\(agent.name): \(installer.summary)")
            do {
                try await installer.run { output in FileHandle.standardOutput.write(Data(output.utf8)) }
            } catch {
                print("\(agent.name): installing failed: \(error)")
                failed = true
                continue
            }
            if agent.target != nil, await setUp([agent], installation, all: false, mayQuit: mayQuit) != 0 { failed = true }
        }
        return failed ? 1 : 0
    }
}
