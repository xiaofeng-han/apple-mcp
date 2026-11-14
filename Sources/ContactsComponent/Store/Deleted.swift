@preconcurrency import Contacts
import AppCore
import ContactsModel
import ContactsShim
import Foundation
import Wire

/// What this app deleted, kept 30 days: Contacts has no Recently Deleted, and a delete reaches every
/// device. Each deleted card is archived whole (every field and its photo, as Contacts.framework holds
/// it), with its note, account and groups, in ~/Library/Application Support/AppleContactsMCP/Deleted.
/// Restoring adds it back with its own id, as Contacts.app's own undo of a delete does.
extension ContactsStore {
    static var deletedFolder: URL {
        let folder = AppSettings.supportDirectory.appendingPathComponent("Deleted", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static let keepDays = 30.0

    struct Backup: Codable {
        let card: String
        let name: String
        let account: String
        let accountName: String
        let note: String?
        let groups: [String]
        let deleted: Date
        /// The card, archived with NSKeyedArchiver.
        let archive: Data
    }

    private static func file(for card: String) -> URL {
        deletedFolder.appendingPathComponent(card.replacingOccurrences(of: ":", with: "_") + ".json")
    }

    /// Archives cards before they are deleted. Refuses while Contacts' AppleScript cannot see a card
    /// (Contacts is still starting), since its note would be missing from the copy.
    func backUp(_ cardIDs: [String]) async throws(ContactsError) -> [Backup] {
        let keys = Self.fullKeys + Self.photoKeys + [CNContactVCardSerialization.descriptorForRequiredKeys()]
        let cards = try self.cards(cardIDs, keys: keys)
        let notes = try await script.notes(of: cardIDs)
        for card in cards where notes[card.identifier] == .missingCard {
            throw ContactsError("Contacts is still opening \"\(Self.displayName(card))\", so its note cannot be kept yet; nothing was deleted. Try again in a moment.")
        }
        let accounts = Dictionary((try? self.accounts())?.map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        var backups: [Backup] = []
        func failed(_ message: String) -> ContactsError {
            removeBackups(backups.map(\.card))
            return ContactsError(message)
        }
        for card in cards {
            let archive: Data
            do {
                archive = try NSKeyedArchiver.archivedData(withRootObject: card, requiringSecureCoding: true)
            } catch {
                throw failed("Could not keep a copy of \"\(Self.displayName(card))\" before deleting it (\(error.localizedDescription)); nothing was deleted.")
            }
            var note: String?
            if case .text(let text)? = notes[card.identifier], !text.isEmpty { note = text }
            let account = accountID(ofCard: card.identifier) ?? ""
            let backup = Backup(card: card.identifier, name: Self.displayName(card), account: account,
                                accountName: accounts[account]?.name ?? account, note: note,
                                groups: groups(ofCards: [card]).map(\.identifier), deleted: Date(), archive: archive)
            do {
                try JSONEncoder().encode(backup).write(to: Self.file(for: card.identifier), options: .atomic)
            } catch {
                throw failed("Could not keep a copy of \"\(backup.name)\" before deleting it (\(error.localizedDescription)); nothing was deleted.")
            }
            backups.append(backup)
        }
        return backups
    }

    /// Removes copies kept for a delete that did not happen.
    func removeBackups(_ cardIDs: [String]) {
        for card in cardIDs { try? FileManager.default.removeItem(at: Self.file(for: card)) }
    }

    /// The backups of the last 30 days, newest first; older ones are removed.
    func deletedBackups() -> [Backup] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.deletedFolder, includingPropertiesForKeys: nil)) ?? []
        let cutoff = Date().addingTimeInterval(-Self.keepDays * 86_400)
        var backups: [Backup] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let backup = try? JSONDecoder().decode(Backup.self, from: data) else { continue }
            if backup.deleted < cutoff {
                try? FileManager.default.removeItem(at: file)
            } else {
                backups.append(backup)
            }
        }
        return backups.sorted { $0.deleted > $1.deleted }
    }

    func listDeleted() -> JSON {
        let rows = deletedBackups().map { backup -> JSON in
            let left = Int(ceil(Self.keepDays - Date().timeIntervalSince(backup.deleted) / 86_400))
            return ["id": .string(backup.card), "name": .string(backup.name), "account": .string(backup.accountName),
                    "deleted": .string(Self.stamp(backup.deleted)), "days_left": .int(max(left, 0))]
        }
        return ["deleted": .array(rows), "count": .int(rows.count)]
    }

    /// Brings a deleted card back with its id, then its groups and its note. If a step after the card
    /// itself fails, calling it again finishes the rest (the copy is kept until everything is back).
    func restore(_ cardID: String) async throws(ContactsError) -> JSON {
        guard let backup = deletedBackups().first(where: { $0.card.caseInsensitiveCompare(cardID) == .orderedSame }) else {
            throw ContactsError("No deleted card \(cardID) in the last 30 days; restore_contact without id lists them.")
        }
        try guarded(backup.name, what: "contacts")
        let homeGroups = backup.groups.compactMap { id in try? group(id) }.filter { writeGuard?.allows($0.name) ?? true }
        let resuming = !(try cards([backup.card], keys: [CNContactIdentifierKey as NSString])).isEmpty
        var account: Account
        var warning: String?
        if resuming {
            account = try self.account(accountID(ofCard: backup.card) ?? backup.account)
            let current = try await script.notes(of: [backup.card])
            if backup.note != nil, current[backup.card] == .missingCard {
                throw ContactsError("Contacts is still opening \"\(backup.name)\", so its note is not back yet; restore_contact with id \(backup.card) again in a moment finishes it.")
            }
            if let note = backup.note, current[backup.card] == ContactsScript.Note.none || current[backup.card] == .text("") {
                if downtimeCards([backup.card]).isEmpty {
                    try await script.setNote(backup.card, to: note)
                } else {
                    warning = "Its note was not restored: Contacts lets no other app write the note of a contact allowed during Downtime. The note was: \(note)"
                }
            }
            let inside = Set(try cards([backup.card], keys: [CNContactIdentifierKey as NSString]).flatMap { groups(ofCards: [$0]).map(\.identifier) })
            for group in homeGroups where !inside.contains(group.id) { try await membership([backup.card], in: group.id, present: true) }
        } else {
            let contact: CNContact
            do {
                guard let unarchived = try NSKeyedUnarchiver.unarchivedObject(ofClass: CNContact.self, from: backup.archive) else { throw CocoaError(.coderReadCorrupt) }
                contact = unarchived
            } catch {
                throw ContactsError("The copy of \"\(backup.name)\" cannot be read (\(error.localizedDescription)).")
            }
            let card = try Self.bridged { try CSStore.restorableCopy(of: contact) }
            // A note cannot go on a card allowed during Downtime from here, so such a card comes back
            // with its note and without that allowance (the user can give it again in Screen Time).
            var downtime = Self.text(contact, "downtimeWhitelist") == "true"
            if downtime, backup.note != nil {
                try Self.bridged { try CSStore.setDowntimeAllowed(false, contact: card) }
                downtime = false
                warning = "It is no longer allowed during Screen Time's Downtime: Contacts lets no other app write the note of such a contact, and the note came back. Allow it again in Screen Time if you want."
            }
            let accounts = (try? self.accounts()) ?? []
            if let original = accounts.first(where: { $0.id == backup.account }) { account = original } else { account = try defaultAccount() }
            let request = CNSaveRequest()
            prepare(request, cards: [], account: account.id, changingDowntime: downtime)
            request.add(card, toContainerWithIdentifier: account.id)
            try attempt { try store.execute(request) }
            // Groups first, while the card has no note (Contacts.framework cannot save a card with one),
            // then the note through Contacts' AppleScript.
            do {
                try addWithoutNote(backup.card, to: homeGroups.map(\.id))
                if let note = backup.note { try await script.setNote(backup.card, to: note) }
            } catch {
                throw ContactsError("\(error) \"\(backup.name)\" is back, but not yet all its groups and its note; restore_contact with id \(backup.card) again finishes it.")
            }
        }
        removeBackups([backup.card])
        var answer = await readBack(backup.card, name: backup.name, what: "Restored")
        if var object = answer.object {
            if account.id != backup.account { object["note_on_account"] = .string("Its account is gone, so it was restored to \(account.name).") }
            if let warning { object["warning"] = .string(warning) }
            answer = .object(object)
        }
        return answer
    }
}
