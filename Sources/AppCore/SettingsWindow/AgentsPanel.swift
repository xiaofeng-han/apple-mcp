import Agents
import AppKit
import SwiftUI

/// The AI assistants on this Mac, for the settings window: which are installed, whether each one
/// starts this server (or has the skill, in skill mode), and one click to install or set one up.
/// Looked up when the window opens.
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

    /// What Set Up writes: the server's entry in the assistant's settings, or the skill.
    enum Mode { case server, skill }

    struct Row: Identifiable {
        let agent: Agent
        /// nil while looking.
        var presence: Presence?
        var registration: Registration?
        /// The skill, in `folder` or the agent's own skills folder.
        var skill: Registration?
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
    @Published var mode = Mode.server {
        didSet { clearMessages() }
    }
    /// The project folder skills go in; nil puts them in each assistant's own skills folder.
    @Published private(set) var folder: URL?
    private let language: () -> Language
    /// The skill for a copy of the app.
    private let skill: (Installation) -> String

    init(skill: @escaping (Installation) -> String, language: @escaping () -> Language) {
        self.skill = skill
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
        let skill = self.skill(installation)
        var read: [ConfigTarget: Registration] = [:]
        var skills: [String: Registration] = [:]
        for index in rows.indices {
            let agent = rows[index].agent
            if let target = agent.target {
                let registration = read[target] ?? target.registration(for: installation)
                read[target] = registration
                rows[index].registration = registration
            }
            if let target = agent.skills {
                let file = target.file(project: folder).path
                let registration = skills[file] ?? target.registration(of: skill, project: folder)
                skills[file] = registration
                rows[index].skill = registration
            }
        }
    }

    /// The row's state in the current mode.
    func status(_ row: Row) -> Registration? {
        mode == .server ? row.registration : row.skill
    }

    /// Asks for the project folder skills go in.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = text("Choose", "选择")
        panel.message = text("Choose the project folder for the skill.", "选择要放技能的项目文件夹。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url)
    }

    func setFolder(_ url: URL?) {
        folder = url
        clearMessages()
        readConfigs()
    }

    /// Messages about the last action belong to the mode and folder it was done in.
    private func clearMessages() {
        for index in rows.indices where !rows[index].isWorking { rows[index].activity = .idle }
    }

    private func update(_ id: String, _ change: (inout Row) -> Void) {
        if let index = rows.firstIndex(where: { $0.id == id }) { change(&rows[index]) }
    }

    private func text(_ english: String, _ chinese: String) -> String {
        language() == .chinese ? chinese : english
    }

    func setUp(_ id: String) async {
        guard mode == .server else { return setUpSkill(id) }
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

    /// Writes the skill where the agent reads it.
    func setUpSkill(_ id: String) {
        guard let installation, let target = rows.first(where: { $0.id == id })?.agent.skills else { return }
        update(id) { $0.activity = .working(("Setting up…", "正在配置…")) }
        do {
            try target.install(self.skill(installation), project: folder)
            readConfigs()
            update(id) { $0.activity = .done(("New sessions will have it.", "新开的会话即可使用。")) }
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
        guard let row = rows.first(where: { $0.id == id }), canSetUp(row) else {
            update(id) { $0.activity = .done(("Installed.", "已安装。")) }
            return
        }
        await setUp(id)
    }

    /// Sets up every installed agent that is not set up yet, each config or skill file once.
    func setUpAll() async {
        var done = Set<String>()
        for row in rows where canSetUp(row) {
            let file = mode == .server ? row.agent.target?.rawValue : row.agent.skills?.file(project: folder).path
            guard let file, done.insert(file).inserted else { continue }
            await setUp(row.id)
        }
    }

    var needsSetUp: Bool { rows.contains { canSetUp($0) } }

    /// Installed, able to use the server (or, for the skill, to run commands), and not set up in a
    /// way this app leaves alone.
    func canSetUp(_ row: Row) -> Bool {
        guard row.presence?.path != nil, (mode == .server ? row.agent.target != nil : row.agent.skills != nil) else { return false }
        switch status(row) {
        case .current, .notEditable, nil: return false
        default: return true
        }
    }
}

struct AgentsView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var agents: AgentsState
    let product = Product.current

    var body: some View {
        Form {
            Section {
                LabeledContent(state.text("Installed", "安装方式")) {
                    Text(agents.installation.map(method) ?? state.text("Looking…", "正在检测…"))
                }
                if let installation = agents.installation {
                    LabeledContent(state.text("Command", "命令")) {
                        Text(([installation.command] + (agents.mode == .server ? installation.arguments : [])).joined(separator: " "))
                            .font(.caption.monospaced()).textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                HStack {
                    Text(Product.current.name)
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
            Section {
                Picker(state.text("Set Up As", "配置方式"), selection: $agents.mode) {
                    Text(state.text("MCP Server", "MCP 服务器")).tag(AgentsState.Mode.server)
                    Text(state.text("Skill", "技能")).tag(AgentsState.Mode.skill)
                }
                .pickerStyle(.segmented)
                .disabled(agents.isWorking)
                if agents.mode == .skill {
                    LabeledContent(state.text("Folder", "文件夹")) {
                        HStack {
                            Text(agents.folder.map { Shell.abbreviate($0.path) } ?? state.text("All projects", "所有项目"))
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button(state.text("Choose…", "选择…")) { agents.chooseFolder() }.disabled(agents.isWorking)
                            if agents.folder != nil {
                                Button(state.text("All Projects", "所有项目")) { agents.setFolder(nil) }.disabled(agents.isWorking)
                            }
                        }
                    }
                }
            } footer: {
                Text(agents.mode == .server
                     ? state.text("The assistant starts this app as an MCP server, so its tools are always at hand.",
                                  "助手把本 App 当作 MCP 服务器启动，工具随时可用。")
                     : state.text(
                        "A skill teaches the assistant to run the \(product.command) command when \(product.subject.lowercased()) come up, instead of starting a server. Without a folder it goes in the assistant's own skills folder and works in every project; with one, only in that project (in .claude/skills for Claude, .agents/skills for the others).",
                        "技能会教助手在用到\(product.chineseSubject)时运行 \(product.command) 命令，而不是启动服务器。不选文件夹时，它放在助手自己的技能文件夹里，所有项目都能用；选了文件夹，就只在那个项目里可用（Claude 用 .claude/skills，其他助手用 .agents/skills）。"))
                    .foregroundStyle(.secondary)
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
                Text(agents.mode == .server
                     ? state.text(
                        "Set Up adds the server \"\(product.serverName)\" to the assistant's own settings file, and turns it on if the assistant had turned it off. Nothing else in the file changes. Before the first change of a day, the old file is kept next to it as <name>.bak-<date>-\(product.command).",
                        "「配置」会把服务器 \(product.serverName) 加进该助手自己的设置文件；如果助手把它关掉了，也会重新打开。文件里的其他内容不变。每天第一次修改前，旧文件会备份在旁边，名为 <文件名>.bak-<日期>-\(product.command)。")
                     : state.text(
                        "Set Up writes \(product.serverName)/SKILL.md, which names the command above. Assistants that read the same folder share one file. A skill of that name that this app did not write is left alone.",
                        "「配置」会写入 \(product.serverName)/SKILL.md，其中写明上面的命令。读同一个文件夹的助手共用一个文件。同名但不是本 App 写的技能不会被改动。"))
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
                if let note = agents.mode == .skill ? row.agent.skillNote ?? row.agent.note : row.agent.note {
                    Text(state.text(note.0, note.1)).font(.caption).foregroundStyle(.secondary)
                }
                if let also {
                    Text(also).font(.caption).foregroundStyle(.secondary)
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

    /// That the other way is set up too.
    var also: String? {
        switch agents.mode {
        case .server: row.skill == .current ? state.text("Also set up as a skill.", "也已配置为技能。") : nil
        case .skill: row.registration == .current ? state.text("Also set up as an MCP server.", "也已配置为 MCP 服务器。") : nil
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
        } else if agents.mode == .server ? row.agent.target == nil : row.agent.skills == nil {
            Text(state.text("Not supported", "不支持")).foregroundStyle(.secondary)
        } else {
            let skill = agents.mode == .skill
            // For a skill, where it is.
            let file = skill ? row.agent.skills.map { Shell.abbreviate($0.file(project: agents.folder).path) } ?? "" : ""
            switch agents.status(row) {
            case nil: ProgressView().controlSize(.small)
            case .current:
                Label(state.text("Configured", "已配置"), systemImage: "checkmark.circle.fill").foregroundStyle(.green).help(file)
            case .missing:
                Button(state.text("Set Up", "配置")) { Task { await agents.setUp(row.id) } }.disabled(busy).help(file)
            case .different(let command):
                Button(state.text("Update", "更新")) { Task { await agents.setUp(row.id) } }.disabled(busy)
                    .help(skill ? (command == agents.installation?.command
                                   ? state.text("Written by another version of this app: \(file)", "由本 App 的其他版本写入：\(file)")
                                   : state.text("Written for another copy, \(command): \(file)", "为另一份副本写入（\(command)）：\(file)"))
                          : command.isEmpty ? state.text("Written in a form this app does not change", "写法不是本 App 能改的")
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
                Label(skill ? state.text("Another Skill", "已有同名技能") : state.text("Set Up by Hand", "已手动配置"), systemImage: "hand.raised.fill")
                    .foregroundStyle(.secondary).help(reason)
            }
        }
    }
}
