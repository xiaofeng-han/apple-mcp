import AppKit
import Combine
import EventKit
import SwiftUI

/// The window shown when the app is opened by hand: what it may access, and its one setting.
/// (Plain ObservableObject and Binding, no SwiftUI macros: the Command Line Tools ship without
/// the macro plugins.)
@MainActor
enum SettingsPanel {
    static let remindersPrivacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!
    static let fullDiskPrivacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static func show() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let state = PanelState()
        let window = NSWindow(contentViewController: NSHostingController(rootView: PanelView(state: state)))
        window.title = "Apple Reminders MCP"
        window.styleMask = [.titled, .closable]
        window.center()
        let closer = WindowCloser()
        window.delegate = closer
        window.makeKeyAndOrderFront(nil)
        app.activate()
        withExtendedLifetime((closer, state)) { app.run() }
    }

    final class WindowCloser: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) { NSApplication.shared.terminate(nil) }
    }
}

@MainActor
final class PanelState: ObservableObject {
    @Published private(set) var reminders = EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var fullDisk = DeletedDatabase.available
    @Published private(set) var completesRepeating = Settings.allowCompletingRecurring
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
            Settings.setAllowCompletingRecurring(value)
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

struct PanelView: View {
    @ObservedObject var state: PanelState

    var body: some View {
        Form {
            Section {
                LabeledContent("提醒事项") {
                    switch state.reminders {
                    case .fullAccess: Label("已允许", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    case .notDetermined: Button("允许访问…") { state.requestReminders() }
                    default:
                        Button("在系统设置中打开…") { NSWorkspace.shared.open(SettingsPanel.remindersPrivacy) }
                    }
                }
                LabeledContent("完全磁盘访问（可选）") {
                    if state.fullDisk {
                        Label("已允许", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        HStack {
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                            Button("系统设置…") { NSWorkspace.shared.open(SettingsPanel.fullDiskPrivacy) }
                        }
                    }
                }
            } header: {
                Text("权限")
            } footer: {
                Text("权限记在这个 App 名下，所有 AI 助手共用。完全磁盘访问只用来读：列出「最近删除」里的全部提醒，以及读取提醒上的图片；不开也能正常使用。")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("允许 AI 助手勾完成重复提醒", isOn: state.completesRepeatingBinding)
            } header: {
                Text("设置")
            } footer: {
                Text("勾完成时，「提醒事项」会留下一条已完成的记录，并把提醒推到下一次。关闭后，AI 助手会请你自己在 App 里勾。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
