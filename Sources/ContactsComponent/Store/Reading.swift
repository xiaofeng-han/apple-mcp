@preconcurrency import Contacts
import ContactsModel
import ContactsShim
import Foundation
import Wire

/// How the tools show a contact: one JSON object with every field, its note, groups and cards, and the
/// version (a hash of all of that), which writes check.
extension ContactsStore {
    /// Full records for these contact or card ids, in order; a failed id gets {id, error}.
    func records(_ ids: [String]) async throws(ContactsError) -> [JSON] {
        var contacts: [(id: String, contact: (unified: CNContact, cards: [CNContact])?, error: String?)] = []
        for id in ids {
            do {
                contacts.append((id, try contact(id), nil))
            } catch {
                contacts.append((id, nil, error.description))
            }
        }
        let cardIDs = contacts.flatMap { $0.contact?.cards.map(\.identifier) ?? [] }
        let notes = try await script.notes(of: cardIDs)
        let accounts = Dictionary((try? self.accounts())?.map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        let meIDs = myCardIDs()
        return contacts.map { entry in
            guard let contact = entry.contact else { return ["id": .string(entry.id), "error": .string(entry.error ?? "not found")] }
            return record(contact.unified, cards: contact.cards, notes: notes, accounts: accounts, me: meIDs)
        }
    }

    func record(_ unified: CNContact, cards: [CNContact], notes: [String: ContactsScript.Note], accounts: [String: Account], me: Set<String>) -> JSON {
        var o: [String: JSON] = [
            "id": .string(unified.identifier),
            "name": .string(Self.displayName(unified)),
            "type": .string(unified.contactType == .organization ? "company" : "person"),
        ]
        let texts: [(String, String)] = [
            ("prefix", unified.namePrefix), ("first_name", unified.givenName), ("middle_name", unified.middleName),
            ("last_name", unified.familyName), ("maiden_name", unified.previousFamilyName), ("suffix", unified.nameSuffix),
            ("nickname", unified.nickname), ("phonetic_first_name", unified.phoneticGivenName),
            ("phonetic_middle_name", unified.phoneticMiddleName), ("phonetic_last_name", unified.phoneticFamilyName),
            ("organization", unified.organizationName), ("phonetic_organization", unified.phoneticOrganizationName),
            ("department", unified.departmentName), ("job_title", unified.jobTitle),
        ]
        for (key, value) in texts where !value.isEmpty { o[key] = .string(value) }
        if let order = (cards.first?.value(forKey: "displayNameOrder") as? NSNumber)?.intValue, order != 0 {
            o["name_order"] = .string(order == 1 ? "given_first" : "family_first")
        }
        // The note of the card that gives the contact its name, else the first card with one.
        let cardNotes = cards.compactMap { card -> (String, String)? in
            if case .text(let text)? = notes[card.identifier], !text.isEmpty { return (card.identifier, text) }
            return nil
        }
        if let note = cardNotes.first { o["note"] = .string(note.1) }

        if !unified.phoneNumbers.isEmpty { o["phones"] = labeled(unified.phoneNumbers.map { ($0.label, $0.value.stringValue) }) }
        if !unified.emailAddresses.isEmpty { o["emails"] = labeled(unified.emailAddresses.map { ($0.label, $0.value as String) }) }
        if !unified.urlAddresses.isEmpty { o["urls"] = labeled(unified.urlAddresses.map { ($0.label, $0.value as String) }) }
        if !unified.postalAddresses.isEmpty { o["addresses"] = .array(unified.postalAddresses.map(address)) }
        if !unified.dates.isEmpty {
            o["dates"] = .array(unified.dates.map { item in
                var row: [String: JSON] = ["value": date(item.value as DateComponents)?.json ?? .null]
                if let label = item.label, !label.isEmpty { row["label"] = .string(Labels.friendly(label)) }
                return .object(row)
            })
        }
        if !unified.contactRelations.isEmpty { o["related_names"] = labeled(unified.contactRelations.map { ($0.label, $0.value.name) }) }
        if !unified.socialProfiles.isEmpty {
            o["social_profiles"] = .array(unified.socialProfiles.map { item in
                var row: [String: JSON] = [:]
                if let label = item.label, !label.isEmpty { row["label"] = .string(Labels.friendly(label)) }
                for (key, value) in [("service", item.value.service), ("username", item.value.username),
                                     ("user_id", item.value.userIdentifier), ("url", item.value.urlString)] where !value.isEmpty {
                    row[key] = .string(value)
                }
                return .object(row)
            })
        }
        if !unified.instantMessageAddresses.isEmpty {
            o["instant_messages"] = .array(unified.instantMessageAddresses.map { item in
                var row: [String: JSON] = ["username": .string(item.value.username)]
                if let label = item.label, !label.isEmpty { row["label"] = .string(Labels.friendly(label)) }
                if !item.value.service.isEmpty { row["service"] = .string(item.value.service) }
                return .object(row)
            })
        }
        if let birthday = unified.birthday.flatMap(date) { o["birthday"] = birthday.json }
        if let other = unified.nonGregorianBirthday.flatMap(date) { o["other_birthday"] = other.json }
        if unified.imageDataAvailable || cards.contains(where: \.imageDataAvailable) { o["photo"] = true }
        if cards.contains(where: { Self.text($0, "wallpaperURI") != nil }) { o["poster"] = true }
        for (key, calls) in [("ringtone", true), ("text_tone", false)] {
            if let alert = cards.lazy.compactMap({ CSStore.alert(forCalls: calls, contact: $0) }).first {
                o[key] = .object(alert.reduce(into: [:]) { result, item in
                    if let text = item.value as? String { result[item.key] = .string(text) }
                    else if let flag = item.value as? Bool { result[item.key] = .bool(flag) }
                })
            }
        }
        if cards.contains(where: { Self.text($0, "downtimeWhitelist") == "true" }) { o["downtime_allowed"] = true }
        if cards.contains(where: { me.contains($0.identifier) }) { o["my_card"] = true }
        o["groups"] = .array(groups(ofCards: cards).map { ["id": .string($0.identifier), "name": .string($0.name)] })
        o["cards"] = .array(cards.map { card in
            var row: [String: JSON] = ["id": .string(card.identifier)]
            if let accountID = accountID(ofCard: card.identifier) {
                row["account"] = .string(accounts[accountID]?.name ?? accountID)
            }
            if cards.count > 1 {
                if Self.flag(card, "preferredForName") { row["gives_name"] = true }
                if Self.flag(card, "preferredForImage") { row["gives_photo"] = true }
                if let note = cardNotes.first(where: { $0.0 == card.identifier }), note.0 != cardNotes.first?.0 { row["note"] = .string(note.1) }
            }
            return .object(row)
        })
        var shown = JSON.object(o)
        o["version"] = .string(Versions.of(shown))
        if let created = cards.compactMap(\.creationDateIfFetched).min() { o["created"] = .string(Self.stamp(created)) }
        if let modified = cards.compactMap(\.modificationDateIfFetched).max() { o["modified"] = .string(Self.stamp(modified)) }
        shown = .object(o)
        return shown
    }

    /// One line per contact for lists: id, version, name, company, first phone and email.
    func summary(_ record: JSON) -> JSON {
        guard let o = record.object else { return record }
        var row: [String: JSON] = [:]
        for key in ["id", "version", "name", "type", "organization", "job_title", "my_card", "error"] { row[key] = o[key] }
        if let phone = o["phones"]?.array?.first?["value"] { row["phone"] = phone }
        if let email = o["emails"]?.array?.first?["value"] { row["email"] = email }
        if let cards = o["cards"]?.array, cards.count > 1 { row["cards"] = .int(cards.count) }
        return .object(row.filter { $0.value != .null })
    }

    func labeled(_ items: [(String?, String)]) -> JSON {
        .array(items.map { label, value in
            var row: [String: JSON] = ["value": .string(value)]
            if let label, !label.isEmpty { row["label"] = .string(Labels.friendly(label)) }
            return .object(row)
        })
    }

    func address(_ item: CNLabeledValue<CNPostalAddress>) -> JSON {
        let value = item.value
        var row: [String: JSON] = [:]
        if let label = item.label, !label.isEmpty { row["label"] = .string(Labels.friendly(label)) }
        for (key, text) in [("street", value.street), ("sub_locality", value.subLocality), ("city", value.city),
                            ("sub_administrative_area", value.subAdministrativeArea), ("state", value.state),
                            ("postal_code", value.postalCode), ("country", value.country), ("country_code", value.isoCountryCode)] where !text.isEmpty {
            row[key] = .string(text)
        }
        return .object(row)
    }

    func date(_ components: DateComponents) -> ContactDate? {
        guard let month = components.month, let day = components.day, month != NSDateComponentUndefined, day != NSDateComponentUndefined else { return nil }
        let calendar = components.calendar?.identifier ?? .gregorian
        let year = components.year.flatMap { $0 == NSDateComponentUndefined ? nil : $0 }
        let era = components.era.flatMap { $0 == NSDateComponentUndefined ? nil : $0 }
        return ContactDate(calendar: Self.calendarName(calendar), era: calendar == .gregorian ? nil : era, year: year,
                           month: month, day: day, leapMonth: components.isLeapMonth ?? false)
    }

    nonisolated static let calendarIdentifiers: [String: Calendar.Identifier] = [
        "gregorian": .gregorian, "buddhist": .buddhist, "chinese": .chinese, "coptic": .coptic,
        "ethiopic-amete-mihret": .ethiopicAmeteMihret, "ethiopic-amete-alem": .ethiopicAmeteAlem, "hebrew": .hebrew,
        "indian": .indian, "islamic": .islamic, "islamic-civil": .islamicCivil, "islamic-tabular": .islamicTabular,
        "islamic-umm-al-qura": .islamicUmmAlQura, "japanese": .japanese, "persian": .persian, "republic-of-china": .republicOfChina,
    ]

    nonisolated static func calendarName(_ identifier: Calendar.Identifier) -> String {
        calendarIdentifiers.first { $0.value == identifier }?.key ?? "\(identifier)"
    }

    nonisolated static func stamp(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.timeZone = .current
        format.formatOptions = [.withInternetDateTime]
        return format.string(from: date)
    }

    /// The groups any of these cards is directly in.
    func groups(ofCards cards: [CNContact]) -> [CNGroup] {
        var seen = Set<String>()
        var result: [CNGroup] = []
        for card in cards {
            guard let predicate = CSStore.groups(withMemberContact: card, parents: false) else { continue }
            for group in (try? store.groups(matching: predicate)) ?? [] where seen.insert(group.identifier).inserted {
                result.append(group)
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The My Card of each account (card ids).
    func myCardIDs() -> Set<String> {
        guard let predicate = CSStore.meContactsPredicate() else { return [] }
        let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as NSString])
        request.unifyResults = false
        request.predicate = predicate
        var ids = Set<String>()
        try? store.enumerateContacts(with: request) { contact, _ in ids.insert(contact.identifier) }
        return ids
    }
}

extension CNContact {
    var creationDateIfFetched: Date? { isKeyAvailable("creationDate") ? value(forKey: "creationDate") as? Date : nil }
    var modificationDateIfFetched: Date? { isKeyAvailable("modificationDate") ? value(forKey: "modificationDate") as? Date : nil }
}
