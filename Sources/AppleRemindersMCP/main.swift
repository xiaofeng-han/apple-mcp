import EventKit
import Foundation
import Launcher
import Wire

let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
let arguments = Set(CommandLine.arguments.dropFirst())

/// What to do: `--stdio` (or input from a pipe or socket) serves MCP; `setup` asks for the
/// Reminders permission in the terminal; `--self-check` prints a diagnosis; `agents` lists, sets
/// up and installs AI agents; `--settings` (or a double-click in Finder) opens the settings window.
enum Mode { case serve, setup, check, agents, settings }

let mode: Mode = {
    if CommandLine.arguments.dropFirst().first == "agents" { return .agents }
    if arguments.contains("setup") || arguments.contains("authorize") { return .setup }
    if arguments.contains("--self-check") { return .check }
    if arguments.contains("--settings") { return .settings }
    if arguments.contains("--stdio") { return .serve }
    var info = stat()
    fstat(STDIN_FILENO, &info)
    let kind = info.st_mode & S_IFMT
    return kind == S_IFIFO || kind == S_IFSOCK ? .serve : .settings
}()

// Only the app bundle has an identity worth holding the Reminders permission; a bare build runs
// with whatever started it.
if Bundle.main.bundleIdentifier == "com.xiaofeng.apple-reminders-mcp" {
    launcher_become_responsible("APPLE_REMINDERS_MCP_RELAUNCHED")
}
setvbuf(stdout, nil, _IOLBF, 0)

func describe(_ status: EKAuthorizationStatus) -> String {
    switch status {
    case .fullAccess: "full access"
    case .notDetermined: "not asked yet"
    case .denied: "denied"
    case .restricted: "restricted"
    case .writeOnly: "write only"
    @unknown default: "unknown (\(status.rawValue))"
    }
}

/// APPLE_REMINDERS_MCP_WRITE_GUARD: comma-separated names of the only lists, groups, smart lists
/// and templates writes may touch (for development and checks).
let writeGuard: Set<String>? = ProcessInfo.processInfo.environment["APPLE_REMINDERS_MCP_WRITE_GUARD"].flatMap { value in
    let names = Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    return names.isEmpty ? nil : names
}
let store = RemindersStore(writeGuard: writeGuard)

/// Runs `work` on the main actor and exits with what it returns. The top-level code itself stays
/// synchronous: async top-level code runs as one long job on the main queue, and the settings
/// window's event loop inside it would keep every other main-actor task from running.
func runThenExit(_ work: @escaping @MainActor () async -> Int32) -> Never {
    Task { @MainActor in exit(await work()) }
    dispatchMain()
}

switch mode {
case .setup:
    runThenExit {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        print("Reminders access:", describe(status))
        if status == .notDetermined {
            print("Asking for access; click Allow in the dialog (it may be behind other windows).")
            let granted = (try? await EKEventStore().requestFullAccessToReminders()) ?? false
            print(granted ? "Access granted." : "Access was not granted.")
        } else if status != .fullAccess {
            print(RemindersStore.permissionHelp)
        }
        return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess ? 0 : 1
    }

case .check:
    print("Apple Reminders MCP \(version) (\(Bundle.main.bundleIdentifier ?? "development build"))")
    print("Reminders access:", describe(EKEventStore.authorizationStatus(for: .reminder)))
    if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
        do {
            let lists = try store.lists()
            let total = try lists.reduce(0) { $0 + (try store.reminders(in: $1.id).count) }
            print("Reminders data: OK, \(total) reminders in \(lists.count) lists")
        } catch {
            print("Reminders data:", error)
        }
    }
    print("Full Disk Access (optional):", DeletedDatabase.available ? "yes" : "no")
    print("Agents may complete repeating reminders:", Settings.allowCompletingRecurring ? "yes" : "no")
    if let writeGuard { print("Write guard:", writeGuard.sorted().map { "\"\($0)\"" }.joined(separator: ", ")) }
    exit(0)

case .agents:
    runThenExit { await AgentsCommand.run(Array(CommandLine.arguments.dropFirst(2))) }

case .settings:
    SettingsPanel.show()
    exit(0)

case .serve:
    let instructions = """
        Apple Reminders on this Mac, synced through iCloud to the user's devices. find_reminders and \
        list_lists read; pass a reminder's id and version to update_reminder or delete_reminder. Times are \
        local to \(TimeZone.current.identifier): due and start take 2026-10-21 (all day) or 2026-10-21T09:00, \
        and a due time adds an alert then. urgent makes that alert ring like an alarm and needs a due time; \
        repeat and early_alerts need a due date. Tags are native, written without #. Subtasks are one level \
        deep (parent_id); sections divide a list. Lists marked shared are seen by other people: confirm \
        with the user before adding to or changing them, and assign with assigned_to. Deleted reminders \
        go to Recently Deleted; list_deleted and restore_reminder bring them back.
        """
    let service = Service(name: "apple-reminders-mcp", version: version, instructions: instructions,
                          tools: readTools(store) + writeTools(store) + organizeTools(store))
    runThenExit {
        await StdioServer.run(service)
        return 0
    }
}
