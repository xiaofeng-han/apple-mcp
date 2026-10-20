import Foundation
import Wire

/// The fields create_reminder and update_reminder share, as store change keys (see
/// RemindersStore.prepare and RKBridge.h).
func reminderChanges(_ input: Input) throws -> [String: Any] {
    var changes: [String: Any] = [:]
    if let title = try input.text("title") { changes["title"] = title }
    if input.has("notes") { changes["notes"] = try input.text("notes") ?? "" }
    if let flagged = try input.flag("flagged") { changes["flagged"] = flagged }
    if let urgent = try input.flag("urgent") { changes["urgent"] = urgent }
    if let completed = try input.flag("completed") { changes["completed"] = completed }
    if let priority = try input.pick("priority", from: Priority.names) { changes["priority"] = Priority.value(priority) }
    for key in ["due", "start"] {
        if input.cleared(key) { changes[key] = NSNull() } else if let date = try input.due(key) { changes[key] = date as NSDateComponents }
    }
    if input.cleared("repeat") { changes["repeat"] = NSNull() } else if let rule = try input.repeatRule("repeat") { changes["repeat"] = rule }
    if let tags = try input.tags("tags") { changes["tags"] = tags }
    if input.cleared("parent_id") { changes["parentId"] = NSNull() } else if let parent = try input.text("parent_id") { changes["parentId"] = parent }
    if input.cleared("section") { changes["section"] = NSNull() } else if let section = try input.text("section") { changes["section"] = section }
    if input.cleared("early_alerts") { changes["earlyAlerts"] = NSNull() } else if let alerts = try input.earlyAlerts("early_alerts") {
        changes["earlyAlerts"] = alerts.isEmpty ? NSNull() : alerts
    }
    if input.cleared("location") { changes["location"] = NSNull() } else if let trigger = try input.trigger("location") { changes["location"] = trigger }
    if input.cleared("when_messaging") { changes["contact"] = NSNull() } else if let contact = try input.contact("when_messaging") { changes["contact"] = contact }
    if input.cleared("url") { changes["url"] = NSNull() } else if let url = try input.url("url") { changes["url"] = url }
    if let paths = try input.texts("add_images") { changes["addImages"] = paths }
    if let ids = try input.texts("remove_images") { changes["removeImages"] = ids }
    if input.cleared("assigned_to") { changes["assignee"] = NSNull() } else if let person = try input.text("assigned_to") { changes["assignee"] = person }
    if let position = try input.position("position") { changes["position"] = position }
    return changes
}

let reminderFields: [String: JSON] = [
    "notes": Schema.text("Plain text"),
    "due": Schema.clearable(Schema.text("2026-10-21 (all day) or 2026-10-21T09:00 (local time); a time adds an alert then")),
    "start": Schema.clearable(Schema.text("Start date, same format as due")),
    "repeat": Schema.clearable(["type": "object", "description": "Repeats from the due date", "additionalProperties": false, "required": ["frequency"],
        "properties": [
            "frequency": Schema.choice(RepeatRule.frequencies, "How often"),
            "interval": Schema.whole("Every n periods; default 1"),
            "days_of_week": Schema.texts("mon … sun; for monthly or yearly, 1mon is the first Monday and -1fri the last Friday"),
            "days_of_month": Schema.wholes("1 … 31, or -1 for the last day"),
            "months": Schema.wholes("1 … 12, for yearly"),
            "until": Schema.text("Last date, 2026-12-31"),
            "count": Schema.whole("Number of times, instead of until"),
        ]]),
    "early_alerts": Schema.clearable(Schema.list(of: Schema.object([
        "before": Schema.whole("How long before the due date"), "unit": Schema.choice(EarlyAlert.units, "Default minutes"),
    ], required: ["before"]), "Early reminders, replacing any there are; [] or null removes them")),
    "location": Schema.clearable(Schema.any("Alert at a place, {title, latitude, longitude, radius (meters, default 100), address, when: arriving|leaving}, or getting-in-car, getting-out-of-car; replaces any place alert; null removes it")),
    "when_messaging": Schema.clearable(Schema.object(["phones": Schema.texts("Phone numbers"), "emails": Schema.texts("Email addresses")])),
    "url": Schema.clearable(Schema.text("A link shown on the reminder")),
    "add_images": Schema.texts("Image files on this Mac to attach"),
    "priority": Schema.choice(Priority.names, "Priority"),
    "flagged": Schema.flag("Flag"),
    "urgent": Schema.flag("Alarm-style alert that rings like an alarm on the user's devices; needs a due time"),
    "tags": Schema.texts("Native tags without #; replaces all tags"),
    "parent_id": Schema.clearable(Schema.text("Makes it a subtask of this top-level reminder in the same list; null makes it top level")),
    "section": Schema.clearable(Schema.text("Section name or id in the reminder's list; null takes it out of its section")),
    "assigned_to": Schema.clearable(Schema.text("On a shared list: a person's name (or me); null unassigns")),
    "position": Schema.object(["after": Schema.text("Reminder id"), "before": Schema.text("Reminder id")]),
]

func writeTools(_ store: RemindersStore) -> [Tool] {
    [
        Tool("create_reminder", title: "Create a reminder",
             summary: "Creates a reminder. Without list it goes to the default list (or the parent's list).",
             input: {
                 var properties = reminderFields
                 properties["title"] = Schema.text("Title")
                 properties["list"] = Schema.text("List name or id")
                 return Schema.object(properties, required: ["title"])
             }(), effect: .writes) { fields in
            let input = Input(fields)
            let title = try input.requiredText("title"), list = try input.text("list")
            var changes = try reminderChanges(input)
            changes.removeValue(forKey: "title")
            for key in changes.keys where changes[key] is NSNull { changes.removeValue(forKey: key) }
            return try await withStore(store) {
                let (reminder, target) = try store.create(title: title, list: list, changes: changes)
                return .json("Created.", Output.reminder(reminder, in: target))
            }
        },

        Tool("update_reminder", title: "Update a reminder",
             summary: """
                 Changes only the fields given; null clears a field. Pass the version from find_reminders or \
                 get_reminder. completed: true checks it off; for a repeating reminder Reminders keeps a \
                 completed copy and moves it to its next date (unless the user turned that off in the app's \
                 settings). list moves it to another list.
                 """,
             input: {
                 var properties = reminderFields
                 properties["id"] = Schema.text("Reminder id")
                 properties["version"] = Schema.text("Version you read")
                 properties["title"] = Schema.text("New title")
                 properties["completed"] = Schema.flag("Check off or reopen")
                 properties["list"] = Schema.text("Move to this list (name or id)")
                 properties["remove_images"] = Schema.texts("Image ids to remove")
                 return Schema.object(properties, required: ["id", "version"])
             }(), effect: .writes) { fields in
            let input = Input(fields)
            let id = try input.requiredText("id"), version = try input.requiredText("version")
            var changes = try reminderChanges(input)
            if let list = try input.text("list") { changes["listId"] = list }
            guard !changes.isEmpty else { throw BadInput("Nothing to change") }
            return try await withStore(store) {
                let (reminder, list, completedCopy) = try store.update(id: id, version: version, changes: changes)
                let lead = completedCopy ? "Completed this occurrence: Reminders kept a completed copy, and the reminder moved to its next date." : "Updated."
                return .json(lead, Output.reminder(reminder, in: list))
            }
        },

        Tool("delete_reminder", title: "Delete a reminder",
             summary: "Moves a reminder and its subtasks to Recently Deleted; restore_reminder brings them back.",
             input: Schema.object(["id": Schema.text("Reminder id"), "version": Schema.text("Version you read")], required: ["id", "version"]),
             effect: .deletes) { fields in
            let input = Input(fields)
            let id = try input.requiredText("id"), version = try input.requiredText("version")
            return try await withStore(store) {
                let titles = try store.delete(id: id, version: version)
                return ToolAnswer("Moved to Recently Deleted: " + titles.map { "\"\($0)\"" }.joined(separator: ", ") + ".")
            }
        },

        Tool("restore_reminder", title: "Restore a deleted reminder",
             summary: "Brings a reminder back from Recently Deleted, with the subtasks deleted along with it. Without list it returns to the list it was deleted from, or the default list.",
             input: Schema.object(["id": Schema.text("Id from list_deleted"), "list": Schema.text("List name or id to restore into")], required: ["id"]),
             effect: .writes) { fields in
            let input = Input(fields)
            let id = try input.requiredText("id"), list = try input.text("list")
            return try await withStore(store) {
                let (restored, target) = try store.restore(id: id, list: list)
                return .json("Restored into \"\(target.name)\".", .array(restored.map { Output.reminder($0, in: target) }))
            }
        },
    ]
}
