import Foundation
import Wire

/// How tools show reminders, lists and the rest. Fields at their default are left out, so
/// results stay short.
enum Output {
    // ISO8601DateFormatter is thread-safe; Swift cannot know that.
    nonisolated(unsafe) static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    static let sortNames: [(tool: String, stored: String)] = [
        ("default", "default"), ("manual", "manual"), ("due-date", "displayDate_asc"), ("due-date-latest-first", "displayDate_desc"),
        ("created-newest-first", "creationDate_desc"), ("created-oldest-first", "creationDate_asc"), ("priority", "priority_desc"),
        ("priority-lowest-first", "priority_asc"), ("title", "title_asc"), ("title-reverse", "title_desc"),
    ]

    static func repeatRule(_ rule: RepeatRule) -> JSON {
        var o: [String: JSON] = [
            "frequency": .string(RepeatRule.frequencies.indices.contains(rule.frequency) ? RepeatRule.frequencies[rule.frequency] : "\(rule.frequency)"),
            "interval": .int(rule.interval),
        ]
        if !rule.daysOfWeek.isEmpty { o["days_of_week"] = .array(rule.daysOfWeek.map { .string(RepeatRule.weekdayName($0)) }) }
        if !rule.daysOfMonth.isEmpty { o["days_of_month"] = .array(rule.daysOfMonth.map { .int($0) }) }
        if !rule.monthsOfYear.isEmpty { o["months"] = .array(rule.monthsOfYear.map { .int($0) }) }
        if let end = rule.endDate { o["until"] = .string(Due.format(Calendar.current.dateComponents([.year, .month, .day], from: end))) }
        if let count = rule.count { o["count"] = .int(count) }
        return .object(o)
    }

    static func trigger(_ trigger: Trigger) -> JSON {
        switch trigger {
        case .car(let gettingIn): return .string(gettingIn ? "getting-in-car" : "getting-out-of-car")
        case .place(let title, let latitude, let longitude, let radius, let address, let leaving):
            var o: [String: JSON] = [
                "title": .string(title), "latitude": .double(latitude), "longitude": .double(longitude), "radius": .double(radius),
                "when": .string(leaving ? "leaving" : "arriving"),
            ]
            if let address { o["address"] = .string(address) }
            return .object(o)
        }
    }

    static func reminder(_ r: ReminderInfo, in list: ListInfo, detail: Bool = false) -> JSON {
        var o: [String: JSON] = ["id": .string(r.id), "version": .string(r.version), "list": .string(list.name), "title": .string(r.title)]
        if let due = r.due { o["due"] = .string(Due.format(due)) }
        if let start = r.start { o["start"] = .string(Due.format(start)) }
        if let rule = r.repeatRule { o["repeat"] = repeatRule(rule) }
        if r.priority != 0 { o["priority"] = .string(Priority.name(r.priority)) }
        if r.flagged { o["flagged"] = true }
        if r.urgent { o["urgent"] = true }
        if !r.tags.isEmpty { o["tags"] = .array(r.tags.map { .string($0) }) }
        if let notes = r.notes { o["notes"] = .string(notes) }
        if let parent = r.parentID { o["parent_id"] = .string(parent) }
        if let section = r.sectionID, let name = list.sections.first(where: { $0.id == section })?.name { o["section"] = .string(name) }
        if let trigger = r.trigger { o["location"] = self.trigger(trigger) }
        if !r.contactPhones.isEmpty || !r.contactEmails.isEmpty {
            o["when_messaging"] = ["phones": .array(r.contactPhones.map { .string($0) }), "emails": .array(r.contactEmails.map { .string($0) })]
        }
        if let url = r.urls.first { o["url"] = .string(url) }
        if !r.images.isEmpty { o["images"] = .int(r.images.count) }
        if let assignee = r.assigneeID {
            o["assigned_to"] = .string(list.sharees.first { $0.id.caseInsensitiveCompare(assignee) == .orderedSame }?.name ?? assignee)
        }
        if r.completed {
            o["completed"] = true
            if let at = r.completionDate { o["completed_at"] = .string(stamp.string(from: at)) }
        }
        if detail {
            o["list_id"] = .string(list.id)
            if list.shared { o["shared_list"] = true }
            if !r.alarms.isEmpty { o["alarms"] = .array(r.alarms.map { .string($0) }) }
            if let alerts = r.earlyAlerts, !alerts.isEmpty {
                o["early_alerts"] = .array(alerts.map { ["before": .int($0.count), "unit": .string(EarlyAlert.units[$0.unit])] })
            }
            if !r.images.isEmpty {
                o["images"] = .array(r.images.map { image in
                    ["id": .string(image.id), "type": .string(image.type), "width": .int(image.width), "height": .int(image.height), "bytes": .int(image.size)]
                })
            }
            if r.urls.count > 1 { o["urls"] = .array(r.urls.map { .string($0) }) }
        }
        return .object(o)
    }

    static func list(_ list: ListInfo, groups: [GroupInfo], counts: (open: Int, total: Int)? = nil, isDefault: Bool = false) -> JSON {
        var o: [String: JSON] = ["id": .string(list.id), "name": .string(list.name)]
        if let counts {
            o["open"] = .int(counts.open)
            o["total"] = .int(counts.total)
        }
        if isDefault { o["default"] = true }
        if list.pinned { o["pinned"] = true }
        if list.groceries { o["type"] = "groceries" }
        if let group = list.groupID, let name = groups.first(where: { $0.id == group })?.name { o["group"] = .string(name) }
        if let color = ListAppearance.describe(name: list.colorName, hex: list.colorHex) { o["color"] = .string(color) }
        if let icon = list.icon { o["icon"] = .string(icon) }
        if let sorting = list.sorting, sorting != "default" { o["sort"] = .string(sortNames.first { $0.stored == sorting }?.tool ?? sorting) }
        if !list.sections.isEmpty { o["sections"] = .array(list.sections.map { .string($0.name) }) }
        if list.shared {
            o["shared"] = true
            o["people"] = .array(list.sharees.map { person in
                var row: [String: JSON] = ["name": .string(person.name)]
                if person.me { row["me"] = true }
                if person.status != 1 { row["invited"] = true }
                return .object(row)
            })
        }
        return .object(o)
    }

    static func smartList(_ smartList: SmartListInfo, lists: [ListInfo]) -> JSON {
        let (match, filters) = SmartFilter.decode(smartList.filter) { id in lists.first { $0.id == id }?.name ?? id }
        var o: [String: JSON] = ["id": .string(smartList.id), "name": .string(smartList.name), "match": .string(match), "filters": filters]
        if let color = ListAppearance.describe(name: smartList.colorName, hex: smartList.colorHex) { o["color"] = .string(color) }
        if let icon = smartList.icon { o["icon"] = .string(icon) }
        return .object(o)
    }
}

extension ToolAnswer {
    static func json(_ lead: String, _ value: JSON) -> ToolAnswer { ToolAnswer(lead.isEmpty ? value.text : "\(lead) \(value.text)") }
}
