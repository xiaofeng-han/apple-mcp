import AppKit
@preconcurrency import Contacts
import ContactsModel
import ContactsShim
import Foundation
import Wire

/// A tool's arguments, read by type. A wrong type or unknown value is BadInput (a JSON-RPC error);
/// absent and null both read as nil.
struct Input {
    let fields: [String: JSON]
    init(_ fields: [String: JSON]) { self.fields = fields }

    func text(_ key: String) throws -> String? {
        guard let value = fields[key], value != .null else { return nil }
        guard let text = value.string else { throw BadInput("\(key) must be text") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func required(_ key: String) throws -> String {
        guard let text = try text(key) else { throw BadInput("\(key) is required") }
        return text
    }

    func flag(_ key: String) throws -> Bool? {
        guard let value = fields[key], value != .null else { return nil }
        guard let flag = value.bool else { throw BadInput("\(key) must be true or false") }
        return flag
    }

    func number(_ key: String, _ allowed: ClosedRange<Int>) throws -> Int? {
        guard let value = fields[key], value != .null else { return nil }
        guard let number = value.int, allowed.contains(number) else { throw BadInput("\(key) must be a whole number from \(allowed.lowerBound) to \(allowed.upperBound)") }
        return number
    }

    func pick(_ key: String, from options: [String]) throws -> String? {
        guard let text = try text(key) else { return nil }
        guard options.contains(text) else { throw BadInput("\(key) must be one of: \(options.joined(separator: ", "))") }
        return text
    }

    func texts(_ key: String) throws -> [String]? {
        guard let value = fields[key], value != .null else { return nil }
        guard let items = value.array else { throw BadInput("\(key) must be a list of text") }
        return try items.map { item in
            guard let text = item.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { throw BadInput("\(key) must be a list of text") }
            return text
        }
    }
}

extension ToolAnswer {
    static func json(_ lead: String, _ value: JSON) -> ToolAnswer {
        ToolAnswer(lead.isEmpty ? value.text : "\(lead) \(value.text)", data: value)
    }
}

/// Runs a tool on the main actor after the access check (and after putting back any note a stopped
/// save left aside); Contacts problems become failed answers the agent can read and act on, while bad
/// input stays a JSON-RPC error.
@MainActor
func run(_ store: ContactsStore, _ body: @MainActor () async throws -> ToolAnswer) async throws -> ToolAnswer {
    do {
        try store.ensureAccess()
        store.fresh()
        await store.restoreNotesSetAside()
        return try await body()
    } catch let error as ContactsError {
        return ToolAnswer(error.description, data: ["error": .string(error.description)], failed: true)
    }
}

@MainActor
func readTools(_ store: ContactsStore) -> [Tool] {
    [
        Tool(ContactsTools.overview) { _ in
            try await run(store) { .json("", try store.overview()) }
        },

        Tool(ContactsTools.findContacts) { fields in
            let input = Input(fields)
            let filters = FindFilters(query: try input.text("query"), phone: try input.text("phone"), email: try input.text("email"),
                                      group: try input.text("group"), smartList: try input.text("smart_list"), account: try input.text("account"),
                                      type: try input.pick("type", from: ["person", "company"]), criteria: fields["criteria"].flatMap { $0 == .null ? nil : $0 },
                                      limit: try input.number("limit", 1...500) ?? 50, offset: try input.number("offset", 0...100_000) ?? 0)
            return try await run(store) { .json("", try await store.find(filters)) }
        },

        Tool(ContactsTools.readContact) { fields in
            let input = Input(fields)
            let ids = (try input.text("id").map { [$0] } ?? []) + (try input.texts("ids") ?? [])
            guard !ids.isEmpty else { throw BadInput("id or ids is required") }
            guard ids.count <= 20 else { throw BadInput("read at most 20 contacts at a time") }
            return try await run(store) {
                let records = try await store.records(ids)
                if records.count == 1, let error = records[0]["error"]?.string { throw ContactsError(error) }
                return .json("", records.count == 1 && fields["ids"] == nil ? records[0] : ["contacts": .array(records)])
            }
        },

        Tool(ContactsTools.readPhoto) { fields in
            let input = Input(fields)
            let id = try input.required("id")
            let which = try input.pick("which", from: ["photo", "full", "poster"]) ?? "photo"
            return try await run(store) {
                let (data, name) = try store.photo(id, which: which)
                let (image, mime) = displayable(data)
                return ToolAnswer(content: [.text("\(name): \(which), \(image.count) bytes"), .image(image, mimeType: mime)])
            }
        },

        Tool(ContactsTools.listGroups) { fields in
            let input = Input(fields)
            let group = try input.text("group")
            let nested = try input.flag("nested") ?? false
            return try await run(store) {
                if let group { return .json("", try await store.members(group, nested: nested)) }
                return .json("", try store.groupsOverview())
            }
        },

        Tool(ContactsTools.findDuplicates) { fields in
            let input = Input(fields)
            let by = try input.pick("by", from: ["name", "email_or_phone"]) ?? "name"
            let account = try input.text("account")
            return try await run(store) { .json("", try store.duplicates(byName: by == "name", account: account)) }
        },

        Tool(ContactsTools.contactChanges) { fields in
            let input = Input(fields)
            let since = try input.text("since")
            let own = try input.flag("include_own") ?? false
            return try await run(store) { .json("", try await store.changes(since: since, includeOwn: own)) }
        },
    ]
}

/// JPEG or PNG as they are; anything else (HEIC, TIFF) as JPEG, which every client shows.
func displayable(_ data: Data) -> (Data, String) {
    if data.starts(with: [0xFF, 0xD8, 0xFF]) { return (data, "image/jpeg") }
    if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return (data, "image/png") }
    if let rep = NSBitmapImageRep(data: data), let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
        return (jpeg, "image/jpeg")
    }
    return (data, "image/jpeg")
}

struct FindFilters {
    let query: String?, phone: String?, email: String?, group: String?, smartList: String?, account: String?, type: String?
    let criteria: JSON?
    let limit: Int, offset: Int
}

extension ContactsStore {
    func overview() throws(ContactsError) -> JSON {
        let accounts = try self.accounts()
        let unified = try unifiedContacts(nil, keys: [CNContactIdentifierKey as NSString])
        var rows: [JSON] = []
        var cards = 0
        for account in accounts {
            let count = try cardIDs(inAccount: account.id).count
            cards += count
            var row: [String: JSON] = ["id": .string(account.id), "name": .string(account.name), "kind": .string(account.kind), "cards": .int(count)]
            if account.isDefault { row["default"] = true }
            if account.kind == "On My Mac" { row["syncs"] = false }
            rows.append(.object(row))
        }
        var result: [String: JSON] = ["accounts": .array(rows), "contacts": .int(unified.count), "cards": .int(cards),
                                      "groups": .int(try allGroups().count), "smart_lists": .int((try? smartLists().count) ?? 0)]
        if let me = myCardIDs().first, let card = try? self.cards([me], keys: Self.summaryKeys).first {
            result["my_card"] = ["id": .string(me), "name": .string(Self.displayName(card))]
        }
        let deleted = deletedBackups().count
        if deleted > 0 { result["recently_deleted_by_this_app"] = .int(deleted) }
        return .object(result)
    }

    /// Unified contact ids holding these cards (a contact linked across accounts once).
    func unifiedIDs(ofCards cards: some Sequence<String>, map: [String: String]) -> Set<String> {
        Set(cards.compactMap { map[$0] })
    }

    func find(_ filters: FindFilters) async throws -> JSON {
        let matches = try await matching(filters)
        let page = Array(matches.dropFirst(filters.offset).prefix(filters.limit))
        let records = try await self.records(page.map(\.identifier))
        var result: [String: JSON] = ["total": .int(matches.count), "showing": .int(page.count), "contacts": .array(records.map(summary))]
        if filters.offset + page.count < matches.count { result["next_offset"] = .int(filters.offset + page.count) }
        return .object(result)
    }

    /// The unified contacts the filters let through, in Contacts' order.
    func matching(_ filters: FindFilters) async throws -> [CNContact] {
        // Every unified contact in Contacts' order, and which cards each is made of.
        let all = try unifiedContacts(nil, keys: Self.summaryKeys + [Self.key("linkedContacts")])
        var cardToContact: [String: String] = [:]
        for contact in all {
            let cards = ((contact.value(forKey: "linkedContacts") as? [CNContact]) ?? []).map(\.identifier)
            for card in cards.isEmpty ? [contact.identifier] : cards { cardToContact[card] = contact.identifier }
        }
        var allowed: Set<String>?
        func narrow(_ ids: Set<String>) { allowed = allowed.map { $0.intersection(ids) } ?? ids }

        if let query = filters.query {
            for word in query.split(whereSeparator: \.isWhitespace) {
                guard let predicate = CSStore.fullTextPredicate(forText: String(word)) else { throw ContactsError("This version of macOS has no full-text contact search.") }
                narrow(Set(try unifiedContacts(predicate, keys: [CNContactIdentifierKey as NSString]).map(\.identifier)))
            }
        }
        if let phone = filters.phone {
            narrow(Set(try unifiedContacts(CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phone)),
                                           keys: [CNContactIdentifierKey as NSString, CNContactPhoneNumbersKey as NSString]).map(\.identifier)))
        }
        if let email = filters.email {
            narrow(Set(try unifiedContacts(CNContact.predicateForContacts(matchingEmailAddress: email),
                                           keys: [CNContactIdentifierKey as NSString, CNContactEmailAddressesKey as NSString]).map(\.identifier)))
        }
        if let name = filters.group {
            let group = try group(name)
            var cards = try memberCardIDs(group.id)
            var queue = subgroupIDs(group.id), seen = Set([group.id])
            while let next = queue.first {
                queue.removeFirst()
                guard seen.insert(next).inserted else { continue }
                cards += try memberCardIDs(next)
                queue += subgroupIDs(next)
            }
            narrow(unifiedIDs(ofCards: cards, map: cardToContact))
        }
        if let name = filters.smartList {
            narrow(unifiedIDs(ofCards: (try smartList(name)["members"] as? [String]) ?? [], map: cardToContact))
        }
        if let criteria = filters.criteria {
            narrow(unifiedIDs(ofCards: try cardsMatching(try self.criteria(criteria)), map: cardToContact))
        }
        if let name = filters.account {
            narrow(unifiedIDs(ofCards: try cardIDs(inAccount: try account(name).id), map: cardToContact))
        }
        var matches = all.filter { allowed?.contains($0.identifier) ?? true }
        if let type = filters.type { matches = matches.filter { ($0.contactType == .organization) == (type == "company") } }
        return matches
    }
}
