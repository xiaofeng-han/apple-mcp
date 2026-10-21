import Foundation
import NoteModel
import Wire

func writeTools(_ store: NotesStore) -> [Tool] {
    [
        Tool("create_note", title: "Create a note",
             summary: "Creates a note from Markdown; its first line is the title.",
             input: Schema.object([
                 "markdown": Schema.text("The note"),
                 "folder": Schema.text("Path or id; default Notes"),
             ], required: ["markdown"]), effect: .writes) { fields in
            let input = Input(fields)
            let blocks = parseInserted(try input.requiredText("markdown"))
            guard !blocks.isEmpty else { throw BadInput("markdown is empty") }
            let folder = try input.text("folder")
            return try await withNotes(store) {
                let folderID = try folder.map { reference throws(NotesError) in try store.folder(reference).id }
                return try await report("Created", try store.create(in: folderID, blocks), store)
            }
        },

        Tool("edit_note", title: "Edit a note",
             summary: """
                 Changes a note in one call: replace (exact Markdown from read_note, pairs applied in order), \
                 insert (Markdown at the end, the start, or under a heading), or rewrite (the whole note). Only \
                 what changes is written; the rest keeps all its formatting.
                 """,
             input: Schema.object([
                 "id": Schema.text("Note id"),
                 "version": Schema.text("From read_note; required for rewrite"),
                 "replace": Schema.list(of: Schema.object([
                     "old": Schema.text("Exact Markdown; must be unique unless all"), "new": Schema.text("Markdown"),
                     "all": Schema.flag("Replace every occurrence"),
                 ], required: ["old", "new"]), "Replacements"),
                 "insert": Schema.text("Markdown to add"),
                 "at": Schema.text("end (default), start, or a heading's text; list items join that section's list"),
                 "rewrite": Schema.text("The whole note as Markdown"),
             ], required: ["id"]), effect: .deletes) { fields in
            let input = Input(fields)
            let reference = try input.requiredText("id")
            let version = try input.text("version")
            let pairs = try (input.objects("replace", keys: ["old", "new", "all"]) ?? []).map { pair in
                guard let old = try pair.rawText("old"), !old.isEmpty else { throw BadInput("replace.old must not be empty") }
                guard let new = try pair.rawText("new") else { throw BadInput("replace.new is required") }
                return (old: old, new: new, all: try pair.flag("all") ?? false)
            }
            let insert = try input.rawText("insert").map(parseInserted)
            let at = try input.text("at") ?? "end"
            let rewrite = try input.rawText("rewrite").map(parseInserted)
            if rewrite != nil, !pairs.isEmpty || insert != nil { throw BadInput("rewrite cannot be combined with replace or insert") }
            if rewrite == nil, pairs.isEmpty, insert == nil { throw BadInput("give replace, insert or rewrite") }
            if rewrite != nil, version == nil { throw BadInput("rewrite needs the version from read_note") }
            if let rewrite, rewrite.isEmpty { throw BadInput("rewrite is empty; delete_note deletes a note") }
            if let insert, insert.isEmpty { throw BadInput("insert is empty") }
            return try await withNotes(store) {
                let id = try store.resolveNote(reference)
                let result = try store.update(id, version: version) { current throws(NotesError) in
                    if var rewrite {
                        // Blank lines at the end are invisible; keep the note's own.
                        if case .paragraph(let p)? = rewrite.last, p.isBlank {} else {
                            rewrite += current.reversed().prefix { if case .paragraph(let p) = $0 { p.isBlank } else { false } }.reversed()
                        }
                        return rewrite
                    }
                    var blocks = current
                    if !pairs.isEmpty {
                        var markdown = Markdown.render(current.mappingAttachmentIDs(ShortID.of))
                        for (old, new, all) in pairs {
                            let count = markdown.components(separatedBy: old).count - 1
                            if count == 0 {
                                throw .notFound("\"\(old)\" in the note" + (closestLine(to: old, in: markdown).map { "; the closest line is \"\($0)\"" } ?? "; read it again"))
                            }
                            if count > 1, !all { throw .refused("\"\(old)\" appears \(count) times; add text around it, or set all") }
                            markdown = markdown.replacingOccurrences(of: old, with: new)
                        }
                        blocks = Markdown.parse(markdown)
                    }
                    if let insert {
                        blocks.insert(contentsOf: insert, at: try insertionPoint(in: blocks, at: at, for: insert))
                    }
                    return blocks
                }
                return try await report("Updated", result, store)
            }
        },

        Tool("delete_note", title: "Delete a note",
             summary: "Moves a note to Recently Deleted, where move_note can bring it back.",
             input: Schema.object(["id": Schema.text("Note id")], required: ["id"]), effect: .deletes) { fields in
            let reference = try Input(fields).requiredText("id")
            return try await withNotes(store) {
                let id = try store.resolveNote(reference)
                let note = try store.noteInfo(id)
                try await store.delete(id)
                return ToolAnswer("Moved \"\(note.title)\" to Recently Deleted.")
            }
        },

        Tool("move_note", title: "Move a note",
             summary: """
                 Moves a note to another folder, or back from Recently Deleted. A move into or out of a shared \
                 folder needs allow_shared, after asking the user.
                 """,
             input: Schema.object([
                 "id": Schema.text("Note id"),
                 "folder": Schema.text("Path or id"),
                 "allow_shared": Schema.flag("The user agreed to changing who can see the note"),
             ], required: ["id", "folder"]), effect: .writes) { fields in
            let input = Input(fields)
            let reference = try input.requiredText("id"), folder = try input.requiredText("folder")
            let allowShared = try input.flag("allow_shared") ?? false
            return try await withNotes(store) {
                let id = try store.resolveNote(reference)
                let moved = try await store.move(id, to: folder, allowShared: allowShared)
                let state = try await store.upload(id)
                return ToolAnswer("\(moved.restored ? "Restored" : "Moved") \"\(moved.title)\" from \(moved.from) to \(moved.to). "
                    + "id: \(ShortID.of(id)) | \(uploadText(state)).")
            }
        },

        Tool("manage_folder", title: "Manage a folder",
             summary: """
                 Creates (folder is the new path), renames, deletes or exports a folder. delete takes an empty \
                 folder, or with recursive and expected_notes everything in it (the notes go to Recently Deleted). \
                 export writes it and its folders as Markdown with the original attachments, to a new folder or \
                 .zip. Renaming a shared folder needs allow_shared, after asking the user.
                 """,
             input: Schema.object([
                 "action": Schema.choice(["create", "rename", "delete", "export"], "What to do"),
                 "folder": Schema.text("Path or id; for create, the new folder's path"),
                 "name": Schema.text("New name, for rename"),
                 "to": Schema.text("For export: a new folder or .zip path"),
                 "recursive": Schema.flag("delete: also everything in it"),
                 "expected_notes": Schema.whole("delete with recursive: the notes you saw in it and its folders"),
                 "allow_shared": Schema.flag("The user agreed to renaming a shared folder"),
             ], required: ["action", "folder"]), effect: .deletes) { fields in
            let input = Input(fields)
            guard let action = try input.pick("action", from: ["create", "rename", "delete", "export"]) else { throw BadInput("action is required") }
            let folder = try input.requiredText("folder")
            let name = try input.text("name"), to = try input.text("to")
            let recursive = try input.flag("recursive") ?? false
            let expected = try input.number("expected_notes", 0...1_000_000)
            let allowShared = try input.flag("allow_shared") ?? false
            switch action {
            case "rename" where name == nil: throw BadInput("rename needs name")
            case "export" where to == nil: throw BadInput("export needs to: a new folder or .zip path")
            case "delete" where recursive && expected == nil:
                throw BadInput("recursive needs expected_notes: the number of notes you saw in the folder and its folders")
            default: break
            }
            return try await withNotes(store) {
                switch action {
                case "create":
                    return ToolAnswer("Created the folder \(try await store.createFolder(folder)).")
                case "rename":
                    let (old, new) = try await store.renameFolder(folder, to: name!, allowShared: allowShared)
                    return ToolAnswer("Renamed \(old) to \(new).")
                case "delete" where recursive:
                    let done = try await store.deleteFolderTree(folder, expected: expected!)
                    return ToolAnswer("Moved \(done.notes) note\(done.notes == 1 ? "" : "s") to Recently Deleted and deleted "
                        + "\(done.folders) folder\(done.folders == 1 ? "" : "s") (\(done.path) and the folders in it).")
                case "delete":
                    return ToolAnswer("Deleted the empty folder \(try await store.deleteFolder(folder)).")
                default:
                    return exportAnswer(try await store.export(folder, to: to!))
                }
            }
        },
    ]
}

/// Markdown given to write, without blank lines at its end (they would become empty paragraphs).
func parseInserted(_ markdown: String) -> [Block] {
    var blocks = Markdown.parse(markdown)
    while case .paragraph(let p)? = blocks.last, p.isBlank { blocks.removeLast() }
    return blocks
}

/// Where inserted blocks go. Under a heading: list items join the section's last list of their
/// kind (a new checkbox stays with the checklist even when text follows it), anything else goes
/// at the end of the section, before its blank lines. "start" is just below the title; "end"
/// is before the note's trailing blank lines.
func insertionPoint(in blocks: [Block], at: String, for inserted: [Block]) throws(NotesError) -> Int {
    func blank(_ index: Int) -> Bool { if case .paragraph(let p) = blocks[index] { p.isBlank } else { false } }
    switch at.lowercased() {
    case "start":
        if case .paragraph(let p)? = blocks.first, p.style == .title || !p.pieces.isEmpty { return 1 }
        return 0
    case "end":
        var end = blocks.count
        while end > 1, blank(end - 1) { end -= 1 }
        return end
    default:
        let section = try Sections.find(at, in: blocks)
        if case .paragraph(let first)? = inserted.first, let family = first.style.listFamily,
            let last = section.dropFirst().last(where: { index in
                if case .paragraph(let p) = blocks[index] { p.style.listFamily == family } else { false }
            })
        {
            return last + 1
        }
        var end = section.upperBound
        while end > section.lowerBound + 1, blank(end - 1) { end -= 1 }
        return end
    }
}

/// The line that best matches the start of `text`, to help with a near miss; nil when no line
/// shares at least two characters with it (pointing at an unrelated line only misleads).
func closestLine(to text: String, in markdown: String) -> String? {
    let target = text.components(separatedBy: "\n").first ?? text
    var best: (line: String, score: Int)?
    for line in markdown.components(separatedBy: "\n") where !line.isEmpty {
        let common = zip(line, target).prefix { $0 == $1 }.count
        let inside = stride(from: target.count, through: 1, by: -1).first { line.contains(target.prefix($0)) } ?? 0
        let score = max(common, inside)
        if score > (best?.score ?? 0) { best = (line, score) }
    }
    guard let best, best.score >= min(2, target.count) else { return nil }
    return best.line
}

/// Uploads a change and says how the write went. A note that does not read back exactly as
/// written is a warning, not a failure: the write happened, and a client that retries would add
/// the change twice.
@MainActor
func report(_ verb: String, _ result: WriteResult, _ store: NotesStore) async throws(NotesError) -> ToolAnswer {
    var result = result
    var state = try await store.upload(result.id)
    var rebuilt = false
    // A table changed in place that does not upload (it was edited in Notes during this Notes
    // session) is made again, so other devices still get the change.
    let stuck = Set(state.pendingTables).intersection(result.tablesEdited)
    if !state.uploaded, state.noteSynced, !stuck.isEmpty {
        let again = try store.rebuildTables(result.id, tables: stuck)
        result = WriteResult(id: again.id, title: again.title, version: again.version, mismatch: result.mismatch ?? again.mismatch)
        state = try await store.upload(result.id)
        rebuilt = true
    }
    var text = "\(verb) \"\(result.title)\". id: \(ShortID.of(result.id)) | version: \(result.version) | \(uploadText(state))"
    if rebuilt { text += "; the changed table was made again so iCloud would take it, which reset formatting inside its cells" }
    text += "."
    if let mismatch = result.mismatch {
        text += "\nWarning: the note does not read back exactly as written: \(mismatch). Read it again before changing it further."
    }
    return ToolAnswer(text)
}

func uploadText(_ state: CloudState) -> String {
    state.uploaded ? "uploaded to iCloud" : "saved on this Mac; Notes has not uploaded it to iCloud yet and will do so later"
}

/// A few lines however large the folder: totals, problems, and what a delete would need.
@MainActor
func exportAnswer(_ result: ExportResult) -> ToolAnswer {
    let exported = result.notes - result.locked - result.failed.count
    var lines = ["Exported \(result.path): \(exported) of \(result.notes) notes in \(result.folders) folder\(result.folders == 1 ? "" : "s") "
        + "and \(result.files) attachment file\(result.files == 1 ? "" : "s"), to \(result.destination). manifest.md there lists every note."]
    var problems: [String] = []
    if result.locked > 0 { problems.append("\(result.locked) locked note\(result.locked == 1 ? " was" : "s were") not exported (Notes keeps them encrypted)") }
    if result.missing > 0 { problems.append("\(result.missing) attachment\(result.missing == 1 ? " is" : "s are") not on this Mac") }
    if !result.failed.isEmpty {
        problems.append("\(result.failed.count) note\(result.failed.count == 1 ? "" : "s") could not be read: "
            + result.failed.prefix(5).joined(separator: "; ") + (result.failed.count > 5 ? "; …" : ""))
    }
    if !problems.isEmpty { lines.append("Check before deleting the folder: " + problems.joined(separator: "; ") + ". manifest.md has the details.") }
    lines.append(result.locked > 0
        ? "Locked notes keep the folder from being deleted with its contents; unlock them or move them out in Notes first."
        : "To delete the folder with everything in it (once the user agrees): action delete, recursive: true, expected_notes: \(result.notes).")
    return ToolAnswer(lines.joined(separator: "\n"), failed: !result.failed.isEmpty)
}
