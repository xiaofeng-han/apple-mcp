import Agents
import AppKit
import Foundation
import Launcher
import Wire

/// An app's whole main.swift: `AppMain.run(NotesComponent.self)`.
public enum AppMain {
    /// What to do, by the first word: `--stdio` (or, with no words, input from a pipe or socket)
    /// serves MCP; `setup` checks and asks for the permissions from a terminal; `--self-check`
    /// prints a diagnosis; `agents` lists, sets up and installs AI agents; `skill` prints the skill;
    /// `--settings` (or, with no words, a double-click in Finder) opens the settings window; a word
    /// of the app's own (Component.modes) runs that; anything else is a command (see Commands). Only
    /// the first word counts, so a search may be for "setup" and a reminder may be called that.
    enum Mode: Equatable {
        case serve, setup, check, agents, skill, version, settings, command
        case own(String)
    }

    static func mode(_ words: [String], own: Set<String>, inputIsPiped: () -> Bool) -> Mode {
        switch words.first {
        case "--stdio": .serve
        case "setup": .setup
        case "--self-check": .check
        case "agents": .agents
        case "skill": .skill
        case "--version": .version
        case "--settings": .settings
        case nil: inputIsPiped() ? .serve : .settings
        case let word? where own.contains(word): .own(word)
        default: .command
        }
    }

    /// Whether stdin is a pipe or a socket, as when an agent starts the server.
    static func inputIsPiped() -> Bool {
        var info = stat()
        fstat(STDIN_FILENO, &info)
        let kind = info.st_mode & S_IFMT
        return kind == S_IFIFO || kind == S_IFSOCK
    }

    @MainActor
    public static func run<App: Component>(_: App.Type) -> Never {
        let product = App.product
        Product.current = product
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let words = Array(CommandLine.arguments.dropFirst())

        // Only the app bundle has an identity worth holding the permissions; a bare build runs with
        // whatever started it.
        if Bundle.main.bundleIdentifier == product.bundleID {
            launcher_become_responsible(product.environmentPrefix + "_RELAUNCHED")
        }
        setvbuf(stdout, nil, _IOLBF, 0)

        let writeGuard = ProcessInfo.processInfo.environment[product.environmentPrefix + "_WRITE_GUARD"].flatMap { $0.isEmpty ? nil : $0 }
        let component = App(ComponentContext(version: version, writeGuard: writeGuard))
        let modes = component.modes

        switch mode(words, own: Set(modes.keys), inputIsPiped: inputIsPiped) {
        case .setup:
            runThenExit { await component.setup() }

        case .check:
            runThenExit {
                print("\(product.name) \(version) (\(Bundle.main.bundleIdentifier ?? "development build"))")
                for line in await component.selfCheck() { print(line) }
                let tools = component.tools
                let exposure = AppSettings.exposure
                if AppSettings.toolsFileOverride != nil {
                    print("Tools file:", exposure.file.path, "(from \(AppSettings.toolsFileVariable))")
                }
                do {
                    let offered = Set(try exposure.offered(tools).map(\.name))
                    let off = tools.map(\.name).filter { !offered.contains($0) }.sorted()
                    print("Tools offered to AI assistants: \(offered.count) of \(tools.count)" + (off.isEmpty ? "" : " (turned off: \(off.joined(separator: ", ")))"))
                } catch {
                    print("Tools offered to AI assistants: none, \(exposure.file.path) can't be read (\(error))")
                }
                if let writeGuard = component.writeGuardDescription { print("Write guard: \(writeGuard)") }
                return 0
            }

        case .agents:
            runThenExit { await AgentsCommand(version: version, skill: component.skillText).run(Array(words.dropFirst())) }

        case .skill:
            print(component.skillText(Installation.detect()), terminator: "")
            exit(0)

        case .version:
            print("\(product.command) \(version)")
            exit(0)

        case .command:
            runThenExit { await Commands(cli: App.cli, tools: component.tools).run(words) }

        case .settings:
            SettingsPanel.show(component)
            exit(0)

        case .own(let word):
            runThenExit { await modes[word]!(words) }

        case .serve:
            let service = Service(name: product.command, version: version, instructions: component.instructions,
                                  tools: component.tools, exposure: AppSettings.exposure)
            runThenExit {
                await StdioServer.run(service, wireLog: product.environmentPrefix + "_WIRE_LOG")
                return 0
            }
        }
    }

    /// Runs `work` on the main actor and exits with what it returns. The caller stays synchronous:
    /// async top-level code runs as one long job on the main queue, and the settings window's event
    /// loop inside it would keep every other main-actor task from running.
    ///
    /// The main thread runs a run loop rather than dispatchMain(), which would retire it and serve
    /// the main queue from another thread: Notes' Core Data contexts are main-queue contexts, and
    /// saving one off the main thread deadlocks.
    static func runThenExit(_ work: @escaping @MainActor @Sendable () async -> Int32) -> Never {
        Task { @MainActor in exit(await work()) }
        RunLoop.main.add(Port(), forMode: .default)  // so the run loop never runs out of sources
        while true { RunLoop.main.run() }
    }
}
