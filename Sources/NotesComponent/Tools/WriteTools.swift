import Foundation
import NoteModel
import Wire

func writeTools(_ store: NotesStore) -> [Tool] {
    [
        Tool("create_note", title: "Create a note",
             summary: """
                 Creates a note from Markdown; its first line is the title. ![name](/path/to/file) attaches a \
                 file, ![](https://…) adds a link card. Or copies a note with everything in it (copy_of).
                 """,
             input: Schema.object([
                 "markdown": Schema.text("The note"),
                 "copy_of": Schema.text("Instead of markdown: the id of a note to copy, attachments and all"),
                 "folder": Schema.text("Path or id; default Notes, or for a copy the note's own folder"),
                 "wait": waitSchema,
             ]), effect: .writes) { fields in
            let input = Input(fields)
            let markdown = try input.text("markdown"), copyOf = try input.text("copy_of")
            guard (markdown == nil) != (copyOf == nil) else { throw BadInput("give markdown or copy_of") }
            let blocks = markdown.map(parseInserted) ?? []
            if markdown != nil, blocks.isEmpty { throw BadInput("markdown is empty") }
            let folder = try input.text("folder")
            let wait = try input.flag("wait") ?? true
            return try await withNotes(store) {
                let folderID = try folder.map { reference throws(NotesError) in try store.folder(reference).id }
                if let copyOf {
                    return try await report("Created a copy", try store.duplicate(try store.resolveNote(copyOf), into: folderID), store, wait: wait)
                }
                return try await report("Created", try store.create(in: folderID, blocks), store, wait: wait)
            }
        },

        Tool("edit_note", title: "Edit a note",
             summary: """
                 Changes a note in one call: replace (exact Markdown from read_note, pairs applied in order), \
                 replace_section (what is under a heading) or replace_before (what is between the title and a \
                 heading), insert (Markdown at the end, the start, or under a heading), or rewrite (the whole \
                 note); check, uncheck and checklist tick, untick, sort or clear checklist items; pinned pins it. \
                 Only what changes is written; the rest keeps all its formatting. A note changed since its \
                 version was read is refused.
                 """,
             input: Schema.object([
                 "id": Schema.text("Note id"),
                 "version": Schema.text("The version read_note, overview or search gave"),
                 "replace": Schema.list(of: Schema.object([
                     "old": Schema.text("Exact Markdown; must be unique unless all"), "new": Schema.text("Markdown"),
                     "all": Schema.flag("Replace every occurrence"),
                 ], required: ["old", "new"]), "Replacements"),
                 "replace_section": headingEdit("What is under a heading, up to the next heading of its level or higher, becomes the Markdown; the heading stays"),
                 "replace_before": headingEdit("Everything between the title and a heading becomes the Markdown; both stay"),
                 "insert": Schema.text("Markdown to add"),
                 "at": Schema.text("end (default), start, or a heading's text; list items join that section's list"),
                 "rewrite": Schema.text("The whole note as Markdown"),
                 "check": Schema.texts("Tick the checklist items with these texts"),
                 "uncheck": Schema.texts("Untick the checklist items with these texts"),
                 "checklist": Schema.choice(Checklist.Action.allCases.map(\.rawValue), "Every checklist item: tick, untick, move the ticked ones to the bottom of their list, or delete them"),
                 "pinned": Schema.flag("Pin (true) or unpin (false) the note"),
                 "wait": waitSchema,
             ], required: ["id", "version"]), effect: .deletes) { fields in
            let input = Input(fields)
            let reference = try input.requiredText("id")
            let version = try input.requiredText("version")
            let pairs = try (input.objects("replace", keys: ["old", "new", "all"]) ?? []).map { pair in
                guard let old = try pair.rawText("old"), !old.isEmpty else { throw BadInput("replace.old must not be empty") }
                guard let new = try pair.rawText("new") else { throw BadInput("replace.new is required") }
                return (old: old, new: new, all: try pair.flag("all") ?? false)
            }
            let replaceSection = try headingEdit(input, "replace_section"), replaceBefore = try headingEdit(input, "replace_before")
            let insert = try input.rawText("insert").map(parseInserted)
            let at = try input.text("at") ?? "end"
            let rewrite = try input.rawText("rewrite").map(parseInserted)
            let pinned = try input.flag("pinned")
            let wait = try input.flag("wait") ?? true
            let check = try input.texts("check") ?? [], uncheck = try input.texts("uncheck") ?? []
            let checklist = try input.pick("checklist", from: Checklist.Action.allCases.map(\.rawValue)).flatMap(Checklist.Action.init(rawValue:))
            let ticks = !check.isEmpty || !uncheck.isEmpty || checklist != nil
            let sections = replaceSection != nil || replaceBefore != nil
            if rewrite != nil, !pairs.isEmpty || sections || insert != nil || ticks {
                throw BadInput("rewrite cannot be combined with replace, replace_section, replace_before, insert or checklist changes")
            }
            let changesBody = rewrite != nil || !pairs.isEmpty || sections || insert != nil || ticks
            if !changesBody, pinned == nil { throw BadInput("give replace, replace_section, replace_before, insert, rewrite, check, uncheck, checklist or pinned") }
            if let rewrite, rewrite.isEmpty { throw BadInput("rewrite is empty; delete_note deletes a note") }
            if let insert, insert.isEmpty { throw BadInput("insert is empty") }
            return try await withNotes(store) {
                let id = try store.resolveNote(reference)
                guard changesBody else {
                    let result = try store.setPinned(id, pinned!, version: version)
                    return try await report(pinned! ? "Pinned" : "Unpinned", result, store, wait: wait)
                }
                var result = try store.update(id, version: version) { current throws(NotesError) in
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
                    if let (heading, replacement) = replaceSection {
                        blocks = try SectionEdits.replaceSection(heading, with: replacement, in: blocks)
                    }
                    if let (heading, replacement) = replaceBefore {
                        blocks = try SectionEdits.replaceBefore(heading, with: replacement, in: blocks)
                    }
                    if let insert {
                        blocks.insert(contentsOf: insert, at: try insertionPoint(in: blocks, at: at, for: insert))
                    }
                    var missing = Checklist.set(check, checked: true, in: &blocks)
                    missing += Checklist.set(uncheck, checked: false, in: &blocks)
                    if !missing.isEmpty {
                        throw .notFound("a checklist item " + missing.map { "\"\($0)\"" }.joined(separator: ", ") + " in the note; give each item's text as read_note shows it after the checkbox")
                    }
                    if let checklist { blocks = Checklist.apply(checklist, to: blocks) }
                    return blocks
                }
                if let pinned {
                    let written = result
                    result = try store.setPinned(id, pinned, version: nil)
                    result.mismatch = written.mismatch
                    result.tablesEdited = written.tablesEdited
                    result.added = written.added
                }
                return try await report(pinned.map { $0 ? "Updated and pinned" : "Updated and unpinned" } ?? "Updated", result, store, wait: wait)
            }
        },

        Tool("delete_note", title: "Delete notes",
             summary: """
                 Moves a note, or several (notes), to Recently Deleted, where move_note can bring them back. A \
                 note changed since its version was read is refused.
                 """,
             input: Schema.object([
                 "id": Schema.text("Note id"), "version": Schema.text("The version read_note, overview or search gave"),
                 "notes": Schema.list(of: Schema.object(["id": Schema.text("Note id"), "version": Schema.text("Its version")], required: ["id", "version"]),
                                      "Instead of id and version: up to 100 notes"),
             ]), effect: .deletes) { fields in
            let targets = try Input(fields).targets()
            return try await withNotes(store) {
                var done: [(id: String, title: String)] = [], failed: [String] = []
                for (reference, version) in targets {
                    do throws(NotesError) {
                        let id = try store.resolveNote(reference)
                        let note = try store.noteInfo(id)
                        try await store.delete(id, version: version)
                        done.append((id, note.title))
                    } catch {
                        if case .noAccess = error { throw error }
                        if targets.count == 1 { throw error }
                        failed.append("\(reference): \(error)")
                    }
                }
                var lines = [done.count == 1 ? "Moved \"\(done[0].title)\" to Recently Deleted." : "Moved \(done.count) notes to Recently Deleted."]
                if !failed.isEmpty { lines += ["Not deleted:"] + failed.map { "  " + $0 } }
                let data: JSON = ["deleted": .array(done.map { ["id": .string($0.id), "title": .string($0.title)] }),
                                  "failed": .array(failed.map(JSON.string))]
                return ToolAnswer(lines.joined(separator: "\n"), data: data, failed: done.isEmpty)
            }
        },

        Tool("move_note", title: "Move notes",
             summary: """
                 Moves a note, or several (notes), to another folder, or back from Recently Deleted. A move into or \
                 out of a shared folder needs allow_shared, after asking the user. A note changed since its version \
                 was read is refused.
                 """,
             input: Schema.object([
                 "id": Schema.text("Note id"),
                 "folder": Schema.text("Path or id"),
                 "version": Schema.text("The version read_note, overview or search gave"),
                 "notes": Schema.list(of: Schema.object(["id": Schema.text("Note id"), "version": Schema.text("Its version")], required: ["id", "version"]),
                                      "Instead of id and version: up to 100 notes"),
                 "allow_shared": Schema.flag("The user agreed to changing who can see the notes"),
                 "wait": waitSchema,
             ], required: ["folder"]), effect: .writes) { fields in
            let input = Input(fields)
            let targets = try input.targets()
            let folder = try input.requiredText("folder")
            let allowShared = try input.flag("allow_shared") ?? false
            let wait = try input.flag("wait") ?? true
            return try await withNotes(store) {
                if targets.count == 1 {
                    let id = try store.resolveNote(targets[0].id)
                    let moved = try await store.move(id, to: folder, allowShared: allowShared, version: targets[0].version)
                    let state = try await requestUpload(store, id, wait: wait)
                    let version = try store.version(of: id)
                    let data: JSON = ["id": .string(id), "title": .string(moved.title), "version": .string(version), "from": .string(moved.from),
                                      "to": .string(moved.to), "restored": .bool(moved.restored), "uploaded": .bool(state.uploaded), "waited": .bool(wait)]
                    return ToolAnswer("\(moved.restored ? "Restored" : "Moved") \"\(moved.title)\" from \(moved.from) to \(moved.to). "
                        + "id: \(ShortID.of(id)) | version: \(version) | \(uploadText(state, waited: wait)).", data: data)
                }
                // Each move is itself what makes Notes upload a note, so the uploads are waited for together.
                var moved: [(id: String, moved: Moved)] = [], failed: [String] = []
                for (reference, version) in targets {
                    do throws(NotesError) {
                        let id = try store.resolveNote(reference)
                        moved.append((id, try await store.move(id, to: folder, allowShared: allowShared, version: version)))
                    } catch {
                        if case .noAccess = error { throw error }
                        failed.append("\(reference): \(error)")
                    }
                }
                // Without waiting, every upload is one not waited for.
                let waiting = wait ? await store.waitForUploads(moved.map(\.id)) : moved.count
                var lines: [String] = []
                if let first = moved.first {
                    let uploads = !wait ? "; \(notWaitedText)."
                        : waiting == 0 ? ", all uploaded to iCloud." : "; \(waiting) not uploaded to iCloud yet (Notes will do so later)."
                    lines.append("Moved \(moved.count) note\(moved.count == 1 ? "" : "s") to \(first.moved.to)" + uploads)
                    lines += moved.map { "  \(ShortID.of($0.id)) | \(Output.title($0.moved.title)) | from \($0.moved.from)" }
                }
                if !failed.isEmpty { lines += ["Not moved:"] + failed.map { "  " + $0 } }
                let data: JSON = [
                    "moved": .array(moved.map { item in
                        ["id": .string(item.id), "title": .string(item.moved.title), "from": .string(item.moved.from), "to": .string(item.moved.to),
                         "restored": .bool(item.moved.restored)]
                    }),
                    "failed": .array(failed.map(JSON.string)), "not_uploaded": .int(waiting), "waited": .bool(wait),
                ]
                return ToolAnswer(lines.joined(separator: "\n"), data: data, failed: moved.isEmpty)
            }
        },

        Tool("manage_tag", title: "Manage a tag",
             summary: """
                 Renames a tag in every note that has it, or deletes it from every note (the notes stay; delete \
                 needs expected_notes, the number of notes overview lists with the tag). Ask the user before \
                 deleting a tag.
                 """,
             input: Schema.object([
                 "action": Schema.choice(["rename", "delete"], "What to do"),
                 "tag": Schema.text("The tag, # optional"),
                 "name": Schema.text("For rename: the new name"),
                 "expected_notes": Schema.whole("For delete: the number of notes with the tag"),
             ], required: ["action", "tag"]), effect: .deletes) { fields in
            let input = Input(fields)
            guard let action = try input.pick("action", from: ["rename", "delete"]) else { throw BadInput("action is required") }
            let tag = try input.requiredText("tag"), name = try input.text("name")
            let expected = try input.number("expected_notes", 1...100_000)
            if action == "rename", name == nil { throw BadInput("rename needs name") }
            if action == "delete", expected == nil { throw BadInput("delete needs expected_notes: the number of notes with the tag") }
            return try await withNotes(store) {
                if action == "rename" {
                    let (old, count, uploaded) = try await store.renameTag(tag, to: name!)
                    return ToolAnswer("Renamed #\(old) to #\(name!.hasPrefix("#") ? String(name!.dropFirst()) : name!) in \(count) note\(count == 1 ? "" : "s"); "
                        + "\(uploaded ? "uploaded to iCloud" : "saved on this Mac; Notes will upload it to iCloud later").")
                }
                let (old, written, failed) = try store.removeTag(tag, expected: expected!)
                var waiting = 0
                for result in written where !(try await store.upload(result.id).uploaded) { waiting += 1 }
                var lines = ["Took #\(old) out of \(written.count) note\(written.count == 1 ? "" : "s")"
                    + (waiting == 0 ? ", all uploaded to iCloud." : "; \(waiting) not uploaded to iCloud yet (Notes will do so later).")]
                lines += written.map { "  \(ShortID.of($0.id)) | version: \($0.version) | \(Output.title($0.title))" }
                if !failed.isEmpty { lines += ["Not changed:"] + failed.map { "  " + $0 } }
                return ToolAnswer(lines.joined(separator: "\n"), failed: written.isEmpty)
            }
        },

        Tool("manage_folder", title: "Manage a folder",
             summary: """
                 Creates (folder is the new path; with tags, a smart folder of the notes with them), renames, \
                 moves (into another folder, or the top level), deletes or exports a folder. delete takes an empty \
                 folder, or with recursive and expected_notes everything in it (the notes go to Recently Deleted). \
                 export writes it and its folders as Markdown with the original attachments, to a new folder or \
                 .zip. Renaming or moving a shared folder needs allow_shared, after asking the user.
                 """,
             input: Schema.object([
                 "action": Schema.choice(["create", "rename", "move", "delete", "export"], "What to do"),
                 "folder": Schema.text("Path or id; for create, the new folder's path"),
                 "name": Schema.text("New name, for rename"),
                 "into": Schema.text("For move: the folder to put it in; empty for the top level"),
                 "tags": Schema.texts("For create: make a smart folder showing the notes with these tags"),
                 "match": Schema.choice(["any", "all"], "For a smart folder: notes with any of the tags (default) or all of them"),
                 "to": Schema.text("For export: a new folder or .zip path"),
                 "recursive": Schema.flag("delete: also everything in it"),
                 "expected_notes": Schema.whole("delete with recursive: the notes you saw in it and its folders"),
                 "allow_shared": Schema.flag("The user agreed to renaming or moving a shared folder"),
             ], required: ["action", "folder"]), effect: .deletes) { fields in
            let input = Input(fields)
            guard let action = try input.pick("action", from: ["create", "rename", "move", "delete", "export"]) else { throw BadInput("action is required") }
            let folder = try input.requiredText("folder")
            let name = try input.text("name"), to = try input.text("to")
            let into = try input.rawText("into")
            let tags = try input.texts("tags") ?? []
            let matchAll = try input.pick("match", from: ["any", "all"]) == "all"
            let recursive = try input.flag("recursive") ?? false
            let expected = try input.number("expected_notes", 0...1_000_000)
            let allowShared = try input.flag("allow_shared") ?? false
            switch action {
            case "rename" where name == nil: throw BadInput("rename needs name")
            case "move" where into == nil: throw BadInput("move needs into: the folder to put it in, or empty for the top level")
            case "export" where to == nil: throw BadInput("export needs to: a new folder or .zip path")
            case "delete" where recursive && expected == nil:
                throw BadInput("recursive needs expected_notes: the number of notes you saw in the folder and its folders")
            default: break
            }
            return try await withNotes(store) {
                // A smart folder holds no notes: it is made from tags, and renamed or deleted on its own.
                if action == "rename" || action == "delete", case .smart(let smart) = try store.scope(folder) {
                    if action == "rename" {
                        let new = try await store.changeSmartFolder(smart, renameTo: name!)
                        return ToolAnswer("Renamed the smart folder \(smart.name) to \(new); \(folderUploadText(await store.waitForFolderUpload(smart.id))).")
                    }
                    let gone = try await store.changeSmartFolder(smart, renameTo: nil)
                    return ToolAnswer("Deleted the smart folder \(gone); its notes stay where they are; \(folderUploadText(await store.waitForFolderUpload(smart.id))).")
                }
                switch action {
                case "create" where !tags.isEmpty:
                    guard FolderPath.split(folder).count == 1 else { throw NotesError.refused("smart folders are made at the top level; give just a name") }
                    let made = try await store.createSmartFolder(FolderPath.split(folder)[0], tags: tags, matchAll: matchAll)
                    let count = try store.notes(in: made).count
                    return ToolAnswer("Created the smart folder \(made.name) (\(made.rule)), \(count) note\(count == 1 ? "" : "s") now; "
                        + "\(folderUploadText(await store.waitForFolderUpload(made.id))).")
                case "create":
                    return ToolAnswer("Created the folder \(try await store.createFolder(folder)).")
                case "rename":
                    let (old, new) = try await store.renameFolder(folder, to: name!, allowShared: allowShared)
                    return ToolAnswer("Renamed \(old) to \(new).")
                case "move":
                    let parent = into!.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    let (old, new) = try await store.moveFolder(folder, into: parent.isEmpty ? nil : parent, allowShared: allowShared)
                    let id = try store.folder(new).id
                    return ToolAnswer("Moved \(old) to \(new); \(folderUploadText(await store.waitForFolderUpload(id))).")
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

/// The `wait` field of the writes that upload a note.
let waitSchema = Schema.flag("Wait until iCloud has the change (default true); false returns once it is saved and the upload is requested")

/// A field of replace_section or replace_before: a heading and the Markdown that goes with it.
func headingEdit(_ about: String) -> JSON {
    guard case .object(var schema) = Schema.object([
        "heading": Schema.text("A heading's text (# optional), as read_note's section takes it"),
        "markdown": Schema.text("The new Markdown; empty takes out what was there"),
    ], required: ["heading", "markdown"]) else { return [:] }
    schema["description"] = .string(about)
    return .object(schema)
}

/// replace_section or replace_before as given: the heading, and the paragraphs its Markdown makes.
func headingEdit(_ input: Input, _ key: String) throws -> (heading: String, blocks: [Block])? {
    guard let edit = try input.object(key, keys: ["heading", "markdown"]) else { return nil }
    guard let heading = try edit.text("heading") else { throw BadInput("\(key).heading is required") }
    guard let markdown = try edit.rawText("markdown") else { throw BadInput("\(key).markdown is required (it may be empty)") }
    return (heading, parseInserted(markdown))
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
/// the change twice. Without `wait`, the upload is asked for and not waited for, so what only
/// waiting shows (a table or a tag that iCloud did not take) is not put right.
@MainActor
func report(_ verb: String, _ result: WriteResult, _ store: NotesStore, wait: Bool = true) async throws(NotesError) -> ToolAnswer {
    var result = result
    var state = try await requestUpload(store, result.id, watching: result.added, wait: wait)
    var rebuilt = false
    if wait {
        // A table changed in place that does not upload (it was edited in Notes during this Notes
        // session) is made again, so other devices still get the change.
        let stuck = Set(state.pendingAttachments).intersection(result.tablesEdited)
        if !state.uploaded, state.noteSynced, !stuck.isEmpty {
            let again = try store.rebuildTables(result.id, tables: stuck)
            result = WriteResult(id: again.id, title: again.title, version: again.version, mismatch: result.mismatch ?? again.mismatch, added: result.added)
            state = try await store.upload(result.id, watching: result.added)
            rebuilt = true
        }
        // Notes can mark a new tag deleted while it uploads the note; such tags are brought back and uploaded.
        if !result.added.isEmpty, try store.repairTags(result.id) { state = try await store.upload(result.id, watching: result.added) }
    }
    var text = "\(verb) \"\(result.title)\". id: \(ShortID.of(result.id)) | version: \(result.version) | \(uploadText(state, waited: wait))"
    if rebuilt { text += "; the changed table was made again so iCloud would take it, which reset formatting inside its cells" }
    text += "."
    if let mismatch = result.mismatch {
        text += "\nWarning: the note does not read back exactly as written: \(mismatch). Read it again before changing it further."
    }
    let data: JSON = [
        "id": .string(result.id), "title": .string(result.title), "version": .string(result.version), "uploaded": .bool(state.uploaded),
        "waited": .bool(wait), "mismatch": Output.json(result.mismatch), "tables_rebuilt": .bool(rebuilt),
    ]
    return ToolAnswer(text, data: data)
}

/// Asks Notes to upload a note, and waits until iCloud has it, or with `wait` false only looks once.
@MainActor
func requestUpload(_ store: NotesStore, _ id: String, watching added: [String] = [], wait: Bool) async throws(NotesError) -> CloudState {
    if wait { return try await store.upload(id, watching: added) }
    return try await store.upload(id, watching: added, timeout: 0)
}

func folderUploadText(_ uploaded: Bool) -> String {
    uploaded ? "uploaded to iCloud" : "saved on this Mac; Notes has not uploaded it to iCloud yet and will do so later"
}

/// What a write says when it asked for the upload and did not wait for it (`wait: false`).
let notWaitedText = "saved on this Mac; upload requested, not waited for"

func uploadText(_ state: CloudState, waited: Bool = true) -> String {
    guard waited else { return notWaitedText }
    return state.uploaded ? "uploaded to iCloud" : "saved on this Mac; Notes has not uploaded it to iCloud yet and will do so later"
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
