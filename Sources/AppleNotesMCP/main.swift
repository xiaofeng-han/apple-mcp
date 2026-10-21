import Agents
import AppKit
import Foundation
import Launcher
import NoteModel
import Wire

let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
let words = Array(CommandLine.arguments.dropFirst())

/// What to do, by the first word: `--stdio` (or, with no words, input from a pipe or socket)
/// serves MCP; `setup` checks and asks for the permissions from a terminal; `--self-check` prints
/// a diagnosis; `agents` lists, sets up and installs AI agents; `skill` prints the skill;
/// `--settings` (or, with no words, a double-click in Finder) opens the settings window; anything
/// else is a command (see Commands). Only the first word counts, so a search may be for "setup".
enum Mode { case serve, setup, check, agents, skill, version, settings, command }

let mode: Mode = {
    switch words.first {
    case "--stdio": return .serve
    case "setup": return .setup
    case "--self-check": return .check
    case "agents": return .agents
    case "skill": return .skill
    case "--version": return .version
    case "--settings": return .settings
    case nil:
        var info = stat()
        fstat(STDIN_FILENO, &info)
        let kind = info.st_mode & S_IFMT
        return kind == S_IFIFO || kind == S_IFSOCK ? .serve : .settings
    default: return .command
    }
}()

// Only the app bundle has an identity worth holding the permissions; a bare build runs with
// whatever started it.
if Bundle.main.bundleIdentifier == "com.xiaofeng.apple-notes-mcp" {
    launcher_become_responsible("APPLE_NOTES_MCP_RELAUNCHED")
}
setvbuf(stdout, nil, _IOLBF, 0)

/// APPLE_NOTES_MCP_WRITE_GUARD: while set (development and checks), only notes titled with this
/// prefix, and folders named with it, may be changed.
let writeGuard = ProcessInfo.processInfo.environment["APPLE_NOTES_MCP_WRITE_GUARD"].flatMap { $0.isEmpty ? nil : $0 }
let store = MainActor.assumeIsolated { NotesStore(writeGuard: writeGuard) }
/// What the server offers and the commands run.
let tools = MainActor.assumeIsolated { readTools(store, Descriptions()) + attachmentTools(store) + writeTools(store) }

func describe(_ state: Permissions.State) -> String {
    switch state {
    case .granted: "allowed"
    case .denied: "denied"
    case .notAsked: "not asked yet"
    case .unknown: "unknown (Notes is not running)"
    }
}

/// Runs `work` on the main actor and exits with what it returns. The top-level code itself stays
/// synchronous: async top-level code runs as one long job on the main queue, and the settings
/// window's event loop inside it would keep every other main-actor task from running.
///
/// The main thread runs a run loop rather than dispatchMain(), which would retire it and serve
/// the main queue from another thread: Notes' Core Data contexts are main-queue contexts, and
/// saving one off the main thread deadlocks.
func runThenExit(_ work: @escaping @MainActor () async -> Int32) -> Never {
    Task { @MainActor in exit(await work()) }
    RunLoop.main.add(Port(), forMode: .default)  // so the run loop never runs out of sources
    while true { RunLoop.main.run() }
}

switch mode {
case .setup:
    runThenExit {
        print("Full Disk Access:", Permissions.fullDiskAccess ? "allowed" : "not allowed")
        var automation = Permissions.automation(ask: false)
        if automation != .granted && automation != .denied {
            print("Asking to control Notes; click OK in the dialog (it may be behind other windows).")
            Permissions.startNotesHidden()
            for _ in 0..<20 {
                automation = await Task.detached { Permissions.automation(ask: true) }.value
                if automation != .unknown { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        print("Automation → Notes:", describe(automation))
        if !Permissions.fullDiskAccess {
            print("\n" + Permissions.fullDiskHelp)
            NSWorkspace.shared.open(Permissions.fullDiskSettings)
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
        if automation == .denied { print("\n" + Permissions.automationHelp) }
        return Permissions.fullDiskAccess && automation == .granted ? 0 : 1
    }

case .check:
    runThenExit {
        print("Apple Notes MCP \(version) (\(Bundle.main.bundleIdentifier ?? "development build"))")
        print("Full Disk Access:", Permissions.fullDiskAccess ? "allowed" : "not allowed")
        print("Automation → Notes:", describe(Permissions.automation(ask: false)))
        if launcher_is_sandboxed() != 0 { print("Sandbox: yes, so macOS keeps Notes out of reach; run this outside the sandbox") }
        do {
            let folders = try NotesStore(writeGuard: nil).folders()
            print("Notes data: OK, \(folders.reduce(0) { $0 + $1.noteCount }) notes in \(folders.count) folders")
        } catch {
            print("Notes data:", error)
        }
        if Settings.toolsFileOverride != nil {
            print("Tools file:", Settings.exposure.file.path, "(from APPLE_NOTES_MCP_TOOLS_FILE)")
        }
        do {
            let offered = Set(try Settings.exposure.offered(tools).map(\.name))
            let off = tools.map(\.name).filter { !offered.contains($0) }.sorted()
            print("Tools offered to AI assistants: \(offered.count) of \(tools.count)" + (off.isEmpty ? "" : " (turned off: \(off.joined(separator: ", ")))"))
        } catch {
            print("Tools offered to AI assistants: none, \(Settings.exposure.file.path) can't be read (\(error))")
        }
        if let writeGuard { print("Write guard: \"\(writeGuard)\"") }
        return 0
    }

case .agents:
    runThenExit { await AgentsCommand.run(Array(words.dropFirst())) }

case .skill:
    print(Skill.text(for: Installation.detect()), terminator: "")
    exit(0)

case .version:
    print("apple-notes-mcp \(version)")
    exit(0)

case .command:
    runThenExit { await Commands.run(words, tools: tools) }

case .settings:
    MainActor.assumeIsolated { SettingsPanel.show(tools: tools) }
    exit(0)

case .serve:
    let instructions = """
        Apple Notes on this Mac, synced through iCloud. Find notes with overview or search, then read_note, \
        and pass its version back to edit_note; make all changes to one note in a single edit_note call. \
        Each note paragraph is one Markdown line: # title, ## heading, ### subheading, * and - lists, 1. numbered, \
        - [ ] / - [x] checkboxes, > quote, two spaces per indent level, ``` monospaced, **bold**, *italic*, \
        ~~strike~~, <u>underline</u>, <mark>highlight</mark>, [link](url), | tables |. Keep \
        ![…](attachment:…) placeholders where they are. To describe many notes: overview with undescribed: \
        true, then one describe_note call.
        """
    let service = Service(name: "apple-notes-mcp", version: version, instructions: instructions,
                          tools: tools, exposure: Settings.exposure)
    runThenExit {
        await StdioServer.run(service)
        return 0
    }
}
