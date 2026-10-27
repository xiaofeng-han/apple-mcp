import AppCore
import AppKit
import Combine
import EventKit
import SwiftUI

/// The permissions and the setting, for the settings window's General tab; the permissions are
/// looked at again every second.
@MainActor
final class RemindersAccessState: ObservableObject {
    static let remindersPrivacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!
    static let fullDiskPrivacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    @Published private(set) var reminders = EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var fullDisk = DeletedDatabase.available
    @Published private(set) var completesRepeating = AppSettings.allowCompletingRecurring
    private var poll: AnyCancellable?

    init() {
        // Permissions change in System Settings, outside this app; look again every second.
        poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reminders = EKEventStore.authorizationStatus(for: .reminder)
                self?.fullDisk = DeletedDatabase.available
            }
        }
    }

    var completesRepeatingBinding: Binding<Bool> {
        Binding(get: { self.completesRepeating }, set: { value in
            AppSettings.setAllowCompletingRecurring(value)
            self.completesRepeating = value
        })
    }

    func requestReminders() {
        Task {
            _ = try? await EKEventStore().requestFullAccessToReminders()
            reminders = EKEventStore.authorizationStatus(for: .reminder)
        }
    }
}

/// The General tab's permissions (Reminders, and Full Disk Access, which is optional) and setting.
struct RemindersGeneralSection: View {
    @ObservedObject var panel: PanelState
    @StateObject private var state = RemindersAccessState()

    var body: some View {
        let allowed = Label(panel.text("Allowed", "已允许"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        Section {
            LabeledContent(panel.text("Reminders", "提醒事项")) {
                switch state.reminders {
                case .fullAccess: allowed
                case .notDetermined: Button(panel.text("Allow Access…", "允许访问…")) { state.requestReminders() }
                default:
                    Button(panel.text("Open in System Settings…", "在系统设置中打开…")) {
                        NSWorkspace.shared.open(RemindersAccessState.remindersPrivacy)
                    }
                }
            }
            LabeledContent(panel.text("Full Disk Access (optional)", "完全磁盘访问（可选）")) {
                if state.fullDisk {
                    allowed
                } else {
                    HStack {
                        Button(panel.text("Show in Finder", "在访达中显示")) {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                        Button(panel.text("System Settings…", "系统设置…")) { NSWorkspace.shared.open(RemindersAccessState.fullDiskPrivacy) }
                    }
                }
            }
        } header: {
            Text(panel.text("Permissions", "权限"))
        } footer: {
            Text(panel.text(
                "The permissions belong to this app and are shared by every AI assistant. Full Disk Access is only used for reading: to list everything in Recently Deleted and to read images on reminders. Everything else works without it.",
                "权限记在这个 App 名下，所有 AI 助手共用。完全磁盘访问只用来读：列出「最近删除」里的全部提醒，以及读取提醒上的图片；不开也能正常使用。"))
                .foregroundStyle(.secondary)
        }
        Section {
            Toggle(panel.text("Allow AI assistants to complete repeating reminders", "允许 AI 助手勾完成重复提醒"),
                   isOn: state.completesRepeatingBinding)
        } header: {
            Text(panel.text("Settings", "设置"))
        } footer: {
            Text(panel.text(
                "When a repeating reminder is completed, Reminders keeps a completed copy and moves the reminder to its next date. With this off, AI assistants ask you to check it off in the app yourself.",
                "勾完成时，「提醒事项」会留下一条已完成的记录，并把提醒推到下一次。关闭后，AI 助手会请你自己在 App 里勾。"))
                .foregroundStyle(.secondary)
        }
    }
}
