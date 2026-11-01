import Agents
import AppCore
import AppKit
import Foundation
import JournalModel
import JournalShared
import Launcher
import NoteModel
import SwiftUI
import Wire

/// Apple Journal MCP on the shared base (see AppCore's Component).
@MainActor
public final class JournalComponent: Component {
    nonisolated public static let product = JournalTools.product

    nonisolated public static let cli = JournalCommands.cli

    /// APPLE_JOURNAL_MCP_WRITE_GUARD: while set (development and checks), only entries titled with
    /// this prefix, and journals named with it, may be changed.
    let writeGuard: String?
    let store: JournalStore
    public let tools: [Tool]

    public init(_ context: ComponentContext) {
        writeGuard = context.writeGuard
        store = JournalStore(writeGuard: context.writeGuard)
        tools = readTools(store) + writeTools(store)
    }

    public let instructions = """
        Apple's Journal app on this Mac, synced through iCloud. overview lists the journals and insights; \
        find_entries finds entries (by words, journal, date, bookmark or kind of attachment), read_entry reads \
        them as Markdown with their attachments' details, and read_attachment opens a photo, video or recording. \
        Every change to an entry (edit_entry, delete_entry) passes back the version read_entry or find_entries \
        gave, and an entry changed since is refused. Entry text is Markdown: **bold**, *italic*, <u>underline</u>, \
        ~~strike~~, * and - lists, 1. numbered, > quote; keep ![…](attachment:…) placeholders where they are. \
        Dates are local: 2026-10-21T09:30, or 2026-10-21. Deleted entries stay 30 days in Recently Deleted \
        (find_entries with deleted: true); restore_entry brings one back. Journal entries are private: share \
        what they say only as the user asks.
        """

    nonisolated public static let chineseToolTitles = JournalTools.chineseTitles

    public var modes: [String: @MainActor @Sendable ([String]) async -> Int32] {
        ["--check-markdown": { [self] _ in checkMarkdown() }]
    }

    public func setup() async -> Int32 {
        if let problem = Compatibility.problem {
            print(problem)
            return 1
        }
        guard Permissions.hasData else {
            print(Permissions.noDataHelp)
            return 1
        }
        print("Full Disk Access:", Permissions.fullDiskAccess ? "allowed" : "not allowed")
        guard Permissions.fullDiskAccess else {
            print("\n" + Permissions.fullDiskHelp)
            NSWorkspace.shared.open(Permissions.fullDiskSettings)
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            return 1
        }
        return 0
    }

    public func selfCheck() async -> [String] {
        var lines = [
            "Journal: " + (Permissions.journalVersion.map { "version \($0)" } ?? "not found")
                + (Compatibility.missing.isEmpty ? ", supported" : ", not supported (\(Compatibility.missing.count) of \(JournalSymbols.all.count) functions missing)"),
            "Full Disk Access: " + (Permissions.fullDiskAccess ? "allowed" : "not allowed"),
        ]
        if launcher_is_sandboxed() != 0 { lines.append("Sandbox: yes, so macOS keeps Journal out of reach; run this outside the sandbox") }
        if Compatibility.missing.isEmpty, Permissions.fullDiskAccess {
            do {
                let entries = try store.entryObjects(deleted: nil)
                let journals = try store.journalObjects().filter { !$0.isDefaultJournal }
                lines.append("Journal data: OK, \(entries.count) entries in \(journals.count) journals besides the default one")
                lines.append("iCloud: " + (store.syncsWithICloud() ? "on" : "off"))
            } catch {
                lines.append("Journal data: \(error)")
            }
        }
        return lines
    }

    public var writeGuardDescription: String? { writeGuard.map { "\"\($0)\"" } }

    public func generalSection(_ panel: PanelState) -> AnyView {
        AnyView(JournalGeneralSection(panel: panel))
    }

    /// `--check-markdown`: every entry read, written as Markdown and parsed back, must come out the
    /// same as far as Journal can hold it; what does not is listed. Reads only. Worth running after
    /// a macOS update.
    func checkMarkdown() -> Int32 {
        do {
            var checked = 0, differ: [String] = []
            for object in try store.entryObjects(deleted: nil) {
                checked += 1
                let info = store.info(object)
                let (markdown, _) = store.markdown(object)
                let original: NSAttributedString
                if JournalStore.isLegacy(object) {
                    original = EntryText.fromRTF(object.value(forKey: "text") as? Data).map(EntryText.canonical(legacy:)) ?? NSAttributedString()
                } else if let text = object.mergeableAttributedText {
                    original = EntryText.canonical(text).0
                } else {
                    continue
                }
                let back = try EntryText.canonical(Markdown.parse(markdown))
                if EntryText.Edit(old: original, new: EntryText.keepingLineEnds(of: original, in: back)) != nil {
                    differ.append("\(info.id) \(info.title.isEmpty ? Output.day(info.date) : info.title)")
                }
            }
            print("\(checked) entries read; \(differ.count) do not read back the same from Markdown" + (differ.isEmpty ? "." : ":"))
            for line in differ.prefix(20) { print("  " + line) }
            return differ.isEmpty ? 0 : 1
        } catch {
            print("Journal data:", error)
            return 1
        }
    }
}
