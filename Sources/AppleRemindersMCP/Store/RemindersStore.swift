import EventKit
import ImageIO
import Foundation
import ReminderKitShim

/// Everything the tools need, on top of RKBridge: the permission check, the write guard,
/// version checks, the rules Reminders enforces in its own UI, and Recently Deleted. Calls into
/// ReminderKit are serialized, because the MCP transport runs requests concurrently and
/// ReminderKit's store is not documented as thread-safe.
final class RemindersStore: @unchecked Sendable {
    /// While set (development and checks), writes only touch lists and groups with these names.
    let writeGuard: Set<String>?
    let deletionLog: DeletionLog
    private let lock = NSLock()
    private var bridge: RKBridge?

    init(writeGuard: Set<String>?, deletionLog: DeletionLog = DeletionLog()) {
        self.writeGuard = writeGuard
        self.deletionLog = deletionLog
    }

    // MARK: Permission

    static let permissionHelp = """
        Apple Reminders MCP has no access to Reminders. Ask the user to allow it in System Settings → \
        Privacy & Security → Reminders (turn on "Apple Reminders MCP" with full access), or to open \
        ~/Applications/AppleRemindersMCP.app once and click Allow.
        """

    /// Asks for access the first time (the system dialog appears on the Mac) and fails with
    /// instructions when it was refused.
    func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = (try? await EKEventStore().requestFullAccessToReminders()) ?? false
            if !granted { throw StoreError(Self.permissionHelp) }
        default:
            throw StoreError(Self.permissionHelp)
        }
    }

    private func withBridge<T>(_ body: (RKBridge) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if bridge == nil {
            do { bridge = try RKBridge.open() } catch { throw StoreError("ReminderKit is unavailable: \(error.localizedDescription)") }
        }
        do {
            return try body(bridge!)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError(error.localizedDescription)
        }
    }

    // MARK: Reading

    func lists() throws -> [ListInfo] {
        try withBridge { try $0.lists().map(ListInfo.init) }
    }

    func groups() throws -> [GroupInfo] {
        try withBridge { try $0.groups().map { GroupInfo(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "") } }
    }

    func defaultListID() throws -> String {
        try withBridge { try $0.defaultListID() }
    }

    func reminders(in listID: String) throws -> [ReminderInfo] {
        try withBridge { try $0.reminders(inList: listID).map(ReminderInfo.init) }
    }

    /// A list by id or exact name; a name shared by several lists needs the id.
    func resolveList(_ nameOrID: String) throws -> ListInfo {
        let all = try lists()
        if let list = all.first(where: { $0.id.caseInsensitiveCompare(nameOrID) == .orderedSame }) { return list }
        let named = all.filter { $0.name == nameOrID }
        if named.count == 1 { return named[0] }
        if named.isEmpty {
            throw StoreError("No list named \"\(nameOrID)\". Lists: \(all.map { "\"\($0.name)\"" }.joined(separator: ", ")).")
        }
        throw StoreError("Several lists are named \"\(nameOrID)\"; pass one of these ids: \(named.map(\.id).joined(separator: ", ")).")
    }

    func resolveGroup(_ nameOrID: String) throws -> GroupInfo {
        let all = try groups()
        if let group = all.first(where: { $0.id.caseInsensitiveCompare(nameOrID) == .orderedSame }) { return group }
        let named = all.filter { $0.name == nameOrID }
        if named.count == 1 { return named[0] }
        if named.isEmpty {
            throw StoreError("No group named \"\(nameOrID)\". Groups: \(all.isEmpty ? "none" : all.map { "\"\($0.name)\"" }.joined(separator: ", ")).")
        }
        throw StoreError("Several groups are named \"\(nameOrID)\"; pass one of these ids: \(named.map(\.id).joined(separator: ", ")).")
    }

    func resolveSection(_ nameOrID: String, in list: ListInfo) throws -> SectionInfo {
        if let section = list.sections.first(where: { $0.id.caseInsensitiveCompare(nameOrID) == .orderedSame || $0.name == nameOrID }) {
            return section
        }
        let names = list.sections.map { "\"\($0.name)\"" }.joined(separator: ", ")
        throw StoreError("The list \"\(list.name)\" has no section \"\(nameOrID)\". Sections: \(names.isEmpty ? "none" : names).")
    }

    func reminder(_ id: String) throws -> (ReminderInfo, ListInfo) {
        for list in try lists() {
            if let found = try reminders(in: list.id).first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
                return (found, list)
            }
        }
        throw StoreError("No reminder with id \(id). It may have been deleted (see list_deleted); otherwise find it again with find_reminders.")
    }

    // MARK: Checks

    private func checkWritable(_ name: String) throws {
        if let writeGuard, !writeGuard.contains(name) {
            throw StoreError("Writes are limited to \(writeGuard.sorted().map { "\"\($0)\"" }.joined(separator: ", ")) (APPLE_REMINDERS_MCP_WRITE_GUARD).")
        }
    }

    private func checkWritable(_ list: ListInfo) throws { try checkWritable(list.name) }

    private func checkVersion(_ reminder: ReminderInfo, _ version: String) throws {
        guard reminder.version == version else {
            throw StoreError("\"\(reminder.title)\" changed since it was read (version \(reminder.version), not \(version)). Read it again with get_reminder and retry.")
        }
    }

    /// Reminders allows one level of subtasks within a list.
    private func checkParent(_ parentID: String, child: String?, listID: String) throws -> ReminderInfo {
        let (parent, parentList) = try reminder(parentID)
        if parent.id == child { throw StoreError("A reminder cannot be its own parent.") }
        if parent.parentID != nil { throw StoreError("\"\(parent.title)\" is itself a subtask; Reminders allows one level of subtasks.") }
        if parentList.id != listID { throw StoreError("The parent \"\(parent.title)\" is in the list \"\(parentList.name)\"; a subtask must be in its parent's list.") }
        return parent
    }

    /// Turns the tool-level keys `section` and `repeat` into bridge keys and applies the rules
    /// that involve the reminder's resulting state.
    private func prepare(_ changes: inout [String: Any], list: ListInfo, current: ReminderInfo?) throws {
        if let name = changes.removeValue(forKey: "section") {
            changes["sectionId"] = name is NSNull ? NSNull() : try resolveSection(name as! String, in: list).id
        }
        let newDue: DateComponents? = changes["due"] is NSNull ? nil : (changes["due"] as? NSDateComponents).map { $0 as DateComponents } ?? current?.due
        if let rule = changes["repeat"] as? RepeatRule {
            if newDue == nil { throw StoreError("A repeating reminder needs a due date; pass due as well.") }
            changes["repeat"] = rule.bridgeValue
        } else if changes["due"] is NSNull, current?.repeatRule != nil {
            // Reminders does not keep a rule without a date.
            changes["repeat"] = NSNull()
        }
        // Urgent needs a due time, both when it is turned on and when the due date changes under it.
        let urgent = changes["urgent"] as? Bool ?? current?.urgent ?? false
        if urgent, newDue?.hour == nil {
            if changes["urgent"] as? Bool == true {
                throw StoreError("An urgent reminder needs a due date with a time, e.g. 2026-10-21T09:00.")
            }
            changes["urgent"] = false
        }
        if let alerts = changes["earlyAlerts"] as? [EarlyAlert] {
            if newDue == nil { throw StoreError("Early reminders count back from the due date; pass due as well.") }
            changes["earlyAlerts"] = alerts.map(\.stored)
        }
        if let trigger = changes["location"] as? Trigger { changes["location"] = trigger.bridgeValue }
        if let assignee = changes.removeValue(forKey: "assignee") {
            if assignee is NSNull {
                changes["assigneeId"] = NSNull()
            } else {
                let wanted = assignee as! String
                guard list.shared else { throw StoreError("\"\(list.name)\" is not shared, so its reminders cannot be assigned.") }
                let joined = list.sharees.filter { $0.status == 1 }
                guard let person = joined.first(where: { $0.id.caseInsensitiveCompare(wanted) == .orderedSame })
                    ?? joined.first(where: { $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame })
                    ?? (["me", "myself"].contains(wanted.lowercased()) ? joined.first(where: \.me) : nil)
                else {
                    throw StoreError("No one called \"\(wanted)\" has joined \"\(list.name)\". People: \(joined.map { "\"\($0.name)\"\($0.me ? " (me)" : "")" }.joined(separator: ", ")).")
                }
                changes["assigneeId"] = person.id
            }
        }
        if let paths = changes["addImages"] as? [String] {
            changes["addImages"] = try paths.map { path -> [String: Any] in
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                    let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
                else { throw StoreError("\(path) is not an image this Mac can read.") }
                return ["path": url.path, "width": width, "height": height]
            }
        }
        if let removing = changes["removeImages"] as? [String], let current {
            if let unknown = removing.first(where: { id in !current.images.contains { $0.id.caseInsensitiveCompare(id) == .orderedSame } }) {
                throw StoreError("\"\(current.title)\" has no image \(unknown); get_reminder lists its images.")
            }
        }
        if let position = changes["position"] as? [String: String], let neighborID = position["after"] ?? position["before"] {
            let (neighbor, neighborList) = try reminder(neighborID)
            let parent = (changes["parentId"] as? String) ?? (changes["parentId"] is NSNull ? nil : current?.parentID)
            if neighborList.id != list.id || neighbor.parentID?.uppercased() != parent?.uppercased() {
                throw StoreError("\"\(neighbor.title)\" is not next to it: a reminder can only be placed among reminders of the same list and level (top level, or subtasks of the same parent).")
            }
            changes["position"] = [position["after"] != nil ? "after" : "before": neighbor.id]
        }
    }

    // MARK: Reminders

    func create(title: String, list nameOrID: String?, changes: [String: Any]) throws -> (ReminderInfo, ListInfo) {
        var changes = changes
        var named = try nameOrID.map(resolveList)
        if let parentID = changes["parentId"] as? String {
            let (parent, parentList) = try reminder(parentID)
            if named == nil { named = parentList }
            _ = try checkParent(parent.id, child: nil, listID: named!.id)
            changes["parentId"] = parent.id
        }
        let list = try named ?? resolveList(defaultListID())
        try checkWritable(list)
        try prepare(&changes, list: list, current: nil)
        let id = try withBridge { try $0.addReminder(toList: list.id, title: title, changes: changes) }
        return try reminder(id)
    }

    /// Returns the updated reminder; for a completed repeating reminder that is the reminder at
    /// its next occurrence, and `completedCopy` says so.
    func update(id: String, version: String, changes: [String: Any]) throws -> (reminder: ReminderInfo, list: ListInfo, completedCopy: Bool) {
        let (current, list) = try reminder(id)
        try checkWritable(list)
        try checkVersion(current, version)
        var changes = changes
        var target = list
        if let destination = changes["listId"] as? String {
            let moved = try resolveList(destination)
            try checkWritable(moved)
            if moved.id == list.id {
                changes.removeValue(forKey: "listId")
            } else {
                if try reminders(in: list.id).contains(where: { $0.parentID == current.id }) {
                    throw StoreError("\"\(current.title)\" has subtasks; move or delete them first, or move them one by one.")
                }
                changes["listId"] = moved.id
                target = moved
            }
        }
        if let parentID = changes["parentId"] as? String {
            _ = try checkParent(parentID, child: current.id, listID: target.id)
            if try reminders(in: list.id).contains(where: { $0.parentID == current.id }) {
                throw StoreError("\"\(current.title)\" has subtasks of its own, so it cannot become a subtask.")
            }
        } else if changes["parentId"] is NSNull, current.parentID == nil {
            changes.removeValue(forKey: "parentId")
        }
        var completedCopy = false
        if changes["completed"] as? Bool == true, current.recurring, !current.completed {
            guard Settings.allowCompletingRecurring else {
                throw StoreError("\"\(current.title)\" repeats, and the user turned off completing repeating reminders in Apple Reminders MCP's settings. Ask the user to check it off in Reminders.")
            }
            changes["completeRecurring"] = true
            completedCopy = true
        }
        try prepare(&changes, list: target, current: current)
        try withBridge { try $0.updateReminder(current.id, changes: changes) }
        let (updated, updatedList) = try reminder(current.id)
        return (updated, updatedList, completedCopy)
    }

    /// Deletes a reminder and its subtasks; returns their titles.
    func delete(id: String, version: String) throws -> [String] {
        let (current, list) = try reminder(id)
        try checkWritable(list)
        try checkVersion(current, version)
        let subtasks = try reminders(in: list.id).filter { $0.parentID == current.id }
        return try softDelete(subtasks + [current], from: list)
    }

    private func softDelete(_ targets: [ReminderInfo], from list: ListInfo) throws -> [String] {
        guard !targets.isEmpty else { return [] }
        let now = Date()
        deletionLog.record(targets.map {
            DeletionLog.Entry(id: $0.id, title: $0.title, listID: list.id, listName: list.name, parentID: $0.parentID, deletedAt: now)
        })
        try withBridge { try $0.deleteReminders(targets.map(\.id)) }
        return targets.map(\.title)
    }

    struct DeletedItem: Sendable {
        let id: String
        let title: String
        let deletedAt: Date?
        let fromList: String?
        let parentID: String?
        let completed: Bool
    }

    /// Restorable reminders in Recently Deleted: everything when the app can read Reminders'
    /// database, otherwise what this server deleted. `complete` says which.
    func deleted() throws -> (items: [DeletedItem], complete: Bool) {
        let logged = deletionLog.entries()
        let database = DeletedDatabase.recentlyDeleted()
        var candidates: [String: (title: String, deletedAt: Date?, parentID: String?)] = [:]
        for row in database ?? [] { candidates[row.id] = (row.title, row.deletedAt, row.parentID) }
        for entry in logged { candidates[entry.id] = (entry.title, entry.deletedAt, entry.parentID) }
        let alive = try withBridge { try $0.deletedReminders(Array(candidates.keys)) }
        // Restored or purged since: drop them from the log.
        let gone = Set(logged.map(\.id)).subtracting(alive.keys)
        if !gone.isEmpty { deletionLog.forget(gone) }
        let byID = Dictionary(logged.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let items = alive.map { id, info -> DeletedItem in
            let known = candidates[id]
            return DeletedItem(
                id: id, title: info["title"] as? String ?? known?.title ?? "", deletedAt: known?.deletedAt,
                fromList: byID[id]?.listName, parentID: known?.parentID ?? info["parentId"] as? String,
                completed: info["completed"] as? Bool ?? false)
        }
        return (items.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }, database != nil)
    }

    /// Restores a deleted reminder, with the subtasks deleted along with it, into `list` or the
    /// list it was deleted from (the default list when neither is known or the old one is gone).
    func restore(id: String, list nameOrID: String?) throws -> (restored: [ReminderInfo], list: ListInfo) {
        let (items, _) = try deleted()
        guard let item = items.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw StoreError("No restorable reminder with id \(id) in Recently Deleted. list_deleted shows what can be restored.")
        }
        let logged = deletionLog.entries().first { $0.id == item.id }
        let target: ListInfo
        if let nameOrID {
            target = try resolveList(nameOrID)
        } else if let logged, let original = try lists().first(where: { $0.id == logged.listID }) {
            target = original
        } else {
            target = try resolveList(defaultListID())
        }
        try checkWritable(target)
        let subtasks = items.filter { $0.parentID == item.id }
        let ids = [item.id] + subtasks.map(\.id)
        try withBridge { try $0.restoreReminders(ids, toList: target.id) }
        deletionLog.forget(Set(ids))
        // Put subtasks back under their parent if the restore left them at the top level.
        for subtask in subtasks {
            if let (restored, _) = try? reminder(subtask.id), restored.parentID == nil {
                try withBridge { try $0.updateReminder(subtask.id, changes: ["parentId": item.id]) }
            }
        }
        return (ids.compactMap { try? reminder($0).0 }, target)
    }

    // MARK: Lists

    /// `changes`: color (bridge dictionary), icon, group (name or id; NSNull for none), pinned,
    /// groceries, sorting, position ({after or before: list name or id}).
    private func listChanges(_ changes: [String: Any]) throws -> [String: Any] {
        var result = changes
        if let group = result.removeValue(forKey: "group") {
            if group is NSNull {
                result["groupId"] = NSNull()
            } else {
                let resolved = try resolveGroup(group as! String)
                try checkWritable(resolved.name)
                result["groupId"] = resolved.id
            }
        }
        if let position = result["position"] as? [String: String], let neighbor = position["after"] ?? position["before"] {
            result["position"] = [position["after"] != nil ? "after" : "before": try resolveList(neighbor).id]
        }
        return result
    }

    func createList(_ name: String, changes: [String: Any]) throws -> ListInfo {
        try checkWritable(name)
        if try lists().contains(where: { $0.name == name }) { throw StoreError("A list named \"\(name)\" already exists.") }
        let prepared = try listChanges(changes)
        let id = try withBridge { try $0.createList(named: name, changes: prepared) }
        return try resolveList(id)
    }

    /// `changes`: name, color, icon, group.
    func updateList(_ nameOrID: String, changes: [String: Any]) throws -> ListInfo {
        let list = try resolveList(nameOrID)
        try checkWritable(list)
        if let name = changes["name"] as? String, name != list.name {
            try checkWritable(name)
            if try lists().contains(where: { $0.name == name }) { throw StoreError("A list named \"\(name)\" already exists.") }
        }
        let prepared = try listChanges(changes)
        try withBridge { try $0.updateList(list.id, changes: prepared) }
        return try resolveList(list.id)
    }

    /// Deletes a list. One that still has reminders needs `withReminders`; they go to Recently
    /// Deleted first, so list_deleted and restore_reminder can bring them back to another list.
    func deleteList(_ nameOrID: String, withReminders: Bool) throws -> (list: ListInfo, deleted: Int) {
        let list = try resolveList(nameOrID)
        try checkWritable(list)
        if try defaultListID() == list.id { throw StoreError("\"\(list.name)\" is the default list and cannot be deleted.") }
        let reminders = try self.reminders(in: list.id)
        if !reminders.isEmpty && !withReminders {
            throw StoreError("\"\(list.name)\" still has \(reminders.count) reminders (including completed ones). Confirm with the user, then pass confirm_delete_reminders: true; they go to Recently Deleted.")
        }
        _ = try softDelete(reminders, from: list)
        try withBridge { try $0.deleteList(list.id) }
        return (list, reminders.count)
    }

    // MARK: Groups

    func createGroup(_ name: String) throws -> GroupInfo {
        try checkWritable(name)
        if try groups().contains(where: { $0.name == name }) { throw StoreError("A group named \"\(name)\" already exists.") }
        let id = try withBridge { try $0.createGroup(named: name) }
        return try resolveGroup(id)
    }

    func renameGroup(_ nameOrID: String, to name: String) throws -> GroupInfo {
        let group = try resolveGroup(nameOrID)
        try checkWritable(group.name)
        try checkWritable(name)
        if try groups().contains(where: { $0.name == name }) { throw StoreError("A group named \"\(name)\" already exists.") }
        try withBridge { try $0.renameGroup(group.id, to: name) }
        return try resolveGroup(group.id)
    }

    /// Only empty groups; move their lists out with manage_list first.
    func deleteGroup(_ nameOrID: String) throws -> GroupInfo {
        let group = try resolveGroup(nameOrID)
        try checkWritable(group.name)
        let members = try lists().filter { $0.groupID == group.id }
        if !members.isEmpty {
            throw StoreError("The group \"\(group.name)\" still has the lists \(members.map { "\"\($0.name)\"" }.joined(separator: ", ")); move them out with manage_list (group: null) first.")
        }
        try withBridge { try $0.deleteGroup(group.id) }
        return group
    }

    // MARK: Smart lists

    func smartLists() throws -> [SmartListInfo] {
        try withBridge { try $0.smartLists().map(SmartListInfo.init) }
    }

    func resolveSmartList(_ nameOrID: String) throws -> SmartListInfo {
        let all = try smartLists()
        if let found = all.first(where: { $0.id.caseInsensitiveCompare(nameOrID) == .orderedSame }) { return found }
        let named = all.filter { $0.name == nameOrID }
        if named.count == 1 { return named[0] }
        if named.isEmpty {
            throw StoreError("No smart list named \"\(nameOrID)\". Smart lists: \(all.isEmpty ? "none" : all.map { "\"\($0.name)\"" }.joined(separator: ", ")).")
        }
        throw StoreError("Several smart lists are named \"\(nameOrID)\"; pass one of these ids: \(named.map(\.id).joined(separator: ", ")).")
    }

    /// `changes`: filter (stored JSON), color (bridge dictionary), icon.
    func createSmartList(_ name: String, changes: [String: Any]) throws -> SmartListInfo {
        try checkWritable(name)
        if try smartLists().contains(where: { $0.name == name }) { throw StoreError("A smart list named \"\(name)\" already exists.") }
        let id = try withBridge { try $0.createSmartList(named: name, changes: changes) }
        return try resolveSmartList(id)
    }

    /// `changes`: name, filter, color, icon.
    func updateSmartList(_ nameOrID: String, changes: [String: Any]) throws -> SmartListInfo {
        let smartList = try resolveSmartList(nameOrID)
        try checkWritable(smartList.name)
        if let name = changes["name"] as? String, name != smartList.name {
            try checkWritable(name)
            if try smartLists().contains(where: { $0.name == name }) { throw StoreError("A smart list named \"\(name)\" already exists.") }
        }
        try withBridge { try $0.updateSmartList(smartList.id, changes: changes) }
        return try resolveSmartList(smartList.id)
    }

    /// A smart list only shows reminders, so deleting it deletes none.
    func deleteSmartList(_ nameOrID: String) throws -> SmartListInfo {
        let smartList = try resolveSmartList(nameOrID)
        try checkWritable(smartList.name)
        try withBridge { try $0.deleteSmartList(smartList.id) }
        return smartList
    }

    // MARK: Sections

    func createSection(_ name: String, in nameOrID: String) throws -> (SectionInfo, ListInfo) {
        let list = try resolveList(nameOrID)
        try checkWritable(list)
        if list.sections.contains(where: { $0.name == name }) { throw StoreError("\"\(list.name)\" already has a section \"\(name)\".") }
        let id = try withBridge { try $0.createSection(named: name, inList: list.id) }
        let updated = try resolveList(list.id)
        return (try resolveSection(id, in: updated), updated)
    }

    func renameSection(_ section: String, in nameOrID: String, to name: String) throws -> (SectionInfo, ListInfo) {
        let list = try resolveList(nameOrID)
        try checkWritable(list)
        let found = try resolveSection(section, in: list)
        try withBridge { try $0.renameSection(found.id, inList: list.id, to: name) }
        let updated = try resolveList(list.id)
        return (try resolveSection(found.id, in: updated), updated)
    }

    /// Deleting a section keeps its reminders; they stay in the list without a section.
    func deleteSection(_ section: String, in nameOrID: String) throws -> (SectionInfo, ListInfo) {
        let list = try resolveList(nameOrID)
        try checkWritable(list)
        let found = try resolveSection(section, in: list)
        try withBridge { try $0.deleteSection(found.id, inList: list.id) }
        return (found, list)
    }
}

// MARK: - Detail, images, tags, templates, ordering

extension RemindersStore {
    /// One reminder with its early reminders, which the list fetch leaves out.
    func detail(_ id: String) throws -> (ReminderInfo, ListInfo) {
        let (_, list) = try reminder(id)
        let raw = try withBridge { try $0.reminderDetail(id) }
        return (ReminderInfo(raw), list)
    }

    /// The bytes of an image attachment. Reminders keeps them in its own container, so this needs
    /// Full Disk Access for the app.
    func imageData(reminder id: String, image imageID: String) throws -> (Data, ImageInfo) {
        let (reminder, _) = try reminder(id)
        guard let image = reminder.images.first(where: { $0.id.caseInsensitiveCompare(imageID) == .orderedSame }) else {
            throw StoreError("\"\(reminder.title)\" has no image \(imageID); get_reminder lists its images.")
        }
        guard let path = image.path, let data = FileManager.default.contents(atPath: path) else {
            throw StoreError("Reading images needs Full Disk Access for Apple Reminders MCP (System Settings → Privacy & Security → Full Disk Access); Reminders keeps them in its own folder.")
        }
        return (data, image)
    }

    /// Every tag in use, with how many open and how many reminders in all have it.
    func tags() throws -> [(name: String, open: Int, total: Int)] {
        var counts: [String: (name: String, open: Int, total: Int)] = [:]
        for list in try lists() {
            for reminder in try reminders(in: list.id) {
                for tag in reminder.tags {
                    var entry = counts[tag.lowercased()] ?? (tag, 0, 0)
                    entry.total += 1
                    if !reminder.completed { entry.open += 1 }
                    counts[tag.lowercased()] = entry
                }
            }
        }
        return counts.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Renames a tag everywhere, or with nil removes it; returns how many reminders changed.
    func replaceTag(_ tag: String, with replacement: String?) throws -> Int {
        if let writeGuard {
            for list in try lists() where !writeGuard.contains(list.name) {
                if try reminders(in: list.id).contains(where: { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }) {
                    throw StoreError("Reminders outside \(writeGuard.sorted().map { "\"\($0)\"" }.joined(separator: ", ")) have this tag (APPLE_REMINDERS_MCP_WRITE_GUARD).")
                }
            }
        }
        return try withBridge { try $0.replaceTag(tag, with: replacement).intValue }
    }

    func templates() throws -> [TemplateInfo] {
        try withBridge { try $0.templates().map { TemplateInfo(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "") } }
    }

    func resolveTemplate(_ nameOrID: String) throws -> TemplateInfo {
        let all = try templates()
        if let found = all.first(where: { $0.id.caseInsensitiveCompare(nameOrID) == .orderedSame }) { return found }
        let named = all.filter { $0.name == nameOrID }
        if named.count == 1 { return named[0] }
        if named.isEmpty {
            throw StoreError("No template named \"\(nameOrID)\". Templates: \(all.isEmpty ? "none" : all.map { "\"\($0.name)\"" }.joined(separator: ", ")).")
        }
        throw StoreError("Several templates are named \"\(nameOrID)\"; pass one of these ids: \(named.map(\.id).joined(separator: ", ")).")
    }

    /// Reminders copies the list into the template in the background, so it can take a moment
    /// to show its reminders.
    func createTemplate(_ name: String, from nameOrID: String, includeCompleted: Bool) throws -> TemplateInfo {
        let list = try resolveList(nameOrID)
        try checkWritable(name)
        let id = try withBridge { try $0.createTemplate(named: name, fromList: list.id, includeCompleted: includeCompleted) }
        return (try? resolveTemplate(id)) ?? TemplateInfo(id: id, name: name)
    }

    func createList(fromTemplate nameOrID: String, name: String?) throws -> ListInfo {
        let template = try resolveTemplate(nameOrID)
        try checkWritable(name ?? template.name)
        let id = try withBridge { try $0.createList(fromTemplate: template.id, name: name) }
        return try resolveList(id)
    }

    func deleteTemplate(_ nameOrID: String) throws -> TemplateInfo {
        let template = try resolveTemplate(nameOrID)
        try checkWritable(template.name)
        try withBridge { try $0.deleteTemplate(template.id) }
        return template
    }

    func moveSection(_ section: String, in nameOrID: String, relativeTo other: String, after: Bool) throws -> ListInfo {
        let list = try resolveList(nameOrID)
        try checkWritable(list)
        let moving = try resolveSection(section, in: list)
        let anchor = try resolveSection(other, in: list)
        if moving.id == anchor.id { throw StoreError("A section cannot move next to itself.") }
        try withBridge { try $0.moveSection(moving.id, inList: list.id, relativeTo: anchor.id, after: after) }
        return try resolveList(list.id)
    }

    /// Moves a list's completed reminders to Recently Deleted; returns how many.
    func clearCompleted(in nameOrID: String) throws -> (list: ListInfo, count: Int) {
        let list = try resolveList(nameOrID)
        try checkWritable(list)
        let done = try reminders(in: list.id).filter(\.completed)
        _ = try softDelete(done, from: list)
        return (list, done.count)
    }
}
