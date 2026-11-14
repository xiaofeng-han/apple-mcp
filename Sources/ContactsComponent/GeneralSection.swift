import AppCore
import AppKit
import Carbon
import Combine
import Contacts
import SwiftUI

/// The two permissions this app needs: Contacts, and Automation → Contacts (notes and group members go
/// through Contacts' AppleScript).
enum ContactsPermissions {
    enum State: Equatable {
        case granted, denied, notAsked
        /// Contacts is not running, so Automation cannot be checked.
        case unknown
    }

    static let contactsSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!
    static let automationSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    static func automation(ask: Bool) -> State {
        var target = AEAddressDesc()
        let id = Array(ContactsScript.bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, id, id.count, &target) == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .unknown
        }
    }

    /// Starts Contacts hidden, so Automation can be checked and asked for.
    @MainActor static func startContactsHidden() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: ContactsScript.bundleID).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ContactsScript.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Asks for Automation → Contacts (macOS shows its prompt if the user has not decided yet).
    @MainActor static func askForAutomation() async -> State {
        startContactsHidden()
        var state = State.unknown
        for _ in 0..<20 where state == .unknown {
            state = await Task.detached { automation(ask: true) }.value
            if state == .unknown { try? await Task.sleep(for: .milliseconds(250)) }
        }
        return state
    }
}

/// The permissions, for the settings window's General tab; looked at again every second.
@MainActor
final class ContactsAccessState: ObservableObject {
    @Published private(set) var contacts = CNContactStore.authorizationStatus(for: .contacts)
    @Published private(set) var automation = ContactsPermissions.automation(ask: false)
    @Published private(set) var asking = false
    private var poll: AnyCancellable?

    init() {
        poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.asking else { return }
                self.contacts = CNContactStore.authorizationStatus(for: .contacts)
                let automation = ContactsPermissions.automation(ask: false)
                if automation != .unknown || self.automation == .notAsked { self.automation = automation }
            }
        }
    }

    func requestContacts() {
        Task {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
            contacts = CNContactStore.authorizationStatus(for: .contacts)
        }
    }

    func requestAutomation() {
        asking = true
        Task {
            automation = await ContactsPermissions.askForAutomation()
            asking = false
        }
    }
}

struct ContactsGeneralSection: View {
    @ObservedObject var panel: PanelState
    @StateObject private var state = ContactsAccessState()

    var body: some View {
        let allowed = Label(panel.text("Allowed", "已允许"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        Section {
            LabeledContent(panel.text("Contacts", "通讯录")) {
                switch state.contacts {
                case .authorized: allowed
                case .notDetermined: Button(panel.text("Allow Access…", "允许访问…")) { state.requestContacts() }
                default:
                    Button(panel.text("System Settings…", "系统设置…")) { NSWorkspace.shared.open(ContactsPermissions.contactsSettings) }
                }
            }
            LabeledContent(panel.text("Automation → Contacts", "自动化 → 通讯录")) {
                switch state.automation {
                case .granted: allowed
                case .denied:
                    Button(panel.text("System Settings…", "系统设置…")) { NSWorkspace.shared.open(ContactsPermissions.automationSettings) }
                case .notAsked, .unknown:
                    if state.asking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(panel.text("Allow…", "允许…")) { state.requestAutomation() }
                    }
                }
            }
        } header: {
            Text(panel.text("Permissions", "权限"))
        } footer: {
            Text(panel.text(
                "The permissions belong to this app and are shared by every AI assistant. Contacts is read and written through Apple's Contacts framework; notes and group members go through Contacts itself (Automation), because macOS keeps notes from apps without Apple's notes entitlement. Changes sync through iCloud.",
                "权限记在这个 App 名下，所有 AI 助手共用。通讯录通过苹果的 Contacts 框架读写；备注和分组成员通过「通讯录」App 本身（自动化）读写，因为 macOS 不让没有苹果备注授权的 App 访问备注。改动会经 iCloud 同步。"))
                .foregroundStyle(.secondary)
        }
    }
}
