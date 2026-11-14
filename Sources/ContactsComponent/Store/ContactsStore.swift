@preconcurrency import Contacts
import ContactsModel
import ContactsShim
import Foundation
import Launcher

/// Contacts on this Mac, through Contacts.framework (with the private parts in ContactsShim) and
/// Contacts.app's AppleScript for notes and group members. Everything runs on the main actor, which
/// serializes the tools (AppleScript and AddressBook are not thread-safe) and keeps one write at a
/// time.
///
/// A contact as the tools see it is Contacts' unified contact: one person, made of one card per
/// account when cards are linked. Its id is a card id ("<UUID>:ABPerson") or, when linked, the shared
/// link id (a bare UUID). Writes always go to cards: a write through a unified contact would copy
/// every value onto every linked card.
@MainActor
final class ContactsStore {
    /// Saves are tagged with this author, so contact_changes can leave them out.
    static let author = "com.xiaofeng.apple-contacts-mcp"

    let writeGuard: WriteGuard?
    /// A new store for each tool call (see fresh()): a store kept for the life of the server keeps the
    /// cards it has read, and Contacts' sync agent changes them from its own process (a new ETag after
    /// each upload), after which saving a link from the old view fails (NSCocoaErrorDomain 134040).
    private(set) var store = CNContactStore()
    let script = ContactsScript()

    /// Starts each tool call from what Contacts holds now.
    func fresh() {
        store = CNContactStore()
    }

    init(writeGuard: WriteGuard?) {
        self.writeGuard = writeGuard
    }

    // MARK: Access

    nonisolated static let permissionHelp = """
        Apple Contacts MCP has no access to Contacts. Ask the user to turn on "Apple Contacts MCP" in \
        System Settings → Privacy & Security → Contacts, or to run `apple-contacts-mcp setup` and click Allow.
        """

    static let sandboxHelp = """
        Apple Contacts MCP ran inside a sandbox (Codex runs commands in one), where macOS keeps it from \
        Contacts. Run the same command again outside the sandbox, which the user may have to approve.
        """

    static func describe(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .authorized: "full access"
        case .notDetermined: "not asked yet"
        case .denied: "denied"
        case .restricted: "restricted"
        case .limited: "limited to some contacts"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }

    /// Tools never ask for access themselves (a dialog in the middle of an agent's call is easy to
    /// miss): `setup` does, from a terminal or the settings window.
    func ensureAccess() throws(ContactsError) {
        if launcher_is_sandboxed() != 0 { throw ContactsError(Self.sandboxHelp) }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { throw ContactsError(Self.permissionHelp) }
    }

    // MARK: Keys

    static func key(_ name: String) -> CNKeyDescriptor { name as NSString }

    /// What lists and searches show.
    static let summaryKeys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as NSString, CNContactTypeKey as NSString, CNContactOrganizationNameKey as NSString,
        CNContactJobTitleKey as NSString, CNContactPhoneNumbersKey as NSString, CNContactEmailAddressesKey as NSString,
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName), key("linkIdentifier"),
    ]

    /// Everything read_contact shows and update_contact may change (the note aside, which only
    /// AppleScript reads).
    static let fullKeys: [CNKeyDescriptor] = [
        CNContactIdentifierKey, CNContactTypeKey, CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey,
        CNContactFamilyNameKey, CNContactPreviousFamilyNameKey, CNContactNameSuffixKey, CNContactNicknameKey,
        CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey, CNContactPhoneticFamilyNameKey, CNContactOrganizationNameKey,
        CNContactPhoneticOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey, CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey, CNContactUrlAddressesKey, CNContactPostalAddressesKey, CNContactDatesKey, CNContactRelationsKey,
        CNContactSocialProfilesKey, CNContactInstantMessageAddressesKey, CNContactBirthdayKey, CNContactNonGregorianBirthdayKey,
        CNContactImageDataAvailableKey,
    ].map { $0 as NSString } + [
        key("creationDate"), key("modificationDate"),
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        key("linkIdentifier"), key("preferredForName"), key("preferredForImage"), key("displayNameOrder"),
        key("downtimeWhitelist"), key("callAlert"), key("textAlert"), key("cropRect"), key("wallpaperURI"),
    ]

    // MARK: Accounts

    struct Account {
        /// The container's id, "<UUID>:ABAccount" ("_local:ABAccount" for On My Mac).
        let id: String
        let name: String
        /// iCloud, CardDAV, Exchange, local, …
        let kind: String
        let isDefault: Bool
        let canBeDefault: Bool

        /// AddressBook's id for the account: the container id without ":ABAccount".
        var bookID: String { id.hasSuffix(":ABAccount") ? String(id.dropLast(":ABAccount".count)) : id }
    }

    func accounts() throws(ContactsError) -> [Account] {
        let containers = try attempt { try store.containers(matching: nil) }
        let defaultID = store.defaultContainerIdentifier()
        let named = (try? CSAddressBook.accounts()) ?? []
        return containers.map { container in
            let bookID = container.identifier.hasSuffix(":ABAccount") ? String(container.identifier.dropLast(":ABAccount".count)) : container.identifier
            let row = named.first { ($0["id"] as? String) == bookID }
            var kind: String
            switch container.type {
            case .local: kind = "On My Mac"
            case .exchange: kind = "Exchange"
            case .cardDAV: kind = "CardDAV"
            default: kind = "other"
            }
            if let type = row?["type"] as? String {
                if type.localizedCaseInsensitiveContains("google") || type.localizedCaseInsensitiveContains("gmail") { kind = "Google" }
                else if type.localizedCaseInsensitiveContains("icloud") || type.localizedCaseInsensitiveContains("dotmac") { kind = "iCloud" }
            }
            let name = (row?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (container.name.isEmpty ? kind : container.name)
            return Account(id: container.identifier, name: name, kind: kind, isDefault: container.identifier == defaultID,
                           canBeDefault: (row?["can_be_default"] as? Bool) ?? false)
        }
    }

    func account(_ nameOrID: String) throws(ContactsError) -> Account {
        let all = try accounts()
        if let found = all.first(where: { $0.id.caseInsensitiveCompare(nameOrID) == .orderedSame || $0.bookID.caseInsensitiveCompare(nameOrID) == .orderedSame }) {
            return found
        }
        let named = all.filter { $0.name.caseInsensitiveCompare(nameOrID) == .orderedSame || $0.kind.caseInsensitiveCompare(nameOrID) == .orderedSame }
        if named.count == 1 { return named[0] }
        let list = all.map { "\"\($0.name)\" (\($0.kind), \($0.id))" }.joined(separator: ", ")
        if named.isEmpty { throw ContactsError("No account \"\(nameOrID)\". Accounts: \(list).") }
        throw ContactsError("Several accounts match \"\(nameOrID)\"; pass one of these ids: \(named.map(\.id).joined(separator: ", ")).")
    }

    /// The account named, or Contacts' default one.
    func account(orDefault nameOrID: String?) throws(ContactsError) -> Account {
        if let nameOrID { return try account(nameOrID) }
        return try defaultAccount()
    }

    /// The account named, or all of them.
    func accounts(only nameOrID: String?) throws(ContactsError) -> [Account] {
        if let nameOrID { return [try account(nameOrID)] }
        return try accounts()
    }

    /// The accounts that sync with a server (not On My Mac).
    func syncingAccounts() throws(ContactsError) -> [Account] {
        try accounts().filter { !$0.id.hasPrefix("_local") }
    }

    func defaultAccount() throws(ContactsError) -> Account {
        guard let account = try accounts().first(where: \.isDefault) else { throw ContactsError("Contacts has no default account.") }
        return account
    }

    /// The account a card is in.
    func accountID(ofCard cardID: String) -> String? {
        (try? store.containers(matching: CNContainer.predicateForContainerOfContact(withIdentifier: cardID)))?.first?.identifier
    }

    // MARK: Fetching

    /// Runs a Contacts call, turning its errors (and the CNErrorDomain codes agents can act on) into
    /// plain messages.
    func attempt<T>(_ body: () throws -> T) throws(ContactsError) -> T {
        do {
            return try body()
        } catch let error as ContactsError {
            throw error
        } catch {
            throw Self.explain(error)
        }
    }

    /// Calls the shim, whose failures (a missing private method, a refusal) become plain messages.
    nonisolated static func bridged<T>(_ body: () throws -> T) throws(ContactsError) -> T {
        do {
            return try body()
        } catch let error as ContactsError {
            throw error
        } catch {
            throw ContactsError((error as NSError).localizedDescription)
        }
    }

    nonisolated static func explain(_ error: Error) -> ContactsError {
        let error = error as NSError
        switch (error.domain, error.code) {
        case (CNErrorDomain, 200): return ContactsError("No such contact (it may have been deleted or merged); find it again.")
        case (CNErrorDomain, 100): return ContactsError(permissionHelp)
        case (CNErrorDomain, 206): return ContactsError("Contacts refused the change: the record is read-only (\(error.localizedDescription)).")
        case (CNErrorDomain, 300...399): return ContactsError("Contacts refused a value: \(error.localizedFailureReason ?? error.localizedDescription)")
        case (NSCocoaErrorDomain, 134092):
            return ContactsError("Contacts could not save the card because of its note (it is protected); this app moves notes aside around saves, so try again.")
        default:
            // Core Data puts the reason of a failed save in its underlying errors.
            let details = ((error.userInfo["NSDetailedErrors"] as? [NSError]) ?? [error.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 })
                .map { "\($0.domain) \($0.code): \($0.localizedFailureReason ?? $0.localizedDescription)" }
            let reason = details.isEmpty ? "" : " — " + details.prefix(3).joined(separator: "; ")
            return ContactsError("Contacts: \(error.localizedDescription) (\(error.domain) \(error.code))\(reason)")
        }
    }

    /// Individual cards (not unified), in the given order, with these keys.
    func cards(_ ids: [String], keys: [CNKeyDescriptor] = fullKeys) throws(ContactsError) -> [CNContact] {
        guard !ids.isEmpty else { return [] }
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = false
        request.predicate = CNContact.predicateForContacts(withIdentifiers: ids)
        var found: [String: CNContact] = [:]
        try attempt { try store.enumerateContacts(with: request) { contact, _ in found[contact.identifier] = contact } }
        return ids.compactMap { found[$0] }
    }

    /// A contact by its id or one of its cards' ids: the unified contact and its cards, the card that
    /// gives it its name first.
    func contact(_ id: String, keys: [CNKeyDescriptor] = fullKeys) throws(ContactsError) -> (unified: CNContact, cards: [CNContact]) {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        let unified: CNContact
        do {
            unified = try store.unifiedContact(withIdentifier: trimmed, keysToFetch: keys + [Self.key("linkedContacts")])
        } catch {
            throw ContactsError("No contact with id \(trimmed) (it may have been deleted, merged or unlinked); find it again with find_contacts.")
        }
        var cardIDs = ((unified.value(forKey: "linkedContacts") as? [CNContact]) ?? []).map(\.identifier)
        if cardIDs.isEmpty { cardIDs = [unified.identifier] }
        var cards = try self.cards(cardIDs, keys: keys)
        if cards.isEmpty { throw ContactsError("No contact with id \(trimmed); find it again with find_contacts.") }
        cards.sort { Self.flag($0, "preferredForName") && !Self.flag($1, "preferredForName") }
        return (unified, cards)
    }

    static func flag(_ contact: CNContact, _ key: String) -> Bool {
        guard contact.isKeyAvailable(key) else { return false }
        return (contact.value(forKey: key) as? Bool) ?? ((contact.value(forKey: key) as? NSNumber)?.boolValue ?? false)
    }

    static func text(_ contact: CNContact, _ key: String) -> String? {
        guard contact.isKeyAvailable(key) else { return nil }
        return (contact.value(forKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The name Contacts shows: a company is its organization, a person their full name.
    static func displayName(_ contact: CNContact) -> String {
        if contact.isKeyAvailable(CNContactTypeKey), contact.contactType == .organization,
           contact.isKeyAvailable(CNContactOrganizationNameKey), !contact.organizationName.isEmpty {
            return contact.organizationName
        }
        let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        if !name.isEmpty { return name }
        if contact.isKeyAvailable(CNContactOrganizationNameKey), !contact.organizationName.isEmpty { return contact.organizationName }
        return "No Name"
    }

    /// Unified contacts matching a predicate (nil: all), sorted as Contacts sorts them.
    func unifiedContacts(_ predicate: NSPredicate?, keys: [CNKeyDescriptor] = summaryKeys) throws(ContactsError) -> [CNContact] {
        let request = CNContactFetchRequest(keysToFetch: keys + [CNContact.descriptorForAllComparatorKeys()])
        request.predicate = predicate
        request.sortOrder = .userDefault
        var found: [CNContact] = []
        try attempt { try store.enumerateContacts(with: request) { contact, _ in found.append(contact) } }
        return found
    }

    /// Ids of the cards in an account.
    func cardIDs(inAccount accountID: String) throws(ContactsError) -> [String] {
        let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as NSString])
        request.unifyResults = false
        request.predicate = CNContact.predicateForContactsInContainer(withIdentifier: accountID)
        var ids: [String] = []
        try attempt { try store.enumerateContacts(with: request) { contact, _ in ids.append(contact.identifier) } }
        return ids
    }

    /// Standard labels of a multi-value property, as Contacts stores them (for Labels.stored).
    func standardLabels(_ key: String) -> [String] {
        if let cached = labelCache[key] { return cached }
        let selector = NSSelectorFromString("standardLabelsForPropertyWithKey:options:")
        var labels: [String] = []
        if CNContactStore.responds(to: selector) {
            typealias Call = @convention(c) (AnyObject, Selector, NSString, UInt) -> NSArray?
            let call = unsafeBitCast(CNContactStore.method(for: selector), to: Call.self)
            labels = (call(CNContactStore.self, selector, key as NSString, 1) as? [String]) ?? []
        }
        if labels.isEmpty {
            labels = [CNLabelHome, CNLabelWork, CNLabelSchool, CNLabelOther, CNLabelPhoneNumberMobile, CNLabelPhoneNumberMain,
                      CNLabelPhoneNumberHomeFax, CNLabelPhoneNumberWorkFax, CNLabelPhoneNumberPager, CNLabelPhoneNumberiPhone,
                      CNLabelURLAddressHomePage, CNLabelDateAnniversary, CNLabelEmailiCloud]
        }
        labelCache[key] = labels
        return labels
    }

    private var labelCache: [String: [String]] = [:]

    // MARK: The write guard

    func guarded(_ name: String, what: String) throws(ContactsError) {
        try writeGuard?.check(name, what: what)
    }

    func guarded(_ contact: CNContact) throws(ContactsError) {
        try guarded(Self.displayName(contact), what: "contacts")
    }
}
