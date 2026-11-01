import Foundation
import JournalShared
import NoteModel
import Wire

/// What Markdown can be in an entry, for the tools' descriptions.
let markdownHelp = """
    Markdown, one paragraph per line: **bold**, *italic*, <u>underline</u>, ~~strike~~, * or - lists, 1. \
    numbered, two spaces per indent level, > quote.
    """

func writeTools(_ store: JournalStore) -> [Tool] {
    [
        Tool("create_entry", title: "Create a journal entry",
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
             ]), effect: .writes) { fields in
            let input = Input(fields)
            var change = EntryChange()
            change.title = try input.rawText("title")
            change.body = try input.rawText("body").map(Markdown.parse)
            change.date = try input.entryDate("date")
            change.journal = try input.text("journal")
            change.bookmarked = try input.flag("bookmarked")
            if (change.title ?? "").isEmpty, (change.body.map { Markdown.render($0) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw BadInput("give a title or a body")
            }
            return try await withJournal(store) {
                let entry = try store.create(change)
                let uploaded = await store.waitForUpload([entry])
                return try written("Created.", store, entry, uploaded: uploaded)
            }
        },

        Tool("edit_entry", title: "Edit a journal entry",
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
             ], required: ["id", "version"]), effect: .writes) { fields in
            let input = Input(fields)
            let reference = try input.requiredText("id"), version = try input.requiredText("version")
            let body = try input.rawText("body")
            let pairs = try (input.objects("replace", keys: ["old", "new", "all"]) ?? []).map { pair in
                guard let old = try pair.rawText("old"), !old.isEmpty else { throw BadInput("replace.old must not be empty") }
                guard let new = try pair.rawText("new") else { throw BadInput("replace.new is required") }
                return (old: old, new: new, all: try pair.flag("all") ?? false)
            }
            let append = try input.text("append")
            if body != nil, !pairs.isEmpty || append != nil { throw BadInput("body rewrites the whole text; it cannot be combined with replace or append") }
            var change = EntryChange()
            change.title = try input.rawText("title")
            change.date = try input.entryDate("date")
            change.bookmarked = try input.flag("bookmarked")
            change.journal = try input.rawText("journal")
            if change.isEmpty, body == nil, pairs.isEmpty, append == nil {
                throw BadInput("give title, body, replace, append, date, bookmarked or journal")
            }
            return try await withJournal(store) {
                if let body {
                    change.body = Markdown.parse(body)
                } else if !pairs.isEmpty || append != nil {
                    var markdown = store.markdown(try store.entryObject(reference)).0
                    for (old, new, all) in pairs {
                        let count = markdown.components(separatedBy: old).count - 1
                        if count == 0 { throw JournalError.notFound("\"\(old)\" in the entry's text; read it again") }
                        if count > 1, !all { throw JournalError.refused("\"\(old)\" appears \(count) times; add text around it, or set all") }
                        markdown = markdown.replacingOccurrences(of: old, with: new)
                    }
                    if let append { markdown = markdown.trimmingCharacters(in: .newlines).isEmpty ? append : markdown + "\n" + append }
                    change.body = Markdown.parse(markdown)
                }
                let entry = try store.edit(reference, version: version, change)
                let uploaded = await store.waitForUpload([entry])
                return try written("Updated.", store, entry, uploaded: uploaded)
            }
        },

        Tool("delete_entry", title: "Delete a journal entry",
             summary: """
                 Moves an entry to Recently Deleted, where Journal keeps it for 30 days and restore_entry brings it \
                 back. permanently deletes one already in Recently Deleted for good, on every device (ask the user \
                 first). An entry changed since its version was read is refused.
                 """,
             input: Schema.object([
                 "id": Schema.text("Entry id"),
                 "version": Schema.text("The version read_entry or find_entries gave"),
                 "permanently": Schema.flag("Delete an entry in Recently Deleted for good"),
             ], required: ["id", "version"]), effect: .deletes) { fields in
            let input = Input(fields)
            let reference = try input.requiredText("id"), version = try input.requiredText("version")
            let permanently = try input.flag("permanently") ?? false
            return try await withJournal(store) {
                let entry = try store.delete(reference, version: version, permanently: permanently)
                let fields: [String: JSON] = ["id": .string(JournalStore.id(entry)), "title": .string(store.title(entry))]
                let uploaded = await store.waitForUpload([entry])
                return Output.written(permanently ? "Deleted for good." : "Moved to Recently Deleted.", fields, uploaded: uploaded)
            }
        },

        Tool("restore_entry", title: "Restore a journal entry",
             summary: "Brings an entry back from Recently Deleted (find_entries with deleted: true lists them).",
             input: Schema.object(["id": Schema.text("Entry id")], required: ["id"]), effect: .writes) { fields in
            let reference = try Input(fields).requiredText("id")
            return try await withJournal(store) {
                let entry = try store.restore(reference)
                let uploaded = await store.waitForUpload([entry])
                return try written("Restored.", store, entry, uploaded: uploaded)
            }
        },

        Tool("duplicate_entry", title: "Duplicate a journal entry",
             summary: "Copies an entry with its text, date, journal and attachments, as Journal's Duplicate does.",
             input: Schema.object(["id": Schema.text("Entry id")], required: ["id"]), effect: .writes) { fields in
            let reference = try Input(fields).requiredText("id")
            return try await withJournal(store) {
                let copy = try store.duplicate(reference)
                let uploaded = await store.waitForUpload([copy])
                return try written("Duplicated.", store, copy, uploaded: uploaded)
            }
        },

        Tool("manage_journal", title: "Create, change or delete a journal",
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
             ], required: ["action", "journal"]), effect: .deletes) { fields in
            let input = Input(fields)
            let action = try input.pick("action", from: ["create", "update", "delete"])!
            let reference = try input.requiredText("journal")
            let newName = try input.text("new_name")
            let color = try input.text("color").map { text in
                guard let color = Appearance.color(text) else { throw BadInput("color must be #RRGGBB or one of: " + Appearance.named.keys.sorted().joined(separator: ", ")) }
                return color
            }
            let icon = try input.text("icon").map { text in
                guard let icon = Appearance.icon(text) else { throw BadInput("icon must be one emoji or an SF Symbol name such as book.closed") }
                return icon
            }
            let moveTo = try input.rawText("move_entries_to"), deleteEntries = try input.flag("delete_entries") ?? false
            let expected = try input.number("expected_entries", 0...1_000_000)
            switch action {
            case "create": if newName != nil || moveTo != nil || deleteEntries { throw BadInput("create takes journal, color and icon") }
            case "update":
                if moveTo != nil || deleteEntries { throw BadInput("update takes new_name, color and icon") }
                if newName == nil, color == nil, icon == nil { throw BadInput("give new_name, color or icon") }
            default:
                if newName != nil || color != nil || icon != nil { throw BadInput("delete takes move_entries_to, or delete_entries and expected_entries") }
                if deleteEntries, moveTo != nil { throw BadInput("give move_entries_to or delete_entries, not both") }
            }
            return try await withJournal(store) {
                switch action {
                case "create":
                    let journal = try store.createJournal(reference, color: color, icon: icon)
                    let uploaded = await store.waitForUpload([journal])
                    return Output.written("Created.", Output.journal(store.info(journal)).object ?? [:], uploaded: uploaded)
                case "update":
                    let journal = try store.updateJournal(reference, name: newName, color: color, icon: icon)
                    let uploaded = await store.waitForUpload([journal])
                    return Output.written("Updated.", Output.journal(store.info(journal)).object ?? [:], uploaded: uploaded)
                default:
                    let (journal, before, count) = try store.deleteJournal(reference, moveTo: moveTo, deleteEntries: deleteEntries, expectedEntries: expected)
                    let fields: [String: JSON] = ["id": .string(before.id), "name": .string(before.name), "entries": .int(count)]
                    let uploaded = await store.waitForUpload([journal])
                    let lead = deleteEntries ? "Deleted, with its entries moved to Recently Deleted."
                        : (moveTo ?? "").isEmpty ? "Deleted; its entries stay in All Entries." : "Deleted; its entries moved to \(moveTo!)."
                    return Output.written(lead, fields, uploaded: uploaded)
                }
            }
        },

        Tool("export_entries", title: "Export journal entries",
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
             ], required: ["to"]), effect: .writes) { fields in
            let input = Input(fields)
            let path = (try input.requiredText("to") as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { throw BadInput("to must be an absolute path") }
            let journalName = try input.text("journal"), bookmarked = try input.flag("bookmarked") ?? false
            let after = try input.day("after"), before = try input.day("before")
            return try await withJournal(store) {
                let journal = try journalName.map { try store.info(store.journalObject($0)) }
                let entries = try store.entryObjects().map(store.info).filter { entry in
                    if bookmarked && !entry.bookmarked { return false }
                    if let journal, !journal.isDefault, !entry.journals.contains(journal.id) { return false }
                    if let after, entry.date < after { return false }
                    if let before, entry.date >= before { return false }
                    return true
                }
                let result = try store.export(entries, to: URL(fileURLWithPath: path))
                var o: [String: JSON] = ["folder": .string(path), "entries": .int(result.entries), "files": .int(result.files)]
                if !result.missing.isEmpty { o["not_downloaded"] = .array(result.missing.map { .string($0) }) }
                return ToolAnswer("Exported. " + JSON.object(o).text)
            }
        },
    ]
}

/// The answer to a write about an entry: the entry as find_entries shows it, and its upload.
@MainActor
private func written(_ lead: String, _ store: JournalStore, _ entry: JournalEntryMO, uploaded: Bool?) throws(JournalError) -> ToolAnswer {
    let names = Dictionary(uniqueKeysWithValues: try store.journalObjects().map { (JournalStore.id($0), store.name($0)) })
    return Output.written(lead, Output.summary(store.info(entry), journals: names).object ?? [:], uploaded: uploaded)
}
