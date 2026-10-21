import Foundation
import Wire

/// color and icon, shared by lists and smart lists.
func appearanceChanges(_ input: Input) throws -> [String: Any] {
    var changes: [String: Any] = [:]
    if let color = try input.text("color") {
        guard let value = ListAppearance.color(color) else {
            throw BadInput("color must be one of \(ListAppearance.colorNames.joined(separator: ", ")) or #RRGGBB")
        }
        changes["color"] = value
    }
    if input.has("icon") { changes["icon"] = try input.text("icon") ?? "" }
    return changes
}

let colorField = Schema.text("red, orange, yellow, green, light-blue, blue, indigo, pink, purple, brown, gray, rose, or #RRGGBB")
let iconField = Schema.text("An emoji, or an emblem name such as nature2; empty for the default")

func organizeTools(_ store: RemindersStore) -> [Tool] {
    [
        Tool("manage_list", title: "Create, change or delete a list",
             summary: """
                 create a list; update its name, color, icon, group, pin, type (groceries sorts items into \
                 aisles), sort order or place in the sidebar; clear_completed moves its completed reminders \
                 to Recently Deleted; delete removes it (one with reminders needs confirm_delete_reminders: \
                 true; ask the user first; its reminders go to Recently Deleted).
                 """,
             input: Schema.object([
                 "action": Schema.choice(["create", "update", "clear_completed", "delete"], "What to do"),
                 "list": Schema.text("New list name for create; list name or id otherwise"),
                 "new_name": Schema.text("For update"),
                 "color": colorField, "icon": iconField,
                 "group": Schema.clearable(Schema.text("Group name or id to put it in; null takes it out")),
                 "pinned": Schema.flag("Pin to the top of the sidebar"),
                 "type": Schema.choice(["standard", "groceries"], "List type"),
                 "sort": Schema.choice(Output.sortNames.map(\.tool), "How Reminders sorts the list"),
                 "position": Schema.object(["after": Schema.text("List name or id"), "before": Schema.text("List name or id")]),
                 "confirm_delete_reminders": Schema.flag("Delete a list that still has reminders"),
             ], required: ["action", "list"]), effect: .deletes) { fields in
            let input = Input(fields)
            let action = try input.pick("action", from: ["create", "update", "clear_completed", "delete"]) ?? ""
            let list = try input.requiredText("list")
            var changes = try appearanceChanges(input)
            if let name = try input.text("new_name") { changes["name"] = name }
            if input.cleared("group") { changes["group"] = NSNull() } else if let group = try input.text("group") { changes["group"] = group }
            if let pinned = try input.flag("pinned") { changes["pinned"] = pinned }
            if let type = try input.pick("type", from: ["standard", "groceries"]) { changes["groceries"] = type == "groceries" }
            if let sort = try input.pick("sort", from: Output.sortNames.map(\.tool)) { changes["sorting"] = Output.sortNames.first { $0.tool == sort }!.stored }
            if let position = try input.position("position") { changes["position"] = position }
            let confirm = try input.flag("confirm_delete_reminders") ?? false
            if action == "update" && changes.isEmpty { throw BadInput("update needs something to change") }
            return try await withStore(store) {
                let groups = { (try? store.groups()) ?? [] }
                switch action {
                case "create":
                    changes.removeValue(forKey: "name")
                    let created = try store.createList(list, changes: changes)
                    return .json("Created.", Output.list(created, groups: groups()))
                case "update":
                    let updated = try store.updateList(list, changes: changes)
                    return .json("Updated.", Output.list(updated, groups: groups()))
                case "clear_completed":
                    let (cleared, count) = try store.clearCompleted(in: list)
                    return ToolAnswer("Moved \(count) completed reminders of \"\(cleared.name)\" to Recently Deleted.")
                default:
                    let (deleted, count) = try store.deleteList(list, withReminders: confirm)
                    return ToolAnswer("Deleted the list \"\(deleted.name)\"" + (count > 0 ? "; its \(count) reminders are in Recently Deleted." : "."))
                }
            }
        },

        Tool("manage_group", title: "Create, rename or delete a list group",
             summary: "Groups hold lists in the sidebar. create, rename, or delete an empty group; put lists in a group with manage_list.",
             input: Schema.object([
                 "action": Schema.choice(["create", "rename", "delete"], "What to do"),
                 "group": Schema.text("New group name for create; group name or id otherwise"),
                 "new_name": Schema.text("For rename"),
             ], required: ["action", "group"]), effect: .deletes) { fields in
            let input = Input(fields)
            let action = try input.pick("action", from: ["create", "rename", "delete"]) ?? ""
            let group = try input.requiredText("group"), newName = try input.text("new_name")
            if action == "rename" && newName == nil { throw BadInput("rename needs new_name") }
            return try await withStore(store) {
                switch action {
                case "create":
                    let created = try store.createGroup(group)
                    return ToolAnswer("Created the group \"\(created.name)\". id: \(created.id)")
                case "rename":
                    let renamed = try store.renameGroup(group, to: newName!)
                    return ToolAnswer("Renamed the group to \"\(renamed.name)\".")
                default:
                    let deleted = try store.deleteGroup(group)
                    return ToolAnswer("Deleted the empty group \"\(deleted.name)\".")
                }
            }
        },

        Tool("manage_section", title: "Create, rename, move or delete a section",
             summary: """
                 Sections divide a list. create, rename, move (next to another section) or delete one; \
                 deleting keeps its reminders in the list. Put reminders in a section with create_reminder or \
                 update_reminder.
                 """,
             input: Schema.object([
                 "action": Schema.choice(["create", "rename", "move", "delete"], "What to do"),
                 "list": Schema.text("List name or id"),
                 "section": Schema.text("New section name for create; section name or id otherwise"),
                 "new_name": Schema.text("For rename"),
                 "position": Schema.object(["after": Schema.text("Section name"), "before": Schema.text("Section name")]),
             ], required: ["action", "list", "section"]), effect: .deletes) { fields in
            let input = Input(fields)
            let action = try input.pick("action", from: ["create", "rename", "move", "delete"]) ?? ""
            let list = try input.requiredText("list"), section = try input.requiredText("section")
            let newName = try input.text("new_name"), position = try input.position("position")
            if action == "rename" && newName == nil { throw BadInput("rename needs new_name") }
            if action == "move" && position == nil { throw BadInput("move needs position") }
            return try await withStore(store) {
                switch action {
                case "create":
                    let (created, target) = try store.createSection(section, in: list)
                    return ToolAnswer("Created the section \"\(created.name)\" in \"\(target.name)\". id: \(created.id)")
                case "rename":
                    let (renamed, target) = try store.renameSection(section, in: list, to: newName!)
                    return ToolAnswer("Renamed the section to \"\(renamed.name)\" in \"\(target.name)\".")
                case "move":
                    let after = position!["after"] != nil
                    let moved = try store.moveSection(section, in: list, relativeTo: position!["after"] ?? position!["before"]!, after: after)
                    return .json("Moved. Sections now:", .array(moved.sections.map { .string($0.name) }))
                default:
                    let (deleted, target) = try store.deleteSection(section, in: list)
                    return ToolAnswer("Deleted the section \"\(deleted.name)\" from \"\(target.name)\"; its reminders stay in the list.")
                }
            }
        },

        Tool("manage_smart_list", title: "Create, change or delete a smart list",
             summary: """
                 Smart lists show the reminders matching their filters; list_lists shows them with their \
                 filters. create one, update its name, color, icon, match or filters (filters replaces them \
                 all), or delete it (no reminders are deleted). find_reminders with smart_list shows what one holds.
                 """,
             input: Schema.object([
                 "action": Schema.choice(["create", "update", "delete"], "What to do"),
                 "smart_list": Schema.text("New name for create; smart list name or id otherwise"),
                 "new_name": Schema.text("For update"),
                 "color": colorField, "icon": iconField,
                 "match": Schema.choice(["all", "any"], "Whether a reminder must match all filters or any; default all"),
                 "filters": Schema.object([
                     "tags": Schema.any("any, untagged, or {include: [tags], exclude: [tags], match: all|any}"),
                     "date": Schema.any("today, none, {before|on|after: \"2026-10-21\"}, {from: date, until: date}, or {next|past: 10, unit: hour|day|week|month|year, include_past_due: bool}"),
                     "time": Schema.choice(SmartFilter.times + ["none"], "Time of day of the due time"),
                     "priorities": Schema.list(of: Schema.choice(["low", "medium", "high"], "Priority"), "Any of these priorities"),
                     "flagged": Schema.flag("Flagged or not flagged"),
                     "lists": Schema.any("{include: [list names or ids]} or {exclude: [...]}"),
                     "location": Schema.any("none, getting-in-car, getting-out-of-car, or {latitude, longitude, radius, title, when: arriving|leaving}"),
                 ]),
             ], required: ["action", "smart_list"]), effect: .deletes) { fields in
            let input = Input(fields)
            let action = try input.pick("action", from: ["create", "update", "delete"]) ?? ""
            let smartList = try input.requiredText("smart_list")
            let match = try input.pick("match", from: ["all", "any"])
            var filters: [String: JSON]?
            if let value = fields["filters"], value != .null {
                guard let object = value.object else { throw BadInput("filters must be an object") }
                filters = object
            }
            var changes = try appearanceChanges(input)
            if let name = try input.text("new_name") { changes["name"] = name }
            if action == "create" && filters == nil { throw BadInput("create needs filters") }
            if action == "update" && changes.isEmpty && filters == nil && match == nil { throw BadInput("update needs something to change") }
            return try await withStore(store) {
                let lists = try store.lists()
                let resolveList = { (nameOrID: String) throws -> String in
                    do { return try store.resolveList(nameOrID).id } catch let error as StoreError { throw BadInput(error.description) }
                }
                switch action {
                case "create":
                    changes["filter"] = try SmartFilter.encode(match: match ?? "all", filters: filters!, resolveList: resolveList)
                    let created = try store.createSmartList(smartList, changes: changes)
                    return .json("Created.", Output.smartList(created, lists: lists))
                case "update":
                    let current = try store.resolveSmartList(smartList)
                    if let filters {
                        let keep = SmartFilter.decode(current.filter) { $0 }.match
                        changes["filter"] = try SmartFilter.encode(match: match ?? keep, filters: filters, resolveList: resolveList)
                    } else if let match {
                        changes["filter"] = SmartFilter.settingMatch(current.filter, to: match)
                    }
                    let updated = try store.updateSmartList(current.id, changes: changes)
                    return .json("Updated.", Output.smartList(updated, lists: lists))
                default:
                    let deleted = try store.deleteSmartList(smartList)
                    return ToolAnswer("Deleted the smart list \"\(deleted.name)\"; no reminders were deleted.")
                }
            }
        },

        Tool("manage_tag", title: "Rename or delete a tag",
             summary: "Renames a tag on every reminder that has it (merging into an existing tag of that name), or deletes it from all of them. list_tags shows the tags.",
             input: Schema.object([
                 "action": Schema.choice(["rename", "delete"], "What to do"),
                 "tag": Schema.text("Tag, without #"),
                 "new_name": Schema.text("For rename"),
             ], required: ["action", "tag"]), effect: .deletes) { fields in
            let input = Input(fields)
            let action = try input.pick("action", from: ["rename", "delete"]) ?? ""
            let strip = { (tag: String) in tag.hasPrefix("#") ? String(tag.dropFirst()) : tag }
            let tag = strip(try input.requiredText("tag")), newName = try input.text("new_name").map(strip)
            if action == "rename" && newName == nil { throw BadInput("rename needs new_name") }
            return try await withStore(store) {
                let count = try store.replaceTag(tag, with: action == "rename" ? newName : nil)
                if count == 0 { return ToolAnswer("No reminder has the tag \"\(tag)\".", failed: true) }
                return ToolAnswer(action == "rename" ? "Renamed \"\(tag)\" to \"\(newName!)\" on \(count) reminders." : "Removed \"\(tag)\" from \(count) reminders.")
            }
        },

        Tool("manage_template", title: "Save, use or delete a list template",
             summary: """
                 create saves a list as a template (Reminders copies its reminders in the background); use makes \
                 a new list from a template; delete removes a template. list_lists shows the templates.
                 """,
             input: Schema.object([
                 "action": Schema.choice(["create", "use", "delete"], "What to do"),
                 "template": Schema.text("New template name for create; template name or id otherwise"),
                 "list": Schema.text("For create: the list to save; for use: the new list's name (default the template's)"),
                 "include_completed": Schema.flag("For create: keep completed reminders too; default false"),
             ], required: ["action", "template"]), effect: .deletes) { fields in
            let input = Input(fields)
            let action = try input.pick("action", from: ["create", "use", "delete"]) ?? ""
            let template = try input.requiredText("template"), list = try input.text("list")
            let includeCompleted = try input.flag("include_completed") ?? false
            if action == "create" && list == nil { throw BadInput("create needs the list to save") }
            return try await withStore(store) {
                switch action {
                case "create":
                    let created = try store.createTemplate(template, from: list!, includeCompleted: includeCompleted)
                    return ToolAnswer("Saved \"\(list!)\" as the template \"\(created.name)\". id: \(created.id)")
                case "use":
                    let made = try store.createList(fromTemplate: template, name: list)
                    return .json("Created from the template.", Output.list(made, groups: (try? store.groups()) ?? []))
                default:
                    let deleted = try store.deleteTemplate(template)
                    return ToolAnswer("Deleted the template \"\(deleted.name)\".")
                }
            }
        },
    ]
}
