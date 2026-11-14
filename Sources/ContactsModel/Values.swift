import CryptoKit
import Foundation
import Wire

/// A problem the model can act on (not found, changed since read, refused); the text goes back as a
/// failed tool answer.
package struct ContactsError: Error, CustomStringConvertible, Sendable {
    package let description: String
    /// The change itself was saved; only a step after it (writing a note back) is still pending.
    package let afterSave: Bool
    package init(_ description: String, afterSave: Bool = false) {
        self.description = description
        self.afterSave = afterSave
    }
}

/// A day as Contacts keeps it: a Gregorian date with or without a year (a birthday that comes every
/// year), or a date in another calendar (a lunar birthday) with its era and leap-month mark.
package struct ContactDate: Sendable, Equatable {
    package var calendar: String
    package var era: Int?
    package var year: Int?
    package var month: Int
    package var day: Int
    package var leapMonth: Bool

    package init(calendar: String = "gregorian", era: Int? = nil, year: Int? = nil, month: Int, day: Int, leapMonth: Bool = false) {
        self.calendar = calendar
        self.era = era
        self.year = year
        self.month = month
        self.day = day
        self.leapMonth = leapMonth
    }

    /// The calendars Contacts' "other calendar" birthday takes, by the names the tools use.
    package static let calendars = [
        "buddhist", "chinese", "coptic", "ethiopic-amete-alem", "ethiopic-amete-mihret", "gregorian", "hebrew", "indian",
        "islamic", "islamic-civil", "islamic-tabular", "islamic-umm-al-qura", "japanese", "persian", "republic-of-china",
    ]

    /// "1990-05-17" or "05-17" (no year: every year) for a Gregorian date; nil for another calendar,
    /// which only has the object form.
    package var short: String? {
        guard calendar == "gregorian" else { return nil }
        if let year { return String(format: "%04d-%02d-%02d", year, month, day) }
        return String(format: "%02d-%02d", month, day)
    }

    /// Parses "1990-05-17", or "05-17" / "--05-17" for a day with no year. The day must exist in that
    /// month (February 29 only in a leap year, or with no year).
    package static func parse(_ text: String) -> ContactDate? {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("--") { body.removeFirst(2) }
        let parts = body.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.map { $0! }
        switch numbers.count {
        case 3:
            guard body.split(separator: "-")[0].count == 4, valid(year: numbers[0], month: numbers[1], day: numbers[2]) else { return nil }
            return ContactDate(year: numbers[0], month: numbers[1], day: numbers[2])
        case 2:
            guard valid(year: nil, month: numbers[0], day: numbers[1]) else { return nil }
            return ContactDate(month: numbers[0], day: numbers[1])
        default:
            return nil
        }
    }

    /// Whether the day exists in that Gregorian month; with no year, February has 29 days.
    package static func valid(year: Int?, month: Int, day: Int) -> Bool {
        guard (1...12).contains(month), day >= 1 else { return false }
        let lengths = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        var length = lengths[month - 1]
        if month == 2, let year, !(year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) { length = 28 }
        return day <= length
    }

    /// The tool form: the short string for Gregorian dates, else {calendar, era, year, month, day, leap_month}.
    package var json: JSON {
        if let short { return .string(short) }
        var object: [String: JSON] = ["calendar": .string(calendar), "month": .int(month), "day": .int(day)]
        if let era { object["era"] = .int(era) }
        if let year { object["year"] = .int(year) }
        if leapMonth { object["leap_month"] = true }
        return .object(object)
    }
}

/// Contacts' labels as the tools write them: the standard ones by plain words ("mobile", "home fax",
/// "homepage", "father in law"), anything else as it is (a custom label, "iPhone", "iCloud").
/// Contacts stores the standard ones as tokens such as `_$!<HomeFAX>!$_`.
package enum Labels {
    /// A stored label as the tools show it.
    package static func friendly(_ stored: String) -> String {
        guard stored.hasPrefix("_$!<"), stored.hasSuffix(">!$_"), stored.count > 8 else { return stored }
        let inner = String(stored.dropFirst(4).dropLast(4))
        if inner == "HomePage" { return "homepage" }
        var words: [String] = []
        var current = ""
        let characters = Array(inner)
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let previous = index > 0 ? characters[index - 1] : nil
            let startsWord = character.isUppercase && !current.isEmpty
                && ((previous?.isLowercase ?? false) || (next?.isLowercase ?? false))
            if startsWord {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }.joined(separator: " ")
    }

    /// What the tools were given, as Contacts stores it: one of `standard` when the words match it
    /// (ignoring case, spaces, hyphens and apostrophes), otherwise the text as a custom label.
    package static func stored(_ given: String, standard: [String]) -> String {
        let key = normalized(given)
        for label in standard where normalized(friendly(label)) == key || normalized(label) == key { return label }
        return given
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { !" -_'’".contains($0) }
    }
}

/// How the values of a multi-value field (phones, emails, …) are spread over the cards of one person
/// (cards in iCloud, Gmail, … linked into one contact): which existing value stays (possibly with a
/// new label), which goes, and which new one is added to which card. Values are matched by a key
/// (digits of a phone number, a lower-cased email, …), so a value keeps its card and its identity.
package enum MultiValuePlan {
    package struct Existing: Sendable, Equatable {
        package let card: Int
        package let id: String
        package let label: String?
        package let key: String
        package init(card: Int, id: String, label: String?, key: String) {
            self.card = card
            self.id = id
            self.label = label
            self.key = key
        }
    }

    package enum Step: Sendable, Equatable {
        /// Keep this value on its card, relabelled when `label` differs from its own; with `desired`,
        /// also take that desired value's text when it differs only in form (case, spacing, punctuation).
        case keep(card: Int, id: String, label: String?, desired: Int?)
        case remove(card: Int, id: String)
        /// Add the desired value at this index to the card.
        case add(card: Int, desired: Int)
    }

    /// `desired` is the whole new list as (label, key); new values go to `target`. A desired value
    /// matches one existing value; the same value on another linked card (Contacts shows it once) stays
    /// there as it is. Values whose key is not desired are removed.
    package static func steps(existing: [Existing], desired: [(label: String?, key: String)], target: Int) -> [Step] {
        var used = Set<Int>()
        var steps: [Step] = []
        var keptOn: [String: Set<Int>] = [:]
        for (index, want) in desired.enumerated() {
            if let match = existing.indices.first(where: { !used.contains($0) && existing[$0].key == want.key }) {
                used.insert(match)
                steps.append(.keep(card: existing[match].card, id: existing[match].id, label: want.label, desired: index))
                keptOn[want.key, default: []].insert(existing[match].card)
            } else {
                steps.append(.add(card: target, desired: index))
            }
        }
        for index in existing.indices where !used.contains(index) {
            let value = existing[index]
            if let cards = keptOn[value.key], !cards.contains(value.card) {
                keptOn[value.key, default: []].insert(value.card)
                steps.append(.keep(card: value.card, id: value.id, label: value.label, desired: nil))
            } else {
                steps.append(.remove(card: value.card, id: value.id))
            }
        }
        return steps
    }

    /// The matching keys Contacts' values are compared by.
    package static func phoneKey(_ number: String) -> String {
        let digits = number.filter(\.isNumber)
        return number.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" + digits : digits
    }

    package static func textKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Versions: a hash of everything a tool shows of a contact (timestamps and groups aside: joining a
/// group does not conflict with an edit), so a write is refused
/// when the contact changed anywhere (another device, Contacts.app, another agent) since it was read.
package enum Versions {
    package static func of(_ shown: JSON) -> String {
        var fields = shown.object ?? [:]
        for key in ["version", "created", "modified", "groups"] { fields.removeValue(forKey: key) }
        let digest = SHA256.hash(data: Data(JSON.object(fields).text.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// Write guard (APPLE_CONTACTS_MCP_WRITE_GUARD, for development and checks): writes only touch
/// contacts, groups and smart lists whose name starts with one of these prefixes, case ignored.
package struct WriteGuard: Sendable {
    package let prefixes: [String]

    package init?(_ value: String?) {
        let prefixes = (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !prefixes.isEmpty else { return nil }
        self.prefixes = prefixes
    }

    package func allows(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return prefixes.contains { trimmed.range(of: $0, options: [.caseInsensitive, .anchored]) != nil }
    }

    package func check(_ name: String, what: String) throws(ContactsError) {
        guard allows(name) else {
            throw ContactsError("Refused by the write guard (APPLE_CONTACTS_MCP_WRITE_GUARD): only \(what) whose name starts with \(description) may be changed, not \"\(name)\".")
        }
    }

    package var description: String { prefixes.map { "\"\($0)\"" }.joined(separator: " or ") }
}
