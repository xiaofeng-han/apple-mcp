import AppKit
@preconcurrency import Contacts
import ContactsModel
import ContactsShim
import Foundation
import Wire

/// The contact fields create_contact and update_contact take, read and checked once, then applied to
/// cards. A field that is absent stays as it is; null clears it; a list replaces the whole list.
struct ContactEdit {
    var type: CNContactType?
    /// Single text fields by tool name; nil clears.
    var texts: [String: String?] = [:]
    var nameOrder: Int?
    /// .some(nil) clears the note.
    var note: String??
    var phones: [(label: String?, value: String)]?
    var emails: [(label: String?, value: String)]?
    var urls: [(label: String?, value: String)]?
    var relatedNames: [(label: String?, value: String)]?
    var addresses: [(label: String?, value: CNPostalAddress)]?
    var dates: [(label: String?, value: ContactDate)]?
    var socialProfiles: [(label: String?, value: CNSocialProfile)]?
    var instantMessages: [(label: String?, value: CNInstantMessageAddress)]?
    var birthday: ContactDate??
    var otherBirthday: ContactDate??
    /// .some(nil) removes the photo.
    var photo: Data??
    var photoCrop: CGRect?
    var ringtone: String??
    var textTone: String??
    var emergencyBypass: (calls: Bool, texts: Bool)?
    var downtimeAllowed: Bool?

    static let textKeys = ["prefix", "first_name", "middle_name", "last_name", "maiden_name", "suffix", "nickname",
                           "phonetic_first_name", "phonetic_middle_name", "phonetic_last_name", "organization",
                           "phonetic_organization", "department", "job_title"]

    /// Notes longer than this do not reach iCloud (its CardDAV limit is between 175,000 and 200,000
    /// characters); Contacts keeps them on the Mac, silently unsynced.
    static let noteLimit = 150_000

    var changesCard: Bool {
        type != nil || !texts.isEmpty || nameOrder != nil || phones != nil || emails != nil || urls != nil || relatedNames != nil
            || addresses != nil || dates != nil || socialProfiles != nil || instantMessages != nil || birthday != nil
            || otherBirthday != nil || photo != nil || photoCrop != nil || ringtone != nil || textTone != nil
            || emergencyBypass != nil || downtimeAllowed != nil
    }

    var isEmpty: Bool { !changesCard && note == nil }

    // MARK: Reading the input

    init(_ fields: [String: JSON], labels: (String) -> [String]) throws {
        func value(_ key: String) -> JSON? { fields[key] }
        func cleared(_ key: String) -> Bool { fields[key] == .null }
        func list(_ key: String) throws -> [[String: JSON]]? {
            guard let raw = value(key) else { return nil }
            if raw == .null { return [] }
            guard let items = raw.array else { throw BadInput("\(key) must be a list of objects") }
            return try items.map { item in
                guard let object = item.object else { throw BadInput("each of \(key) must be an object") }
                return object
            }
        }
        func text(_ object: [String: JSON], _ key: String, in field: String) throws -> String? {
            guard let value = object[key], value != .null else { return nil }
            guard let text = value.string else { throw BadInput("\(field).\(key) must be text") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : text
        }
        func known(_ object: [String: JSON], _ keys: [String], in field: String) throws {
            if let unknown = object.keys.sorted().first(where: { !keys.contains($0) }) {
                throw BadInput("\(field).\(unknown) is not known; use \(keys.joined(separator: ", "))")
            }
        }
        func label(_ object: [String: JSON], field: String, property: String) throws -> String? {
            try text(object, "label", in: field).map { Labels.stored($0, standard: labels(property)) }
        }
        func labeledTexts(_ key: String, property: String) throws -> [(label: String?, value: String)]? {
            try list(key)?.map { object in
                try known(object, ["label", "value"], in: key)
                guard let value = try text(object, "value", in: key) else { throw BadInput("each of \(key) needs a value") }
                return (try label(object, field: key, property: property), value)
            }
        }

        if let type = value("type"), type != .null {
            guard let name = type.string, ["person", "company"].contains(name) else { throw BadInput("type must be person or company") }
            self.type = name == "company" ? .organization : .person
        }
        for key in Self.textKeys where value(key) != nil {
            if cleared(key) { texts[key] = .some(nil); continue }
            guard let text = value(key)?.string else { throw BadInput("\(key) must be text or null") }
            texts[key] = .some(text.isEmpty ? nil : text)
        }
        if let order = value("name_order"), order != .null {
            guard let name = order.string, let number = ["default": 0, "given_first": 1, "family_first": 2][name] else {
                throw BadInput("name_order must be default, given_first or family_first")
            }
            nameOrder = number
        }
        if value("note") != nil {
            if cleared("note") {
                note = .some(nil)
            } else {
                guard let text = value("note")?.string else { throw BadInput("note must be text or null") }
                guard text.count <= Self.noteLimit else { throw BadInput("note is longer than \(Self.noteLimit) characters, more than iCloud keeps") }
                note = .some(text.isEmpty ? nil : text)
            }
        }
        phones = try labeledTexts("phones", property: CNContactPhoneNumbersKey)
        emails = try labeledTexts("emails", property: CNContactEmailAddressesKey)
        urls = try labeledTexts("urls", property: CNContactUrlAddressesKey)
        relatedNames = try labeledTexts("related_names", property: CNContactRelationsKey)
        let addressKeys = ["label", "street", "sub_locality", "city", "sub_administrative_area", "state", "postal_code", "country", "country_code"]
        addresses = try list("addresses")?.map { object in
            try known(object, addressKeys, in: "addresses")
            let address = CNMutablePostalAddress()
            address.street = try text(object, "street", in: "addresses") ?? ""
            address.subLocality = try text(object, "sub_locality", in: "addresses") ?? ""
            address.city = try text(object, "city", in: "addresses") ?? ""
            address.subAdministrativeArea = try text(object, "sub_administrative_area", in: "addresses") ?? ""
            address.state = try text(object, "state", in: "addresses") ?? ""
            address.postalCode = try text(object, "postal_code", in: "addresses") ?? ""
            address.country = try text(object, "country", in: "addresses") ?? ""
            address.isoCountryCode = (try text(object, "country_code", in: "addresses") ?? "").lowercased()
            guard !(address.street + address.city + address.state + address.postalCode + address.country).isEmpty else {
                throw BadInput("each address needs a street, city, state, postal code or country")
            }
            return (try label(object, field: "addresses", property: CNContactPostalAddressesKey), address.copy() as! CNPostalAddress)
        }
        dates = try list("dates")?.map { object in
            try known(object, ["label", "value"], in: "dates")
            guard let text = try text(object, "value", in: "dates"), let date = ContactDate.parse(text) else {
                throw BadInput("dates value must look like 2015-06-01, or 06-01 for every year, and be a real day")
            }
            return (try label(object, field: "dates", property: CNContactDatesKey), date)
        }
        socialProfiles = try list("social_profiles")?.map { object in
            try known(object, ["label", "service", "username", "user_id", "url"], in: "social_profiles")
            let username = try text(object, "username", in: "social_profiles"), url = try text(object, "url", in: "social_profiles")
            guard username != nil || url != nil else { throw BadInput("each social profile needs a username or url") }
            let profile = CNSocialProfile(urlString: url, username: username, userIdentifier: try text(object, "user_id", in: "social_profiles"),
                                          service: try text(object, "service", in: "social_profiles"))
            return (try label(object, field: "social_profiles", property: CNContactSocialProfilesKey), profile)
        }
        instantMessages = try list("instant_messages")?.map { object in
            try known(object, ["label", "service", "username"], in: "instant_messages")
            guard let username = try text(object, "username", in: "instant_messages") else { throw BadInput("each instant message address needs a username") }
            let address = CNInstantMessageAddress(username: username, service: try text(object, "service", in: "instant_messages") ?? "")
            return (try label(object, field: "instant_messages", property: CNContactInstantMessageAddressesKey), address)
        }
        if value("birthday") != nil {
            if cleared("birthday") { birthday = .some(nil) } else {
                guard let text = value("birthday")?.string, let date = ContactDate.parse(text) else {
                    throw BadInput("birthday must look like 1990-05-17, or 05-17 when the year is not known, and be a real day")
                }
                birthday = .some(date)
            }
        }
        if let other = value("other_birthday") {
            if other == .null { otherBirthday = .some(nil) } else {
                guard let object = other.object else { throw BadInput("other_birthday must be {calendar, year, month, day, leap_month}") }
                try known(object, ["calendar", "era", "year", "month", "day", "leap_month"], in: "other_birthday")
                guard let calendar = object["calendar"]?.string, ContactDate.calendars.contains(calendar), calendar != "gregorian" else {
                    throw BadInput("other_birthday.calendar must be one of: \(ContactDate.calendars.filter { $0 != "gregorian" }.joined(separator: ", "))")
                }
                guard let month = object["month"]?.int, (1...13).contains(month), let day = object["day"]?.int, (1...31).contains(day) else {
                    throw BadInput("other_birthday needs month (1–13) and day (1–31)")
                }
                otherBirthday = .some(ContactDate(calendar: calendar, era: object["era"]?.int, year: object["year"]?.int, month: month, day: day,
                                                  leapMonth: object["leap_month"]?.bool ?? false))
            }
        }
        if let photo = value("photo") {
            if photo == .null {
                if let crop = value("photo_crop"), crop != .null { throw BadInput("photo_crop goes with a photo file, not with photo: null") }
                self.photo = .some(nil)
            } else {
                guard let path = photo.string, path.hasPrefix("/") else { throw BadInput("photo must be an absolute path") }
                // Only a regular file of a sensible size is read (not a device, a pipe or a huge file).
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                let attributes = try? FileManager.default.attributesOfItem(atPath: resolved)
                guard let attributes, attributes[.type] as? FileAttributeType == .typeRegular else { throw BadInput("photo: \(path) is not a file") }
                let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                guard size > 0 else { throw BadInput("photo: \(path) is empty") }
                guard size <= 20_000_000 else { throw BadInput("photo: \(path) is larger than 20 MB") }
                guard let data = FileManager.default.contents(atPath: resolved), !data.isEmpty else { throw BadInput("photo: cannot read \(path)") }
                guard let image = NSImageRep(contentsOfFile: resolved), image.pixelsWide > 0, image.pixelsHigh > 0 else {
                    throw BadInput("photo: \(path) is not an image macOS reads")
                }
                self.photo = .some(data)
                if let crop = value("photo_crop"), crop != .null {
                    let width = image.pixelsWide, height = image.pixelsHigh
                    let refused = BadInput("photo_crop must be four whole numbers [x, y, width, height] inside the image (\(width)×\(height))")
                    guard let items = crop.array, items.count == 4 else { throw refused }
                    var numbers: [Int] = []
                    for item in items {
                        guard let number = item.int else { throw refused }
                        numbers.append(number)
                    }
                    let (x, y, w, h) = (numbers[0], numbers[1], numbers[2], numbers[3])
                    guard x >= 0, y >= 0, w > 0, h > 0, x < width, y < height, w <= width - x, h <= height - y else { throw refused }
                    // Contacts keeps the crop with its origin at the image's bottom left.
                    photoCrop = CGRect(x: x, y: height - y - h, width: w, height: h)
                } else {
                    let side = min(image.pixelsWide, image.pixelsHigh)
                    photoCrop = CGRect(x: (image.pixelsWide - side) / 2, y: (image.pixelsHigh - side) / 2, width: side, height: side)
                }
            }
        } else if value("photo_crop") != nil {
            throw BadInput("photo_crop goes with photo")
        }
        for (key, calls) in [("ringtone", true), ("text_tone", false)] where value(key) != nil {
            let tone: String?? = cleared(key) ? .some(nil) : .some(try {
                guard let text = value(key)?.string, !text.isEmpty else { throw BadInput("\(key) must be a tone id, <default> or <none>") }
                return text
            }())
            if calls { ringtone = tone } else { textTone = tone }
        }
        if let bypass = value("emergency_bypass"), bypass != .null {
            guard let name = bypass.string, let choice = ["off": (false, false), "calls": (true, false), "texts": (false, true), "both": (true, true)][name] else {
                throw BadInput("emergency_bypass must be off, calls, texts or both")
            }
            emergencyBypass = choice
        }
        if let downtime = value("downtime_allowed"), downtime != .null {
            guard let flag = downtime.bool else { throw BadInput("downtime_allowed must be true or false") }
            downtimeAllowed = flag
        }
    }

    // MARK: Applying it

    /// Applies the edit to a person's cards: single fields to the target card, list values spread over
    /// the cards they are on (new ones to the target), the photo to the target (the others' cleared when
    /// it is removed). Returns the indexes of the cards that changed.
    func apply(to cards: [CNMutableContact], target: Int) throws(ContactsError) -> Set<Int> {
        var changed = Set<Int>()
        let card = cards[target]
        if let type { card.contactType = type; changed.insert(target) }
        // A value goes to the target card; clearing clears it on every linked card that has it, since
        // Contacts would otherwise show another card's.
        for (key, value) in texts {
            guard let path = Self.textPaths[key] else { continue }
            if let value {
                card[keyPath: path] = value
                changed.insert(target)
            } else {
                for (index, other) in cards.enumerated() where index == target || !other[keyPath: path].isEmpty {
                    other[keyPath: path] = ""
                    changed.insert(index)
                }
            }
        }
        if let nameOrder {
            try ContactsStore.bridged { try CSStore.setDisplayNameOrder(nameOrder, contact: card) }
            changed.insert(target)
        }
        if let phones {
            changed.formUnion(spread(cards, target: target, desired: phones.map { ($0.label, MultiValuePlan.phoneKey($0.value)) },
                                     get: { $0.phoneNumbers }, set: { $0.phoneNumbers = $1 }, key: { MultiValuePlan.phoneKey($0.stringValue) }, exact: { $0.stringValue },
                                     make: { CNPhoneNumber(stringValue: phones[$0].value) }))
        }
        if let emails {
            changed.formUnion(spread(cards, target: target, desired: emails.map { ($0.label, MultiValuePlan.textKey($0.value)) },
                                     get: { $0.emailAddresses }, set: { $0.emailAddresses = $1 }, key: { MultiValuePlan.textKey($0 as String) }, exact: { $0 as String },
                                     make: { emails[$0].value as NSString }))
        }
        if let urls {
            changed.formUnion(spread(cards, target: target, desired: urls.map { ($0.label, MultiValuePlan.textKey($0.value)) },
                                     get: { $0.urlAddresses }, set: { $0.urlAddresses = $1 }, key: { MultiValuePlan.textKey($0 as String) }, exact: { $0 as String },
                                     make: { urls[$0].value as NSString }))
        }
        if let relatedNames {
            changed.formUnion(spread(cards, target: target, desired: relatedNames.map { ($0.label, MultiValuePlan.textKey($0.value)) },
                                     get: { $0.contactRelations }, set: { $0.contactRelations = $1 }, key: { MultiValuePlan.textKey($0.name) }, exact: { $0.name },
                                     make: { CNContactRelation(name: relatedNames[$0].value) }))
        }
        if let addresses {
            changed.formUnion(spread(cards, target: target, desired: addresses.map { ($0.label, Self.addressKey($0.value)) },
                                     get: { $0.postalAddresses }, set: { $0.postalAddresses = $1 }, key: Self.addressKey, exact: Self.addressText,
                                     make: { addresses[$0].value }))
        }
        if let dates {
            changed.formUnion(spread(cards, target: target, desired: dates.map { ($0.label, Self.dateKey($0.value)) },
                                     get: { $0.dates }, set: { $0.dates = $1 }, key: { Self.dateKey(Self.date($0 as DateComponents)) }, exact: { Self.dateKey(Self.date($0 as DateComponents)) },
                                     make: { Self.components(dates[$0].value) as NSDateComponents }))
        }
        if let socialProfiles {
            changed.formUnion(spread(cards, target: target, desired: socialProfiles.map { ($0.label, Self.socialKey($0.value)) },
                                     get: { $0.socialProfiles }, set: { $0.socialProfiles = $1 }, key: Self.socialKey,
                                     exact: { [$0.service, $0.username, $0.userIdentifier, $0.urlString].joined(separator: "|") },
                                     make: { socialProfiles[$0].value }))
        }
        if let instantMessages {
            changed.formUnion(spread(cards, target: target, desired: instantMessages.map { ($0.label, Self.messageKey($0.value)) },
                                     get: { $0.instantMessageAddresses }, set: { $0.instantMessageAddresses = $1 }, key: Self.messageKey,
                                     exact: { [$0.service, $0.username].joined(separator: "|") },
                                     make: { instantMessages[$0].value }))
        }
        if let birthday {
            if let date = birthday {
                card.birthday = Self.components(date)
                changed.insert(target)
            } else {
                for (index, other) in cards.enumerated() where index == target || other.birthday != nil {
                    other.birthday = nil
                    changed.insert(index)
                }
            }
        }
        if let otherBirthday {
            if let date = otherBirthday {
                card.nonGregorianBirthday = Self.components(date)
                changed.insert(target)
            } else {
                for (index, other) in cards.enumerated() where index == target || other.nonGregorianBirthday != nil {
                    other.nonGregorianBirthday = nil
                    changed.insert(index)
                }
            }
        }
        if let photo {
            if let data = photo {
                card.imageData = data
                try ContactsStore.bridged { try CSStore.clearThumbnail(of: card) }
                if let photoCrop { try ContactsStore.bridged { try CSStore.setCropRect(photoCrop, contact: card) } }
                changed.insert(target)
                if cards.count > 1 {
                    for (index, other) in cards.enumerated() {
                        try ContactsStore.bridged { try CSStore.setPreferredForImage(index == target, contact: other) }
                        changed.insert(index)
                    }
                }
            } else {
                for (index, other) in cards.enumerated() where other.imageDataAvailable {
                    other.imageData = nil
                    try ContactsStore.bridged { try CSStore.clearThumbnail(of: other) }
                    changed.insert(index)
                }
            }
        }
        for (calls, tone) in [(true, ringtone), (false, textTone)] {
            guard let tone else { continue }
            if let sound = tone {
                let current = CSStore.alert(forCalls: calls, contact: card)
                try ContactsStore.bridged {
                    try CSStore.setAlertForCalls(calls, sound: sound, vibration: current?["vibration"] as? String,
                                                 ignoreMute: (current?["ignore_mute"] as? Bool) ?? false, clear: false, contact: card)
                }
                changed.insert(target)
            } else {
                // Cleared on every card that has one, as Contacts would otherwise show another card's.
                for (index, other) in cards.enumerated() where index == target || CSStore.alert(forCalls: calls, contact: other) != nil {
                    try ContactsStore.bridged {
                        try CSStore.setAlertForCalls(calls, sound: nil, vibration: nil, ignoreMute: false, clear: true, contact: other)
                    }
                    changed.insert(index)
                }
            }
        }
        if let emergencyBypass {
            for (calls, on) in [(true, emergencyBypass.calls), (false, emergencyBypass.texts)] {
                let current = CSStore.alert(forCalls: calls, contact: card)
                if current == nil && !on { continue }
                try ContactsStore.bridged {
                    try CSStore.setAlertForCalls(calls, sound: (current?["sound"] as? String) ?? "<default>", vibration: current?["vibration"] as? String,
                                                 ignoreMute: on, clear: false, contact: card)
                }
            }
            changed.insert(target)
        }
        if let downtimeAllowed {
            for (index, other) in cards.enumerated() {
                try ContactsStore.bridged { try CSStore.setDowntimeAllowed(downtimeAllowed, contact: other) }
                changed.insert(index)
            }
        }
        return changed
    }

    nonisolated(unsafe) static let textPaths: [String: ReferenceWritableKeyPath<CNMutableContact, String>] = [
        "prefix": \.namePrefix, "first_name": \.givenName, "middle_name": \.middleName, "last_name": \.familyName,
        "maiden_name": \.previousFamilyName, "suffix": \.nameSuffix, "nickname": \.nickname,
        "phonetic_first_name": \.phoneticGivenName, "phonetic_middle_name": \.phoneticMiddleName, "phonetic_last_name": \.phoneticFamilyName,
        "organization": \.organizationName, "phonetic_organization": \.phoneticOrganizationName, "department": \.departmentName,
        "job_title": \.jobTitle,
    ]

    /// Spreads a list over the cards with MultiValuePlan, keeping each value's identity (and so its
    /// card); new values are added at the end of the target card's list. `exact` is a value as written,
    /// so that a value matched by its key but written differently (case, spacing) takes the new form.
    private func spread<V>(_ cards: [CNMutableContact], target: Int, desired: [(label: String?, key: String)],
                           get: (CNMutableContact) -> [CNLabeledValue<V>], set: (CNMutableContact, [CNLabeledValue<V>]) -> Void,
                           key: (V) -> String, exact: (V) -> String, make: (Int) -> V) -> Set<Int> {
        var existing: [MultiValuePlan.Existing] = []
        for (index, card) in cards.enumerated() {
            for item in get(card) { existing.append(.init(card: index, id: item.identifier, label: item.label, key: key(item.value))) }
        }
        var lists = cards.map(get)
        var changed = Set<Int>()
        for step in MultiValuePlan.steps(existing: existing, desired: desired, target: target) {
            switch step {
            case .keep(let card, let id, let label, let wanted):
                guard let index = lists[card].firstIndex(where: { $0.identifier == id }) else { continue }
                var item = lists[card][index], touched = false
                if item.label != label { item = item.settingLabel(label); touched = true }
                if let wanted, exact(item.value) != exact(make(wanted)) { item = item.settingValue(make(wanted)); touched = true }
                guard touched else { continue }
                lists[card][index] = item
                changed.insert(card)
            case .remove(let card, let id):
                lists[card].removeAll { $0.identifier == id }
                changed.insert(card)
            case .add(let card, let index):
                lists[card].append(CNLabeledValue(label: desired[index].label, value: make(index)))
                changed.insert(card)
            }
        }
        for card in changed { set(cards[card], lists[card]) }
        return changed
    }

    static func addressKey(_ address: CNPostalAddress) -> String {
        [address.street, address.subLocality, address.city, address.subAdministrativeArea, address.state, address.postalCode,
         address.country, address.isoCountryCode].map(MultiValuePlan.textKey).joined(separator: "|")
    }

    static func addressText(_ address: CNPostalAddress) -> String {
        [address.street, address.subLocality, address.city, address.subAdministrativeArea, address.state, address.postalCode,
         address.country, address.isoCountryCode].joined(separator: "|")
    }

    static func socialKey(_ profile: CNSocialProfile) -> String {
        [profile.service, profile.username, profile.urlString].map(MultiValuePlan.textKey).joined(separator: "|")
    }

    static func messageKey(_ address: CNInstantMessageAddress) -> String {
        [address.service, address.username].map(MultiValuePlan.textKey).joined(separator: "|")
    }

    static func dateKey(_ date: ContactDate?) -> String {
        guard let date else { return "" }
        return "\(date.calendar)|\(date.year ?? 0)|\(date.month)|\(date.day)|\(date.leapMonth)"
    }

    static func date(_ components: DateComponents) -> ContactDate? {
        guard let month = components.month, let day = components.day, month != NSDateComponentUndefined, day != NSDateComponentUndefined else { return nil }
        let year = components.year.flatMap { $0 == NSDateComponentUndefined ? nil : $0 }
        return ContactDate(calendar: ContactsStore.calendarName(components.calendar?.identifier ?? .gregorian), year: year, month: month, day: day,
                           leapMonth: components.isLeapMonth ?? false)
    }

    static func components(_ date: ContactDate) -> DateComponents {
        var components = DateComponents()
        if date.calendar != "gregorian", let identifier = ContactsStore.calendarIdentifiers[date.calendar] {
            components.calendar = Calendar(identifier: identifier)
            components.era = date.era
            components.isLeapMonth = date.leapMonth
        }
        components.year = date.year
        components.month = date.month
        components.day = date.day
        return components
    }
}
