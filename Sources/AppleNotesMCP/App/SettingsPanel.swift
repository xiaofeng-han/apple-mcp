import AppKit
import Combine
import SwiftUI
import Wire

/// The window shown when the app is opened by hand: the AI assistants it can be set up with, the
/// tools they are offered, and what it may access, in English or Chinese. (Plain ObservableObject
/// and Binding, no SwiftUI macros: the Command Line Tools ship without the macro plugins.)
///
/// The app is a regular app (no LSUIElement), so macOS brings the window to the front when it is
/// opened from Finder, Spotlight or `open`: an agent app is not given the foreground, and asking
/// for it afterwards (NSApp.activate) is only a request since macOS 14.
@MainActor
enum SettingsPanel {
    static func show(tools: [Tool]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let state = PanelState()
        let agents = AgentsState { [unowned state] in state.language }
        let toolsState = ToolsState(tools: tools)
        let window = NSWindow(contentViewController: NSHostingController(rootView: PanelView(state: state, agents: agents, tools: toolsState)))
        window.title = "Apple Notes MCP"
        window.styleMask = [.titled, .closable]
        window.center()
        let closer = WindowCloser(state: state, agents: agents)
        window.delegate = closer
        app.delegate = closer
        // Built again when the window's language changes; the publisher sends the new choice
        // before it is stored.
        let menu = state.$languageChoice.sink { choice in
            MainActor.assumeIsolated { app.mainMenu = mainMenu(Language.resolve(choice)) }
        }
        window.makeKeyAndOrderFront(nil)
        app.activate()
        withExtendedLifetime((closer, state, agents, toolsState, menu)) { app.run() }
    }

    /// The menu bar's app menu. Without it the app's name in the menu bar opens an empty menu and
    /// ⌘Q does nothing. Quit goes through applicationShouldTerminate, like closing the window.
    static func mainMenu(_ language: Language) -> NSMenu {
        func text(_ english: String, _ chinese: String) -> String { language == .chinese ? chinese : english }
        let name = "Apple Notes MCP"
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: text("Hide \(name)", "隐藏 \(name)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: text("Hide Others", "隐藏其他"), action: #selector(NSApplication.hideOtherApplications(_:)),
                        keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: text("Show All", "全部显示"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: text("Quit \(name)", "退出 \(name)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem()
        item.submenu = appMenu
        let bar = NSMenu()
        bar.addItem(item)
        return bar
    }

    /// Closing the window quits the app. Quitting while an agent is being installed or set up
    /// would cut it off halfway, so the user is asked first, however the app is quit.
    final class WindowCloser: NSObject, NSWindowDelegate, NSApplicationDelegate {
        let state: PanelState
        let agents: AgentsState
        private var confirmed = false

        init(state: PanelState, agents: AgentsState) {
            self.state = state
            self.agents = agents
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            MainActor.assumeIsolated { mayQuit() }
        }

        func windowWillClose(_ notification: Notification) { NSApplication.shared.terminate(nil) }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            MainActor.assumeIsolated { mayQuit() ? .terminateNow : .terminateCancel }
        }

        @MainActor
        private func mayQuit() -> Bool {
            guard !confirmed, agents.rows.contains(where: \.isWorking) else { return true }
            let alert = NSAlert()
            alert.messageText = state.text("Quit while an agent is being set up?", "AI 助手还在安装或配置，要退出吗？")
            alert.informativeText = state.text("Quitting now may leave its installation or settings unfinished.",
                                               "现在退出可能让安装或配置停在一半。")
            alert.addButton(withTitle: state.text("Keep Going", "继续"))
            alert.addButton(withTitle: state.text("Quit", "退出"))
            confirmed = alert.runModal() == .alertSecondButtonReturn
            return confirmed
        }
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
    @Published private(set) var fullDisk = Permissions.fullDiskAccess
    @Published private(set) var automation = Permissions.automation(ask: false)
    @Published private(set) var asking = false
    @Published private(set) var languageChoice = Settings.interfaceLanguage
    private var poll: AnyCancellable?

    init() {
        // Permissions change in System Settings, outside this app; look again every second.
        poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.asking else { return }
                self.fullDisk = Permissions.fullDiskAccess
                let automation = Permissions.automation(ask: false)
                // Without Notes running the answer is "unknown"; keep what was known.
                if automation != .unknown || self.automation == .notAsked { self.automation = automation }
            }
        }
    }

    var language: Language { Language.resolve(languageChoice) }

    /// The text in the window's language.
    func text(_ english: String, _ chinese: String) -> String {
        language == .chinese ? chinese : english
    }

    /// "system" or a Language raw value.
    var languageBinding: Binding<String> {
        Binding(get: { self.languageChoice ?? "system" }, set: { value in
            let choice = value == "system" ? nil : value
            Settings.setInterfaceLanguage(choice)
            self.languageChoice = choice
        })
    }

    /// Starts Notes hidden (Automation can only be asked for while it runs), then asks; macOS
    /// shows its prompt if the user has not decided yet.
    func askForAutomation() {
        asking = true
        Permissions.startNotesHidden()
        Task {
            var state = Permissions.State.unknown
            for _ in 0..<20 where state == .unknown {
                state = await Task.detached { Permissions.automation(ask: true) }.value
                if state == .unknown { try? await Task.sleep(for: .milliseconds(250)) }
            }
            automation = state
            asking = false
        }
    }
}

struct PanelView: View {
    enum Tab { case agents, tools, general }

    @ObservedObject var state: PanelState
    @ObservedObject var agents: AgentsState
    @ObservedObject var tools: ToolsState
    @State private var tab = Tab.agents

    var body: some View {
        TabView(selection: $tab) {
            AgentsView(state: state, agents: agents).tabItem { Text(state.text("AI Assistants", "AI 助手")) }.tag(Tab.agents)
            ToolsView(state: state, tools: tools).tabItem { Text(state.text("Tools", "工具")) }.tag(Tab.tools)
            GeneralView(state: state).tabItem { Text(state.text("General", "通用")) }.tag(Tab.general)
        }
        .frame(width: 580, height: 660)
    }
}

struct GeneralView: View {
    @ObservedObject var state: PanelState

    var body: some View {
        let allowed = Label(state.text("Allowed", "已允许"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        Form {
            Section {
                LabeledContent(state.text("Full Disk Access", "完全磁盘访问")) {
                    if state.fullDisk {
                        allowed
                    } else {
                        HStack {
                            Button(state.text("Show in Finder", "在访达中显示")) {
                                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                            }
                            Button(state.text("System Settings…", "系统设置…")) { NSWorkspace.shared.open(Permissions.fullDiskSettings) }
                        }
                    }
                }
                LabeledContent(state.text("Automation → Notes", "自动化 → 备忘录")) {
                    switch state.automation {
                    case .granted: allowed
                    case .denied:
                        Button(state.text("System Settings…", "系统设置…")) { NSWorkspace.shared.open(Permissions.automationSettings) }
                    case .notAsked, .unknown:
                        if state.asking {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(state.text("Allow…", "允许…")) { state.askForAutomation() }
                        }
                    }
                }
            } header: {
                Text(state.text("Permissions", "权限"))
            } footer: {
                Text(state.text(
                    "Full Disk Access lets the app read your notes; add Apple Notes MCP to the list in System Settings (Show in Finder, then drag it in, or click +). Automation lets it ask Notes to upload changes to iCloud and to move and delete notes and folders. The permissions belong to this app and are shared by every AI assistant.",
                    "完全磁盘访问用来读取备忘录：在系统设置的列表里加入 Apple Notes MCP（先「在访达中显示」再拖进去，或点 +）。自动化用来让「备忘录」把改动上传到 iCloud，以及移动、删除笔记和文件夹。权限记在这个 App 名下，所有 AI 助手共用。"))
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
    }
}
