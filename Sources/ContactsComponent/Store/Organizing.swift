@preconcurrency import Contacts
import ContactsModel
import ContactsShim
import Foundation
import Wire

/// Smart lists, linked cards, merging and duplicates, the My Card and the default account.
extension ContactsStore {
    // MARK: Smart lists

    func createSmartList(_ name: String, criteria: [String: Any], highlight: Bool) throws(ContactsError) -> JSON {
        try guarded(name, what: "smart lists")
        if try smartLists().contains(where: { ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ContactsError("A smart list named \"\(name)\" exists already.")
        }
        let id = try Self.bridged { try CSAddressBook.createSmartList(name, criteria: criteria, highlight: highlight) }
        return smartListJSON(try smartList(id))
    }

    func updateSmartList(_ nameOrID: String, name: String?, criteria: [String: Any]?, highlight: Bool?) throws(ContactsError) -> JSON {
        let list = try smartList(nameOrID)
        let id = list["id"] as? String ?? nameOrID
        try guarded(list["name"] as? String ?? "", what: "smart lists")
        if let name {
            try guarded(name, what: "smart lists")
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ContactsError("A smart list name cannot be empty.") }
            if try smartLists().contains(where: { ($0["id"] as? String) != id && ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }) {
                throw ContactsError("A smart list named \"\(name)\" exists already.")
            }
        }
        guard name != nil || criteria != nil || highlight != nil else { throw ContactsError("Give a new_name, criteria or highlight.") }
        try Self.bridged { try CSAddressBook.updateSmartList(id, name: name, criteria: criteria, highlight: highlight.map { NSNumber(value: $0) }) }
        return smartListJSON(try smartList(id))
    }

    func deleteSmartList(_ nameOrID: String) throws(ContactsError) -> JSON {
        let list = try smartList(nameOrID)
        try guarded(list["name"] as? String ?? "", what: "smart lists")
        try Self.bridged { try CSAddressBook.deleteSmartList(list["id"] as? String ?? "") }
        return ["deleted": .string(list["name"] as? String ?? ""), "id": .string(list["id"] as? String ?? "")]
    }

    func smartListJSON(_ list: [String: Any]) -> JSON {
        var row: [String: JSON] = ["id": .string(list["id"] as? String ?? ""), "name": .string(list["name"] as? String ?? ""),
                                   "cards": .int((list["members"] as? [String])?.count ?? 0)]
        if let criteria = list["criteria"] { row["criteria"] = Self.json(criteria) }
        if (list["highlight"] as? Bool) == true { row["highlight"] = true }
        return .object(row)
    }

    // MARK: Linking

    /// Mutable copies of every card of these contacts, for link and merge.
    private func allCards(_ ids: [String], keys: [CNKeyDescriptor] = fullKeys) throws(ContactsError) -> [CNContact] {
        var cards: [CNContact] = []
        for id in ids {
            for card in try contact(id, keys: keys).cards where !cards.contains(where: { $0.identifier == card.identifier }) {
                try guarded(card)
                cards.append(card)
            }
        }
        return cards
    }

    func link(_ ids: [String]) async throws(ContactsError) -> JSON {
        let cards = try allCards(ids)
        guard cards.count >= 2 else { throw ContactsError("Give two or more contacts or cards to link.") }
        // The first card gives the linked contact its name, the first with a photo its photo.
        let photo = cards.first { $0.imageDataAvailable }?.identifier
        try await notesAside(cards.map(\.identifier)) {
            try Self.bridged { try CSAddressBook.linkCards(cards.map(\.identifier), photoCard: photo) }
        }
        return try await records([cards[0].identifier]).first ?? .null
    }

    func unlink(_ id: String) async throws(ContactsError) -> JSON {
        let (_, cards) = try contact(id)
        guard cards.count > 1 else { throw ContactsError("That contact has one card; there is nothing to unlink.") }
        for card in cards { try guarded(card) }
        let one = id.hasSuffix(":ABPerson") ? cards.first { $0.identifier == id } : nil
        // Unlinking all but one card leaves the last one on its own.
        let affected = one.map { [$0] } ?? Array(cards.dropLast())
        try await notesAside(affected.map(\.identifier)) {
            for card in affected { try Self.bridged { try CSAddressBook.unlinkCard(card.identifier) } }
        }
        return ["unlinked": .array(affected.map { .string($0.identifier) }),
                "contacts": .array(try await records(cards.map(\.identifier)).map(summary))]
    }

    /// Makes one card give its linked contact the name (or the photo).
    func prefer(_ cardID: String, name: Bool) async throws(ContactsError) -> JSON {
        let (_, cards) = try contact(cardID)
        guard cards.count > 1 else { throw ContactsError("That contact has one card; it gives the \(name ? "name" : "photo") already.") }
        guard cards.contains(where: { $0.identifier == cardID }) else { throw ContactsError("Give the id of one of the contact's cards (read_contact lists them).") }
        for card in cards { try guarded(card) }
        try await notesAside(cards.map(\.identifier)) {
            try Self.bridged { try CSAddressBook.preferCard(cardID, forName: name) }
        }
        return try await records([cardID]).first ?? .null
    }

    // MARK: Merging

    /// Merges cards into the first: values joined, empty fields filled, notes joined, the photo kept,
    /// groups carried over, the others deleted (kept 30 days); cards in other accounts are linked.
    func merge(_ ids: [String], versions: [String]) async throws(ContactsError) -> JSON {
        guard ids.count >= 2 else { throw ContactsError("Give two or more contacts or cards to merge.") }
        guard ids.count == versions.count else { throw ContactsError("Give one version per id, in the same order.") }
        for (id, version) in zip(ids, versions) { try checkVersion(try await current(id).record, version) }
        let keys = Self.fullKeys + Self.photoKeys
        var cards = try allCards(ids, keys: keys)
        if ids[0].hasSuffix(":ABPerson"), let first = cards.firstIndex(where: { $0.identifier == ids[0] }) { cards.swapAt(0, first) }
        let keep = cards[0].mutableCopy() as! CNMutableContact
        let account = accountID(ofCard: keep.identifier)
        let same = cards.dropFirst().filter { accountID(ofCard: $0.identifier) == account }
        let others = cards.dropFirst().filter { accountID(ofCard: $0.identifier) != account }.map { $0.mutableCopy() as! CNMutableContact }
        let notes = try await script.notes(of: cards.map(\.identifier))
        func text(_ id: String) -> String? { if case .text(let t)? = notes[id], !t.isEmpty { return t }; return nil }
        for card in same { Self.absorb(card, into: keep) }
        let joined = ([keep.identifier] + same.map(\.identifier)).compactMap(text)
        var seen = Set<String>()
        let note = joined.filter { seen.insert($0).inserted }.joined(separator: "\n\n")
        let carried = Set(same.flatMap { groups(ofCards: [$0]).map(\.identifier) }).subtracting(groups(ofCards: [keep]).map(\.identifier))
        for id in carried { if let found = try? group(id) { try guarded(found.name, what: "groups") } }
        let backups = try await backUp(same.map(\.identifier))
        // The merged cards' notes are in the joined note, so theirs are set aside and not put back.
        var newNotes: [String: String?] = [:]
        if !note.isEmpty { newNotes[keep.identifier] = note }
        for card in same { newNotes[card.identifier] = .some(nil) }
        var warnings: [String] = []
        do {
            try await saving([keep.identifier] + same.map(\.identifier), newNotes: newNotes) { request in
                request.update(keep)
                for card in same { request.delete(card.mutableCopy() as! CNMutableContact) }
            }
        } catch {
            guard error.afterSave else {
                removeBackups(backups.map(\.card))
                throw error
            }
            warnings.append(error.description)
        }
        if !others.isEmpty {
            do {
                try await notesAside([keep.identifier] + others.map(\.identifier)) {
                    try Self.bridged { try CSAddressBook.linkCards([keep.identifier] + others.map(\.identifier), photoCard: nil) }
                }
            } catch {
                guard error.afterSave else { throw error }
                warnings.append(error.description)
            }
        }
        for group in carried { try await membership([keep.identifier], in: group, present: true) }
        var result = try await records([keep.identifier]).first ?? .null
        if var object = result.object {
            object["merged"] = .array(backups.map { .string($0.card) })
            if !others.isEmpty { object["linked"] = .array(others.map { .string($0.identifier) }) }
            if !warnings.isEmpty { object["warnings"] = .array(warnings.map { .string($0) }) }
            result = .object(object)
        }
        return result
    }

    /// Joins one card's values into another: every list value it lacks, and the single fields it has
    /// empty.
    static func absorb(_ card: CNContact, into keep: CNMutableContact) {
        func has(_ key: String) -> Bool { card.isKeyAvailable(key) && keep.isKeyAvailable(key) }
        func join<V>(_ key: String, _ mine: [CNLabeledValue<V>], _ theirs: () -> [CNLabeledValue<V>], by value: (V) -> String) -> [CNLabeledValue<V>] {
            guard has(key) else { return mine }
            var keys = Set(mine.map { value($0.value) })
            var joined = mine
            for item in theirs() where keys.insert(value(item.value)).inserted { joined.append(CNLabeledValue(label: item.label, value: item.value)) }
            return joined
        }
        if has(CNContactPhoneNumbersKey) { keep.phoneNumbers = join(CNContactPhoneNumbersKey, keep.phoneNumbers, { card.phoneNumbers }) { MultiValuePlan.phoneKey($0.stringValue) } }
        if has(CNContactEmailAddressesKey) { keep.emailAddresses = join(CNContactEmailAddressesKey, keep.emailAddresses, { card.emailAddresses }) { MultiValuePlan.textKey($0 as String) } }
        if has(CNContactUrlAddressesKey) { keep.urlAddresses = join(CNContactUrlAddressesKey, keep.urlAddresses, { card.urlAddresses }) { MultiValuePlan.textKey($0 as String) } }
        if has(CNContactPostalAddressesKey) { keep.postalAddresses = join(CNContactPostalAddressesKey, keep.postalAddresses, { card.postalAddresses }, by: ContactEdit.addressKey) }
        if has(CNContactDatesKey) { keep.dates = join(CNContactDatesKey, keep.dates, { card.dates }) { ContactEdit.dateKey(ContactEdit.date($0 as DateComponents)) } }
        if has(CNContactRelationsKey) { keep.contactRelations = join(CNContactRelationsKey, keep.contactRelations, { card.contactRelations }) { MultiValuePlan.textKey($0.name) } }
        if has(CNContactSocialProfilesKey) { keep.socialProfiles = join(CNContactSocialProfilesKey, keep.socialProfiles, { card.socialProfiles }, by: ContactEdit.socialKey) }
        if has(CNContactInstantMessageAddressesKey) {
            keep.instantMessageAddresses = join(CNContactInstantMessageAddressesKey, keep.instantMessageAddresses, { card.instantMessageAddresses }, by: ContactEdit.messageKey)
        }
        let fields: [(String, ReferenceWritableKeyPath<CNMutableContact, String>, KeyPath<CNContact, String>)] = [
            (CNContactNamePrefixKey, \.namePrefix, \.namePrefix), (CNContactGivenNameKey, \.givenName, \.givenName),
            (CNContactMiddleNameKey, \.middleName, \.middleName), (CNContactFamilyNameKey, \.familyName, \.familyName),
            (CNContactPreviousFamilyNameKey, \.previousFamilyName, \.previousFamilyName), (CNContactNameSuffixKey, \.nameSuffix, \.nameSuffix),
            (CNContactNicknameKey, \.nickname, \.nickname), (CNContactPhoneticGivenNameKey, \.phoneticGivenName, \.phoneticGivenName),
            (CNContactPhoneticMiddleNameKey, \.phoneticMiddleName, \.phoneticMiddleName), (CNContactPhoneticFamilyNameKey, \.phoneticFamilyName, \.phoneticFamilyName),
            (CNContactOrganizationNameKey, \.organizationName, \.organizationName),
            (CNContactPhoneticOrganizationNameKey, \.phoneticOrganizationName, \.phoneticOrganizationName),
            (CNContactDepartmentNameKey, \.departmentName, \.departmentName), (CNContactJobTitleKey, \.jobTitle, \.jobTitle),
        ]
        for (key, mine, theirs) in fields where has(key) && keep[keyPath: mine].isEmpty && !card[keyPath: theirs].isEmpty {
            keep[keyPath: mine] = card[keyPath: theirs]
        }
        if has(CNContactBirthdayKey), keep.birthday == nil, let birthday = card.birthday { keep.birthday = birthday }
        if has(CNContactNonGregorianBirthdayKey), keep.nonGregorianBirthday == nil, let other = card.nonGregorianBirthday { keep.nonGregorianBirthday = other }
        if has(CNContactImageDataKey), keep.imageData == nil, let image = card.imageData { keep.imageData = image }
    }

    // MARK: Duplicates

    /// Sets of cards that look like the same person: by name within an account (Contacts' Look for
    /// Duplicates), or by a shared email address or phone number.
    func duplicates(byName: Bool, account nameOrID: String?) throws(ContactsError) -> JSON {
        let accounts = try accounts(only: nameOrID)
        let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as NSString, CNContactTypeKey as NSString, CNContactGivenNameKey as NSString,
                                       CNContactFamilyNameKey as NSString, CNContactOrganizationNameKey as NSString, CNContactPhoneNumbersKey as NSString,
                                       CNContactEmailAddressesKey as NSString, CNContactFormatter.descriptorForRequiredKeys(for: .fullName), Self.key("linkIdentifier")]
        var sets: [[(card: CNContact, account: Account)]] = []
        var all: [(CNContact, Account)] = []
        for account in accounts {
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.unifyResults = false
            request.predicate = CNContact.predicateForContactsInContainer(withIdentifier: account.id)
            var cards: [CNContact] = []
            try attempt { try store.enumerateContacts(with: request) { contact, _ in cards.append(contact) } }
            all += cards.map { ($0, account) }
            if byName {
                let named = Dictionary(grouping: cards) { card -> String in
                    card.contactType == .organization ? "org|" + card.organizationName.lowercased()
                        : (card.familyName + " " + card.givenName).trimmingCharacters(in: .whitespaces).lowercased()
                }
                for (name, group) in named where group.count > 1 && !name.isEmpty && name != "org|" {
                    sets.append(group.map { ($0, account) })
                }
            }
        }
        if !byName {
            var byHandle: [String: [(CNContact, Account)]] = [:]
            for (card, account) in all {
                let handles = Set(card.emailAddresses.map { "e:" + MultiValuePlan.textKey($0.value as String) }
                    + card.phoneNumbers.map { "p:" + MultiValuePlan.phoneKey($0.value.stringValue) }.filter { $0.count > 6 })
                for handle in handles { byHandle[handle, default: []].append((card, account)) }
            }
            var seen = Set<Set<String>>()
            for group in byHandle.values where group.count > 1 {
                let links = Set(group.compactMap { Self.text($0.0, "linkIdentifier") })
                if links.count == 1, group.allSatisfy({ Self.text($0.0, "linkIdentifier") != nil }) { continue }  // linked already
                if seen.insert(Set(group.map { $0.0.identifier })).inserted { sets.append(group.map { ($0.0, $0.1) }) }
            }
        }
        let rows = sets.map { set -> JSON in
            .array(set.map { card, account in
                var row: [String: JSON] = ["id": .string(card.identifier), "name": .string(Self.displayName(card)), "account": .string(account.name)]
                if let phone = card.phoneNumbers.first { row["phone"] = .string(phone.value.stringValue) }
                if let email = card.emailAddresses.first { row["email"] = .string(email.value as String) }
                return .object(row)
            })
        }
        return ["sets": .array(rows), "count": .int(rows.count)]
    }

    // MARK: My Card and accounts

    func setMyCard(_ id: String) async throws(ContactsError) -> JSON {
        let (_, cards) = try contact(id)
        let card = id.hasSuffix(":ABPerson") ? (cards.first { $0.identifier == id } ?? cards[0]) : cards[0]
        try guarded(card)
        let request = CNSaveRequest()
        request.transactionAuthor = Self.author
        try Self.bridged { try CSStore.setMeCardIdentifier(card.identifier, request: request) }
        try attempt { try store.execute(request) }
        guard myCardIDs().contains(card.identifier) else { throw ContactsError("Contacts kept its previous My Card.") }
        return try await records([card.identifier]).first ?? .null
    }

    func setDefaultAccount(_ nameOrID: String) throws(ContactsError) -> JSON {
        let account = try account(nameOrID)
        try Self.bridged { try CSAddressBook.setDefaultAccount(account.bookID) }
        return ["default_account": .string(account.name), "id": .string(account.id)]
    }

    func sync(_ nameOrID: String?) throws(ContactsError) -> JSON {
        let accounts = nameOrID == nil ? try syncingAccounts() : try accounts(only: nameOrID)
        try Self.bridged { try CSAddressBook.syncAccounts(accounts.map(\.bookID)) }
        return ["syncing": .array(accounts.map { .string($0.name) }),
                "note": "Contacts syncs in the background; contact_changes shows what arrives."]
    }
}
