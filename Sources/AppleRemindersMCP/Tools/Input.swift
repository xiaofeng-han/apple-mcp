import Foundation
import Wire

/// A tool's arguments, read by type. A wrong type or unknown value is BadInput (a JSON-RPC
/// error); absent and null both read as nil, and `cleared` tells them apart where null means
/// "remove this".
struct Input {
    let fields: [String: JSON]

    init(_ fields: [String: JSON]) { self.fields = fields }

    func has(_ key: String) -> Bool { fields[key] != nil }
    func cleared(_ key: String) -> Bool { fields[key] == .null }

    private func value(_ key: String) -> JSON? {
        guard let value = fields[key], value != .null else { return nil }
        return value
    }

    /// Text; empty text reads as nil.
    func text(_ key: String) throws -> String? {
        guard let value = value(key) else { return nil }
        guard let text = value.string else { throw BadInput("\(key) must be text") }
        return text.isEmpty ? nil : text
    }

    func requiredText(_ key: String) throws -> String {
        guard let text = try text(key) else { throw BadInput("\(key) is required") }
        return text
    }

    func flag(_ key: String) throws -> Bool? {
        guard let value = value(key) else { return nil }
        guard let flag = value.bool else { throw BadInput("\(key) must be true or false") }
        return flag
    }

    func number(_ key: String, _ allowed: ClosedRange<Int>) throws -> Int? {
        guard let value = value(key) else { return nil }
        guard let number = value.int else { throw BadInput("\(key) must be a whole number") }
        guard allowed.contains(number) else { throw BadInput("\(key) must be from \(allowed.lowerBound) to \(allowed.upperBound)") }
        return number
    }

    func decimal(_ key: String) throws -> Double? {
        guard let value = value(key) else { return nil }
        guard let number = value.double else { throw BadInput("\(key) must be a number") }
        return number
    }

    func pick(_ key: String, from options: [String]) throws -> String? {
        guard let text = try text(key) else { return nil }
        guard options.contains(text) else { throw BadInput("\(key) must be one of: \(options.joined(separator: ", "))") }
        return text
    }

    func texts(_ key: String) throws -> [String]? {
        guard let value = value(key) else { return nil }
        guard let items = value.array else { throw BadInput("\(key) must be a list of text") }
        return try items.map { item in
            guard let text = item.string else { throw BadInput("\(key) must be a list of text") }
            return text
        }
    }

    func numbers(_ key: String, _ allowed: ClosedRange<Int>, except excluded: Int? = nil) throws -> [Int]? {
        guard let value = value(key) else { return nil }
        guard let items = value.array else { throw BadInput("\(key) must be a list of whole numbers") }
        return try items.map { item in
            guard let number = item.int, allowed.contains(number), number != excluded else {
                throw BadInput("\(key) must hold whole numbers from \(allowed.lowerBound) to \(allowed.upperBound)\(excluded.map { " other than \($0)" } ?? "")")
            }
            return number
        }
    }

    /// A nested object, with only the given keys.
    func object(_ key: String, keys: Set<String>) throws -> Input? {
        guard let value = value(key) else { return nil }
        guard let fields = value.object else { throw BadInput("\(key) must be an object") }
        if let unknown = fields.keys.sorted().first(where: { !keys.contains($0) }) {
            throw BadInput("\(key).\(unknown) is not known; use \(keys.sorted().joined(separator: ", "))")
        }
        return Input(fields)
    }
}

// MARK: Reminder fields

extension Input {
    func due(_ key: String) throws -> DateComponents? {
        guard let text = try text(key) else { return nil }
        guard let date = Due.parse(text) else { throw BadInput("\(key) must look like 2026-10-21 (all day) or 2026-10-21T09:00 (local time)") }
        return date
    }

    /// Without a leading #.
    func tags(_ key: String) throws -> [String]? {
        try texts(key).map { $0.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }.filter { !$0.isEmpty } }
    }

    func repeatRule(_ key: String) throws -> RepeatRule? {
        guard let rule = try object(key, keys: ["frequency", "interval", "days_of_week", "days_of_month", "months", "until", "count"]) else { return nil }
        guard let frequency = try rule.pick("frequency", from: RepeatRule.frequencies) else {
            throw BadInput("\(key).frequency is required: \(RepeatRule.frequencies.joined(separator: ", "))")
        }
        let days = try (rule.texts("days_of_week") ?? []).map { text in
            guard let day = RepeatRule.weekday(text) else { throw BadInput("\(key).days_of_week: \(text) is not like mon, 1mon (first Monday) or -1fri (last Friday)") }
            return day
        }
        var result = RepeatRule(
            frequency: RepeatRule.frequencies.firstIndex(of: frequency)!, interval: try rule.number("interval", 1...999) ?? 1,
            daysOfWeek: days, daysOfMonth: try rule.numbers("days_of_month", -31...31, except: 0) ?? [],
            monthsOfYear: try rule.numbers("months", 1...12) ?? [])
        if let until = try rule.text("until") {
            guard let day = Due.parse(until), day.hour == nil, let start = Due.instant(day) else { throw BadInput("\(key).until must look like 2026-12-31") }
            result.endDate = start.addingTimeInterval(86_399)  // through the end of that day
        }
        if let count = try rule.number("count", 1...999) {
            if result.endDate != nil { throw BadInput("\(key) takes until or count, not both") }
            result.count = count
        }
        return result
    }

    /// [{before: 15, unit: minutes}, …]
    func earlyAlerts(_ key: String) throws -> [EarlyAlert]? {
        guard let value = fields[key], value != .null else { return nil }
        guard let items = value.array else { throw BadInput("\(key) must be a list like [{\"before\": 15, \"unit\": \"minutes\"}]") }
        return try items.map { item in
            guard let fields = item.object else { throw BadInput("\(key) must be a list like [{\"before\": 15, \"unit\": \"minutes\"}]") }
            let alert = Input(fields)
            guard let before = try alert.number("before", 1...10_000) else { throw BadInput("\(key).before is required") }
            let unit = try alert.pick("unit", from: EarlyAlert.units) ?? "minutes"
            return EarlyAlert(unit: EarlyAlert.units.firstIndex(of: unit)!, count: before)
        }
    }

    /// A place, or getting in or out of the car.
    func trigger(_ key: String) throws -> Trigger? {
        if let word = fields[key]?.string {
            switch word {
            case "getting-in-car": return .car(gettingIn: true)
            case "getting-out-of-car": return .car(gettingIn: false)
            default: throw BadInput("\(key) must be getting-in-car, getting-out-of-car or {title, latitude, longitude, radius, address, when}")
            }
        }
        guard let place = try object(key, keys: ["title", "latitude", "longitude", "radius", "address", "when"]) else { return nil }
        guard let latitude = try place.decimal("latitude"), let longitude = try place.decimal("longitude"),
            (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { throw BadInput("\(key) needs latitude and longitude") }
        let when = try place.pick("when", from: ["arriving", "leaving"]) ?? "arriving"
        return .place(
            title: try place.text("title") ?? "", latitude: latitude, longitude: longitude, radius: try place.decimal("radius") ?? 100,
            address: try place.text("address"), leaving: when == "leaving")
    }

    /// {phones: [...], emails: [...]}
    func contact(_ key: String) throws -> [String: [String]]? {
        guard let contact = try object(key, keys: ["phones", "emails"]) else { return nil }
        let phones = try contact.texts("phones") ?? [], emails = try contact.texts("emails") ?? []
        if phones.isEmpty && emails.isEmpty { throw BadInput("\(key) needs phones or emails") }
        return ["phones": phones, "emails": emails]
    }

    /// {after: id} or {before: id}
    func position(_ key: String) throws -> [String: String]? {
        guard let position = try object(key, keys: ["after", "before"]) else { return nil }
        let after = try position.text("after"), before = try position.text("before")
        guard (after == nil) != (before == nil) else { throw BadInput("\(key) takes after or before") }
        return after.map { ["after": $0] } ?? ["before": before!]
    }

    func url(_ key: String) throws -> String? {
        guard let text = try text(key) else { return nil }
        guard let url = URL(string: text), url.scheme != nil else { throw BadInput("\(key) must be a full URL like https://example.com") }
        return text
    }
}
