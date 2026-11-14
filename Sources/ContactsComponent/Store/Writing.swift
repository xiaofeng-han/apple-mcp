@preconcurrency import Contacts
import ContactsModel
import ContactsShim
import Foundation
import Wire

/// Creating, changing and deleting contacts. Every change goes to individual cards (never through a
/// unified contact, which would copy values onto every linked card), checks the version that was
/// read, and keeps notes through Contacts' AppleScript.
extension ContactsStore {
    struct Written {
        let record: JSON
        /// nil: the contact is in an account kept on this Mac only.
        let uploaded: Bool?
    }

    static let photoKeys: [CNKeyDescriptor] = [CNContactImageDataKey as NSString, CNContactThumbnailImageDataKey as NSString]

    /// A contact read the way read_contact shows it, for the version check.
    func current(_ id: String, keys: [CNKeyDescriptor] = fullKeys) async throws(ContactsError) -> (unified: CNContact, cards: [CNContact], record: JSON) {
        let contact = try contact(id, keys: keys)
        let notes = try await script.notes(of: contact.cards.map(\.identifier))
        let accounts = Dictionary((try? self.accounts())?.map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        return (contact.unified, contact.cards, record(contact.unified, cards: contact.cards, notes: notes, accounts: accounts, me: myCardIDs()))
    }

    func checkVersion(_ record: JSON, _ version: String) throws(ContactsError) {
        let current = record["version"]?.string ?? ""
        guard current == version else {
            throw ContactsError("\"\(record["name"]?.string ?? "The contact")\" changed since it was read (version \(current), not \(version)). Read it again with read_contact and retry.")
        }
    }

    // MARK: Create

    func create(_ edit: ContactEdit, account nameOrID: String?, groups groupNames: [String], wait: Bool) async throws(ContactsError) -> Written {
        guard !edit.isEmpty else { throw ContactsError("Give the contact at least a name, a company, a phone number or an email address.") }
        let account = try account(orDefault: nameOrID)
        let groups = try groupNames.map { name throws(ContactsError) in try group(name) }
        for group in groups {
            guard group.account == account.id else {
                throw ContactsError("Group \"\(group.name)\" is in another account than \(account.name); a contact can only be in groups of its own account.")
            }
            try guarded(group.name, what: "groups")
        }
        if edit.downtimeAllowed == true, case .some(.some(let note)) = edit.note, !note.isEmpty {
            throw ContactsError("A contact allowed during Screen Time's Downtime cannot get a note from this app (Contacts lets no other app write one); create it without one of the two.")
        }
        let card = CNMutableContact()
        card.contactType = .person
        _ = try edit.apply(to: [card], target: 0)
        try guarded(card)
        let request = CNSaveRequest()
        prepare(request, cards: [], account: account.id, changingDowntime: edit.downtimeAllowed == true)
        request.add(card, toContainerWithIdentifier: account.id)
        try attempt { try store.execute(request) }
        let id = card.identifier
        let before = uploadState([id])
        // Groups, then the note. If either fails the new card goes again, so that a retry does not
        // make a second one.
        do {
            try addWithoutNote(id, to: groups.map(\.id))
            if case .some(.some(let note)) = edit.note { try await script.setNote(id, to: note) }
        } catch {
            let undo = CNSaveRequest()
            prepare(undo, cards: [id])
            undo.delete(card)
            if (try? store.execute(undo)) != nil { throw ContactsError("\(error) Nothing was created.") }
            throw ContactsError("\(error) The contact was created as \(id) without it; finish with update_contact rather than creating it again.")
        }
        let uploaded = wait ? await waitForUpload([id], before: before.mapValues { _ in (false, nil) }, seconds: edit.photo != nil ? 90 : 45) : nil
        return Written(record: await readBack(id, name: Self.displayName(card), what: "Created"), uploaded: uploaded)
    }

    /// The record of a card just written; when it cannot be read (Contacts' AppleScript is not
    /// answering), its id and name, so that the answer still says what happened.
    func readBack(_ id: String, name: String, what: String) async -> JSON {
        do {
            if let record = try await records([id]).first { return record }
        } catch {
            return ["id": .string(id), "name": .string(name), "warning": .string("\(what), but it could not be read back: \(error)")]
        }
        return ["id": .string(id), "name": .string(name)]
    }

    // MARK: Update

    func update(_ id: String, version: String, edit: ContactEdit, card cardID: String?, wait: Bool) async throws(ContactsError) -> Written {
        guard !edit.isEmpty else { throw ContactsError("Nothing to change: give at least one field.") }
        let keys = Self.fullKeys + (edit.photo != nil ? Self.photoKeys : [])
        let (_, cards, record) = try await current(id, keys: keys)
        try checkVersion(record, version)
        try guarded(record["name"]?.string ?? "", what: "contacts")
        let target = try targetIndex(cards, cardID)
        let mutable = cards.map { $0.mutableCopy() as! CNMutableContact }
        let changed = try edit.apply(to: mutable, target: target)
        for index in changed.union([target]) { try guarded(mutable[index]) }
        // The note goes to the card it is on, else the target card.
        var newNotes: [String: String?] = [:]
        if edit.note != nil || edit.downtimeAllowed == true {
            let notes = try await script.notes(of: cards.map(\.identifier))
            let noted = cards.filter { card in if case .text(let text)? = notes[card.identifier], !text.isEmpty { return true }; return false }
            if edit.downtimeAllowed == true, !noted.isEmpty || (edit.note ?? nil) != nil {
                throw ContactsError("A contact with a note cannot be allowed during Screen Time's Downtime from this app: Contacts lets no other app write the note of such a contact. Allow it in Screen Time instead; nothing was changed.")
            }
            switch edit.note {
            case .some(.some(let text)):
                // A new note goes to the card that has one, else the target.
                newNotes[(noted.first ?? cards[target]).identifier] = text
            case .some(.none):
                // Cleared on every card that has one, as Contacts would otherwise show another card's.
                for card in noted { newNotes[card.identifier] = .some(nil) }
                if noted.isEmpty { newNotes[cards[target].identifier] = .some(nil) }
            case .none:
                break
            }
        }
        let touched = changed.sorted().map { mutable[$0] }
        let ids = touched.map(\.identifier) + newNotes.keys.filter { key in !touched.contains { $0.identifier == key } }
        let before = uploadState(ids)
        if touched.isEmpty {
            try refuseDowntimeNotes(Array(newNotes.keys))
            for (card, note) in newNotes { try await script.setNote(card, to: note) }
        } else {
            try await saving(touched.map(\.identifier), newNotes: newNotes, changingDowntime: edit.downtimeAllowed != nil) { request in
                for card in touched { request.update(card) }
            }
        }
        let uploaded = wait ? await waitForUpload(ids, before: before, seconds: edit.photo != nil || record["photo"] == true ? 90 : 45) : nil
        let fresh = await readBack(cards[target].identifier, name: record["name"]?.string ?? id, what: "Updated")
        return Written(record: fresh, uploaded: uploaded)
    }

    /// The card a change goes to: the one given (which must be one of the contact's), else the one that
    /// gives the contact its name.
    func targetIndex(_ cards: [CNContact], _ cardID: String?) throws(ContactsError) -> Int {
        guard let cardID else { return 0 }
        guard let index = cards.firstIndex(where: { $0.identifier == cardID }) else {
            throw ContactsError("Card \(cardID) is not one of this contact's cards: \(cards.map(\.identifier).joined(separator: ", ")).")
        }
        return index
    }

    // MARK: Delete

    func delete(_ id: String, version: String, card cardID: String?) async throws(ContactsError) -> JSON {
        let (_, cards, record) = try await current(id)
        try checkVersion(record, version)
        try guarded(record["name"]?.string ?? "", what: "contacts")
        let doomed = try cardID.map { card throws(ContactsError) in [cards[try targetIndex(cards, card)]] } ?? cards
        let backups = try await backUp(doomed.map(\.identifier))
        let request = CNSaveRequest()
        prepare(request, cards: doomed.map(\.identifier))
        for card in doomed { request.delete(card.mutableCopy() as! CNMutableContact) }
        do {
            try attempt { try store.execute(request) }
        } catch {
            removeBackups(backups.map(\.card))
            throw error
        }
        return ["deleted": .string(record["name"]?.string ?? id),
                "cards": .array(backups.map { ["id": .string($0.card), "account": .string($0.accountName)] }),
                "restore": .string("restore_contact with a card id brings it back within 30 days")]
    }
}
