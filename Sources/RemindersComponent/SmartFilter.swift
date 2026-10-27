import Foundation
import Wire

/// Translates smart list filters between the tools' format and the JSON Reminders stores in a
/// smart list's filterData. The stored format was read from smart lists made in Reminders on
/// macOS 27.0.1, and its other values from ReminderKitInternal's Codable keys:
///
///     {"operation": "and" | "or",
///      "hashtags": {"hashtags": {"include": [...], "exclude": [...], "operation": "and" | "or"}} | {"any": ""} | {"untagged": ""},
///      "date": {"today": ""} | {"noDate": ""} | {"beforeDate" | "onDate" | "afterDate": "20-10-2026"}
///              | {"dateRange": ["20-10-2026", "31-10-2026"]}
///              | {"relativeRange": {"direction": "inNext" | "inPast", "magnitude": "10", "units": "day", "includePastDue": true}},
///      "time": {"morning" | "afternoon" | "evening" | "night" | "noTime": ""},
///      "priorities": ["low", "medium", "high"], "flagged": true,
///      "lists": {"include": [list ids], "exclude": [list ids]},
///      "location": {"location": {"latitude", "longitude", "radius", "title", "proximity": "enter" | "leave"}}
///                  | {"vehicle": "connected" | "disconnected"} | {"noLocation": ""}}
enum SmartFilter {
    static let times = ["morning", "afternoon", "evening", "night"]
    static let units = ["hour", "day", "week", "month", "year"]

    // MARK: Tools → Reminders

    /// `resolveList` turns a list name or id into an id.
    static func encode(match: String, filters: [String: JSON], resolveList: (String) throws -> String) throws -> String {
        var out: [String: Any] = ["operation": match == "any" ? "or" : "and"]
        for (key, value) in filters {
            switch key {
            case "tags": out["hashtags"] = try tags(value)
            case "date": out["date"] = try date(value)
            case "time":
                guard let time = value.string, times.contains(time) || time == "none" else {
                    throw BadInput("filters.time must be one of \(times.joined(separator: ", ")) or none")
                }
                out["time"] = [time == "none" ? "noTime" : time: ""]
            case "priorities":
                guard case .array(let items) = value, !items.isEmpty,
                    items.allSatisfy({ ["low", "medium", "high"].contains($0.string ?? "") })
                else { throw BadInput("filters.priorities must be a list of low, medium, high") }
                out["priorities"] = items.compactMap(\.string)
            case "flagged":
                guard case .bool(let flagged) = value else { throw BadInput("filters.flagged must be true or false") }
                out["flagged"] = flagged
            case "lists":
                guard case .object(let o) = value else { throw BadInput("filters.lists must be {include: [...], exclude: [...]}") }
                let include = try strings(o["include"], "filters.lists.include").map(resolveList)
                let exclude = try strings(o["exclude"], "filters.lists.exclude").map(resolveList)
                if include.isEmpty && exclude.isEmpty { throw BadInput("filters.lists needs include or exclude") }
                out["lists"] = ["include": include, "exclude": exclude]
            case "location": out["location"] = try location(value)
            default:
                throw BadInput("filters.\(key) is not a filter; use tags, date, time, priorities, flagged, lists or location")
            }
        }
        guard out.count > 1 else { throw BadInput("filters needs at least one filter") }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func strings(_ value: JSON?, _ name: String) throws -> [String] {
        switch value {
        case nil, .null?: return []
        case .array(let items)?:
            return try items.map { item in
                guard let s = item.string else { throw BadInput("\(name) must be a list of strings") }
                return s
            }
        default: throw BadInput("\(name) must be a list of strings")
        }
    }

    private static func tags(_ value: JSON) throws -> [String: Any] {
        if let word = value.string {
            guard word == "any" || word == "untagged" else { throw BadInput("filters.tags must be any, untagged or {include, exclude, match}") }
            return [word: ""]
        }
        guard case .object(let o) = value else { throw BadInput("filters.tags must be any, untagged or {include, exclude, match}") }
        let strip = { (s: String) in s.hasPrefix("#") ? String(s.dropFirst()) : s }
        let include = try strings(o["include"], "filters.tags.include").map(strip)
        let exclude = try strings(o["exclude"], "filters.tags.exclude").map(strip)
        if include.isEmpty && exclude.isEmpty { throw BadInput("filters.tags needs include or exclude") }
        let match = o["match"]?.string ?? "all"
        guard ["all", "any"].contains(match) else { throw BadInput("filters.tags.match must be all or any") }
        return ["hashtags": ["include": include, "exclude": exclude, "operation": match == "any" ? "or" : "and"]]
    }

    private static func date(_ value: JSON) throws -> [String: Any] {
        if let word = value.string {
            switch word {
            case "today": return ["today": ""]
            case "none": return ["noDate": ""]
            default: throw BadInput(dateHelp)
            }
        }
        guard case .object(let o) = value else { throw BadInput(dateHelp) }
        if let from = o["from"]?.string, let until = o["until"]?.string {
            return ["dateRange": [try storedDay(from, "filters.date.from"), try storedDay(until, "filters.date.until")]]
        }
        for (key, stored) in [("before", "beforeDate"), ("on", "onDate"), ("after", "afterDate")] {
            guard let text = o[key]?.string else { continue }
            return [stored: try storedDay(text, "filters.date.\(key)")]
        }
        for (key, direction) in [("next", "inNext"), ("past", "inPast")] {
            guard let amount = o[key] else { continue }
            let magnitude: Int
            switch amount {
            case .int(let i): magnitude = i
            case .double(let d) where d == d.rounded(): magnitude = Int(d)
            default: throw BadInput("filters.date.\(key) must be a number")
            }
            let unit = o["unit"]?.string ?? "day"
            guard units.contains(unit), magnitude > 0 else { throw BadInput("filters.date needs a positive number and unit \(units.joined(separator: ", "))") }
            var includePastDue = false
            if case .bool(let b)? = o["include_past_due"] { includePastDue = b }
            return ["relativeRange": ["direction": direction, "magnitude": "\(magnitude)", "units": unit, "includePastDue": includePastDue]]
        }
        throw BadInput(dateHelp)
    }

    static let dateHelp = "filters.date must be today, none, {before|on|after: date}, {from: date, until: date} or {next|past: n, unit}"

    /// 2026-10-21 → 21-10-2026, the stored form.
    private static func storedDay(_ text: String, _ name: String) throws -> String {
        guard let day = Due.parse(text), day.hour == nil, let year = day.year, let month = day.month, let dayOfMonth = day.day else {
            throw BadInput("\(name) must look like 2026-10-21")
        }
        return String(format: "%02d-%02d-%04d", dayOfMonth, month, year)
    }

    /// 21-10-2026 → 2026-10-21.
    private static func toolDay(_ stored: String) -> String? {
        let parts = stored.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return String(format: "%04d-%02d-%02d", parts[2], parts[1], parts[0])
    }

    private static func location(_ value: JSON) throws -> [String: Any] {
        switch value.string {
        case "none": return ["noLocation": ""]
        case "getting-in-car": return ["vehicle": "connected"]
        case "getting-out-of-car": return ["vehicle": "disconnected"]
        default: break
        }
        guard case .object(let o) = value, let latitude = number(o["latitude"]), let longitude = number(o["longitude"]) else {
            throw BadInput("filters.location must be none, getting-in-car, getting-out-of-car or {latitude, longitude, radius, title, when: arriving|leaving}")
        }
        let when = o["when"]?.string ?? "arriving"
        guard ["arriving", "leaving"].contains(when) else { throw BadInput("filters.location.when must be arriving or leaving") }
        return ["location": [
            "latitude": latitude, "longitude": longitude, "radius": number(o["radius"]) ?? 100,
            "title": o["title"]?.string ?? "", "proximity": when == "leaving" ? "leave" : "enter",
        ]]
    }

    private static func number(_ value: JSON?) -> Double? {
        switch value {
        case .int(let i)?: Double(i)
        case .double(let d)?: d
        default: nil
        }
    }

    // MARK: Reminders → tools

    /// The match mode and filters in the tools' format; parts this translation does not know are
    /// passed through under "other", as stored.
    static func decode(_ stored: String?, listName: (String) -> String) -> (match: String, filters: JSON) {
        guard let data = stored?.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("all", [:])
        }
        var filters: [String: JSON] = [:]
        var other: [String: JSON] = [:]
        for (key, value) in object where key != "operation" {
            let known: JSON?
            switch key {
            case "hashtags": known = decodeTags(value)
            case "date": known = decodeDate(value)
            case "time": known = (value as? [String: Any])?.keys.first.map { .string($0 == "noTime" ? "none" : $0) }
            case "priorities": known = (value as? [String]).map { .array($0.map { .string($0) }) }
            case "flagged": known = (value as? Bool).map { .bool($0) }
            case "lists":
                known = (value as? [String: Any]).map { o in
                    .object([
                        "include": .array((o["include"] as? [String] ?? []).map { .string(listName($0)) }),
                        "exclude": .array((o["exclude"] as? [String] ?? []).map { .string(listName($0)) }),
                    ])
                }
            case "location": known = decodeLocation(value)
            default: known = nil
            }
            let name = ["hashtags": "tags"][key] ?? key
            if let known { filters[name] = known } else { other[key] = JSON(any: value) }
        }
        if !other.isEmpty { filters["other"] = .object(other) }
        return ((object["operation"] as? String) == "or" ? "any" : "all", .object(filters))
    }

    private static func decodeTags(_ value: Any) -> JSON? {
        guard let o = value as? [String: Any] else { return nil }
        if o["any"] != nil { return "any" }
        if o["untagged"] != nil { return "untagged" }
        guard let tags = o["hashtags"] as? [String: Any] else { return nil }
        return .object([
            "include": .array((tags["include"] as? [String] ?? []).map { .string($0) }),
            "exclude": .array((tags["exclude"] as? [String] ?? []).map { .string($0) }),
            "match": .string((tags["operation"] as? String) == "or" ? "any" : "all"),
        ])
    }

    private static func decodeDate(_ value: Any) -> JSON? {
        guard let o = value as? [String: Any] else { return nil }
        if o["today"] != nil { return "today" }
        if o["noDate"] != nil { return "none" }
        if let range = o["dateRange"] as? [String], range.count == 2, let from = toolDay(range[0]), let until = toolDay(range[1]) {
            return ["from": .string(from), "until": .string(until)]
        }
        for (stored, key) in [("beforeDate", "before"), ("onDate", "on"), ("afterDate", "after")] {
            guard let text = o[stored] as? String else { continue }
            return toolDay(text).map { .object([key: .string($0)]) }
        }
        if let range = o["relativeRange"] as? [String: Any], let magnitude = Int("\(range["magnitude"] ?? "")") {
            return .object([
                (range["direction"] as? String) == "inPast" ? "past" : "next": .int(magnitude),
                "unit": .string(range["units"] as? String ?? "day"),
                "include_past_due": .bool(range["includePastDue"] as? Bool ?? false),
            ])
        }
        return nil
    }

    private static func decodeLocation(_ value: Any) -> JSON? {
        guard let o = value as? [String: Any] else { return nil }
        if o["noLocation"] != nil { return "none" }
        if let vehicle = o["vehicle"] as? String { return vehicle == "connected" ? "getting-in-car" : vehicle == "disconnected" ? "getting-out-of-car" : nil }
        guard let place = o["location"] as? [String: Any] else { return nil }
        return .object([
            "latitude": JSON(any: place["latitude"] ?? 0), "longitude": JSON(any: place["longitude"] ?? 0),
            "radius": JSON(any: place["radius"] ?? 100), "title": .string(place["title"] as? String ?? ""),
            "when": .string((place["proximity"] as? String) == "leave" ? "leaving" : "arriving"),
        ])
    }

    /// The stored filter with only its match mode changed.
    static func settingMatch(_ stored: String?, to match: String) -> String? {
        guard let data = stored?.data(using: .utf8), var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        object["operation"] = match == "any" ? "or" : "and"
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
    }
}
