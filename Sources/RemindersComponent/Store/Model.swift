import CryptoKit
import Foundation

/// A problem the model can act on; the text goes back as a tool error.
struct StoreError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct SectionInfo: Sendable {
    let id: String
    let name: String
}

struct GroupInfo: Sendable {
    let id: String
    let name: String
}

/// A person on a shared list.
struct Sharee: Sendable {
    let id: String
    let name: String
    /// 1 when they joined; other values are pending invitations.
    let status: Int
    let me: Bool
}

struct TemplateInfo: Sendable {
    let id: String
    let name: String
}

struct ListInfo: Sendable {
    let id: String
    let name: String
    let shared: Bool
    let groupID: String?
    /// A stored Reminders color name (see ListAppearance), or "custom" with a hex value.
    let colorName: String?
    let colorHex: String?
    /// An emoji, or an emblem name such as nature2; nil for the default icon.
    let icon: String?
    /// In display order.
    let sections: [SectionInfo]
    let pinned: Bool
    /// Items are sorted into grocery sections automatically.
    let groceries: Bool
    /// A REMSortingStyle value, such as manual or priority_desc.
    let sorting: String?
    let sharees: [Sharee]

    init(_ raw: [String: Any]) {
        id = raw["id"] as? String ?? ""
        name = raw["name"] as? String ?? ""
        shared = raw["shared"] as? Bool ?? false
        groupID = raw["groupId"] as? String
        let color = raw["color"] as? [String: String]
        colorName = color?["name"]
        colorHex = color?["hex"]
        icon = (raw["icon"] as? String).map(ListAppearance.readIcon)
        sections = (raw["sections"] as? [[String: String]] ?? []).map { SectionInfo(id: $0["id"] ?? "", name: $0["name"] ?? "") }
        pinned = raw["pinned"] as? Bool ?? false
        groceries = raw["groceries"] as? Bool ?? false
        sorting = raw["sorting"] as? String
        sharees = (raw["sharees"] as? [[String: Any]] ?? []).map {
            Sharee(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "", status: $0["status"] as? Int ?? 0, me: $0["me"] as? Bool ?? false)
        }
    }
}

struct SmartListInfo: Sendable {
    let id: String
    let name: String
    /// The JSON Reminders stores; SmartFilter translates it.
    let filter: String?
    let colorName: String?
    let colorHex: String?
    let icon: String?

    init(_ raw: [String: Any]) {
        id = raw["id"] as? String ?? ""
        name = raw["name"] as? String ?? ""
        filter = raw["filter"] as? String
        let color = raw["color"] as? [String: String]
        colorName = color?["name"]
        colorHex = color?["hex"]
        icon = (raw["icon"] as? String).map(ListAppearance.readIcon)
    }
}

enum ListAppearance {
    /// Reminders' twelve list colors: the name tools use, the name Reminders stores, and the hex
    /// value stored with it (lists made in Reminders on macOS 27.0.1, or its asset catalog).
    /// ReminderKit normalizes the hex of the first seven itself.
    static let palette: [(tool: String, stored: String, hex: String)] = [
        ("red", "red", "#FF383C"), ("orange", "orange", "#FF8D28"), ("yellow", "yellow", "#FFCC00"),
        ("green", "green", "#83D754"), ("blue", "blue", "#0088FF"), ("purple", "purple", "#CB30E0"),
        ("brown", "brown", "#AC7F5E"), ("light-blue", "lightBlue", "#5AC8FA"), ("indigo", "indigo", "#5856D6"),
        ("pink", "pink", "#EA426A"), ("gray", "gray", "#5B626A"), ("rose", "rose", "#D9A69F"),
    ]
    static let colorNames = palette.map(\.tool)

    /// "red", "light-blue" or "#FF8800" → the bridge's color dictionary; nil when it is none of
    /// these. Unknown names never reach ReminderKit, which traps on them.
    static func color(_ text: String) -> [String: String]? {
        let value = text.lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        if let entry = palette.first(where: { $0.tool == value }) { return ["name": entry.stored, "hex": entry.hex] }
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return ["name": "custom", "hex": "#" + hex.uppercased()]
    }

    /// How tools show a stored color.
    static func describe(name: String?, hex: String?) -> String? {
        guard let name else { return nil }
        if let entry = palette.first(where: { $0.stored == name }) { return entry.tool }
        return name == "custom" ? hex : name
    }

    /// Badges are stored as an emblem name or as JSON like {"Emoji" : "🧪"}.
    static func readIcon(_ raw: String) -> String {
        guard raw.hasPrefix("{"), let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let emoji = object["Emoji"] as? String
        else { return raw }
        return emoji
    }
}

/// A recurrence rule as the tools read and write it.
struct RepeatRule: Sendable, Equatable {
    static let frequencies = ["daily", "weekly", "monthly", "yearly", "hourly"]
    static let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    var frequency: Int
    var interval: Int
    /// Weekday 1 (Sunday) … 7 and a week number (0 every week, 1 first, -1 last).
    var daysOfWeek: [[Int]]
    var daysOfMonth: [Int]
    var monthsOfYear: [Int]
    var endDate: Date?
    var count: Int?
    var ical: String?

    init(frequency: Int, interval: Int, daysOfWeek: [[Int]] = [], daysOfMonth: [Int] = [], monthsOfYear: [Int] = [], endDate: Date? = nil, count: Int? = nil) {
        self.frequency = frequency
        self.interval = interval
        self.daysOfWeek = daysOfWeek
        self.daysOfMonth = daysOfMonth
        self.monthsOfYear = monthsOfYear
        self.endDate = endDate
        self.count = count
    }

    init?(_ raw: [String: Any]?) {
        guard let raw, let frequency = raw["frequency"] as? Int else { return nil }
        self.frequency = frequency
        interval = raw["interval"] as? Int ?? 1
        daysOfWeek = (raw["daysOfWeek"] as? [[Int]]) ?? []
        daysOfMonth = raw["daysOfMonth"] as? [Int] ?? []
        monthsOfYear = raw["monthsOfYear"] as? [Int] ?? []
        endDate = raw["endDate"] as? Date
        count = raw["count"] as? Int
        ical = raw["ical"] as? String
    }

    /// The bridge's repeat dictionary.
    var bridgeValue: [String: Any] {
        var value: [String: Any] = ["frequency": frequency, "interval": interval]
        if !daysOfWeek.isEmpty { value["daysOfWeek"] = daysOfWeek }
        if !daysOfMonth.isEmpty { value["daysOfMonth"] = daysOfMonth }
        if !monthsOfYear.isEmpty { value["monthsOfYear"] = monthsOfYear }
        if let endDate { value["endDate"] = endDate }
        if let count { value["count"] = count }
        return value
    }

    /// "mon", "1mon" (first Monday), "-1fri" (last Friday).
    static func weekday(_ text: String) -> [Int]? {
        let lower = text.lowercased()
        guard let name = weekdays.first(where: { lower.hasSuffix($0) }) else { return nil }
        let prefix = lower.dropLast(name.count)
        guard let week = prefix.isEmpty ? 0 : Int(prefix), (-5...5).contains(week) else { return nil }
        return [weekdays.firstIndex(of: name)! + 1, week]
    }

    static func weekdayName(_ day: [Int]) -> String {
        let name = (1...7).contains(day.first ?? 0) ? weekdays[day[0] - 1] : "?"
        return (day.count > 1 && day[1] != 0 ? "\(day[1])" : "") + name
    }
}

struct ReminderInfo: Sendable {
    let id: String
    let listID: String
    let title: String
    let notes: String?
    let completed: Bool
    let completionDate: Date?
    let flagged: Bool
    /// Reminders' scale: 0 none, 1 high, 5 medium, 9 low.
    let priority: Int
    let tags: [String]
    let parentID: String?
    let sectionID: String?
    let due: DateComponents?
    let urgent: Bool
    let recurring: Bool
    let repeatRule: RepeatRule?
    let alarms: [String]
    let start: DateComponents?
    let trigger: Trigger?
    /// "When messaging" this person.
    let contactPhones: [String]
    let contactEmails: [String]
    let urls: [String]
    let images: [ImageInfo]
    let assigneeID: String?
    /// Only filled by RemindersStore.detail: the list fetch does not load them.
    var earlyAlerts: [EarlyAlert]?

    /// A hash of everything the tools show, so a write fails when the user changed the reminder
    /// on any device since it was read. Not the modification date: adding, moving or reordering a
    /// subtask saves its parent too, and that should not turn the parent's next edit into a conflict.
    var version: String {
        let fields: [String] = [
            title, notes ?? "", "\(completed)", completionDate.map { "\($0.timeIntervalSinceReferenceDate)" } ?? "",
            "\(flagged)", "\(priority)", tags.sorted().joined(separator: "\u{1F}"), parentID ?? "",
            due.map(Due.format) ?? "", "\(urgent)", "\(recurring)", listID, alarms.joined(separator: "\u{1F}"),
            sectionID ?? "", repeatRule?.ical ?? "", start.map(Due.format) ?? "", trigger.map { "\($0)" } ?? "",
            contactPhones.joined(separator: ","), contactEmails.joined(separator: ","), urls.joined(separator: " "),
            images.map(\.id).joined(separator: ","), assigneeID ?? "",
        ]
        let digest = SHA256.hash(data: Data(fields.joined(separator: "\u{1E}").utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    init(_ raw: [String: Any]) {
        id = raw["id"] as? String ?? ""
        listID = raw["listId"] as? String ?? ""
        title = raw["title"] as? String ?? ""
        notes = raw["notes"] as? String
        completed = raw["completed"] as? Bool ?? false
        completionDate = raw["completionDate"] as? Date
        flagged = (raw["flagged"] as? Int ?? 0) != 0
        priority = raw["priority"] as? Int ?? 0
        tags = raw["hashtags"] as? [String] ?? []
        parentID = raw["parentId"] as? String
        sectionID = raw["sectionId"] as? String
        repeatRule = RepeatRule(raw["repeat"] as? [String: Any])
        due = (raw["due"] as? NSDateComponents).map { $0 as DateComponents }
        urgent = raw["urgent"] as? Bool ?? false
        recurring = raw["recurring"] as? Bool ?? false
        alarms = (raw["alarms"] as? [Any] ?? []).map { alarm in
            if let components = alarm as? NSDateComponents { return Due.format(components as DateComponents) }
            return "\(alarm)"
        }
        // ReminderKit gives a date-only start back with a midnight time; show it as written.
        start = (raw["start"] as? NSDateComponents).map { stored in
            var components = stored as DateComponents
            if components.hour == 0, components.minute ?? 0 == 0, components.second ?? 0 == 0, components.timeZone == nil {
                components.hour = nil
                components.minute = nil
                components.second = nil
            }
            return components
        }
        trigger = Trigger(raw["location"] as? [String: Any])
        let contact = raw["contact"] as? [String: Any]
        contactPhones = contact?["phones"] as? [String] ?? []
        contactEmails = contact?["emails"] as? [String] ?? []
        urls = raw["urls"] as? [String] ?? []
        images = (raw["images"] as? [[String: Any]] ?? []).map(ImageInfo.init)
        assigneeID = raw["assigneeId"] as? String
        earlyAlerts = (raw["earlyAlerts"] as? [[Int]]).map { $0.compactMap(EarlyAlert.init(stored:)) }
    }
}

/// A place or car alarm. Reminders keeps at most one per reminder.
enum Trigger: Sendable, Equatable, CustomStringConvertible {
    case place(title: String, latitude: Double, longitude: Double, radius: Double, address: String?, leaving: Bool)
    case car(gettingIn: Bool)

    init?(_ raw: [String: Any]?) {
        guard let raw else { return nil }
        if let event = raw["vehicle"] as? Int {
            guard event == 1 || event == 2 else { return nil }
            self = .car(gettingIn: event == 1)
            return
        }
        self = .place(
            title: raw["title"] as? String ?? "", latitude: raw["latitude"] as? Double ?? 0, longitude: raw["longitude"] as? Double ?? 0,
            radius: raw["radius"] as? Double ?? 0, address: raw["address"] as? String, leaving: (raw["proximity"] as? Int) == 2)
    }

    /// The bridge's location dictionary: proximity 1 arriving, 2 leaving; vehicle 1 in, 2 out.
    var bridgeValue: [String: Any] {
        switch self {
        case .car(let gettingIn): return ["vehicle": gettingIn ? 1 : 2]
        case .place(let title, let latitude, let longitude, let radius, let address, let leaving):
            var value: [String: Any] = ["title": title, "latitude": latitude, "longitude": longitude, "radius": radius, "proximity": leaving ? 2 : 1]
            if let address { value["address"] = address }
            return value
        }
    }

    var description: String {
        switch self {
        case .car(let gettingIn): gettingIn ? "car-in" : "car-out"
        case .place(let title, let latitude, let longitude, let radius, _, let leaving): "\(title)|\(latitude)|\(longitude)|\(radius)|\(leaving)"
        }
    }
}

/// An early reminder: an alert `count` units before the due date.
struct EarlyAlert: Sendable, Equatable {
    static let units = ["minutes", "hours", "days", "weeks", "months"]
    let unit: Int
    let count: Int

    init(unit: Int, count: Int) {
        self.unit = unit
        self.count = count
    }

    /// Stored as [unit, -count]: ReminderKit counts backwards from the due date.
    init?(stored: [Int]) {
        guard stored.count == 2, EarlyAlert.units.indices.contains(stored[0]) else { return nil }
        unit = stored[0]
        count = -stored[1]
    }

    var stored: [Int] { [unit, -count] }
}

struct ImageInfo: Sendable {
    let id: String
    let type: String
    let width: Int
    let height: Int
    let size: Int
    let path: String?

    init(_ raw: [String: Any]) {
        id = raw["id"] as? String ?? ""
        type = raw["type"] as? String ?? ""
        width = raw["width"] as? Int ?? 0
        height = raw["height"] as? Int ?? 0
        size = raw["size"] as? Int ?? 0
        path = raw["path"] as? String
    }
}

enum Priority {
    static let names = ["none", "low", "medium", "high"]

    static func value(_ name: String) -> Int {
        switch name {
        case "high": 1
        case "medium": 5
        case "low": 9
        default: 0
        }
    }

    static func name(_ value: Int) -> String {
        switch value {
        case 1...4: "high"
        case 5: "medium"
        case 6...9: "low"
        default: "none"
        }
    }
}

/// Due dates as the tools read and write them: `2026-10-21` (all day) or `2026-10-21T09:00`
/// in the Mac's time zone. ISO 8601 times with an offset are converted to local time.
enum Due {
    static func parse(_ text: String) -> DateComponents? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(whereSeparator: { $0 == "T" || $0 == " " }).map(String.init)
        let date = parts.first?.split(separator: "-").compactMap { Int($0) } ?? []
        guard date.count == 3, (1...12).contains(date[1]), (1...31).contains(date[2]) else { return nil }
        if parts.count == 1 {
            return DateComponents(year: date[0], month: date[1], day: date[2])
        }
        let clock = parts[1]
        if clock.hasSuffix("Z") || clock.dropFirst(5).contains("+") || clock.dropFirst(5).contains("-") {
            let iso = ISO8601DateFormatter()
            guard let instant = iso.date(from: trimmed.replacingOccurrences(of: " ", with: "T")) else { return nil }
            return local(instant)
        }
        let time = clock.split(separator: ":").compactMap { Int($0) }
        guard time.count >= 2, (0...23).contains(time[0]), (0...59).contains(time[1]) else { return nil }
        var components = DateComponents(year: date[0], month: date[1], day: date[2], hour: time[0], minute: time[1])
        components.timeZone = .current
        return components
    }

    static func local(_ instant: Date) -> DateComponents {
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
        components.timeZone = .current
        return components
    }

    static func format(_ components: DateComponents) -> String {
        let day = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        guard let hour = components.hour else { return day }
        return day + String(format: "T%02d:%02d", hour, components.minute ?? 0)
    }

    /// The moment a due date starts, for filtering and sorting; all-day dates start at midnight.
    static func instant(_ components: DateComponents) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = components.timeZone ?? .current
        var copy = components
        copy.timeZone = nil
        copy.calendar = nil
        return calendar.date(from: copy)
    }

    static func now() -> String { format(local(Date())) }
}
