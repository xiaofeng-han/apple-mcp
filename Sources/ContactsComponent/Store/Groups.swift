@preconcurrency import Contacts
import ContactsModel
import ContactsShim
import Foundation
import Wire

/// Groups (Contacts' lists) and smart lists. Groups belong to one account and hold its cards; they can
/// be nested. Members go in and out through Contacts' AppleScript (CNSaveRequest's removeMember is a
/// no-op on macOS 27, and its addMember fails on cards with notes); a group comes out of another
/// through AddressBook (removeSubgroup is a no-op too). Smart lists are AddressBook's, On My Mac only.
extension ContactsStore {
    struct Group {
        let id: String
        let name: String
        let account: String
    }

    func allGroups() throws(ContactsError) -> [Group] {
        var groups: [Group] = []
        for account in try accounts() {
            let found = try attempt { try store.groups(matching: CNGroup.predicateForGroupsInContainer(withIdentifier: account.id)) }
            groups += found.map { Group(id: $0.identifier, name: $0.name, account: account.id) }
        }
        return groups
    }

    /// A group by id or name (a name used in several accounts needs the id).
    func group(_ nameOrID: String) throws(ContactsError) -> Group {
        let all = try allGroups()
        if let found = all.first(where: { $0.id.caseInsensitiveCompare(nameOrID) == .orderedSame }) { return found }
        let named = all.filter { $0.name.caseInsensitiveCompare(nameOrID) == .orderedSame }
        if named.count == 1 { return named[0] }
        if named.isEmpty { throw ContactsError("No group \"\(nameOrID)\"; list_groups lists them.") }
        throw ContactsError("Several groups are named \"\(nameOrID)\"; pass one of these ids: \(named.map(\.id).joined(separator: ", ")).")
    }

    private func cnGroup(_ id: String) throws(ContactsError) -> CNGroup {
        guard let group = try attempt({ try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [id])) }).first else {
            throw ContactsError("No group with id \(id).")
        }
        return group
    }

    func subgroupIDs(_ id: String) -> [String] {
        ((try? store.groups(matching: CNGroup.predicateForSubgroupsInGroup(withIdentifier: id))) ?? []).map(\.identifier)
    }

    /// Card ids directly in a group.
    func memberCardIDs(_ id: String) throws(ContactsError) -> [String] {
        let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as NSString])
        request.unifyResults = false
        request.predicate = CNContact.predicateForContactsInGroup(withIdentifier: id)
        var ids: [String] = []
        try attempt { try store.enumerateContacts(with: request) { contact, _ in ids.append(contact.identifier) } }
        return ids
    }

    /// The group tree by account, and the smart lists.
    func groupsOverview() throws(ContactsError) -> JSON {
        let accounts = try self.accounts()
        let groups = try allGroups()
        let nested = Set(groups.flatMap { subgroupIDs($0.id) })
        func node(_ group: Group, depth: Int) -> JSON {
            var row: [String: JSON] = ["id": .string(group.id), "name": .string(group.name),
                                       "cards": .int((try? memberCardIDs(group.id).count) ?? 0)]
            let children = subgroupIDs(group.id).compactMap { id in groups.first { $0.id == id } }
            if !children.isEmpty, depth < 8 { row["groups"] = .array(children.map { node($0, depth: depth + 1) }) }
            return .object(row)
        }
        var result: [String: JSON] = [:]
        result["accounts"] = .array(accounts.compactMap { account in
            let top = groups.filter { $0.account == account.id && !nested.contains($0.id) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard !top.isEmpty else { return nil }
            return ["account": .string(account.name), "groups": .array(top.map { node($0, depth: 0) })]
        })
        result["smart_lists"] = .array(try smartLists().map { list in
            var row: [String: JSON] = ["id": .string(list["id"] as? String ?? ""), "name": .string(list["name"] as? String ?? ""),
                                       "cards": .int((list["members"] as? [String])?.count ?? 0)]
            if let criteria = list["criteria"] { row["criteria"] = Self.json(criteria) }
            if (list["highlight"] as? Bool) == true { row["highlight"] = true }
            return .object(row)
        })
        return .object(result)
    }

    /// A name or id as a group or a smart list; a name both use needs the id.
    enum Listing {
        case group(Group)
        case smartList([String: Any])
    }

    func listing(_ nameOrID: String) throws(ContactsError) -> Listing {
        let groups = try allGroups()
        if let found = groups.first(where: { $0.id.caseInsensitiveCompare(nameOrID) == .orderedSame }) { return .group(found) }
        var lists: [[String: Any]] = []
        var listError: ContactsError?
        do { lists = try smartLists() } catch { listError = error }
        if let found = lists.first(where: { ($0["id"] as? String)?.caseInsensitiveCompare(nameOrID) == .orderedSame }) { return .smartList(found) }
        let namedGroups = groups.filter { $0.name.caseInsensitiveCompare(nameOrID) == .orderedSame }
        let namedLists = lists.filter { ($0["name"] as? String)?.caseInsensitiveCompare(nameOrID) == .orderedSame }
        switch (namedGroups.count, namedLists.count) {
        case (1, 0): return .group(namedGroups[0])
        case (0, 1): return .smartList(namedLists[0])
        case (0, 0):
            if let listError { throw listError }
            throw ContactsError("No group or smart list \"\(nameOrID)\"; list_groups lists them.")
        default:
            let ids = namedGroups.map(\.id) + namedLists.compactMap { $0["id"] as? String }
            throw ContactsError("Several groups or smart lists are named \"\(nameOrID)\"; pass one of these ids: \(ids.joined(separator: ", ")).")
        }
    }

    /// A group's or smart list's members as summaries, nested groups' too when asked, and a group's
    /// distribution list.
    func members(_ nameOrID: String, nested: Bool) async throws(ContactsError) -> JSON {
        let group: Group
        switch try listing(nameOrID) {
        case .smartList(let list):
            let ids = (list["members"] as? [String]) ?? []
            let rows = try await summaries(ofCards: ids)
            return ["smart_list": .string(list["name"] as? String ?? ""), "count": .int(rows.count), "contacts": .array(rows)]
        case .group(let found):
            group = found
        }
        var ids = try memberCardIDs(group.id)
        if nested {
            var queue = subgroupIDs(group.id), seen = Set<String>([group.id])
            while let next = queue.first {
                queue.removeFirst()
                guard seen.insert(next).inserted else { continue }
                ids += try memberCardIDs(next)
                queue += subgroupIDs(next)
            }
        }
        let rows = try await summaries(ofCards: Array(Set(ids)))
        var result: [String: JSON] = ["group": .string(group.name), "id": .string(group.id), "count": .int(rows.count), "contacts": .array(rows)]
        let children = subgroupIDs(group.id)
        if !children.isEmpty { result["groups"] = .array(children.map { .string($0) }) }
        if let distribution = try? CSAddressBook.distribution(ofGroup: group.id), !distribution.isEmpty {
            let choices = distribution.filter { $0.count > 1 }
            if !choices.isEmpty { result["distribution"] = .array(try choices.map { row throws(ContactsError) in try distributionRow(row) }) }
        }
        return .object(result)
    }

    /// A distribution choice with the chosen values themselves, not their ids.
    private func distributionRow(_ row: [String: Any]) throws(ContactsError) -> JSON {
        let cardID = row["card"] as? String ?? ""
        guard let card = try cards([cardID], keys: [CNContactEmailAddressesKey as NSString, CNContactPhoneNumbersKey as NSString,
                                                   CNContactPostalAddressesKey as NSString, CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]).first else {
            return ["card": .string(cardID)]
        }
        var result: [String: JSON] = ["card": .string(cardID), "name": .string(Self.displayName(card))]
        if let id = row["email"] as? String, let email = card.emailAddresses.first(where: { $0.identifier == id }) { result["email"] = .string(email.value as String) }
        if let id = row["phone"] as? String, let phone = card.phoneNumbers.first(where: { $0.identifier == id }) { result["phone"] = .string(phone.value.stringValue) }
        if let id = row["address"] as? String, let address = card.postalAddresses.first(where: { $0.identifier == id }) {
            result["address"] = .string(Labels.friendly(address.label ?? "") + ": " + CNPostalAddressFormatter.string(from: address.value, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", "))
        }
        return .object(result)
    }

    /// Summaries of the contacts these cards belong to (a linked contact once).
    func summaries(ofCards cardIDs: [String]) async throws(ContactsError) -> [JSON] {
        var seen = Set<String>()
        var ids: [String] = []
        for card in cardIDs {
            guard let unified = try? store.unifiedContact(withIdentifier: card, keysToFetch: [CNContactIdentifierKey as NSString]) else { continue }
            if seen.insert(unified.identifier).inserted { ids.append(card) }
        }
        let rows = try await records(ids).map(summary)
        return rows.sorted { ($0["name"]?.string ?? "").localizedStandardCompare($1["name"]?.string ?? "") == .orderedAscending }
    }

    /// The card of a contact (or the card given) in an account.
    func card(of id: String, inAccount account: String) throws(ContactsError) -> String {
        try cards(of: id, inAccount: account)[0]
    }

    /// A contact's cards in an account (the card given, when a card id is given), the one that gives
    /// the contact its name first.
    func cards(of id: String, inAccount account: String) throws(ContactsError) -> [String] {
        let (_, cards) = try contact(id, keys: [CNContactIdentifierKey as NSString, CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                                Self.key("linkIdentifier"), Self.key("preferredForName")])
        if id.hasSuffix(":ABPerson"), let direct = cards.first(where: { $0.identifier == id }), accountID(ofCard: id) == account {
            try guarded(direct)
            return [id]
        }
        let here = cards.filter { accountID(ofCard: $0.identifier) == account }
        guard !here.isEmpty else {
            throw ContactsError("\"\(Self.displayName(cards[0]))\" has no card in that group's account; groups hold cards of their own account only.")
        }
        for card in here { try guarded(card) }
        return here.map(\.identifier)
    }

    // MARK: Changing groups

    func createGroup(_ name: String, account nameOrID: String?, parent: String?, members: [String]) async throws(ContactsError) -> JSON {
        try guarded(name, what: "groups")
        let account = try account(orDefault: nameOrID)
        if try allGroups().contains(where: { $0.account == account.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ContactsError("\(account.name) has a group named \"\(name)\" already.")
        }
        let outer = try parent.map { name throws(ContactsError) in try self.group(name) }
        if let outer {
            guard outer.account == account.id else { throw ContactsError("Group \"\(outer.name)\" is in another account.") }
            try guarded(outer.name, what: "groups")
        }
        let cardIDs = try members.map { id throws(ContactsError) in try card(of: id, inAccount: account.id) }
        let group = CNMutableGroup()
        group.name = name
        let request = CNSaveRequest()
        request.transactionAuthor = Self.author
        request.add(group, toContainerWithIdentifier: account.id)
        try attempt { try store.execute(request) }
        do {
            if let outer { try nest(group.identifier, in: outer.id) }
            try await membership(cardIDs, in: group.identifier, present: true)
        } catch {
            throw ContactsError("\(error) The group \"\(name)\" was created (\(group.identifier)); finish with manage_group on it rather than creating it again.")
        }
        return try await self.members(group.identifier, nested: false)
    }

    func renameGroup(_ nameOrID: String, to name: String) throws(ContactsError) -> JSON {
        let group = try group(nameOrID)
        try guarded(group.name, what: "groups")
        try guarded(name, what: "groups")
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ContactsError("A group name cannot be empty.") }
        if try allGroups().contains(where: { $0.account == group.account && $0.id != group.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ContactsError("That account has a group named \"\(name)\" already.")
        }
        let mutable = try cnGroup(group.id).mutableCopy() as! CNMutableGroup
        mutable.name = name
        let request = CNSaveRequest()
        request.transactionAuthor = Self.author
        request.update(mutable)
        try attempt { try store.execute(request) }
        return ["id": .string(group.id), "name": .string(name), "renamed_from": .string(group.name)]
    }

    func deleteGroup(_ nameOrID: String) throws(ContactsError) -> JSON {
        let group = try group(nameOrID)
        try guarded(group.name, what: "groups")
        let count = try memberCardIDs(group.id).count
        let request = CNSaveRequest()
        request.transactionAuthor = Self.author
        request.delete(try cnGroup(group.id).mutableCopy() as! CNMutableGroup)
        try attempt { try store.execute(request) }
        return ["deleted": .string(group.name), "id": .string(group.id), "kept_contacts": .int(count)]
    }

    func changeMembers(_ nameOrID: String, add: Bool, ids: [String]) async throws(ContactsError) -> JSON {
        let group = try group(nameOrID)
        try guarded(group.name, what: "groups")
        guard !ids.isEmpty else { throw ContactsError("Give the members (contact or card ids).") }
        let inside = Set(try memberCardIDs(group.id))
        var cardIDs: [String] = []
        for id in ids {
            let cards = try cards(of: id, inAccount: group.account)
            if add {
                // A contact one of whose cards is in the group already is in it.
                if !cards.contains(where: inside.contains) { cardIDs.append(cards[0]) }
            } else {
                cardIDs += cards.filter(inside.contains)
            }
        }
        try await membership(cardIDs, in: group.id, present: add)
        return try await members(group.id, nested: false)
    }

    /// Puts cards in a group (or takes them out) through Contacts' AppleScript, then checks through
    /// Contacts.framework that it happened, and tries again while Contacts.app catches up with a card
    /// this app has just added or restored (until then it acts on its own stale copy, silently).
    func membership(_ cardIDs: [String], in groupID: String, present: Bool) async throws(ContactsError) {
        func pending() throws(ContactsError) -> [String] {
            let inside = Set(try memberCardIDs(groupID))
            return cardIDs.filter { inside.contains($0) != present }
        }
        // Cards allowed during Downtime go through Contacts.framework (their AppleScript save fails):
        // in, when they have no note; never out (the framework does not take members out).
        let downtime = downtimeCards(try pending())
        if let card = downtime.first {
            let notes = try await script.notes(of: downtime.map(\.identifier))
            // An empty note row blocks the framework's save as much as a note.
            let noted = downtime.first { if case .text? = notes[$0.identifier] { return true }; return false }
            if !present || noted != nil {
                throw ContactsError("""
                    "\(Self.displayName(noted ?? card))" is allowed during Screen Time's Downtime: Contacts lets no other app \
                    \(present ? "add it to a group while it has a note" : "take it out of a group"). Change it in Contacts itself.
                    """)
            }
            for card in downtime { try addWithoutNote(card.identifier, to: [groupID]) }
        }
        for _ in 0..<8 {
            let left = try pending()
            if left.isEmpty { return }
            if present { try await script.add(left, toGroup: groupID) } else { try await script.remove(left, fromGroup: groupID) }
            try? await Task.sleep(for: .milliseconds(400))
        }
        if try pending().isEmpty { return }
        throw ContactsError("Contacts did not \(present ? "add the contacts to" : "take the contacts out of") the group; try again.")
    }

    /// Puts a card that has no note in groups through Contacts.framework: right after this app adds
    /// (or restores) a card, Contacts.app does not have it yet, and its AppleScript would act on nothing.
    func addWithoutNote(_ cardID: String, to groupIDs: [String]) throws(ContactsError) {
        guard !groupIDs.isEmpty, let card = try cards([cardID], keys: [CNContactIdentifierKey as NSString]).first else { return }
        let request = CNSaveRequest()
        prepare(request, cards: [cardID])
        for id in groupIDs { request.addMember(card, to: try cnGroup(id)) }
        try attempt { try store.execute(request) }
    }

    func nest(_ child: String, in parent: String) throws(ContactsError) {
        let request = CNSaveRequest()
        request.transactionAuthor = Self.author
        request.addSubgroup(try cnGroup(child), to: try cnGroup(parent))
        try attempt { try store.execute(request) }
    }

    func nestGroup(_ nameOrID: String, parent parentName: String, nest: Bool) throws(ContactsError) -> JSON {
        let group = try group(nameOrID), parent = try self.group(parentName)
        try guarded(group.name, what: "groups")
        try guarded(parent.name, what: "groups")
        guard group.id != parent.id else { throw ContactsError("A group cannot be nested in itself.") }
        guard group.account == parent.account else { throw ContactsError("Both groups must be in the same account.") }
        if nest {
            var queue = subgroupIDs(group.id), seen = Set<String>()
            while let next = queue.first {
                queue.removeFirst()
                if next == parent.id { throw ContactsError("\"\(parent.name)\" is inside \"\(group.name)\" already; nesting it would make a loop.") }
                if seen.insert(next).inserted { queue += subgroupIDs(next) }
            }
            try self.nest(group.id, in: parent.id)
        } else {
            guard subgroupIDs(parent.id).contains(group.id) else { throw ContactsError("\"\(group.name)\" is not inside \"\(parent.name)\".") }
            try Self.bridged { try CSAddressBook.removeSubgroup(group.id, fromGroup: parent.id) }
        }
        let nowInside = subgroupIDs(parent.id).contains(group.id)
        guard nowInside == nest else { throw ContactsError("Contacts did not change the nesting; nothing was changed.") }
        return ["group": .string(group.name), "parent": .string(parent.name), "nested": .bool(nowInside)]
    }

    /// Chooses the email, phone or address a member is reached by in a group.
    func setDistribution(_ nameOrID: String, member: String, email: String?, phone: String?, address: String?) async throws(ContactsError) -> JSON {
        let group = try group(nameOrID)
        try guarded(group.name, what: "groups")
        guard email != nil || phone != nil || address != nil else { throw ContactsError("Give the email, phone or address label to use.") }
        let cardID = try card(of: member, inAccount: group.account)
        guard try memberCardIDs(group.id).contains(cardID) else { throw ContactsError("That contact is not in \"\(group.name)\"; add it first.") }
        guard let card = try cards([cardID], keys: [CNContactEmailAddressesKey as NSString, CNContactPhoneNumbersKey as NSString,
                                                   CNContactPostalAddressesKey as NSString]).first else { throw ContactsError("No card \(cardID).") }
        var choices: [(String, String)] = []
        if let email {
            guard let item = card.emailAddresses.first(where: { MultiValuePlan.textKey($0.value as String) == MultiValuePlan.textKey(email) }) else {
                throw ContactsError("The member has no email address \(email).")
            }
            choices.append(("email", item.identifier))
        }
        if let phone {
            guard let item = card.phoneNumbers.first(where: { MultiValuePlan.phoneKey($0.value.stringValue) == MultiValuePlan.phoneKey(phone) }) else {
                throw ContactsError("The member has no phone number \(phone).")
            }
            choices.append(("phone", item.identifier))
        }
        if let address {
            let matches = card.postalAddresses.filter { Labels.friendly($0.label ?? "").caseInsensitiveCompare(address) == .orderedSame }
            guard matches.count == 1 else { throw ContactsError("Give the label of one of the member's addresses: \(card.postalAddresses.map { Labels.friendly($0.label ?? "") }.joined(separator: ", ")).") }
            choices.append(("address", matches[0].identifier))
        }
        try await saving([cardID]) { _ in
            for (property, value) in choices {
                try Self.bridged { try CSAddressBook.setDistributionOfGroup(group.id, card: cardID, property: property, value: value) }
            }
        }
        return try await members(group.id, nested: false)
    }

    // MARK: Smart lists

    func smartLists() throws(ContactsError) -> [[String: Any]] {
        try Self.bridged { try CSAddressBook.smartLists() }
    }

    func smartList(_ nameOrID: String) throws(ContactsError) -> [String: Any] {
        let lists = try smartLists()
        if let found = lists.first(where: { ($0["id"] as? String)?.caseInsensitiveCompare(nameOrID) == .orderedSame }) { return found }
        let named = lists.filter { ($0["name"] as? String)?.caseInsensitiveCompare(nameOrID) == .orderedSame }
        if named.count == 1 { return named[0] }
        if named.isEmpty { throw ContactsError("No smart list \"\(nameOrID)\".") }
        throw ContactsError("Several smart lists are named \"\(nameOrID)\"; pass one of these ids: \(named.compactMap { $0["id"] as? String }.joined(separator: ", ")).")
    }

    /// Checks smart-list criteria, resolving group and smart-list names to ids.
    func criteria(_ value: JSON) throws -> [String: Any] {
        try Criteria.validated(value) { name in
            do throws(ContactsError) {
                switch try self.listing(name) {
                case .group(let group): return group.id
                case .smartList(let list): return list["id"] as? String ?? ""
                }
            } catch {
                throw BadInput(error.description)
            }
        }
    }

    func cardsMatching(_ criteria: [String: Any]) throws(ContactsError) -> [String] {
        try Self.bridged { try CSAddressBook.cards(matchingCriteria: criteria) }
    }

    static func json(_ value: Any) -> JSON {
        switch value {
        case let text as String: return .string(text)
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): return .bool(number.boolValue)
        case let number as NSNumber: return .int(number.intValue)
        case let list as [Any]: return .array(list.map(json))
        case let object as [String: Any]: return .object(object.mapValues(json))
        default: return .string("\(value)")
        }
    }
}
