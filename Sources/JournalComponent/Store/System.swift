import AppKit
import Foundation

/// A problem the model can read and act on: a missing permission, something not found, a write
/// refused for a reason, an entry changed since it was read, a Journal this app does not know.
enum JournalError: Error, CustomStringConvertible {
    case noAccess(String)
    case notFound(String)
    case refused(String)
    case conflict(String)
    case unsupported(String)
    case failed(String)

    var description: String {
        switch self {
        case .noAccess(let m): m
        case .notFound(let what): "Not found: \(what)."
        case .refused(let m), .conflict(let m), .unsupported(let m), .failed(let m): m
        }
    }
}

/// Where Journal keeps its data, and the one permission the app needs to reach it.
enum Permissions {
    static let journalBundleID = "com.apple.journal"
    /// Journal's app group container ("moments" is Journal's name inside Apple).
    static let library = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Group Containers/group.com.apple.moments/Library")
    static let store = library.appendingPathComponent("moments.sqlite")
    static let attachments = library.appendingPathComponent("Attachments")

    /// Full Disk Access, tested by reading the start of Journal's database (no prompt appears).
    /// False also when Journal has never been opened on this Mac, which `hasData` tells apart.
    static var fullDiskAccess: Bool {
        guard let handle = FileHandle(forReadingAtPath: store.path) else { return false }
        defer { try? handle.close() }
        return ((try? handle.read(upToCount: 16)) ?? Data()).count == 16
    }

    /// Whether Journal's container exists at all. Its folder is visible without Full Disk Access.
    static var hasData: Bool { FileManager.default.fileExists(atPath: library.deletingLastPathComponent().path) }

    static var journalRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: journalBundleID).isEmpty }

    /// Journal's version on this Mac, such as "3.0".
    static var journalVersion: String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: journalBundleID)
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
    }

    /// Starts Journal hidden, so it uploads what this app wrote to iCloud. It runs in the background
    /// anyway once it has been opened; this covers a Mac where it was quit.
    @MainActor static func startJournalHidden() {
        guard !journalRunning, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: journalBundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    static let fullDiskSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static let fullDiskHelp = """
        Apple Journal MCP cannot read Journal's data: it needs Full Disk Access. Ask the user to turn on \
        "Apple Journal MCP" in System Settings → Privacy & Security → Full Disk Access (if it is not \
        listed, add it with + from Applications).
        """
    static let noDataHelp = """
        Journal has no data on this Mac yet. Ask the user to open Journal once (and turn on iCloud for \
        Journal in System Settings to see the entries from their other devices).
        """
    static let sandboxHelp = """
        Apple Journal MCP ran inside a sandbox (Codex runs commands in one), where macOS keeps it from \
        Journal's data. Run the same command again outside the sandbox, which the user may have to approve.
        """
}

/// Whether this Mac's Journal is the one Apple Journal MCP was made for. The app calls Journal's
/// own frameworks through interfaces written for Journal 3.0 on macOS 27.2, and links them weakly:
/// where a function is missing it is reported here instead of called.
enum Compatibility {
    static let madeFor = "Journal 3.0 (macOS 27.2)"

    /// The symbols the app calls that this Mac's frameworks do not have.
    static let missing: [String] = JournalSymbols.all.filter { dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0) == nil }

    static var problem: String? {
        guard !missing.isEmpty else { return nil }
        let journal = Permissions.journalVersion.map { "Journal \($0)" } ?? "Journal"
        return """
            This Mac's \(journal) (macOS \(ProcessInfo.processInfo.operatingSystemVersionString)) lacks \(missing.count) of the \
            \(JournalSymbols.all.count) functions of Journal that Apple Journal MCP calls; it was made for \(madeFor). Nothing \
            was read or changed. Ask the user to update Apple Journal MCP.
            """
    }
}

/// Polls `done` every half second for up to `seconds`.
@MainActor
func waitFor(_ seconds: Double, _ done: () throws(JournalError) -> Bool) async throws(JournalError) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while true {
        if try done() { return true }
        if Date() >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(500))
    }
}
