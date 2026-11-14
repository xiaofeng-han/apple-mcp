import Agents
import AppCore
import Contacts
import ContactsModel
import Foundation
import Launcher
import SwiftUI
import Wire

/// Apple Contacts MCP on the shared base (see AppCore's Component).
@MainActor
public final class ContactsComponent: Component {
    nonisolated public static let product = ContactsTools.product
    nonisolated public static let cli = ContactsCommands.cli
    nonisolated public static let chineseToolTitles = ContactsTools.chineseTitles

    let writeGuard: WriteGuard?
    let store: ContactsStore
    public let tools: [Tool]

    public init(_ context: ComponentContext) {
        writeGuard = WriteGuard(context.writeGuard)
        store = ContactsStore(writeGuard: writeGuard)
        tools = readTools(store) + writeTools(store)
    }

    public var instructions: String {
        """
        Apple Contacts on this Mac, synced through iCloud (and Google, Exchange, …) to the user's devices. \
        find_contacts searches as Contacts does (every word anywhere on the card, the note included); \
        read_contact reads contacts in full with the version update_contact and delete_contact take, and a \
        contact changed since is refused. A contact may be linked cards from several accounts: writes go to \
        its cards, never copy values between accounts, and read_contact lists the cards. Lists (phones, \
        emails, …) are replaced whole; null clears a field. Contacts has no Recently Deleted: delete_contact \
        reaches every device, so ask the user first; this app keeps a copy for 30 days (restore_contact). \
        Groups hold cards of their own account and can be nested; smart lists fill themselves from rules and \
        stay on this Mac. Never invent contact details the user did not give, and confirm before changing the \
        My Card, merging or deleting.
        """
    }

    nonisolated public static func skill(run: String) -> SkillText { ContactsSkill.text(run: run) }

    /// `authorize` is another name for `setup`.
    public var modes: [String: @MainActor @Sendable ([String]) async -> Int32] {
        ["authorize": { [self] _ in await setup() }]
    }

    public func setup() async -> Int32 {
        var status = CNContactStore.authorizationStatus(for: .contacts)
        print("Contacts access:", ContactsStore.describe(status))
        if status == .notDetermined {
            print("Asking for access; click Allow in the dialog (it may be behind other windows).")
            _ = try? await CNContactStore().requestAccess(for: .contacts)
            status = CNContactStore.authorizationStatus(for: .contacts)
            print("Contacts access:", ContactsStore.describe(status))
        } else if status != .authorized {
            print(ContactsStore.permissionHelp)
        }
        var automation = ContactsPermissions.automation(ask: false)
        if automation != .granted {
            print("Asking to control Contacts (for notes and group members); click OK in the dialog.")
            automation = await ContactsPermissions.askForAutomation()
        }
        print("Automation → Contacts:", Self.describe(automation))
        if automation == .denied { print(ContactsScript.automationHelp) }
        return status == .authorized && automation == .granted ? 0 : 1
    }

    static func describe(_ state: ContactsPermissions.State) -> String {
        switch state {
        case .granted: "allowed"
        case .denied: "denied"
        case .notAsked: "not asked yet"
        case .unknown: "unknown (Contacts is not running)"
        }
    }

    public func selfCheck() async -> [String] {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        var lines = ["Contacts access: " + ContactsStore.describe(status),
                     "Automation → Contacts: " + Self.describe(ContactsPermissions.automation(ask: false))]
        if launcher_is_sandboxed() != 0 { lines.append("Sandbox: yes, so macOS keeps Contacts out of reach; run this outside the sandbox") }
        guard status == .authorized else { return lines }
        do {
            let overview = try store.overview()
            let accounts = overview["accounts"]?.array?.map { "\($0["name"]?.string ?? "?") (\($0["cards"]?.int ?? 0))" }.joined(separator: ", ") ?? ""
            lines.append("Contacts data: OK, \(overview["contacts"]?.int ?? 0) contacts (\(overview["cards"]?.int ?? 0) cards) in \(accounts); \(overview["groups"]?.int ?? 0) groups, \(overview["smart_lists"]?.int ?? 0) smart lists")
        } catch {
            lines.append("Contacts data: \(error)")
        }
        let deleted = store.deletedBackups().count
        if deleted > 0 { lines.append("Deleted by this app in the last 30 days: \(deleted) (restore_contact)") }
        return lines
    }

    public var writeGuardDescription: String? { writeGuard.map { "names starting with " + $0.description } }

    public func generalSection(_ panel: PanelState) -> AnyView {
        AnyView(ContactsGeneralSection(panel: panel))
    }
}
