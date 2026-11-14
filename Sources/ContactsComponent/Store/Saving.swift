@preconcurrency import Contacts
import AppCore
import ContactsModel
import ContactsShim
import Foundation

/// Saving cards. Contacts.framework cannot save a card that has a note in a process without Apple's
/// notes entitlement (the save loads the note for the search index, and the load is refused), so the
/// note is set aside first: read, written to a recovery file, removed through Contacts' AppleScript,
/// then the card is saved and the note put back. If this app stops in between, the next call puts it
/// back from the file.
extension ContactsStore {
    /// ~/Library/Application Support/AppleContactsMCP/notes-aside.json: card id → note, while set aside.
    static var asideFile: URL { AppSettings.supportDirectory.appendingPathComponent("notes-aside.json") }

    /// Held (flock) by whichever process, server or command line, is setting notes aside, so another
    /// one never puts back a note that is aside on purpose.
    static var asideLockFile: URL { AppSettings.supportDirectory.appendingPathComponent("notes-aside.lock") }

    private func readAside() -> [String: String] {
        guard let data = try? Data(contentsOf: Self.asideFile) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func writeAside(_ notes: [String: String]) throws(ContactsError) {
        do {
            if notes.isEmpty {
                try? FileManager.default.removeItem(at: Self.asideFile)
            } else {
                try JSONEncoder().encode(notes).write(to: Self.asideFile, options: .atomic)
            }
        } catch {
            throw ContactsError("Could not keep a copy of a note before saving (\(error.localizedDescription)); nothing was changed.")
        }
    }

    /// Takes the notes-aside lock: at once, or (waiting) within a minute. Each call opens the file
    /// anew, so a second call in this same process waits for the first like another process would.
    private func lockAside(wait: Bool) async -> Int32? {
        let descriptor = open(Self.asideLockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        for attempt in 0..<300 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
            if !wait || attempt == 299 { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        close(descriptor)
        return nil
    }

    private func unlockAside(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// Puts back notes a previous run set aside and did not restore (it stopped mid-save). Skipped
    /// while another call holds the lock: those notes are aside on purpose.
    func restoreNotesSetAside() async {
        guard FileManager.default.fileExists(atPath: Self.asideFile.path), let lock = await lockAside(wait: false) else { return }
        defer { unlockAside(lock) }
        let pending = readAside()
        guard !pending.isEmpty else { return }
        var left = pending
        guard let current = try? await script.notes(of: Array(pending.keys)) else { return }
        let downtime = Set(downtimeCards(Array(pending.keys)).map(\.identifier))
        for (card, note) in pending where !downtime.contains(card) {
            switch current[card] {
            case .text(let text)? where !text.isEmpty:
                left.removeValue(forKey: card)  // it has a note again; leave it
            case .missingCard?:
                // AppleScript also answers this way while Contacts is still starting; drop the copy
                // only once Contacts.framework agrees the card is gone.
                if isGone(card) { left.removeValue(forKey: card) }
            default:
                if (try? await script.setNote(card, to: note)) != nil || isGone(card) { left.removeValue(forKey: card) }
            }
        }
        try? writeAside(left)
    }

    /// Cards Screen Time allows during Downtime. Contacts' AppleScript cannot save such a card: the save
    /// fails, and Contacts then keeps that change and every later one unsaved until it quits. So this
    /// app never writes them through AppleScript (their notes; their groups go through the framework).
    func downtimeCards(_ cardIDs: [String]) -> [CNContact] {
        guard !cardIDs.isEmpty else { return [] }
        let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as NSString, CNContactFormatter.descriptorForRequiredKeys(for: .fullName), Self.key("downtimeWhitelist")]
        return ((try? cards(cardIDs, keys: keys)) ?? []).filter { Self.text($0, "downtimeWhitelist") == "true" }
    }

    func refuseDowntimeNotes(_ cardIDs: [String]) throws(ContactsError) {
        guard let card = downtimeCards(cardIDs).first else { return }
        throw ContactsError("""
            "\(Self.displayName(card))" is allowed during Screen Time's Downtime: Contacts lets no other app change \
            its note, nor anything else while it has one (Contacts' save fails, and it then keeps later changes \
            unsaved too). Change it in Contacts itself; nothing was changed.
            """)
    }

    /// Whether Contacts.framework no longer has this card.
    private func isGone(_ card: String) -> Bool {
        guard let found = try? cards([card], keys: [CNContactIdentifierKey as NSString]) else { return false }
        return found.isEmpty
    }

    /// Runs a save of these cards (a CNSaveRequest the body fills) with their notes set aside.
    /// `newNotes` gives notes to write afterwards instead of the old ones (nil removes). Saves are
    /// tagged with this app as author; see prepare(_:cards:) for Screen Time.
    func saving(_ cardIDs: [String], newNotes: [String: String?] = [:], changingDowntime: Bool = false,
                _ body: (CNSaveRequest) throws -> Void) async throws(ContactsError) {
        try await notesAside(cardIDs, newNotes: newNotes) {
            let request = CNSaveRequest()
            prepare(request, cards: cardIDs, changingDowntime: changingDowntime)
            try body(request)
            try store.execute(request)
        }
    }

    /// Screen Time: Contacts.framework treats a card allowed during Downtime as read-only (CNErrorDomain
    /// 206) unless the save ignores guardian restrictions, as Contacts.app's own saves do. This app asks
    /// for that only when such a card (or a change to Downtime itself) is in the save, and never in an
    /// account a guardian manages, so a parent's limits still hold there.
    func prepare(_ request: CNSaveRequest, cards cardIDs: [String], account: String? = nil, changingDowntime: Bool = false) {
        request.transactionAuthor = Self.author
        let cards = (try? self.cards(cardIDs, keys: [CNContactIdentifierKey as NSString, Self.key("downtimeWhitelist")])) ?? []
        guard changingDowntime || cards.contains(where: { Self.text($0, "downtimeWhitelist") == "true" }) else { return }
        let accounts = Set(cardIDs.compactMap(accountID(ofCard:)) + [account].compactMap { $0 })
        guard !accounts.isEmpty,
              let containers = try? store.containers(matching: CNContainer.predicateForContainers(withIdentifiers: Array(accounts))),
              containers.count == accounts.count, !containers.contains(where: { CSStore.isGuardianRestrictedContainer($0) }) else { return }
        CSStore.allowDowntimeChanges(in: request)
    }

    /// Runs a save of these cards (any save: Contacts.framework's or AddressBook's) with their notes set
    /// aside; see saving(_:newNotes:_:). A note that cannot be put back at once stays in the recovery
    /// file (as the note asked for, after a successful save) and goes back on the next call.
    func notesAside(_ cardIDs: [String], newNotes: [String: String?] = [:], _ save: () throws -> Void) async throws(ContactsError) {
        guard let lock = await lockAside(wait: true) else {
            throw ContactsError("Another Apple Contacts MCP is saving a contact with a note; try again in a moment.")
        }
        defer { unlockAside(lock) }
        // The cards getting a new note are set aside too, so that their old note is out of the way
        // (and gone, when the new one is none).
        let involved = Set(cardIDs).union(newNotes.keys)
        let notes = try await script.notes(of: Array(involved))
        for (card, note) in notes where note == .missingCard && !isGone(card) {
            throw ContactsError("Contacts is still opening the card \(card); try again in a moment.")
        }
        var aside: [String: String] = [:]
        for (card, note) in notes {
            if case .text(let text) = note { aside[card] = text }
        }
        try refuseDowntimeNotes(Array(Set(aside.keys).union(newNotes.compactMap { $0.value?.isEmpty == false ? $0.key : nil })))
        if !aside.isEmpty {
            var file = readAside()
            for (card, text) in aside where !text.isEmpty { file[card] = text }
            try writeAside(file)
            var cleared: [String] = []
            for card in aside.keys.sorted() {
                do {
                    try await script.setNote(card, to: nil)
                    cleared.append(card)
                } catch {
                    // Put back what was cleared already, and change nothing else.
                    for done in cleared {
                        if let text = aside[done], !text.isEmpty, (try? await script.setNote(done, to: text)) != nil { file.removeValue(forKey: done) }
                    }
                    for card in aside.keys where !cleared.contains(card) { file.removeValue(forKey: card) }
                    try? writeAside(file)
                    throw error
                }
            }
        }
        var failure: ContactsError?
        do {
            try save()
        } catch let error as ContactsError {
            failure = error
        } catch {
            failure = Self.explain(error)
        }
        // Each card's note now: the one asked for after a successful save, else the one set aside. Every
        // card involved has none at the moment, so only non-empty text needs writing. The recovery file
        // holds the wanted note until it is written.
        // An entry this call did not decide (left by an earlier run for a card that has no note now)
        // stays for restoreNotesSetAside.
        var file = readAside()
        var wanted: [String: String] = [:]
        for card in involved where aside[card] != nil || (failure == nil && newNotes.keys.contains(card)) {
            let note: String? = failure == nil && newNotes.keys.contains(card) ? (newNotes[card] ?? nil) : aside[card]
            if let note, !note.isEmpty { wanted[card] = note }
            file.removeValue(forKey: card)
        }
        for (card, note) in wanted { file[card] = note }
        try? writeAside(file)
        var unwritten: [String] = []
        for card in wanted.keys.sorted() {
            if (try? await script.setNote(card, to: wanted[card])) != nil {
                file.removeValue(forKey: card)
            } else {
                unwritten.append(card)
            }
        }
        try? writeAside(file)
        if let failure { throw failure }
        if !unwritten.isEmpty {
            throw ContactsError("The change was saved, but Contacts did not take the note of \(unwritten.joined(separator: ", ")) yet; it is kept and written on the next call (read the contact again then).", afterSave: true)
        }
    }

    // MARK: Uploads

    /// Each card's CardDAV ETag (Contacts.framework's externalModificationTag): the server gives a new
    /// one each time it accepts the card, so a changed ETag means the change reached iCloud (or the
    /// account's server). This app cannot read Contacts' database itself, even with the Contacts
    /// permission; the framework reads it on its behalf.
    func uploadState(_ cardIDs: [String]) -> [String: (synced: Bool, tag: String?)] {
        guard let cards = try? cards(cardIDs, keys: [CNContactIdentifierKey as NSString, Self.key("externalModificationTag")]) else { return [:] }
        var states: [String: (Bool, String?)] = [:]
        for card in cards {
            let tag = Self.text(card, "externalModificationTag")
            states[card.identifier] = (tag != nil, tag)
        }
        return states
    }

    /// Waits up to `seconds` for Contacts to upload these cards (a new ETag), polling twice a second,
    /// and then for them to settle: iCloud may hand a card back changed right after an upload (a photo
    /// it stored apart, a service name it normalizes), which would change its version. True when all
    /// are uploaded; nil when they are in no syncing account (On My Mac).
    func waitForUpload(_ cardIDs: [String], before: [String: (synced: Bool, tag: String?)], seconds: Double = 45) async -> Bool? {
        let syncing = cardIDs.filter { accountID(ofCard: $0).map { !$0.hasPrefix("_local") } ?? false }
        guard !syncing.isEmpty else { return nil }
        let deadline = Date().addingTimeInterval(seconds)
        var uploaded = false
        while Date() < deadline {
            let now = uploadState(syncing)
            uploaded = syncing.allSatisfy { card in
                guard let tag = now[card]?.tag else { return false }
                return tag != before[card]?.tag
            }
            if uploaded { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard uploaded else { return false }
        var last = lastChange(syncing), quiet = Date()
        while Date() < deadline, Date().timeIntervalSince(quiet) < 3 {
            try? await Task.sleep(for: .milliseconds(500))
            let now = lastChange(syncing)
            if now != last { last = now; quiet = Date() }
        }
        return true
    }

    private func lastChange(_ cardIDs: [String]) -> Date? {
        ((try? cards(cardIDs, keys: [CNContactIdentifierKey as NSString, Self.key("modificationDate")])) ?? []).compactMap(\.modificationDateIfFetched).max()
    }
}
