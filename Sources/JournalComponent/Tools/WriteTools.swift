import CoreData
import Foundation
import JournalModel
import JournalShared
import NoteModel
import Wire

func writeTools(_ store: JournalStore) -> [Tool] {
    [
        Tool(JournalTools.createEntry) { fields in
            let input = Input(fields)
            var change = EntryChange()
            change.title = try input.rawText("title")
            change.body = try input.rawText("body").map(Markdown.parse)
            change.date = try input.entryDate("date")
            change.journal = try input.text("journal")
            change.bookmarked = try input.flag("bookmarked")
            let attach = try input.texts("attach") ?? []
            if (change.title ?? "").isEmpty, (change.body.map { Markdown.render($0) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               attach.isEmpty {
                throw BadInput("give a title, a body or files to attach")
            }
            return try await withJournal(store) {
                change.attach = try await Attaching.prepare(attach)
                let (entry, attached) = try store.create(change)
                let uploaded = await store.waitForUpload([entry] + uploads(attached))
                return try written("Created.", store, entry, attached: attached, uploaded: uploaded)
            }
        },

        Tool(JournalTools.editEntry) { fields in
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
            let attach = try input.texts("attach") ?? []
            change.detach = try input.texts("detach") ?? []
            if change.isEmpty, body == nil, pairs.isEmpty, append == nil, attach.isEmpty {
                throw BadInput("give title, body, replace, append, date, bookmarked, journal, attach or detach")
            }
            return try await withJournal(store) {
                change.attach = try await Attaching.prepare(attach)
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
                let (entry, attached) = try store.edit(reference, version: version, change)
                let uploaded = await store.waitForUpload([entry] + uploads(attached))
                return try written("Updated.", store, entry, attached: attached, uploaded: uploaded)
            }
        },

        Tool(JournalTools.deleteEntry) { fields in
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

        Tool(JournalTools.restoreEntry) { fields in
            let reference = try Input(fields).requiredText("id")
            return try await withJournal(store) {
                let entry = try store.restore(reference)
                let uploaded = await store.waitForUpload([entry])
                return try written("Restored.", store, entry, uploaded: uploaded)
            }
        },

        Tool(JournalTools.duplicateEntry) { fields in
            let reference = try Input(fields).requiredText("id")
            return try await withJournal(store) {
                let copy = try store.duplicate(reference)
                let uploaded = await store.waitForUpload([copy])
                return try written("Duplicated.", store, copy, uploaded: uploaded)
            }
        },

        Tool(JournalTools.manageJournal) { fields in
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

        Tool(JournalTools.exportEntries) { fields in
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

/// The answer to a write about an entry: the entry as find_entries shows it, the attachments it
/// added, and its upload.
@MainActor
private func written(_ lead: String, _ store: JournalStore, _ entry: JournalEntryMO, attached: [Attached] = [], uploaded: Bool?) throws(JournalError) -> ToolAnswer {
    let names = Dictionary(uniqueKeysWithValues: try store.journalObjects().map { (JournalStore.id($0), store.name($0)) })
    var fields = Output.summary(store.info(entry), journals: names).object ?? [:]
    if !attached.isEmpty {
        fields["attached"] = .array(attached.map { item in
            ["id": .string(JournalStore.id(item.asset)), "kind": .string(AssetDetails.kind(item.asset.value(forKey: "assetType") as? String ?? ""))]
        })
    }
    return Output.written(lead, fields, uploaded: uploaded)
}

/// What uploads with the attachments: each asset and its file.
@MainActor
private func uploads(_ attached: [Attached]) -> [NSManagedObject] {
    attached.flatMap { [$0.asset] + Array($0.asset.value(forKey: "fileAttachments") as? Set<NSManagedObject> ?? []) }
}
