import AppKit
import Combine
import EventKit
import SwiftUI

/// The window shown when the app is opened by hand: what it may access, and its settings, in
/// English or Chinese. (Plain ObservableObject and Binding, no SwiftUI macros: the Command Line
/// Tools ship without the macro plugins.)
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

/// The languages the window speaks. Without a choice it takes the first of them in the system's
/// preferred languages, and English when neither is there.
enum Language: String {
    case english = "en", chinese = "zh-Hans"

    static func resolve(_ choice: String?) -> Language {
        if let choice, let language = Language(rawValue: choice) { return language }
        let preferred = Bundle.preferredLocalizations(from: [english.rawValue, chinese.rawValue],
                                                      forPreferences: Locale.preferredLanguages)
        return preferred.first.flatMap(Language.init(rawValue:)) ?? .english
    }
}

@MainActor
final class PanelState: ObservableObject {
    @Published private(set) var reminders = EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var fullDisk = DeletedDatabase.available
    @Published private(set) var completesRepeating = Settings.allowCompletingRecurring
    @Published private(set) var languageChoice = Settings.interfaceLanguage
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

    var language: Language { Language.resolve(languageChoice) }

    /// The text in the window's language.
    func text(_ english: String, _ chinese: String) -> String {
        language == .chinese ? chinese : english
    }

    var completesRepeatingBinding: Binding<Bool> {
        Binding(get: { self.completesRepeating }, set: { value in
            Settings.setAllowCompletingRecurring(value)
            self.completesRepeating = value
        })
    }

    /// "system" or a Language raw value.
    var languageBinding: Binding<String> {
        Binding(get: { self.languageChoice ?? "system" }, set: { value in
            let choice = value == "system" ? nil : value
            Settings.setInterfaceLanguage(choice)
            self.languageChoice = choice
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
        let allowed = Label(state.text("Allowed", "已允许"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        Form {
            Section {
                LabeledContent(state.text("Reminders", "提醒事项")) {
                    switch state.reminders {
                    case .fullAccess: allowed
                    case .notDetermined: Button(state.text("Allow Access…", "允许访问…")) { state.requestReminders() }
                    default:
                        Button(state.text("Open in System Settings…", "在系统设置中打开…")) {
                            NSWorkspace.shared.open(SettingsPanel.remindersPrivacy)
                        }
                    }
                }
                LabeledContent(state.text("Full Disk Access (optional)", "完全磁盘访问（可选）")) {
                    if state.fullDisk {
                        allowed
                    } else {
                        HStack {
                            Button(state.text("Show in Finder", "在访达中显示")) {
                                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                            }
                            Button(state.text("System Settings…", "系统设置…")) { NSWorkspace.shared.open(SettingsPanel.fullDiskPrivacy) }
                        }
                    }
                }
            } header: {
                Text(state.text("Permissions", "权限"))
            } footer: {
                Text(state.text(
                    "The permissions belong to this app and are shared by every AI assistant. Full Disk Access is only used for reading: to list everything in Recently Deleted and to read images on reminders. Everything else works without it.",
                    "权限记在这个 App 名下，所有 AI 助手共用。完全磁盘访问只用来读：列出「最近删除」里的全部提醒，以及读取提醒上的图片；不开也能正常使用。"))
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(state.text("Allow AI assistants to complete repeating reminders", "允许 AI 助手勾完成重复提醒"),
                       isOn: state.completesRepeatingBinding)
            } header: {
                Text(state.text("Settings", "设置"))
            } footer: {
                Text(state.text(
                    "When a repeating reminder is completed, Reminders keeps a completed copy and moves the reminder to its next date. With this off, AI assistants ask you to check it off in the app yourself.",
                    "勾完成时，「提醒事项」会留下一条已完成的记录，并把提醒推到下一次。关闭后，AI 助手会请你自己在 App 里勾。"))
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker(state.text("Language", "语言"), selection: state.languageBinding) {
                    Text(state.text("System Language", "跟随系统")).tag("system")
                    Text("English").tag(Language.english.rawValue)
                    Text("简体中文").tag(Language.chinese.rawValue)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
