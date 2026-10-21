import AppKit
import CoreServices
import Foundation

/// A problem the model can read and act on: a missing permission, something not found, a write
/// refused for a reason, a note changed since it was read.
enum NotesError: Error, CustomStringConvertible {
    case noAccess(String)
    case notFound(String)
    case refused(String)
    case conflict(String)
    case failed(String)

    var description: String {
        switch self {
        case .noAccess(let m): m
        case .notFound(let what): "Not found: \(what)."
        case .refused(let m), .conflict(let m), .failed(let m): m
        }
    }
}

/// The two permissions the app needs, read live.
enum Permissions {
    enum State: Equatable {
        case granted, denied, notAsked
        /// Notes is not running, so Automation cannot be checked.
        case unknown
    }

    static let notesBundleID = "com.apple.Notes"
    static let store = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")

    /// Full Disk Access, tested by reading the start of the Notes database (no prompt appears).
    static var fullDiskAccess: Bool {
        guard let handle = FileHandle(forReadingAtPath: store.path) else { return false }
        defer { try? handle.close() }
        return ((try? handle.read(upToCount: 16)) ?? Data()).count == 16
    }

    /// Automation → Notes. With `ask`, macOS shows its prompt when the user has not decided yet.
    static func automation(ask: Bool) -> State {
        var target = AEAddressDesc()
        let id = Array(notesBundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, id, id.count, &target) == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .unknown
        }
    }

    /// Starts Notes hidden, so Automation can be checked and asked for.
    @MainActor static func startNotesHidden() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: notesBundleID).isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: notesBundleID)
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    static let fullDiskSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let automationSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    static let fullDiskHelp = """
        Apple Notes MCP cannot read the Notes database: it needs Full Disk Access. Ask the user to turn \
        on "Apple Notes MCP" in System Settings → Privacy & Security → Full Disk Access (if it is not \
        listed, add it with + from Applications).
        """
    static let automationHelp = """
        Apple Notes MCP may not control Notes, which it needs to upload changes to iCloud and to move \
        and delete notes and folders. Ask the user to turn on Notes under "Apple Notes MCP" in System \
        Settings → Privacy & Security → Automation, or to open Apple Notes MCP and click Allow.
        """
}

/// Notes' AppleScript, run in this process. NSAppleScript is not thread-safe, hence the main actor.
@MainActor
enum AppleScript {
    /// `text` as an AppleScript string literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Runs `tell application "Notes" to …`, returning the result as text.
    @discardableResult
    static func notes(_ command: String) throws(NotesError) -> String? {
        try run("tell application \"Notes\" to " + command).stringValue
    }

    /// A list result (`id of notes of folder …`), item by item. A list has no string value.
    static func notesList(_ command: String) throws(NotesError) -> [String] {
        let result = try run("tell application \"Notes\" to " + command)
        guard result.descriptorType == typeAEList else { return result.stringValue.map { [$0] } ?? [] }
        guard result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
    }

    static func run(_ source: String) throws(NotesError) -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw .failed("could not compile an AppleScript for Notes") }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info {
            let number = info[NSAppleScript.errorNumber] as? Int ?? 0
            let message = info[NSAppleScript.errorMessage] as? String ?? "unknown error"
            if number == -1743 || number == -1744 { throw .noAccess(Permissions.automationHelp) }
            throw .failed("Notes reported an AppleScript error \(number): \(message)")
        }
        return result
    }
}

/// Polls `done` every quarter second for up to `seconds`.
@MainActor
func waitFor(_ seconds: Double, _ done: () throws(NotesError) -> Bool) async throws(NotesError) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while true {
        if try done() { return true }
        if Date() >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(250))
    }
}
