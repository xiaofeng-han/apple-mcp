import Agents
import AppKit
import SwiftUI
import Wire

/// The tools AI assistants are offered, for the settings window's Tools tab: the user's choice in
/// tools.json, saved as soon as it changes. Read again whenever the file changes, from here or
/// elsewhere.
@MainActor
final class ToolsState: ObservableObject {
    /// By name, so the order never changes.
    let tools: [Tool]
    let exposure = Settings.exposure
    @Published private(set) var choices: [String: Bool] = [:]
    /// Why the file can't be read; no tool is offered then.
    @Published private(set) var unreadable: ToolExposure.Unreadable?
    @Published private(set) var saveError: String?
    private var watch: FileWatch?

    init(tools: [Tool]) {
        self.tools = tools.sorted { $0.name < $1.name }
        reload()
        watch = FileWatch(exposure.file) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        do {
            choices = try exposure.choices()
            unreadable = nil
        } catch {
            unreadable = error as? ToolExposure.Unreadable ?? ToolExposure.Unreadable(reason: .cannotOpen("\(error)"))
        }
    }

    func isOffered(_ tool: Tool) -> Bool {
        unreadable == nil && ToolExposure.exposes(tool, among: tools, choices: choices)
    }

    var offeredCount: Int { tools.filter(isOffered).count }

    func binding(_ tool: Tool) -> Binding<Bool> {
        Binding(get: { self.isOffered(tool) }, set: { value in
            self.choose { $0.name == tool.name ? value : self.isOffered($0) }
        })
    }

    /// Saves a choice for every tool, so the file names each one.
    func choose(_ offered: (Tool) -> Bool) {
        do {
            try exposure.save(Dictionary(uniqueKeysWithValues: tools.map { ($0.name, offered($0)) }))
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
        reload()
    }

    func isOnly(_ offered: (Tool) -> Bool) -> Bool {
        tools.allSatisfy { isOffered($0) == offered($0) }
    }

    static func readOnly(_ tool: Tool) -> Bool { tool.effect == .reads }
}

struct ToolsView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var tools: ToolsState

    var body: some View {
        Form {
            Section {
                ForEach(tools.tools, id: \.name) { tool in
                    ToolRow(tool: tool, state: state, isOn: tools.binding(tool))
                }
                .disabled(tools.unreadable != nil)
            } header: {
                Text(state.text("Tools AI assistants can use", "AI 助手可以用的工具"))
            } footer: {
                Text(state.text(
                    "Saved in \(Shell.abbreviate(tools.exposure.file.path)), so the choice stays through restarts and updates. Changes apply at once: a turned-off tool is refused even if an assistant listed it earlier, and running assistants are told to look again (some notice only in a new session, and ones started before this version need a restart). Tools added by later versions start on, unless you turned off another tool with the same label (Read-only, Writes or Can delete).",
                    "保存在 \(Shell.abbreviate(tools.exposure.file.path))，重启和更新后都保留。改动立即生效：关掉的工具即使助手之前列出过也会被拒绝调用，正在运行的助手会收到通知重新查看（有的要到新会话才会发现，这个版本之前启动的要重启）。以后版本新增的工具默认打开，除非你关掉了同一标签（只读、修改、可删除）的其他工具。"))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // The choices and the count stay in view while the list scrolls.
        .safeAreaInset(edge: .top, spacing: 0) { bar }
    }

    var bar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(state.text("All", "全选")) { tools.choose { _ in true } }
                    .disabled(tools.isOnly { _ in true }).help(state.text("Turn on every tool", "打开全部工具"))
                // While the file can't be read every tool shows off, but None still starts it over.
                Button(state.text("None", "全不选")) { tools.choose { _ in false } }
                    .disabled(tools.unreadable == nil && tools.isOnly { _ in false }).help(state.text("Turn off every tool", "关掉全部工具"))
                Button(state.text("Invert", "反选")) { tools.choose { !tools.isOffered($0) } }
                    .help(state.text("Turn on what is off, and off what is on", "开的关掉，关的打开"))
                Button(state.text("Read-Only", "只读")) { tools.choose(ToolsState.readOnly) }
                    .disabled(tools.unreadable == nil && tools.isOnly(ToolsState.readOnly))
                    .help(state.text("Turn on only the tools marked Read-only, and turn off the rest", "只开标着「只读」的工具，其余关掉"))
                Spacer()
                Text(state.text("\(tools.offeredCount) of \(tools.tools.count) offered", "已开放 \(tools.offeredCount) / \(tools.tools.count)"))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            if let unreadable = tools.unreadable {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.text("The file can't be read (\(unreadable)), so AI assistants get no tools. Choosing here starts over and keeps a copy of it.",
                                    "文件读不了（\(reason(unreadable))），所以 AI 助手拿不到任何工具。在这里重新选择会从头开始，并保留它的副本。"))
                        .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(state.text("Show in Finder", "在访达中显示")) {
                        NSWorkspace.shared.activateFileViewerSelecting([tools.exposure.file])
                    }
                }
            }
            if let saveError = tools.saveError {
                Text(state.text("Saving failed: \(saveError)", "保存失败：\(saveError)")).foregroundStyle(.red).textSelection(.enabled)
            }
            if tools.unreadable == nil && tools.offeredCount == 0 {
                Text(state.text("With no tools, AI assistants can't use Notes at all.", "一个工具都不开，AI 助手就完全用不了备忘录。"))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    func reason(_ unreadable: ToolExposure.Unreadable) -> String {
        switch unreadable.reason {
        case .empty: "文件是空的"
        case .notJSON: "不是有效的 JSON"
        case .wrongShape: #"格式应为 {"tools": {"工具名": true 或 false, …}}"#
        case .notTrueOrFalse(let name): "“\(name)” 的值应为 true 或 false"
        case .cannotOpen(let error): error
        }
    }
}

struct ToolRow: View {
    let tool: Tool
    @ObservedObject var state: PanelState
    let isOn: Binding<Bool>

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: isOn) {
                HStack(spacing: 8) {
                    Text(tool.name).font(.body.monospaced())
                    Spacer(minLength: 8)
                    Text(state.language == .chinese ? Self.chineseTitles[tool.name] ?? tool.title : tool.title)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .toggleStyle(.checkbox)
            effect.frame(width: 72, alignment: .trailing)
        }
        .help(tool.summary)
    }

    var effect: some View {
        let (english, chinese, color): (String, String, Color) = switch tool.effect {
        case .reads: ("Read-only", "只读", .secondary)
        case .writes: ("Writes", "修改", .orange)
        case .deletes: ("Can delete", "可删除", .red)
        }
        return Text(state.text(english, chinese))
            .font(.caption2).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }

    /// The tools' titles in Chinese; the English ones are what agents see.
    static let chineseTitles = [
        "create_note": "新建笔记",
        "delete_note": "删除笔记",
        "describe_note": "给笔记写简介",
        "edit_note": "修改笔记",
        "manage_folder": "新建、重命名、删除或导出文件夹",
        "move_note": "移动笔记",
        "overview": "笔记概览",
        "read_attachment": "读取附件",
        "read_note": "读取笔记",
        "search": "搜索笔记",
    ]
}
