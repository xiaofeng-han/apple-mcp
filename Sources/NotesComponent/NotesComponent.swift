import Agents
import AppCore
import AppKit
import Foundation
import Launcher
import NoteModel
import SwiftUI
import Wire

/// Apple Notes MCP on the shared base (see AppCore's Component).
@MainActor
public final class NotesComponent: Component {
    nonisolated public static let product = Product(name: "Apple Notes MCP", bundleID: "com.xiaofeng.apple-notes-mcp", appName: "AppleNotesMCP",
                                        command: "apple-notes-mcp", serverName: "apple-notes", environmentPrefix: "APPLE_NOTES_MCP",
                                        subject: "Notes", chineseSubject: "备忘录")

    /// APPLE_NOTES_MCP_WRITE_GUARD: while set (development and checks), only notes titled with this
    /// prefix, and folders named with it, may be changed.
    let writeGuard: String?
    let store: NotesStore
    public let tools: [Tool]

    public init(_ context: ComponentContext) {
        writeGuard = context.writeGuard
        store = NotesStore(writeGuard: context.writeGuard)
        tools = readTools(store, Descriptions()) + attachmentTools(store) + writeTools(store)
    }

    public let instructions = """
        Apple Notes on this Mac, synced through iCloud. Find notes with overview or search, then read_note; \
        every change (edit_note, move_note, delete_note) passes back the version they gave, and a note changed \
        since is refused. Make all changes to one note in a single edit_note call. Each note paragraph is one \
        Markdown line: # title, ## heading, ### subheading, * and - lists, 1. numbered, - [ ] / - [x] checkboxes, \
        > quote, two spaces per indent level, ``` monospaced, **bold**, *italic*, ~~strike~~, <u>underline</u>, \
        <mark>highlight</mark>, [link](url), | tables |, #tag, [text](note:id) a link to a note, --- a divider. \
        Keep ![…](attachment:…) placeholders where they are; ![name](/path/to/file) attaches a file. Deleted \
        notes stay 30 days in Recently Deleted (overview folder "Recently Deleted"). To describe many notes: \
        overview with undescribed: true, then one describe_note call.
        """

    nonisolated public static let chineseToolTitles = [
        "create_note": "新建笔记",
        "delete_note": "删除笔记",
        "describe_note": "给笔记写简介",
        "edit_note": "修改笔记",
        "manage_folder": "新建、重命名、删除或导出文件夹",
        "manage_tag": "重命名或删除标签",
        "move_note": "移动笔记",
        "overview": "笔记概览",
        "read_attachment": "读取附件",
        "read_note": "读取笔记",
        "search": "搜索笔记",
    ]

    public var modes: [String: @MainActor @Sendable ([String]) async -> Int32] {
        ["--copy-note": { [self] words in copyNote(words) }, "--check-markdown": { [self] _ in checkMarkdown() },
         "--list-json": { [self] words in listJSON(words) }]
    }

    static func describe(_ state: Permissions.State) -> String {
        switch state {
        case .granted: "allowed"
        case .denied: "denied"
        case .notAsked: "not asked yet"
        case .unknown: "unknown (Notes is not running)"
        }
    }

    public func setup() async -> Int32 {
        print("Full Disk Access:", Permissions.fullDiskAccess ? "allowed" : "not allowed")
        var automation = Permissions.automation(ask: false)
        if automation != .granted && automation != .denied {
            print("Asking to control Notes; click OK in the dialog (it may be behind other windows).")
            Permissions.startNotesHidden()
            for _ in 0..<20 {
                automation = await Task.detached { Permissions.automation(ask: true) }.value
                if automation != .unknown { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        print("Automation → Notes:", Self.describe(automation))
        if !Permissions.fullDiskAccess {
            print("\n" + Permissions.fullDiskHelp)
            NSWorkspace.shared.open(Permissions.fullDiskSettings)
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
        if automation == .denied { print("\n" + Permissions.automationHelp) }
        return Permissions.fullDiskAccess && automation == .granted ? 0 : 1
    }

    public func selfCheck() async -> [String] {
        var lines = [
            "Full Disk Access: " + (Permissions.fullDiskAccess ? "allowed" : "not allowed"),
            "Automation → Notes: " + Self.describe(Permissions.automation(ask: false)),
        ]
        if launcher_is_sandboxed() != 0 { lines.append("Sandbox: yes, so macOS keeps Notes out of reach; run this outside the sandbox") }
        do {
            let folders = try NotesStore(writeGuard: nil).folders()
            lines.append("Notes data: OK, \(folders.reduce(0) { $0 + $1.noteCount }) notes in \(folders.count) folders")
        } catch {
            lines.append("Notes data: \(error)")
        }
        return lines
    }

    public var writeGuardDescription: String? { writeGuard.map { "\"\($0)\"" } }

    public func generalSection(_ panel: PanelState) -> AnyView {
        AnyView(NotesGeneralSection(panel: panel))
    }

    /// `--check-markdown`: every note read, written as Markdown and parsed back, must come out the
    /// same; what does not is listed. Reads only. Worth running after a macOS update.
    func checkMarkdown() -> Int32 {
        do {
            var checked = 0, differ: [String] = []
            for note in try store.notes(inFolders: nil) + store.recentlyDeletedNotes().map(\.note) where !note.locked {
                let blocks = try store.blocks(note.id)
                checked += 1
                let back = Markdown.parse(Markdown.render(blocks))
                guard back != blocks else { continue }
                let line = zip(back, blocks).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(back.count, blocks.count)
                differ.append("\(ShortID.of(note.id)) \(note.title): line \(line + 1)")
            }
            print("\(checked) notes read; \(differ.count) do not read back the same from Markdown" + (differ.isEmpty ? "." : ":"))
            for line in differ.prefix(20) { print("  " + line) }
            return differ.isEmpty ? 0 : 1
        } catch {
            print("Notes data:", error)
            return 1
        }
    }

    /// `--list-json [QUERY]`, for editor pickers (see ListJSON).
    func listJSON(_ words: [String]) -> Int32 {
        ListJSON.run(words, from: store, write: { print($0) }, fail: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
    }

    /// `--copy-note NOTE [FOLDER]`, run by create_note's copy_of: prints the copy's id.
    func copyNote(_ words: [String]) -> Int32 {
        guard words.count >= 2 else { return 2 }
        do {
            print(try store.copyHere(words[1], into: words.count > 2 ? words[2] : nil))
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }
    }
}
