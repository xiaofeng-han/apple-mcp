import Agents
import Foundation
import Wire

/// What agents see of a tool: its name, title, description, input and effect. The tools themselves
/// (JournalComponent) add what each one does; the specs are here so the tests can check them and the
/// commands against each other without Journal.
package struct ToolSpec: Sendable {
    package let name: String
    package let title: String
    package let summary: String
    package let input: JSON
    package let effect: Tool.Effect

    package init(_ name: String, title: String, summary: String, input: JSON, effect: Tool.Effect) {
        self.name = name
        self.title = title
        self.summary = summary
        self.input = input
        self.effect = effect
    }
}

extension Tool {
    package init(_ spec: ToolSpec, run: @escaping @Sendable ([String: JSON]) async throws -> ToolAnswer) {
        self.init(spec.name, title: spec.title, summary: spec.summary, input: spec.input, effect: spec.effect, run: run)
    }
}

/// What Markdown can be in an entry, for the tools' descriptions.
package let markdownHelp = """
    Markdown, one paragraph per line: **bold**, *italic*, <u>underline</u>, ~~strike~~, * or - lists, 1. \
    numbered, two spaces per indent level, > quote.
    """

package enum JournalTools {
    /// Apple Journal MCP's identity (see Agents' Product).
    package static let product = Product(name: "Apple Journal MCP", bundleID: "com.xiaofeng.apple-journal-mcp", appName: "AppleJournalMCP",
                                    command: "apple-journal-mcp", serverName: "apple-journal", environmentPrefix: "APPLE_JOURNAL_MCP",
                                    subject: "Journal", chineseSubject: "手记")

    /// The tools' titles in Chinese, for the Tools tab.
    package static let chineseTitles = [
        "create_entry": "新建手记",
        "delete_entry": "删除手记",
        "duplicate_entry": "复制手记",
        "edit_entry": "修改手记",
        "export_entries": "导出手记",
        "find_entries": "查找手记",
        "manage_journal": "新建、修改或删除手记本",
        "overview": "手记概览",
        "read_attachment": "读取附件",
        "read_entry": "读取手记",
        "restore_entry": "恢复已删除的手记",
    ]

    package static let overview = ToolSpec("overview", title: "Journal overview",
        summary: """
            The journals (with their colors, icons and how many entries each holds), how many entries there \
            are in all, bookmarked and in Recently Deleted, and the insights Journal shows: days journaled and \
            daily and weekly streaks.
            """,
        input: Schema.object([:]), effect: .reads)

    package static let findEntries = ToolSpec("find_entries", title: "Find journal entries",
        summary: """
            Finds entries, newest first: by words (in the title, the text, the writing prompt, and the places, \
            people, songs, transcripts and handwriting of attachments), journal, bookmark, date and kind of \
            attachment. Each comes with its id and version, a snippet and its attachments by kind. after is \
            inclusive, before exclusive.
            """,
        input: Schema.object([
            "query": Schema.text("Words that must all appear"),
            "journal": Schema.text("Only entries in this journal (name or id)"),
            "bookmarked": Schema.flag("Only bookmarked entries"),
            "after": Schema.text("2026-10-21: entries dated that day or later"),
            "before": Schema.text("2026-10-21: entries dated before that day"),
            "attachments": Schema.list(of: ["type": "string", "enum": .array((AssetDetails.kinds.map(\.name) + ["any", "none"]).map { .string($0) })],
                                       "Only entries with an attachment of one of these kinds; any, or none"),
            "deleted": Schema.flag("Look in Recently Deleted instead"),
            "sort": Schema.choice(["newest", "oldest", "edited"], "Default newest (by the entry's date); edited: most recently changed first"),
            "limit": Schema.whole("Default 50, at most 500"),
            "offset": Schema.whole("Skip this many, for the next page"),
        ]), effect: .reads)

    package static let readEntry = ToolSpec("read_entry", title: "Read journal entries",
        summary: """
            Reads entries in full: the text as Markdown, the date, journal, bookmark, writing prompt, and each \
            attachment's details (places, State of Mind, workouts, music, a recording's transcript, …), with \
            the version edit_entry and delete_entry take. ![…](attachment:id) placeholders mark attachments \
            placed in the text; read_attachment opens any attachment.
            """,
        input: Schema.object([
            "id": Schema.text("Entry id"),
            "ids": Schema.texts("Several entries, up to 20"),
        ]), effect: .reads)

    package static let readAttachment = ToolSpec("read_attachment", title: "Read an attachment",
        summary: """
            Opens one of an entry's attachments (its id from read_entry): photos, a frame of a video, audio \
            recordings (with Journal's transcript), and the details of places, State of Mind, workouts, music \
            and the rest.
            """,
        input: Schema.object([
            "id": Schema.text("Attachment id"),
            "text_only": Schema.flag("Only the details, no images or audio"),
        ], required: ["id"]), effect: .reads)

    package static let createEntry = ToolSpec("create_entry", title: "Create a journal entry",
        summary: """
            Creates an entry with a title and text (\(markdownHelp)), dated now or on date, in a journal, \
            bookmarked if asked. Journal uploads it to iCloud; the answer says whether it has yet.
            """,
        input: Schema.object([
            "title": Schema.text("The title; default none"),
            "body": Schema.text("The text, as Markdown"),
            "date": Schema.text("2026-10-21T09:30, or 2026-10-21; default now"),
            "journal": Schema.text("The journal to put it in (name or id); default none, so only All Entries shows it"),
            "bookmarked": Schema.flag("Bookmark it"),
        ]), effect: .writes)

    package static let editEntry = ToolSpec("edit_entry", title: "Edit a journal entry",
        summary: """
            Changes an entry in one call: its title, its text (body rewrites it all; replace swaps exact \
            Markdown from read_entry, pairs applied in order; append adds Markdown at the end), its date, \
            bookmark or journal. Only what changes is written; the rest keeps its formatting. An entry changed \
            since its version was read is refused.
            """,
        input: Schema.object([
            "id": Schema.text("Entry id"),
            "version": Schema.text("The version read_entry or find_entries gave"),
            "title": Schema.text("The new title; \"\" for none"),
            "body": Schema.text("The whole text, as Markdown"),
            "replace": Schema.list(of: Schema.object([
                "old": Schema.text("Exact Markdown; must be unique unless all"), "new": Schema.text("Markdown"),
                "all": Schema.flag("Replace every occurrence"),
            ], required: ["old", "new"]), "Replacements in the text"),
            "append": Schema.text("Markdown to add at the end of the text"),
            "date": Schema.text("2026-10-21T09:30, or 2026-10-21"),
            "bookmarked": Schema.flag("Bookmark (true) or not (false)"),
            "journal": Schema.text("Move it to this journal (name or id); \"\" takes it out of its journal"),
        ], required: ["id", "version"]), effect: .writes)

    package static let deleteEntry = ToolSpec("delete_entry", title: "Delete a journal entry",
        summary: """
            Moves an entry to Recently Deleted, where Journal keeps it for 30 days and restore_entry brings it \
            back. permanently deletes one already in Recently Deleted for good, on every device (ask the user \
            first). An entry changed since its version was read is refused.
            """,
        input: Schema.object([
            "id": Schema.text("Entry id"),
            "version": Schema.text("The version read_entry or find_entries gave"),
            "permanently": Schema.flag("Delete an entry in Recently Deleted for good"),
        ], required: ["id", "version"]), effect: .deletes)

    package static let restoreEntry = ToolSpec("restore_entry", title: "Restore a journal entry",
        summary: "Brings an entry back from Recently Deleted (find_entries with deleted: true lists them).",
        input: Schema.object(["id": Schema.text("Entry id")], required: ["id"]), effect: .writes)

    package static let duplicateEntry = ToolSpec("duplicate_entry", title: "Duplicate a journal entry",
        summary: "Copies an entry with its text, date, journal and attachments, as Journal's Duplicate does.",
        input: Schema.object(["id": Schema.text("Entry id")], required: ["id"]), effect: .writes)

    package static let manageJournal = ToolSpec("manage_journal", title: "Create, change or delete a journal",
        summary: """
            Creates a journal, changes one's name, color or icon, or deletes one. Deleting moves its entries to \
            another journal (move_entries_to), leaves them in All Entries only (the default), or with \
            delete_entries moves them to Recently Deleted too (ask the user first; expected_entries is how \
            many it holds). The default journal cannot be changed.
            """,
        input: Schema.object([
            "action": Schema.choice(["create", "update", "delete"], "What to do"),
            "journal": Schema.text("New journal name for create; journal name or id otherwise"),
            "new_name": Schema.text("update: the new name"),
            "color": Schema.text("#RRGGBB, or red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray"),
            "icon": Schema.text("An emoji, or an SF Symbol name such as book.closed"),
            "move_entries_to": Schema.text("delete: the journal to move its entries to (name or id)"),
            "delete_entries": Schema.flag("delete: move its entries to Recently Deleted too"),
            "expected_entries": Schema.whole("delete with delete_entries: how many entries it holds"),
        ], required: ["action", "journal"]), effect: .deletes)

    package static let exportEntries = ToolSpec("export_entries", title: "Export journal entries",
        summary: """
            Writes entries as Markdown files, one per entry, with their photos, videos and recordings, into a \
            new folder. Filters as find_entries: journal, bookmarked, after (inclusive), before (exclusive).
            """,
        input: Schema.object([
            "to": Schema.text("A new folder's path"),
            "journal": Schema.text("Only this journal (name or id)"),
            "bookmarked": Schema.flag("Only bookmarked entries"),
            "after": Schema.text("2026-10-21: entries dated that day or later"),
            "before": Schema.text("2026-10-21: entries dated before that day"),
        ], required: ["to"]), effect: .writes)

    package static let all = [overview, findEntries, readEntry, readAttachment, createEntry, editEntry, deleteEntry, restoreEntry, duplicateEntry, manageJournal, exportEntries]
}
