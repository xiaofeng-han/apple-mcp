import AppKit
import Foundation
import Launcher
import NoteModel
import Wire

let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
let arguments = Set(CommandLine.arguments.dropFirst())

/// What to do: `--stdio` (or input from a pipe or socket) serves MCP; `setup` checks and asks for
/// the permissions from a terminal; `--self-check` prints a diagnosis; `agents` lists, sets up and
/// installs AI agents; `--settings` (or a double-click in Finder) opens the settings window.
enum Mode { case serve, setup, check, agents, settings }

let mode: Mode = {
    if CommandLine.arguments.dropFirst().first == "agents" { return .agents }
    if arguments.contains("setup") { return .setup }
    if arguments.contains("--self-check") { return .check }
    if arguments.contains("--settings") { return .settings }
    if arguments.contains("--stdio") { return .serve }
    var info = stat()
    fstat(STDIN_FILENO, &info)
    let kind = info.st_mode & S_IFMT
    return kind == S_IFIFO || kind == S_IFSOCK ? .serve : .settings
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
        do {
            let folders = try NotesStore(writeGuard: nil).folders()
            print("Notes data: OK, \(folders.reduce(0) { $0 + $1.noteCount }) notes in \(folders.count) folders")
        } catch {
            print("Notes data:", error)
        }
        if let writeGuard { print("Write guard: \"\(writeGuard)\"") }
        return 0
    }

case .agents:
    runThenExit { await AgentsCommand.run(Array(CommandLine.arguments.dropFirst(2))) }

case .settings:
    MainActor.assumeIsolated { SettingsPanel.show() }
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
    runThenExit {
        let store = NotesStore(writeGuard: writeGuard)
        let descriptions = Descriptions()
        let service = Service(name: "apple-notes-mcp", version: version, instructions: instructions,
                              tools: readTools(store, descriptions) + attachmentTools(store) + writeTools(store))
        await StdioServer.run(service)
        return 0
    }
}
