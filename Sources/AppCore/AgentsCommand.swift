import Agents
import Foundation

/// `agents`: the settings window's list of AI assistants, in the terminal.
///
///     apple-notes-mcp agents                    which agents are here and set up
///     apple-notes-mcp agents set-up ID… | --all registers the server with them
///     apple-notes-mcp agents install ID…        installs them, then registers the server
///
/// (apple-reminders-mcp alike.)
///
/// `--skill` sets up the skill instead of the server: in each agent's own skills folder, or, with
/// `--folder DIR` (which implies --skill), in that project. `--restart` lets set-up quit and
/// reopen an app that must be closed while its settings change (Claude); `--dry-run` makes install
/// only say what it would do.
struct AgentsCommand {
    let version: String
    /// The skill for a copy of the app.
    let skill: @Sendable (Installation) -> String
    var program = Product.current.command

    /// What set-up writes: the server's entry in the agent's settings, or the skill, globally or in
    /// a project folder.
    enum Mode {
        case server
        case skill(folder: URL?)
    }

    func run(_ arguments: [String]) async -> Int32 {
        var arguments = arguments
        var folder: URL?
        if let index = arguments.firstIndex(where: { $0 == "--folder" || $0.hasPrefix("--folder=") }) {
            let word = arguments.remove(at: index)
            var path = String(word.dropFirst("--folder=".count))
            if word == "--folder" {
                guard index < arguments.count else { return usage() }
                path = arguments.remove(at: index)
            }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
                print("\(url.path) is not a folder.")
                return 2
            }
            folder = url
        }
        let options = Set(arguments.filter { $0.hasPrefix("-") })
        let words = arguments.filter { !$0.hasPrefix("-") }
        let known: Set<String> = ["--all", "--restart", "--dry-run", "--skill"]
        guard options.isSubset(of: known), words.first != "help" else { return usage() }
        let mode = options.contains("--skill") || folder != nil ? Mode.skill(folder: folder) : .server
        let installation = Installation.detect()
        switch words.first {
        case nil, "list":
            guard options.subtracting(["--skill"]).isEmpty, words.count <= 1 else { return usage() }
            list(installation, mode)
            return 0
        case "set-up", "setup":
            let all = options.contains("--all")
            guard let agents = all ? Agent.all : pick(Array(words.dropFirst())), !agents.isEmpty, !all || words.count == 1 else { return usage() }
            return await setUp(agents, installation, mode, all: all, mayQuit: options.contains("--restart"))
        case "install":
            guard let agents = pick(Array(words.dropFirst())), !agents.isEmpty, !options.contains("--all") else { return usage() }
            return await install(agents, installation, mode, dryRun: options.contains("--dry-run"), mayQuit: options.contains("--restart"))
        default:
            return usage()
        }
    }

    func usage() -> Int32 {
        print("""
            usage: \(program) agents [list] [--skill] [--folder DIR]
                   \(program) agents set-up (ID... | --all) [--restart] [--skill] [--folder DIR]
                   \(program) agents install ID... [--dry-run] [--restart] [--skill] [--folder DIR]
            --skill sets up the skill instead of the server; --folder puts it in that project.
            IDs: \(Agent.all.map(\.id).joined(separator: ", "))
            """)
        return 2
    }

    func pick(_ ids: [String]) -> [Agent]? {
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

    func describe(_ installation: Installation) -> String {
        switch installation.method {
        case .homebrew: "installed with Homebrew"
        case .package(let allUsers): allUsers ? "installed from the package for all users" : "installed from the package for this user"
        case .other: installation.bundle == nil ? "not an app bundle (a development build)" : "not installed from a release"
        }
    }

    func list(_ installation: Installation, _ mode: Mode) {
        print("\(Product.current.name) \(version), \(describe(installation)).")
        switch mode {
        case .server:
            print("Agents start: \(installation.command) \(installation.arguments.joined(separator: " "))\n")
        case .skill(let folder):
            print("The skill runs: \(installation.command)")
            print("Skills go in: \(folder.map { "\(Shell.abbreviate($0.path)) (in .claude/skills or .agents/skills)" } ?? "each agent's own skills folder")\n")
        }
        let skill = self.skill(installation)
        for agent in Agent.all {
            let id = agent.id.padding(toLength: 17, withPad: " ", startingAt: 0)
            switch agent.locate() {
            case .absent:
                let install = agent.installer(for: installation).map { "install: \($0.summary)" } ?? agent.installRequirement.0
                print("\(id)\(agent.name): not installed. \(install)")
            case .installed(let path, let version):
                let status = switch mode {
                case .server: status(agent, installation)
                case .skill(let folder): skillStatus(agent, installation, skill, folder: folder)
                }
                print("\(id)\(agent.name)\(version.map { " " + $0 } ?? "") (\(Shell.abbreviate(path))): \(status)")
            }
        }
    }

    func status(_ agent: Agent, _ installation: Installation) -> String {
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

    func skillStatus(_ agent: Agent, _ installation: Installation, _ skill: String, folder: URL?) -> String {
        guard let target = agent.skills else { return "cannot run commands on this Mac" }
        let file = Shell.abbreviate(target.file(project: folder).path)
        switch target.registration(of: skill, project: folder) {
        case .current: return "skill set up in \(file)"
        case .missing: return "no skill (it would go in \(file))"
        case .different(let command) where command == installation.command: return "skill from another version in \(file); set it up again"
        case .different(let command): return "skill for another copy (\(command)) in \(file)"
        case .broken(let command): return "skill with a missing command (\(command)) in \(file)"
        case .disabled: return "skill turned off"
        case .unreadable(let error): return "cannot read its skill: \(error)"
        case .notEditable(let reason): return "\(reason), left alone"
        }
    }

    func setUp(_ agents: [Agent], _ installation: Installation, _ mode: Mode, all: Bool, mayQuit: Bool) async -> Int32 {
        guard case .server = mode else { return setUpSkill(agents, installation, mode, all: all) }
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

    /// Writes the skill where each agent reads it, each file once.
    func setUpSkill(_ agents: [Agent], _ installation: Installation, _ mode: Mode, all: Bool) -> Int32 {
        guard case .skill(let folder) = mode else { return 2 }
        let skill = self.skill(installation)
        var failed = false
        var done = Set<String>()
        for agent in agents {
            guard let target = agent.skills else {
                if !all {
                    print("\(agent.name): cannot run commands on this Mac.")
                    failed = true
                }
                continue
            }
            guard agent.locate() != .absent else {
                if !all {
                    print("\(agent.name): not installed.")
                    failed = true
                }
                continue
            }
            let file = target.file(project: folder)
            guard !done.contains(file.path) else { continue }
            switch target.registration(of: skill, project: folder) {
            case .current:
                print("\(agent.name): skill already set up in \(file.path).")
                done.insert(file.path)
                continue
            case .notEditable(let reason):
                print("\(agent.name): \(reason); change it by hand.")
                failed = true
                continue
            default:
                break
            }
            do {
                try target.install(skill, project: folder)
                done.insert(file.path)
                print("\(agent.name): skill set up in \(file.path). New sessions will have it.")
            } catch {
                print("\(agent.name): \(error)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    func hint(_ agent: Agent, restarted: Bool) -> String {
        switch agent.reload {
        case .newSession: "New sessions will have it."
        case .restart where agent.isOpen: "Restart \(agent.name) to load it."
        case .restart, .quitFirst: restarted ? "\(agent.name) was restarted with it." : "\(agent.name) loads it when it opens."
        }
    }

    func install(_ agents: [Agent], _ installation: Installation, _ mode: Mode, dryRun: Bool, mayQuit: Bool) async -> Int32 {
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
            let canSetUp = switch mode {
            case .server: agent.target != nil
            case .skill: agent.skills != nil
            }
            if canSetUp, await setUp([agent], installation, mode, all: false, mayQuit: mayQuit) != 0 { failed = true }
        }
        return failed ? 1 : 0
    }
}
