import AppKit
import Carbon
import ContactsModel
import Foundation

/// Contacts.app's AppleScript, run in this process: the only way an app without Apple's notes
/// entitlement reads and writes a contact's note (Contacts.framework removes the note from every
/// fetch, and a save of a card that has a note fails), and the way cards go in and out of groups
/// (CNSaveRequest's removeMember is a no-op on macOS 27, and its addMember fails on cards with notes).
///
/// The script is compiled once; handlers are called with typed Apple-event parameters, so no text
/// is ever spliced into AppleScript source. NSAppleScript is not thread-safe, hence the main actor.
/// Every handler that changes something saves in the same call: Contacts keeps AppleScript changes
/// pending until a save, and loses them if it quits first.
@MainActor
final class ContactsScript {
    nonisolated static let bundleID = "com.apple.AddressBook"

    private static let source = """
        on ready()
        \twith timeout of 5 seconds
        \t\ttell application id "com.apple.AddressBook"
        \t\t\treturn count of people
        \t\tend tell
        \tend timeout
        end ready

        on getnotes(ids)
        \ttell application id "com.apple.AddressBook"
        \t\tset out to {}
        \t\trepeat with i in ids
        \t\t\ttry
        \t\t\t\tset end of out to (note of person id (contents of i))
        \t\t\ton error number n
        \t\t\t\tset end of out to n
        \t\t\tend try
        \t\tend repeat
        \t\treturn out
        \tend tell
        end getnotes

        on allnotes()
        \ttell application id "com.apple.AddressBook"
        \t\treturn {id of every person, note of every person}
        \tend tell
        end allnotes

        on setnote(pid, txt)
        \ttell application id "com.apple.AddressBook"
        \t\tif txt is "" then
        \t\t\tset note of person id pid to missing value
        \t\telse
        \t\t\tset note of person id pid to txt
        \t\tend if
        \t\tsave
        \t\treturn unsaved
        \tend tell
        end setnote

        on addtogroup(pids, gid)
        \ttell application id "com.apple.AddressBook"
        \t\trepeat with p in pids
        \t\t\tadd person id (contents of p) to group id gid
        \t\tend repeat
        \t\tsave
        \t\treturn unsaved
        \tend tell
        end addtogroup

        on removefromgroup(pids, gid)
        \ttell application id "com.apple.AddressBook"
        \t\trepeat with p in pids
        \t\t\tremove person id (contents of p) from group id gid
        \t\tend repeat
        \t\tsave
        \t\treturn unsaved
        \tend tell
        end removefromgroup
        """

    static let automationHelp = """
        Apple Contacts MCP may not control Contacts, which it needs for notes and group members. Ask the \
        user to turn on Contacts under "Apple Contacts MCP" in System Settings → Privacy & Security → \
        Automation, or to run `apple-contacts-mcp setup` and click Allow.
        """

    /// Contacts keeps AppleScript changes in memory until a save works; when one does not (a card it
    /// will not save), it keeps that change, and every later one, unsaved until it quits.
    static let unsavedHelp = """
        Contacts did not save the change: it holds a change it cannot save, and saves nothing more until \
        it quits. Ask the user to quit Contacts and try again (what Contacts had not saved is lost).
        """

    private var script: NSAppleScript?

    /// A card's note: nil when it has none; "" when it has an empty one (which still blocks saves).
    /// missingCard: Contacts does not know the card (deleted, or not loaded yet right after Contacts
    /// starts), so callers check with Contacts.framework before acting on it.
    enum Note: Equatable {
        case none
        case text(String)
        case missingCard
    }

    func notes(of cardIDs: [String]) async throws(ContactsError) -> [String: Note] {
        guard !cardIDs.isEmpty else { return [:] }
        if cardIDs.count > 30 {
            let (known, all) = try await everyNote()
            return Dictionary(uniqueKeysWithValues: cardIDs.map { id in (id, all[id] ?? (known.contains(id) ? .none : .missingCard)) })
        }
        let result = try await call("getnotes", [list(cardIDs)])
        var notes: [String: Note] = [:]
        for (index, id) in cardIDs.enumerated() {
            guard let item = result.atIndex(index + 1) else { notes[id] = .missingCard; continue }
            if [typeSInt32, typeSInt16, typeSInt64].contains(item.descriptorType) {
                let number = Int(item.int32Value)
                if number == -1743 || number == -1744 { throw ContactsError(Self.automationHelp) }
                guard number == -1728 else { throw ContactsError("Contacts reported AppleScript error \(number) reading the note of \(id).") }
                notes[id] = .missingCard
                continue
            }
            notes[id] = Self.note(item)
        }
        return notes
    }

    /// Every card's note in one call (about a third of a second for 600 cards); cards without a note
    /// are left out.
    func allNotes() async throws(ContactsError) -> [String: Note] {
        try await everyNote().notes
    }

    /// The cards Contacts knows, and the notes of those that have one.
    private func everyNote() async throws(ContactsError) -> (known: Set<String>, notes: [String: Note]) {
        let result = try await call("allnotes", [])
        guard let ids = result.atIndex(1), let notes = result.atIndex(2), ids.numberOfItems == notes.numberOfItems else {
            throw ContactsError("Contacts answered with notes that do not match its cards; try again.")
        }
        var known = Set<String>(), all: [String: Note] = [:]
        guard ids.numberOfItems > 0 else { return (known, all) }
        for index in 1...ids.numberOfItems {
            guard let id = ids.atIndex(index)?.stringValue, let item = notes.atIndex(index) else { continue }
            known.insert(id)
            let note = Self.note(item)
            if note != .none { all[id] = note }
        }
        return (known, all)
    }

    /// Sets a card's note; nil or "" removes it (the note row goes, which lets Contacts.framework save
    /// the card again).
    func setNote(_ cardID: String, to text: String?) async throws(ContactsError) {
        try saved(await call("setnote", [NSAppleEventDescriptor(string: cardID), NSAppleEventDescriptor(string: text ?? "")]))
    }

    func add(_ cardIDs: [String], toGroup groupID: String) async throws(ContactsError) {
        guard !cardIDs.isEmpty else { return }
        try saved(await call("addtogroup", [list(cardIDs), NSAppleEventDescriptor(string: groupID)]))
    }

    func remove(_ cardIDs: [String], fromGroup groupID: String) async throws(ContactsError) {
        guard !cardIDs.isEmpty else { return }
        try saved(await call("removefromgroup", [list(cardIDs), NSAppleEventDescriptor(string: groupID)]))
    }

    /// A handler that saves answers Contacts' `unsaved` afterwards: true means the save failed.
    private func saved(_ unsaved: NSAppleEventDescriptor) throws(ContactsError) {
        if unsaved.descriptorType == typeTrue || (unsaved.descriptorType == typeBoolean && unsaved.booleanValue) {
            throw ContactsError(Self.unsavedHelp)
        }
    }

    private static func note(_ item: NSAppleEventDescriptor) -> Note {
        switch item.descriptorType {
        case typeType where item.typeCodeValue == OSType(cMissingValue): return .none
        case typeTrue, typeFalse, typeBoolean: return .missingCard
        default: return item.stringValue.map { .text($0) } ?? .none
        }
    }

    private func list(_ items: [String]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (index, item) in items.enumerated() { list.insert(NSAppleEventDescriptor(string: item), at: index + 1) }
        return list
    }

    /// Starts Contacts hidden, without bringing it to the front, when it is not running, and waits
    /// until it answers (it knows no card while it is still loading).
    ///
    /// An Apple event sent while Contacts is still launching can stay unanswered: this process then
    /// waited out AppleScript's 2-minute timeout on every try, up to 40 tries, while a new process
    /// was answered at once. So the first event waits until Contacts has finished launching, each
    /// try gives up after 5 seconds and recompiles the script (Contacts is looked up again), and
    /// after 30 seconds this throws instead of waiting on.
    private func ensureRunning() async throws(ContactsError) {
        var running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
        if !running.isEmpty, running.allSatisfy(\.isFinishedLaunching) { return }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        if running.isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
                throw ContactsError("Contacts.app is not on this Mac.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.addsToRecentItems = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        while clock.now < deadline {
            running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            if !running.isEmpty, running.allSatisfy(\.isFinishedLaunching) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        while clock.now < deadline {
            let (_, info) = try execute("ready", [])
            guard let number = info?[NSAppleScript.errorNumber] as? Int else { return }
            if number == -1743 || number == -1744 { throw ContactsError(Self.automationHelp) }
            // Timed out (-1712), or the connection went stale (-609, -600): look Contacts up again.
            if [-1712, -609, -600].contains(number) { script = nil }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw ContactsError("Contacts.app does not answer. Ask the user to quit Contacts and try again.")
    }

    /// Runs a handler once; the error, if any, is returned rather than thrown.
    private func execute(_ handler: String, _ arguments: [NSAppleEventDescriptor]) throws(ContactsError) -> (NSAppleEventDescriptor, NSDictionary?) {
        if script == nil {
            let compiled = NSAppleScript(source: Self.source)
            var info: NSDictionary?
            guard let compiled, compiled.compileAndReturnError(&info) else {
                throw ContactsError("The AppleScript for Contacts did not compile: \(info?[NSAppleScript.errorMessage] ?? "unknown error")")
            }
            script = compiled
        }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        let parameters = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() { parameters.insert(argument, at: index + 1) }
        event.setParam(parameters, forKeyword: keyDirectObject)
        var info: NSDictionary?
        let result = script!.executeAppleEvent(event, error: &info)
        return (result, info)
    }

    private func call(_ handler: String, _ arguments: [NSAppleEventDescriptor]) async throws(ContactsError) -> NSAppleEventDescriptor {
        try await ensureRunning()
        var (result, info) = try execute(handler, arguments)
        // Contacts.app hears of a card this app has just added a moment later; until then it does not
        // know the card (-1728). Ask again for a few seconds.
        for _ in 0..<10 where (info?[NSAppleScript.errorNumber] as? Int) == -1728 {
            try? await Task.sleep(for: .milliseconds(300))
            (result, info) = try execute(handler, arguments)
        }
        if let info {
            let number = info[NSAppleScript.errorNumber] as? Int ?? 0
            let message = info[NSAppleScript.errorMessage] as? String ?? "unknown error"
            if number == -1743 || number == -1744 { throw ContactsError(Self.automationHelp) }
            if number == -1728 { throw ContactsError("Contacts does not know that card or group (it may have been deleted); find it again.") }
            throw ContactsError("Contacts reported an AppleScript error \(number): \(message)")
        }
        return result
    }
}
