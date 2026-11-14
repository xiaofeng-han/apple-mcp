@preconcurrency import Contacts
import ContactsModel
import ContactsShim
import Foundation
import Wire

/// vCard export and import, the change feed, Contacts' settings and photos.
extension ContactsStore {
    // MARK: Export

    /// Writes contacts (unified, as Contacts exports them) to a new .vcf file, with notes from
    /// Contacts' AppleScript.
    func export(_ ids: [String], to path: String, version21: Bool, notes withNotes: Bool, photos: Bool) async throws(ContactsError) -> JSON {
        guard path.hasPrefix("/") else { throw ContactsError("to must be an absolute path.") }
        let url = URL(fileURLWithPath: path)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ContactsError("\(path) exists already; give a new file.") }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isFolder), isFolder.boolValue else {
            throw ContactsError("The folder \(url.deletingLastPathComponent().path) does not exist.")
        }
        guard !ids.isEmpty else { throw ContactsError("Nothing to export.") }
        let keys: [CNKeyDescriptor] = [CNContactVCardSerialization.descriptorForRequiredKeys(), CNContactThumbnailImageDataKey as NSString,
                                       Self.key("linkedContacts"), Self.key("preferredForName")]
        var contacts: [CNContact] = []
        var noteCards: [String: String] = [:]
        var missing: [String] = [], notesLeftOut: [String] = []
        for id in ids {
            guard let unified = try? store.unifiedContact(withIdentifier: id, keysToFetch: keys) else { missing.append(id); continue }
            guard !contacts.contains(where: { $0.identifier == unified.identifier }) else { continue }
            contacts.append(unified)
            let cards = ((unified.value(forKey: "linkedContacts") as? [CNContact]) ?? []).map(\.identifier)
            noteCards[unified.identifier] = (cards.isEmpty ? [unified.identifier] : cards).joined(separator: "\n")
        }
        guard !contacts.isEmpty else { throw ContactsError("None of the contacts to export was found: \(missing.joined(separator: ", ")).") }
        if withNotes {
            let all = try await script.notes(of: noteCards.values.flatMap { $0.split(separator: "\n").map(String.init) })
            contacts = contacts.map { contact in
                let cards = noteCards[contact.identifier]?.split(separator: "\n").map(String.init) ?? []
                // A card Contacts does not know yet (just added elsewhere) may have a note it cannot give.
                if cards.contains(where: { all[$0] == .missingCard }) { notesLeftOut.append(contact.identifier) }
                guard let text = cards.lazy.compactMap({ card -> String? in
                    if case .text(let text)? = all[card], !text.isEmpty { return text }
                    return nil
                }).first else { return contact }
                guard let copy = try? CSStore.copy(of: contact, withNote: text) else {
                    notesLeftOut.append(contact.identifier)
                    return contact
                }
                return copy
            }
        }
        let data = try Self.bridged { try CSStore.vCard(for: contacts, version21: version21, photos: photos, notes: withNotes) }
        do {
            try data.write(to: url, options: .withoutOverwriting)
        } catch {
            throw ContactsError("Could not write \(path): \(error.localizedDescription)")
        }
        var answer: [String: JSON] = ["file": .string(path), "contacts": .int(contacts.count), "bytes": .int(data.count),
                                      "format": .string(version21 ? "vCard 2.1" : "vCard 3.0")]
        if !missing.isEmpty { answer["not_found"] = .array(missing.map { .string($0) }) }
        if !notesLeftOut.isEmpty { answer["notes_left_out"] = .array(notesLeftOut.map { .string($0) }) }
        return .object(answer)
    }

    // MARK: Import

    enum DuplicateChoice: String { case skip, update, keepBoth = "keep_both", replace }

    /// Imports a .vcf file. Duplicates are cards in the target account with the same name (last and
    /// first name, or the company), as Contacts' import matches them. A failure part way says what was
    /// imported before it.
    func importFile(_ path: String, account nameOrID: String?, group groupName: String?, duplicates: DuplicateChoice) async throws(ContactsError) -> JSON {
        guard let data = FileManager.default.contents(atPath: path) else { throw ContactsError("Cannot read \(path).") }
        let parsed: [CNContact]
        do { parsed = try CNContactVCardSerialization.contacts(with: data) } catch { throw ContactsError("\(path) is not a vCard file Contacts reads: \(error.localizedDescription)") }
        guard !parsed.isEmpty else { throw ContactsError("\(path) holds no contacts.") }
        let account = try account(orDefault: nameOrID)
        let group = try groupName.map { name throws(ContactsError) in try self.group(name) }
        if let group, group.account != account.id { throw ContactsError("Group \"\(group.name)\" is in another account than \(account.name).") }
        if let group { try guarded(group.name, what: "groups") }
        for contact in parsed { try guarded(Self.displayName(contact), what: "contacts") }

        let keys: [CNKeyDescriptor] = Self.fullKeys + Self.photoKeys
        func nameKey(_ contact: CNContact) -> String {
            contact.contactType == .organization ? "org|" + contact.organizationName.lowercased()
                : (contact.familyName + " " + contact.givenName).trimmingCharacters(in: .whitespaces).lowercased()
        }
        var byName = Dictionary(grouping: try cards(try cardIDs(inAccount: account.id), keys: keys), by: nameKey).mapValues { $0.map(\.identifier) }
        var added: [String] = [], updated: [String] = [], replaced: [String] = [], skipped: [JSON] = [], warnings: [String] = []
        func soFar() -> String {
            "Before that: \(added.count) added\(added.isEmpty ? "" : " (\(added.joined(separator: ", ")))"), \(updated.count) updated, \(replaced.count) replaced\(replaced.isEmpty ? "" : " (\(replaced.joined(separator: ", ")); restore_contact brings them back)")."
        }
        for contact in parsed {
            do throws(ContactsError) {
                let name = Self.displayName(contact)
                let note = contact.isKeyAvailable(CNContactNoteKey) ? contact.note : ""
                let key = nameKey(contact)
                let matchID = key == "org|" || key.isEmpty || duplicates == .keepBoth ? nil : byName[key]?.first
                let match = try matchID.flatMap { id throws(ContactsError) in try cards([id], keys: keys).first }
                if let match, duplicates == .update || duplicates == .replace { try guarded(match) }
                guard let match else {
                    added.append(try await add(contact, note: note, account: account.id, groups: group.map { [$0.id] } ?? []))
                    continue
                }
                switch duplicates {
                case .skip, .keepBoth:
                    skipped.append(["name": .string(name), "existing": .string(match.identifier)])
                case .update:
                    let keep = match.mutableCopy() as! CNMutableContact
                    Self.absorb(contact, into: keep)
                    var newNotes: [String: String?] = [:]
                    if !note.isEmpty {
                        let current = try await script.notes(of: [match.identifier])
                        if case .text(let old)? = current[match.identifier], !old.isEmpty {
                            if old != note { newNotes[match.identifier] = old + "\n\n" + note }
                        } else {
                            newNotes[match.identifier] = note
                        }
                    }
                    try await saving([match.identifier], newNotes: newNotes) { request in request.update(keep) }
                    updated.append(match.identifier)
                case .replace:
                    // The new card first, in the old one's groups; then the old one goes (a copy kept 30
                    // days); then the new one is linked to the old one's other cards and made the My Card
                    // if the old one was. A failure in those last steps is a warning.
                    let oldGroups = groups(ofCards: [match]).map(\.identifier).filter { id in (try? self.group(id)).map { writeGuard?.allows($0.name) ?? true } ?? false }
                    let siblingCards = ((try? self.contact(match.identifier).cards) ?? []).filter { $0.identifier != match.identifier }
                    let siblings = siblingCards.filter { writeGuard?.allows(Self.displayName($0)) ?? true }.map(\.identifier)
                    let wasMine = myCardIDs().contains(match.identifier)
                    let newID = try await add(contact, note: note, account: account.id, groups: Array(Set(oldGroups + (group.map { [$0.id] } ?? []))))
                    added.append(newID)
                    let backups = try await backUp([match.identifier])
                    let request = CNSaveRequest()
                    prepare(request, cards: [match.identifier])
                    request.delete(match.mutableCopy() as! CNMutableContact)
                    do {
                        try attempt { try store.execute(request) }
                    } catch {
                        removeBackups(backups.map(\.card))
                        throw ContactsError("\(error) \"\(name)\" was added as \(newID) but the old card \(match.identifier) is still there.")
                    }
                    replaced.append(match.identifier)
                    // Cards this import adds are never matched by later entries of the same file.
                    byName[key] = (byName[key] ?? []).filter { $0 != match.identifier }
                    if !siblings.isEmpty {
                        do throws(ContactsError) {
                            try await notesAside([newID] + siblings) { try Self.bridged { try CSAddressBook.linkCards([newID] + siblings, photoCard: nil) } }
                        } catch {
                            warnings.append(error.afterSave ? "\(name): linked, but \(error)"
                                            : "\(name): not linked to its other cards \(siblings.joined(separator: ", ")) (\(error)); link_contacts can do it.")
                        }
                    }
                    if wasMine {
                        let me = CNSaveRequest()
                        me.transactionAuthor = Self.author
                        if (try? Self.bridged({ try CSStore.setMeCardIdentifier(newID, request: me) })) == nil || (try? store.execute(me)) == nil {
                            warnings.append("\(name) was the My Card; set_my_card makes the new card \(newID) the My Card.")
                        }
                    }
                }
            } catch {
                throw ContactsError("\(error) \(soFar())")
            }
        }
        if let group, !updated.isEmpty {
            do throws(ContactsError) { try await membership(updated, in: group.id, present: true) } catch { throw ContactsError("\(error) \(soFar())") }
        }
        var result: [String: JSON] = ["account": .string(account.name), "added": .int(added.count), "ids": .array(added.map { .string($0) })]
        if !updated.isEmpty { result["updated"] = .array(updated.map { .string($0) }) }
        if !replaced.isEmpty { result["replaced"] = .array(replaced.map { .string($0) }); result["restore"] = "restore_contact brings a replaced card back within 30 days" }
        if !skipped.isEmpty { result["skipped_duplicates"] = .array(skipped) }
        if !warnings.isEmpty { result["warnings"] = .array(warnings.map { .string($0) }) }
        return .object(result)
    }

    /// Adds a parsed vCard contact (without its note, which Contacts.framework cannot save here), puts
    /// it in groups, and then writes its note through AppleScript. If the groups or the note fail, the
    /// card goes again.
    private func add(_ contact: CNContact, note: String, account: String, groups: [String]) async throws(ContactsError) -> String {
        let card = try Self.bridged { try CSStore.copyOmittingNote(contact) }
        let request = CNSaveRequest()
        prepare(request, cards: [], account: account)
        request.add(card, toContainerWithIdentifier: account)
        try attempt { try store.execute(request) }
        do {
            try addWithoutNote(card.identifier, to: groups)
            if !note.isEmpty { try await script.setNote(card.identifier, to: String(note.prefix(ContactEdit.noteLimit))) }
        } catch {
            let undo = CNSaveRequest()
            prepare(undo, cards: [card.identifier])
            undo.delete(card)
            if (try? store.execute(undo)) != nil { throw error }
            throw ContactsError("\(error) \"\(Self.displayName(card))\" was added as \(card.identifier) without it.")
        }
        return card.identifier
    }

    // MARK: Changes

    func changes(since token: String?, includeOwn: Bool) async throws(ContactsError) -> JSON {
        guard let token else {
            guard let current = CSStore.currentHistoryToken(of: store) else { throw ContactsError("Contacts gave no change-history token.") }
            return ["token": .string(current.base64EncodedString())]
        }
        guard let data = Data(base64Encoded: token) else { throw ContactsError("since is not a token contact_changes gave.") }
        let result: [String: Any]
        do {
            result = try CSStore.changes(in: store, since: data, excludingAuthor: includeOwn ? nil : Self.author)
        } catch {
            throw ContactsError("Contacts could not read its change history (\((error as NSError).localizedDescription)); ask again without since for a new token.")
        }
        let events = (result["events"] as? [[String: Any]]) ?? []
        if events.contains(where: { $0["kind"] as? String == "everything" }) {
            return ["token": .string((result["token"] as? Data)?.base64EncodedString() ?? token),
                    "everything": "Contacts reported that everything may have changed (it reindexed or relinked); read what you need again."]
        }
        var rows: [JSON] = []
        var names: [String: String] = [:]
        for event in events {
            var row: [String: JSON] = [:]
            for (key, value) in event { if let text = value as? String { row[key] = .string(text) } }
            if let id = event["contact"] as? String, event["kind"] as? String != "deleted" {
                if names[id] == nil, let contact = try? store.unifiedContact(withIdentifier: id, keysToFetch: Self.summaryKeys) { names[id] = Self.displayName(contact) }
                if let name = names[id] { row["name"] = .string(name) }
            }
            rows.append(.object(row))
        }
        return ["token": .string((result["token"] as? Data)?.base64EncodedString() ?? token), "changes": .array(rows), "count": .int(rows.count)]
    }

    // MARK: Settings

    static let contactsDomain = "com.apple.AddressBook" as CFString

    func settings() -> JSON {
        func value(_ key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, ContactsStore.contactsDomain) }
        let names = CSStore.nameSettings() ?? [:]
        let shortFormats = ["full name", "first name and last initial", "first initial and last name", "first name only", "last name only"]
        let shortFormat = (names["short_name_format"] as? Int) ?? 0
        let blocked = (CFPreferencesCopyAppValue("AppCanShowSiriSuggestionsBlacklist" as CFString, "com.apple.suggestions" as CFString) as? [String]) ?? []
        return [
            "sort_by": .string((names["sort_by_first_name"] as? Bool) == true ? "first_name" : "last_name"),
            "show_first_name": .string((names["family_name_first"] as? Bool) == true ? "following_last_name" : "before_last_name"),
            "short_names": .bool((names["short_names"] as? Bool) ?? false),
            "short_name_format": .string(shortFormats.indices.contains(shortFormat) ? shortFormats[shortFormat] : "\(shortFormat)"),
            "prefer_nicknames": .bool((names["prefer_nicknames"] as? Bool) ?? false),
            "address_format": .string((names["country_code"] as? String) ?? (value("ABDefaultAddressCountryCode") as? String) ?? "us"),
            "default_account": .string((try? defaultAccount().name) ?? ""),
            "vcard_version": .string(((value("ABUsevCard21Format") as? Bool) ?? false) ? "2.1" : "3.0"),
            "vcard_notes": .bool((value("ABIncludeNotesInVCard") as? Bool) ?? true),
            "vcard_photos": .bool((value("ABIncludePhotosInVCard") as? Bool) ?? true),
            "private_my_card": .bool((value("ABPrivateVCardFieldsEnabled") as? Bool) ?? false),
            "siri_suggestions": .bool(!blocked.contains(ContactsScript.bundleID)),
            "read_only_here": "show_first_name, short_names, short_name_format and prefer_nicknames are macOS-wide (System Settings); default_account changes with manage_accounts",
        ]
    }

    func changeSettings(_ changes: [String: Any]) throws(ContactsError) -> JSON {
        var keys: [(String, Any)] = []
        for (name, value) in changes {
            switch name {
            case "sort_by": keys.append(("ABNameSortingFormat", (value as? String) == "first_name" ? "sortingFirstName sortingLastName" : "sortingLastName sortingFirstName"))
            case "address_format":
                guard let code = (value as? String)?.lowercased(), code.count == 2, code.allSatisfy(\.isLetter) else { throw ContactsError("address_format is a two-letter country code (us, cn, de, …).") }
                keys.append(("ABDefaultAddressCountryCode", code))
            case "vcard_version": keys.append(("ABUsevCard21Format", (value as? String) == "2.1"))
            case "vcard_notes": keys.append(("ABIncludeNotesInVCard", value))
            case "vcard_photos": keys.append(("ABIncludePhotosInVCard", value))
            case "private_my_card": keys.append(("ABPrivateVCardFieldsEnabled", value))
            default: continue
            }
        }
        for (key, value) in keys { CFPreferencesSetAppValue(key as CFString, value as CFPropertyList, Self.contactsDomain) }
        CFPreferencesAppSynchronize(Self.contactsDomain)
        return settings()
    }

    // MARK: Photos

    /// The photo as Contacts shows it (the cropped thumbnail), the full image, or the poster's picture,
    /// from the card that gives the contact its photo.
    func photo(_ id: String, which: String) throws(ContactsError) -> (data: Data, name: String) {
        let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as NSString, CNContactImageDataKey as NSString, CNContactThumbnailImageDataKey as NSString,
                                       CNContactFormatter.descriptorForRequiredKeys(for: .fullName), Self.key("preferredForImage"),
                                       Self.key("linkIdentifier"), Self.key("watchWallpaperImageData")]
        let (unified, cards) = try contact(id, keys: keys)
        let ordered = cards.sorted { Self.flag($0, "preferredForImage") && !Self.flag($1, "preferredForImage") }
        let name = Self.displayName(unified)
        let data: Data?
        switch which {
        case "full": data = ordered.lazy.compactMap(\.imageData).first
        case "poster": data = ordered.lazy.compactMap { $0.value(forKey: "watchWallpaperImageData") as? Data }.first
        default: data = ordered.lazy.compactMap(\.thumbnailImageData).first ?? ordered.lazy.compactMap(\.imageData).first
        }
        guard let data, !data.isEmpty else {
            throw ContactsError(which == "poster" ? "\"\(name)\" has no poster picture on this Mac." : "\"\(name)\" has no photo.")
        }
        return (data, name)
    }
}
