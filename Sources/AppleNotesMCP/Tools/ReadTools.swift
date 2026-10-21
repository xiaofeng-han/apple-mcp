import Foundation
import NoteModel
import Wire

func readTools(_ store: NotesStore, _ descriptions: Descriptions) -> [Tool] {
    [
        Tool("overview", title: "Overview of notes",
             summary: """
                 The folders with their note counts. Given a folder, dates or sort: the notes, one line \
                 each (id | title | date | size | description). undescribed: true lists notes that need a \
                 description, with their opening text, for describe_note.
                 """,
             input: Schema.object([
                 "folder": Schema.text("Path such as \"Projects/Ideas\", or id; includes its folders"),
                 "modified_after": Schema.text("YYYY-MM-DD, inclusive"), "modified_before": Schema.text("YYYY-MM-DD, exclusive"),
                 "created_after": Schema.text("YYYY-MM-DD, inclusive"), "created_before": Schema.text("YYYY-MM-DD, exclusive"),
                 "sort": Schema.choice(NoteOrder.allCases.map(\.rawValue), "Newest first by modified (default) or created, or by title"),
                 "undescribed": Schema.flag("Only notes without a current description"),
                 "depth": Schema.whole("Folder levels shown when listing folders, 1 to 10 (default 1)"),
                 "limit": Schema.whole("Notes listed, 1 to 500 (default 30, 50 with undescribed)"),
             ]), effect: .reads) { fields in
            let input = Input(fields)
            let folder = try input.text("folder")
            let modified = try input.window("modified"), created = try input.window("created")
            let order = try input.order()
            let undescribed = try input.flag("undescribed") ?? false
            let depth = try input.number("depth", 1...10) ?? 1
            let limit = try input.number("limit", 1...500) ?? (undescribed ? 50 : 30)
            return try await withNotes(store) {
                let all = descriptions.all()
                if folder == nil, modified.isEmpty, created.isEmpty, order == nil, !undescribed {
                    return ToolAnswer(try folderTree(store, descriptions: all, depth: depth))
                }
                return ToolAnswer(try noteList(
                    store, descriptions: all, folder: folder, modified: modified, created: created,
                    order: order ?? (created.isEmpty ? .modified : .created),
                    group: folder != nil && order == nil && modified.isEmpty && created.isEmpty, undescribed: undescribed, limit: limit))
            }
        },

        Tool("search", title: "Search notes",
             summary: "Full-text search of titles and text, best matches first, with the text around each match.",
             input: Schema.object([
                 "query": Schema.text("Words to find"),
                 "match": Schema.choice(["all", "any"], "Every word (all, default) or any of them"),
                 "folder": Schema.text("Path or id; includes its folders"),
                 "modified_after": Schema.text("YYYY-MM-DD, inclusive"), "modified_before": Schema.text("YYYY-MM-DD, exclusive"),
                 "created_after": Schema.text("YYYY-MM-DD, inclusive"), "created_before": Schema.text("YYYY-MM-DD, exclusive"),
                 "sort": Schema.choice(NoteOrder.allCases.map(\.rawValue), "Instead of best match: newest modified or created first, or by title"),
                 "limit": Schema.whole("1 to 100 (default 10)"),
             ], required: ["query"]), effect: .reads) { fields in
            let input = Input(fields)
            let query = try input.requiredText("query")
            let matchAll = try input.pick("match", from: ["all", "any"]) != "any"
            let folder = try input.text("folder")
            let modified = try input.window("modified"), created = try input.window("created")
            let order = try input.order()
            let limit = try input.number("limit", 1...100) ?? 10
            return try await withNotes(store) {
                var scope: Set<String>?
                var root: FolderInfo?
                if let folder {
                    let found = try store.folder(folder)
                    root = found
                    scope = Set(try store.folders().filter { $0.names.starts(with: found.names) }.map(\.id))
                }
                let (total, hits) = try store.search(query, matchAll: matchAll, in: scope, modified: modified, created: created, order: order, limit: limit)
                let ranges = [Output.range(modified, "modified"), Output.range(created, "created")].compactMap { $0 }
                let within = (root.map { " in \($0.path)" } ?? "") + (ranges.isEmpty ? "" : " (\(ranges.joined(separator: ", ")))")
                if hits.isEmpty { return ToolAnswer("No notes match \"\(query)\"\(within).") }
                let kinds = try store.attachmentKinds(Set(hits.map(\.note.id)))
                let items = hits.map { hit in
                    (hit.note.folderNames, [
                        "\(ShortID.of(hit.note.id)) | \(Output.title(hit.note.title)) | \(Output.day(order == .created ? hit.note.created : hit.note.modified)) | "
                            + Output.size(characters: hit.length, attachments: kinds[hit.note.id] ?? [:]),
                        "  " + hit.snippet,
                    ])
                }
                let head = "\(total) note\(total == 1 ? "" : "s") match \"\(query)\"\(within)\(total > hits.count ? ", showing \(hits.count)" : ""):"
                return ToolAnswer(([head] + Output.sections(items, root: root?.names, rootPath: root?.path ?? "", group: order == nil)).joined(separator: "\n"))
            }
        },

        Tool("read_note", title: "Read a note",
             summary: """
                 Notes as Markdown, each with the version to pass back when changing it. By id, several \
                 ids, or exact title. A long note can be read one section at a time, or as an outline first.
                 """,
             input: Schema.object([
                 "id": Schema.text("Note id"),
                 "ids": Schema.texts("Up to 20 note ids"),
                 "title": Schema.text("The exact title, instead of an id"),
                 "section": Schema.text("Only the section under this heading"),
                 "outline": Schema.flag("Only the headings, with each section's size"),
             ]), effect: .reads) { fields in
            let input = Input(fields)
            let id = try input.text("id"), ids = try input.texts("ids") ?? [], title = try input.text("title")
            guard [id != nil, !ids.isEmpty, title != nil].filter({ $0 }).count == 1 else { throw BadInput("give one of id, ids or title") }
            guard ids.count <= 20 else { throw BadInput("ids takes at most 20 notes") }
            let section = try input.text("section"), outline = try input.flag("outline") ?? false
            if section != nil, outline { throw BadInput("give section or outline, not both") }
            return try await withNotes(store) {
                var references = id.map { [$0] } ?? ids
                if let title {
                    let matches = try store.notes(titled: title)
                    if matches.isEmpty { throw NotesError.notFound("a note titled \"\(title)\" (search finds notes by their words)") }
                    if matches.count > 1 {
                        return ToolAnswer((["\(matches.count) notes are titled \"\(title)\"; read one by id:"]
                            + matches.map { "\(ShortID.of($0.id)) | \($0.folderPath) | \(Output.day($0.modified))" }).joined(separator: "\n"))
                    }
                    references = [matches[0].id]
                }
                var parts: [String] = []
                for reference in references {
                    do {
                        parts.append(try readNote(store, descriptions, try store.resolveNote(reference), section: section, outline: outline))
                    } catch let error as NotesError where references.count > 1 {
                        parts.append("\(reference): \(error)")
                    }
                }
                return ToolAnswer(parts.joined(separator: "\n\n"))
            }
        },

        Tool("describe_note", title: "Describe notes",
             summary: "Saves one-line descriptions of notes, which overview shows. Several notes per call.",
             input: Schema.object([
                 "descriptions": Schema.list(of: Schema.object([
                     "id": Schema.text("Note id"), "description": Schema.text("One line, under 80 characters"),
                 ], required: ["id", "description"]), "1 to 200 notes"),
             ], required: ["descriptions"]), effect: .writes) { fields in
            guard let items = try Input(fields).objects("descriptions", keys: ["id", "description"]), (1...200).contains(items.count) else {
                throw BadInput("descriptions must be a list of 1 to 200 {id, description}")
            }
            let wanted = try items.map { item in
                let text = try item.requiredText("description").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { throw BadInput("a description must not be empty") }
                return (id: try item.requiredText("id"), text: text)
            }
            return try await withNotes(store) {
                var entries: [String: Descriptions.Entry] = [:]
                var saved: [String] = [], failed: [String] = []
                for (reference, text) in wanted {
                    do throws(NotesError) {
                        let note = try store.noteInfo(try store.resolveNote(reference))
                        entries[note.id] = Descriptions.Entry(text: text, noteModified: note.modified, written: Date())
                        saved.append(note.title)
                    } catch {
                        guard case .noAccess = error else {
                            failed.append("\(reference): \(error)")
                            continue
                        }
                        throw error
                    }
                }
                try descriptions.set(entries)
                var lines = [saved.count == 1 ? "Saved the description of \"\(saved[0])\"." : "Saved \(saved.count) descriptions."]
                if !failed.isEmpty { lines += ["Not saved:"] + failed.map { "  " + $0 } }
                return ToolAnswer(lines.joined(separator: "\n"), failed: saved.isEmpty)
            }
        },
    ]
}

/// Folders as an indented tree down to `depth`: "name (notes, described)". A folder at the depth
/// limit says what it holds below, so the next call can go deeper. Ids are shown only where two
/// folders have one path.
@MainActor
private func folderTree(_ store: NotesStore, descriptions: [String: Descriptions.Entry], depth: Int) throws(NotesError) -> String {
    let folders = try store.folders()
    var described: [String: Int] = [:]
    for note in try store.notes(inFolders: nil) where Descriptions.isCurrent(descriptions[note.id], modified: note.modified) {
        described[note.folderID, default: 0] += 1
    }
    let paths = Dictionary(grouping: folders, by: \.path)
    let total = folders.reduce(0) { $0 + $1.noteCount }
    let deeper = folders.contains { $0.names.count > depth }
    var lines = ["\(total) notes in \(folders.count) folders, \(described.values.reduce(0, +)) described."
        + (deeper ? " Showing \(depth) level\(depth == 1 ? "" : "s"); pass depth for more, or a folder to list its notes." : "")
        + " Name a folder by its path, such as Parent/Child."]
    for folder in folders where folder.names.count <= depth {
        var counts = "\(folder.noteCount)"
        if let d = described[folder.id], d > 0 { counts += ", \(d) described" }
        if folder.names.count == depth {
            let inside = folders.filter { $0.names.count > folder.names.count && $0.names.starts(with: folder.names) }
            if !inside.isEmpty {
                counts += "; \(inside.count) folder\(inside.count == 1 ? "" : "s") inside, \(folder.noteCount + inside.reduce(0) { $0 + $1.noteCount }) notes in all"
            }
        }
        let id = (paths[folder.path]?.count ?? 0) > 1 ? " [id \(ShortID.of(folder.id))]" : ""
        lines.append(String(repeating: "  ", count: folder.names.count - 1) + "\(folder.name) (\(counts))\(id)")
    }
    return lines.joined(separator: "\n")
}

/// Notes one per line, filtered and sorted. With `undescribed`, only notes without a current
/// description, each with its opening text: what describe_note needs.
@MainActor
private func noteList(
    _ store: NotesStore, descriptions: [String: Descriptions.Entry], folder: String?, modified: DateWindow, created: DateWindow,
    order: NoteOrder, group: Bool, undescribed: Bool, limit: Int
) throws(NotesError) -> String {
    var scope: Set<String>?
    var root: FolderInfo?
    var subfolders: String?
    if let folder {
        let found = try store.folder(folder)
        root = found
        let inside = try store.folders().filter { $0.names.count > found.names.count && $0.names.starts(with: found.names) }
        scope = Set([found.id] + inside.map(\.id))
        let direct = inside.filter { $0.names.count == found.names.count + 1 }
        if !direct.isEmpty { subfolders = "Folders in it: " + direct.map { "\($0.name) (\($0.noteCount))" }.joined(separator: ", ") }
    }
    var notes = try store.notes(inFolders: scope).filter { modified.contains($0.modified) && created.contains($0.created) }
    if undescribed { notes = notes.filter { !$0.locked && !Descriptions.isCurrent(descriptions[$0.id], modified: $0.modified) } }
    switch order {
    case .modified: notes.sort { $0.modified > $1.modified }
    case .created: notes.sort { $0.created > $1.created }
    case .title: notes.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    // Cut by the order first, so grouping never drops a folder's newest notes.
    let shown = Array(notes.prefix(limit))
    let ids = Set(shown.map(\.id))
    let texts = try store.plainTexts(ids)
    let kinds = try store.attachmentKinds(ids)
    let ranges = [Output.range(modified, "modified"), Output.range(created, "created")].compactMap { $0 }
    var lines = ["\(root?.path ?? "All folders")\(ranges.isEmpty ? "" : " (\(ranges.joined(separator: ", ")))") — \(notes.count) "
        + (undescribed ? "notes without a current description" : "notes") + (notes.count > shown.count ? ", showing \(shown.count)" : "")]
    if let subfolders { lines.append(subfolders) }
    guard !notes.isEmpty else { return lines.joined(separator: "\n") }
    var items: [(folder: [String], lines: [String])] = []
    for note in shown {
        let text = texts[note.id] ?? ""
        let date = Output.day(order == .created ? note.created : note.modified)
        let line = "\(ShortID.of(note.id)) | \(note.pinned ? "📌 " : "")\(Output.title(note.title)) | \(date) | "
            + (note.locked ? "locked" : Output.size(characters: text.count, attachments: kinds[note.id] ?? [:]))
        if undescribed {
            items.append((note.folderNames, [line, "  " + opening(text, title: note.title)]))
            continue
        }
        let summary: String
        if note.locked {
            summary = "(locked)"
        } else if let entry = descriptions[note.id] {
            summary = (Descriptions.isCurrent(entry, modified: note.modified) ? "" : "(older) ") + entry.text
        } else {
            summary = "~ " + Descriptions.extract(text, title: note.title)
        }
        items.append((note.folderNames, [line + " | " + summary]))
    }
    lines.append("id | title | \(order == .created ? "created" : "modified") | size" + (undescribed ? "" : " | description"))
    lines += Output.sections(items, root: root?.names, rootPath: root?.path ?? "", group: group)
    if undescribed {
        lines.append("Write one line for each with describe_note, many notes per call.")
    } else if items.contains(where: { $0.lines[0].contains(" | ~ ") }) {
        lines.append("~ marks a description taken from the note's first line; (older) one written before the note last changed.")
    }
    return lines.joined(separator: "\n")
}

/// About 300 characters after the title, on one line.
private func opening(_ text: String, title: String) -> String {
    var lines = text.replacingOccurrences(of: "\u{FFFC}", with: "").components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if lines.first == title { lines.removeFirst() }
    let joined = lines.joined(separator: " ¶ ")
    if joined.isEmpty { return "(title only)" }
    return joined.count > 300 ? String(joined.prefix(299)) + "…" : joined
}

/// A header (id, version, folder, date, flags), then the Markdown. Attachment ids are shortened;
/// writes take them back.
@MainActor
private func readNote(_ store: NotesStore, _ descriptions: Descriptions, _ id: String, section: String?, outline: Bool) throws(NotesError) -> String {
    let note = try store.noteInfo(id)
    let blocks = try store.blocks(id)
    var header = "id: \(ShortID.of(id)) | version: \(NotesStore.version(of: blocks)) | folder: \(note.folderPath) | modified: \(Output.minute(note.modified))"
    if note.shared { header += note.sharedReadOnly ? " | shared with you, read-only" : " | shared" }
    if note.inTrash { header += " | in Recently Deleted (move_note restores it)" }
    if !Descriptions.isCurrent(descriptions.all()[id], modified: note.modified) { header += " | needs a description" }
    let shown = blocks.mappingAttachmentIDs(ShortID.of)
    if outline {
        // Sizes are of each section as read_note returns it.
        var lines = [header, "---"]
        let firstHeading = shown.firstIndex { Sections.level($0).map { $0 > 1 } ?? false } ?? shown.count
        let intro = Markdown.render(Array(shown[..<firstHeading])).count
        if intro > 0 { lines.append("(before the first heading) — \(intro) chars") }
        for index in shown.indices {
            guard let level = Sections.level(shown[index]), level > 1, case .paragraph(let p) = shown[index] else { continue }
            let range = Sections.range(in: shown, from: index)
            lines.append(String(repeating: "#", count: level) + " \(p.plainText) — \(Markdown.render(Array(shown[range])).count) chars")
        }
        return lines.joined(separator: "\n")
    }
    if let section {
        let range = try Sections.find(section, in: shown)
        return header + " | this section only\n---\n" + Markdown.render(Array(shown[range]))
    }
    return header + "\n---\n" + Markdown.render(shown)
}

/// Sections of a note: a heading and everything under it up to the next heading of the same or
/// a higher level.
enum Sections {
    /// 1 for the title, 2 for a heading, 3 for a subheading.
    static func level(_ block: Block) -> Int? {
        guard case .paragraph(let p) = block else { return nil }
        return p.style.headingLevel
    }

    static func range(in blocks: [Block], from start: Int) -> Range<Int> {
        let own = level(blocks[start]) ?? 1
        var end = start + 1
        while end < blocks.count, (level(blocks[end]) ?? Int.max) > own { end += 1 }
        return start..<end
    }

    /// The section under the heading with this text (ignoring case and leading #).
    static func find(_ heading: String, in blocks: [Block]) throws(NotesError) -> Range<Int> {
        let wanted = heading.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        let matches = blocks.indices.filter { index in
            guard level(blocks[index]) != nil, case .paragraph(let p) = blocks[index] else { return false }
            return p.plainText.trimmingCharacters(in: .whitespaces).lowercased() == wanted
        }
        guard let found = matches.first else {
            let headings = blocks.compactMap { block -> String? in
                guard (level(block) ?? 1) > 1, case .paragraph(let p) = block else { return nil }
                return p.plainText
            }
            throw .notFound("a heading \"\(heading)\" in this note" + (headings.isEmpty ? " (it has no headings)" : "; its headings: " + headings.joined(separator: " | ")))
        }
        guard matches.count == 1 else { throw .refused("\(matches.count) headings read \"\(heading)\"; use replace instead") }
        return range(in: blocks, from: found)
    }
}
