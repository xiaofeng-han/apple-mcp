import Agents
import AppKit
import SwiftUI

/// The AI assistants on this Mac, for the settings window: which are installed, whether each one
/// starts this server, and one click to install or set one up. Looked up when the window opens.
@MainActor
final class AgentsState: ObservableObject {
    /// Text in both of the window's languages.
    typealias Message = (english: String, chinese: String)

    enum Activity {
        case idle
        case working(Message)
        /// What failed (in both languages) and the error.
        case failed(Message, String)
        case done(Message)
    }

    struct Row: Identifiable {
        let agent: Agent
        /// nil while looking.
        var presence: Presence?
        var registration: Registration?
        var activity = Activity.idle
        var id: String { agent.id }

        var isWorking: Bool {
            if case .working = activity { return true }
            return false
        }
    }

    @Published private(set) var installation: Installation?
    @Published private(set) var rows = Agent.all.map { Row(agent: $0) }
    @Published private(set) var looking = false
    private let language: () -> Language

    init(language: @escaping () -> Language) {
        self.language = language
        refresh()
    }

    var isWorking: Bool { looking || rows.contains(where: \.isWorking) }

    /// Looks again for this copy's install, the agents, and their configs.
    func refresh() {
        guard !looking else { return }
        looking = true
        Task {
            // Reading the login shell's environment takes a moment; do it here, not in the view.
            installation = await Task.detached { _ = Shell.path; return Installation.detect() }.value
            await withTaskGroup(of: (String, Presence).self) { group in
                for agent in Agent.all { group.addTask { (agent.id, agent.locate()) } }
                for await (id, presence) in group { update(id) { $0.presence = presence } }
            }
            readConfigs()
            looking = false
        }
    }

    func readConfigs() {
        guard let installation else { return }
        var read: [ConfigTarget: Registration] = [:]
        for index in rows.indices {
            guard let target = rows[index].agent.target else { continue }
            let registration = read[target] ?? target.registration(for: installation)
            read[target] = registration
            rows[index].registration = registration
        }
    }

    private func update(_ id: String, _ change: (inout Row) -> Void) {
        if let index = rows.firstIndex(where: { $0.id == id }) { change(&rows[index]) }
    }

    private func text(_ english: String, _ chinese: String) -> String {
        language() == .chinese ? chinese : english
    }

    func setUp(_ id: String) async {
        guard let installation, let row = rows.first(where: { $0.id == id }), let presence = row.presence else { return }
        let agent = row.agent
        let mayQuit = agent.mustQuit
        if mayQuit, !confirmQuit(agent) { return }
        update(id) { $0.activity = .working(("Setting up…", "正在配置…")) }
        do {
            try await agent.setUp(installation, presence: presence, mayQuit: mayQuit)
            readConfigs()
            update(id) { $0.activity = .done(Self.hint(agent, restarted: mayQuit)) }
        } catch {
            readConfigs()
            update(id) { $0.activity = .failed(("Setting up failed:", "配置失败："), Self.describe(error)) }
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? ConfigError)?.description ?? error.localizedDescription
    }

    /// What the user does next for the agent to load the server.
    static func hint(_ agent: Agent, restarted: Bool) -> Message {
        switch agent.reload {
        case .newSession:
            return ("New sessions will have it.", "新开的会话即可使用。")
        case .restart where agent.isOpen:
            return ("Restart \(agent.name) to load it.", "重启 \(agent.name) 后生效。")
        case .restart, .quitFirst:
            return restarted ? ("\(agent.name) was restarted with it.", "已重启 \(agent.name) 并加载。")
                : ("\(agent.name) loads it when it opens.", "\(agent.name) 下次打开时加载。")
        }
    }

    private func confirmQuit(_ agent: Agent) -> Bool {
        let alert = NSAlert()
        alert.messageText = text("Quit \(agent.name) to set it up?", "退出 \(agent.name) 来配置？")
        alert.informativeText = text(
            "\(agent.name) writes its settings back from memory, so it has to be closed while the server is added. It opens again afterwards. Sessions running in its Code tab stop.",
            "\(agent.name) 会把内存里的设置写回文件，所以添加服务器时它得关着，之后会自动重新打开。Code 标签页里正在运行的会话会停下。")
        alert.addButton(withTitle: text("Quit and Set Up", "退出并配置"))
        alert.addButton(withTitle: text("Cancel", "取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Installs the agent, then sets it up.
    func install(_ id: String) async {
        guard let installation, let agent = rows.first(where: { $0.id == id })?.agent, let installer = agent.installer(for: installation) else { return }
        update(id) { $0.activity = .working(("Installing…", "正在安装…")) }
        do {
            try await installer.run { output in
                guard let line = output.split(whereSeparator: \.isNewline).last?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return }
                Task { @MainActor in self.update(id) { $0.activity = .working((line, line)) } }
            }
        } catch {
            update(id) { $0.activity = .failed(("Installing failed:", "安装失败："), Self.describe(error)) }
            return
        }
        let presence = await Task.detached { agent.locate() }.value
        update(id) { $0.presence = presence }
        guard presence != .absent else {
            update(id) { $0.activity = .failed(("Installing failed:", "安装失败："), "the installer finished, but \(agent.name) is not where it was expected") }
            return
        }
        readConfigs()
        guard agent.target != nil, rows.first(where: { $0.id == id })?.registration != .current else {
            update(id) { $0.activity = .done(("Installed.", "已安装。")) }
            return
        }
        await setUp(id)
    }

    /// Sets up every installed agent that is not set up yet, each config once.
    func setUpAll() async {
        var done = Set<ConfigTarget>()
        for row in rows where Self.canSetUp(row) {
            guard let target = row.agent.target, done.insert(target).inserted else { continue }
            await setUp(row.id)
        }
    }

    var needsSetUp: Bool { rows.contains(where: Self.canSetUp) }

    /// Installed, able to use the server, and not set up in a way this app leaves alone.
    static func canSetUp(_ row: Row) -> Bool {
        guard row.presence?.path != nil, row.agent.target != nil else { return false }
        switch row.registration {
        case .current, .notEditable, nil: return false
        default: return true
        }
    }
}

struct AgentsView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var agents: AgentsState

    var body: some View {
        Form {
            Section {
                LabeledContent(state.text("Installed", "安装方式")) {
                    Text(agents.installation.map(method) ?? state.text("Looking…", "正在检测…"))
                }
                if let installation = agents.installation {
                    LabeledContent(state.text("Command", "命令")) {
                        Text(([installation.command] + installation.arguments).joined(separator: " "))
                            .font(.caption.monospaced()).textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                HStack {
                    Text("Apple Reminders MCP")
                    Spacer()
                    if agents.looking { ProgressView().controlSize(.small) }
                    Button(state.text("Refresh", "刷新")) { agents.refresh() }.disabled(agents.isWorking)
                }
            } footer: {
                if agents.installation?.method == .other {
                    Text(state.text(
                        "This copy was not installed from a release, so agents will start it where it is now.",
                        "这份副本不是从正式版本安装的，AI 助手会从它现在的位置启动它。"))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(vendors, id: \.self) { vendor in
                Section(vendor) {
                    ForEach(agents.rows.filter { $0.agent.vendor == vendor }) { row in
                        AgentRow(row: row, state: state, agents: agents)
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button(state.text("Set Up All", "全部配置")) { Task { await agents.setUpAll() } }
                        .disabled(agents.isWorking || !agents.needsSetUp)
                }
            } footer: {
                Text(state.text(
                    "Set Up adds the server \"apple-reminders\" to the assistant's own settings file, and turns it on if the assistant had turned it off. Nothing else in the file changes. Before the first change of a day, the old file is kept next to it as <name>.bak-<date>-apple-reminders-mcp.",
                    "「配置」会把服务器 apple-reminders 加进该助手自己的设置文件；如果助手把它关掉了，也会重新打开。文件里的其他内容不变。每天第一次修改前，旧文件会备份在旁边，名为 <文件名>.bak-<日期>-apple-reminders-mcp。"))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    var vendors: [String] {
        var seen = Set<String>()
        return Agent.all.map(\.vendor).filter { seen.insert($0).inserted }
    }

    func method(_ installation: Installation) -> String {
        switch installation.method {
        case .homebrew: state.text("With Homebrew", "用 Homebrew 安装")
        case .package(let allUsers): allUsers ? state.text("From the package, for all users", "用安装包安装（所有用户）")
            : state.text("From the package, for you", "用安装包安装（仅自己）")
        case .other: state.text("Not from a release", "非正式版本")
        }
    }
}

struct AgentRow: View {
    let row: AgentsState.Row
    @ObservedObject var state: PanelState
    @ObservedObject var agents: AgentsState

    var body: some View {
        LabeledContent {
            action
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.agent.name)
                    Text(row.agent.kind == .app ? "App" : "CLI")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let note = row.agent.note {
                    Text(state.text(note.0, note.1)).font(.caption).foregroundStyle(.secondary)
                }
                switch row.activity {
                case .idle: EmptyView()
                case .working(let message): Text(state.text(message.english, message.chinese)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                case .done(let message): Text(state.text(message.english, message.chinese)).font(.caption).foregroundStyle(.secondary)
                case .failed(let what, let error):
                    Text(state.text(what.english, what.chinese) + " " + error)
                        .font(.caption).foregroundStyle(.red).lineLimit(4).textSelection(.enabled).help(error)
                }
            }
        }
    }

    var detail: String? {
        switch row.presence {
        case nil: return nil
        case .absent: return state.text("Not installed", "未安装")
        case .installed(let path, let version):
            return [version, Shell.abbreviate(path)].compactMap { $0 }.joined(separator: " · ")
        }
    }

    @ViewBuilder var action: some View {
        let busy = agents.isWorking
        if row.presence == nil || row.isWorking {
            ProgressView().controlSize(.small)
        } else if row.presence == .absent {
            if let installation = agents.installation, let installer = row.agent.installer(for: installation) {
                Button(state.text("Install", "安装")) { Task { await agents.install(row.id) } }
                    .disabled(busy).help(installer.summary)
            } else {
                let requirement = row.agent.installRequirement
                Text(state.text(requirement.0, requirement.1)).font(.caption).foregroundStyle(.secondary)
            }
        } else if row.agent.target == nil {
            Text(state.text("Not supported", "不支持")).foregroundStyle(.secondary)
        } else {
            switch row.registration {
            case nil: ProgressView().controlSize(.small)
            case .current:
                Label(state.text("Configured", "已配置"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .missing:
                Button(state.text("Set Up", "配置")) { Task { await agents.setUp(row.id) } }.disabled(busy)
            case .different(let command):
                Button(state.text("Update", "更新")) { Task { await agents.setUp(row.id) } }.disabled(busy)
                    .help(command.isEmpty ? state.text("Written in a form this app does not change", "写法不是本 App 能改的")
                          : state.text("Now starts: \(command)", "现在启动的是：\(command)"))
            case .broken(let command):
                Button(state.text("Repair", "修复")) { Task { await agents.setUp(row.id) } }.disabled(busy)
                    .help(state.text("\(command) does not exist", "\(command) 不存在"))
            case .disabled:
                Button(state.text("Turn On", "打开")) { Task { await agents.setUp(row.id) } }.disabled(busy)
                    .help(state.text("The server is turned off in its settings", "服务器在它的设置里被关掉了"))
            case .unreadable(let error):
                Label(state.text("Can't Read Settings", "读不了设置"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).help(error)
            case .notEditable(let reason):
                Label(state.text("Set Up by Hand", "已手动配置"), systemImage: "hand.raised.fill")
                    .foregroundStyle(.secondary).help(reason)
            }
        }
    }
}
