import Foundation
import Wire

/// Runs a tool after the permission check; problems with the reminders themselves become
/// failed answers the model can read and act on.
func withStore(_ store: RemindersStore, _ body: () async throws -> ToolAnswer) async throws -> ToolAnswer {
    do {
        try await store.ensureAccess()
        return try await body()
    } catch let error as StoreError {
        return ToolAnswer(error.description, failed: true)
    }
}

func readTools(_ store: RemindersStore) -> [Tool] {
    [
        Tool("list_lists", title: "List reminder lists",
             summary: """
                 Lists the Reminders lists (counts, group, color, icon, sections, sort order, type, and the \
                 people on shared lists), the groups, the smart lists with their filters, and the templates.
                 """,
             input: Schema.object([:]), effect: .reads) { _ in
            try await withStore(store) {
                let defaultID = try store.defaultListID()
                let groups = try store.groups()
                let lists = try store.lists()
                var result: [String: JSON] = [
                    "lists": .array(try lists.map { list in
                        let reminders = try store.reminders(in: list.id)
                        return Output.list(list, groups: groups, counts: (reminders.filter { !$0.completed }.count, reminders.count), isDefault: list.id == defaultID)
                    }),
                ]
                if !groups.isEmpty {
                    result["groups"] = .array(groups.map { group in
                        ["id": .string(group.id), "name": .string(group.name), "lists": .array(lists.filter { $0.groupID == group.id }.map { .string($0.name) })]
                    })
                }
                let smartLists = try store.smartLists()
                if !smartLists.isEmpty { result["smart_lists"] = .array(smartLists.map { Output.smartList($0, lists: lists) }) }
                let templates = try store.templates()
                if !templates.isEmpty { result["templates"] = .array(templates.map { ["id": .string($0.id), "name": .string($0.name)] }) }
                return ToolAnswer(JSON.object(result).text)
            }
        },

        Tool("find_reminders", title: "Find reminders",
             summary: """
                 Finds reminders across lists, open ones first by due date. Filters combine. due_before is \
                 exclusive: due_before tomorrow gives everything due today or overdue.
                 """,
             input: Schema.object([
                 "list": Schema.text("List name or id; default all lists"),
                 "section": Schema.text("Only this section"),
                 "query": Schema.text("Text in the title or notes"),
                 "include_completed": Schema.flag("Default false"),
                 "flagged": Schema.flag("Only flagged"),
                 "urgent": Schema.flag("Only urgent"),
                 "repeating": Schema.flag("Only repeating"),
                 "has_location": Schema.flag("Only reminders with a place or car alert"),
                 "assigned_to": Schema.text("Only reminders assigned to this person (name, or me)"),
                 "tag": Schema.text("Only this tag (without #)"),
                 "due_before": Schema.text("2026-10-21 or 2026-10-21T09:00, exclusive"),
                 "due_after": Schema.text("2026-10-21 or 2026-10-21T09:00, inclusive"),
                 "limit": Schema.whole("Default 100, at most 500"),
             ]), effect: .reads) { fields in
            let input = Input(fields)
            let listName = try input.text("list"), section = try input.text("section"), query = try input.text("query")
            let includeCompleted = try input.flag("include_completed") ?? false
            let flagged = try input.flag("flagged") ?? false, urgent = try input.flag("urgent") ?? false
            let repeating = try input.flag("repeating") ?? false, located = try input.flag("has_location") ?? false
            let assignedTo = try input.text("assigned_to")
            let tag = try input.text("tag").map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            let before = try input.due("due_before").flatMap(Due.instant), after = try input.due("due_after").flatMap(Due.instant)
            let limit = try input.number("limit", 1...500) ?? 100
            return try await withStore(store) {
                let lists = try listName.map { [try store.resolveList($0)] } ?? store.lists()
                var matches: [(ReminderInfo, ListInfo)] = []
                for list in lists {
                    let sectionIDs = section.map { name in Set(list.sections.filter { $0.name == name || $0.id == name }.map(\.id)) }
                    if let sectionIDs, sectionIDs.isEmpty { continue }
                    let assignee = assignedTo.map { wanted in
                        list.sharees.first { $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame || $0.id.caseInsensitiveCompare(wanted) == .orderedSame
                            || (wanted.lowercased() == "me" && $0.me) }?.id ?? "-"
                    }
                    for r in try store.reminders(in: list.id) {
                        if r.completed && !includeCompleted { continue }
                        if flagged && !r.flagged { continue }
                        if urgent && !r.urgent { continue }
                        if repeating && r.repeatRule == nil { continue }
                        if located && r.trigger == nil { continue }
                        if let assignee, r.assigneeID?.caseInsensitiveCompare(assignee) != .orderedSame { continue }
                        if let sectionIDs, !(r.sectionID.map(sectionIDs.contains) ?? false) { continue }
                        if let tag, !r.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { continue }
                        if let query, !(r.title.localizedCaseInsensitiveContains(query) || (r.notes?.localizedCaseInsensitiveContains(query) ?? false)) { continue }
                        let due = r.due.flatMap(Due.instant)
                        if let before, !(due.map { $0 < before } ?? false) { continue }
                        if let after, !(due.map { $0 >= after } ?? false) { continue }
                        matches.append((r, list))
                    }
                }
                matches.sort { a, b in
                    if a.0.completed != b.0.completed { return !a.0.completed }
                    if a.0.completed { return (a.0.completionDate ?? .distantPast) > (b.0.completionDate ?? .distantPast) }
                    let da = a.0.due.flatMap(Due.instant) ?? .distantFuture, db = b.0.due.flatMap(Due.instant) ?? .distantFuture
                    return da != db ? da < db : a.0.title < b.0.title
                }
                let shown = matches.prefix(limit)
                var result: [String: JSON] = [
                    "now": .string(Due.now()), "time_zone": .string(TimeZone.current.identifier),
                    "count": .int(shown.count), "reminders": .array(shown.map { Output.reminder($0.0, in: $0.1) }),
                ]
                if matches.count > shown.count { result["more"] = .int(matches.count - shown.count) }
                return ToolAnswer(JSON.object(result).text)
            }
        },

        Tool("get_reminder", title: "Read a reminder",
             summary: "Reads one reminder in full: alarms, early alerts, images, subtasks, and its current version.",
             input: Schema.object(["id": Schema.text("Reminder id")], required: ["id"]), effect: .reads) { fields in
            let id = try Input(fields).requiredText("id")
            return try await withStore(store) {
                let (reminder, list) = try store.detail(id)
                guard case .object(var o) = Output.reminder(reminder, in: list, detail: true) else { return ToolAnswer("{}") }
                let subtasks = try store.reminders(in: list.id).filter { $0.parentID == reminder.id }
                if !subtasks.isEmpty {
                    o["subtasks"] = .array(subtasks.map { s in
                        var row: [String: JSON] = ["id": .string(s.id), "title": .string(s.title)]
                        if s.completed { row["completed"] = true }
                        return .object(row)
                    })
                }
                return ToolAnswer(JSON.object(o).text)
            }
        },

        Tool("read_image", title: "Look at an image on a reminder",
             summary: "Returns an image attached to a reminder (ids from get_reminder). Needs Full Disk Access for the app.",
             input: Schema.object(["reminder_id": Schema.text("Reminder id"), "image_id": Schema.text("Image id")], required: ["reminder_id", "image_id"]),
             effect: .reads) { fields in
            let input = Input(fields)
            let reminderID = try input.requiredText("reminder_id"), imageID = try input.requiredText("image_id")
            return try await withStore(store) {
                let (data, image) = try store.imageData(reminder: reminderID, image: imageID)
                let mime = image.type.contains("png") ? "image/png" : image.type.contains("heic") ? "image/heic" : image.type.contains("gif") ? "image/gif" : "image/jpeg"
                return ToolAnswer(content: [.text("\(image.width)×\(image.height), \(data.count) bytes"), .image(data, mimeType: mime)])
            }
        },

        Tool("list_tags", title: "List tags",
             summary: "Lists every tag in use, with how many open and how many reminders in all have it.",
             input: Schema.object([:]), effect: .reads) { _ in
            try await withStore(store) {
                ToolAnswer(JSON.array(try store.tags().map { ["tag": .string($0.name), "open": .int($0.open), "total": .int($0.total)] }).text)
            }
        },

        Tool("list_deleted", title: "List recently deleted reminders",
             summary: "Lists reminders in Recently Deleted that restore_reminder can bring back, newest first.",
             input: Schema.object([:]), effect: .reads) { _ in
            try await withStore(store) {
                let (items, complete) = try store.deleted()
                var result: [String: JSON] = [
                    "deleted": .array(items.map { item in
                        var row: [String: JSON] = ["id": .string(item.id), "title": .string(item.title)]
                        if let at = item.deletedAt { row["deleted_at"] = .string(Output.stamp.string(from: at)) }
                        if let list = item.fromList { row["from_list"] = .string(list) }
                        if let parent = item.parentID { row["parent_id"] = .string(parent) }
                        if item.completed { row["completed"] = true }
                        return .object(row)
                    }),
                ]
                if !complete {
                    result["note"] = "Only reminders deleted through this server are listed. With Full Disk Access for Apple Reminders MCP, this lists everything in Recently Deleted."
                }
                return ToolAnswer(JSON.object(result).text)
            }
        },
    ]
}
