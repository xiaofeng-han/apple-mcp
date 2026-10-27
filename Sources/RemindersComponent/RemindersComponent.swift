import Agents
import AppCore
import EventKit
import Foundation
import Launcher
import SwiftUI
import Wire

/// Apple Reminders MCP on the shared base (see AppCore's Component).
@MainActor
public final class RemindersComponent: Component {
    nonisolated public static let product = Product(name: "Apple Reminders MCP", bundleID: "com.xiaofeng.apple-reminders-mcp", appName: "AppleRemindersMCP",
                                        command: "apple-reminders-mcp", serverName: "apple-reminders", environmentPrefix: "APPLE_REMINDERS_MCP",
                                        subject: "Reminders", chineseSubject: "提醒事项")

    /// APPLE_REMINDERS_MCP_WRITE_GUARD: comma-separated names of the only lists, groups, smart lists
    /// and templates writes may touch (for development and checks).
    let writeGuard: Set<String>?
    let store: RemindersStore
    public let tools: [Tool]

    public init(_ context: ComponentContext) {
        writeGuard = context.writeGuard.flatMap { value in
            let names = Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            return names.isEmpty ? nil : names
        }
        store = RemindersStore(writeGuard: writeGuard)
        tools = readTools(store) + writeTools(store) + organizeTools(store)
    }

    public var instructions: String {
        """
        Apple Reminders on this Mac, synced through iCloud to the user's devices. find_reminders and \
        list_lists read; pass a reminder's id and version to update_reminder or delete_reminder. Times are \
        local to \(TimeZone.current.identifier): due and start take 2026-10-21 (all day) or 2026-10-21T09:00, \
        and a due time adds an alert then. urgent makes that alert ring like an alarm and needs a due time; \
        repeat and early_alerts need a due date. Tags are native, written without #. Subtasks are one level \
        deep (parent_id); sections divide a list. Lists marked shared are seen by other people: confirm \
        with the user before adding to or changing them, and assign with assigned_to. Deleted reminders \
        go to Recently Deleted; list_deleted and restore_reminder bring them back.
        """
    }

    nonisolated public static let chineseToolTitles = [
        "create_reminder": "新建提醒",
        "delete_reminder": "删除提醒",
        "find_reminders": "查找提醒",
        "get_reminder": "读取一条提醒",
        "list_deleted": "列出最近删除的提醒",
        "list_lists": "列出提醒清单",
        "list_tags": "列出标签",
        "manage_group": "新建、重命名或删除清单分组",
        "manage_list": "新建、修改或删除清单",
        "manage_section": "新建、重命名、移动或删除分区",
        "manage_smart_list": "新建、修改或删除智能清单",
        "manage_tag": "重命名或删除标签",
        "manage_template": "存为、使用或删除清单模板",
        "read_image": "查看提醒上的图片",
        "restore_reminder": "恢复已删除的提醒",
        "update_reminder": "修改提醒",
    ]

    /// `authorize` is another name for `setup`.
    public var modes: [String: @MainActor @Sendable ([String]) async -> Int32] {
        ["authorize": { [self] _ in await setup() }]
    }

    static func describe(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: "full access"
        case .notDetermined: "not asked yet"
        case .denied: "denied"
        case .restricted: "restricted"
        case .writeOnly: "write only"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }

    public func setup() async -> Int32 {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        print("Reminders access:", Self.describe(status))
        if status == .notDetermined {
            print("Asking for access; click Allow in the dialog (it may be behind other windows).")
            let granted = (try? await EKEventStore().requestFullAccessToReminders()) ?? false
            print(granted ? "Access granted." : "Access was not granted.")
        } else if status != .fullAccess {
            print(RemindersStore.permissionHelp)
        }
        return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess ? 0 : 1
    }

    public func selfCheck() async -> [String] {
        var lines = ["Reminders access: " + Self.describe(EKEventStore.authorizationStatus(for: .reminder))]
        if launcher_is_sandboxed() != 0 { lines.append("Sandbox: yes, so macOS keeps Reminders out of reach; run this outside the sandbox") }
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            do {
                let lists = try store.lists()
                let total = try lists.reduce(0) { $0 + (try store.reminders(in: $1.id).count) }
                lines.append("Reminders data: OK, \(total) reminders in \(lists.count) lists")
            } catch {
                lines.append("Reminders data: \(error)")
            }
        }
        lines.append("Full Disk Access (optional): " + (DeletedDatabase.available ? "yes" : "no"))
        lines.append("Agents may complete repeating reminders: " + (AppSettings.allowCompletingRecurring ? "yes" : "no"))
        return lines
    }

    public var writeGuardDescription: String? { writeGuard.map { $0.sorted().map { "\"\($0)\"" }.joined(separator: ", ") } }

    public func generalSection(_ panel: PanelState) -> AnyView {
        AnyView(RemindersGeneralSection(panel: panel))
    }
}
