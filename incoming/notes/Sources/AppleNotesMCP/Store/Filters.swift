import CoreData
import Foundation
import NoteModel
import NotesShim

/// What overview and search can narrow notes to besides folders and dates: what Notes' own smart
/// folders and sidebar offer.
struct NoteFilter {
    /// Groups of notes as Notes defines them (ICQuery): Quick Notes, Math Notes and call
    /// recordings by where they came from, checklists by the note's own flags.
    enum Group: String, CaseIterable {
        case pinned, shared, locked
        case quickNotes = "quick-notes", mathNotes = "math-notes", calls
        case checklists, unchecked, tagged, untagged, mentions

        var label: String {
            switch self {
            case .quickNotes: "Quick Notes"
            case .mathNotes: "Math Notes"
            case .calls: "call recordings"
            case .unchecked: "with unticked items"
            case .checklists: "with checklists"
            case .mentions: "with mentions"
            default: rawValue
            }
        }
    }

    static let attachmentKinds = ["image", "scan", "drawing", "table", "PDF", "audio", "video", "link", "file", "any", "none"]

    /// Tag names, without #; a note needs all of them.
    var tags: [String] = []
    /// A note needs to be in all of them.
    var groups: [Group] = []
    /// Kinds of attachment; a note needs one of them. "any" or "none" instead of kinds.
    var attachments: [String] = []

    var isEmpty: Bool { tags.isEmpty && groups.isEmpty && attachments.isEmpty }

    /// "pinned, tagged #work, with images or PDFs", for a list's heading.
    var parts: [String] {
        var parts = groups.map(\.label)
        if !tags.isEmpty { parts.append("tagged " + tags.map { "#" + $0 }.joined(separator: " and ")) }
        switch attachments {
        case []: break
        case ["any"]: parts.append("with attachments")
        case ["none"]: parts.append("without attachments")
        default: parts.append("with " + attachments.map { $0 == "PDF" ? "PDFs" : $0 + "s" }.joined(separator: " or "))
        }
        return parts
    }
}

/// The tags and mentions in notes.
struct InlineFacts {
    /// Tags of each note: standardized name → the name as written, without #.
    var tags: [String: [String: String]] = [:]
    var mentions: Set<String> = []
}

extension NotesStore {
    static let tagType = "com.apple.notes.inlinetextattachment.hashtag"
    static let mentionType = "com.apple.notes.inlinetextattachment.mention"

    /// A tag's name as Notes compares names: without #, ignoring case and accents.
    nonisolated static func tagKey(_ name: String) -> String {
        var name = name.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("#") { name.removeFirst() }
        return name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    func inlineFacts() throws(NotesError) -> InlineFacts {
        var facts = InlineFacts()
        let predicate = NSPredicate(format: "markedForDeletion == NO AND typeUTI IN %@", [Self.tagType, Self.mentionType])
        for attachment in try fetch("ICInlineAttachment", predicate) {
            guard let note = attachment.get("note") as? NSManagedObject else { continue }
            let id = string(note, "identifier")
            if string(attachment, "typeUTI") == Self.mentionType {
                facts.mentions.insert(id)
                continue
            }
            var name = string(attachment, "altText").trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("#") { name.removeFirst() }
            guard !name.isEmpty else { continue }
            facts.tags[id, default: [:]][Self.tagKey(name)] = name
        }
        return facts
    }

    /// The notes that pass the filter, in their order.
    func matching(_ notes: [NoteInfo], _ filter: NoteFilter) throws(NotesError) -> [NoteInfo] {
        guard !filter.isEmpty else { return notes }
        let needsInline = !filter.tags.isEmpty || filter.groups.contains { [.tagged, .untagged, .mentions].contains($0) }
        let facts = needsInline ? try inlineFacts() : InlineFacts()
        let kinds = filter.attachments.isEmpty ? [:] : try attachmentKinds(Set(notes.map(\.id)))
        let wantedTags = filter.tags.map(Self.tagKey)
        let wantedKinds = Set(filter.attachments.map { $0.lowercased() })
        return notes.filter { note in
            let tags = facts.tags[note.id] ?? [:]
            for group in filter.groups {
                let passes: Bool
                switch group {
                case .pinned: passes = note.pinned
                case .shared: passes = note.shared
                case .locked: passes = note.locked
                case .quickNotes: passes = note.quickNote
                case .mathNotes: passes = note.mathNote
                case .calls: passes = note.callRecording
                case .checklists: passes = note.hasChecklist
                case .unchecked: passes = note.checklistInProgress
                case .tagged: passes = !tags.isEmpty
                case .untagged: passes = tags.isEmpty
                case .mentions: passes = facts.mentions.contains(note.id)
                }
                if !passes { return false }
            }
            if !wantedTags.allSatisfy({ tags[$0] != nil }) { return false }
            if !wantedKinds.isEmpty {
                let has = Set((kinds[note.id] ?? [:]).filter { $0.value > 0 }.keys.map { $0.lowercased() })
                if wantedKinds == ["any"] { return !has.isEmpty }
                if wantedKinds == ["none"] { return has.isEmpty }
                return !has.isDisjoint(with: wantedKinds)
            }
            return true
        }
    }

    /// Notes with a link to this one (Notes' note links), newest first.
    func backlinks(_ id: String) throws(NotesError) -> [NoteInfo] {
        let predicate = NSPredicate(format: "markedForDeletion == NO AND typeUTI == %@ AND tokenContentIdentifier CONTAINS[c] %@",
                                    "com.apple.notes.inlinetextattachment.link", "applenotes:note/" + id)
        var seen: Set<String> = [id]
        var found: [NoteInfo] = []
        for attachment in try fetch("ICInlineAttachment", predicate) {
            guard let note = attachment.get("note") as? NSManagedObject, note.get("markedForDeletion") as? Bool != true else { continue }
            let info = info(note)
            if info.inTrash || !seen.insert(info.id).inserted { continue }
            found.append(info)
        }
        return found.sorted { $0.modified > $1.modified }
    }

    // MARK: Changing tags

    /// Brings back the tags of a note that Notes marked deleted while the note still uses them.
    /// Notes counts a tag's uses when it saves the note, and Notes.app, saving its own copy of a
    /// note this app just gave a new tag, finds none. True when it brought one back.
    func repairTags(_ noteID: String) throws(NotesError) -> Bool {
        // What the store holds now, read fresh: the write context can still hold the tag as it made it.
        refresh()
        let stored = try note(noteID)
        let account = (stored.get("account") as? NSManagedObject).map { string($0, "identifier") }
        var dead: [String: [String]] = [:]  // name → its tags, all marked deleted
        for use in (stored.get("inlineAttachments") as? Set<NSManagedObject>) ?? []
        where string(use, "typeUTI") == Self.tagType && use.get("markedForDeletion") as? Bool != true {
            let key = string(use, "tokenContentIdentifier")
            guard !key.isEmpty else { continue }
            let tags = try fetch("ICHashtag", NSPredicate(format: "standardizedContent == %@", key))
                .filter { account == nil || ($0.get("account") as? NSManagedObject).map { string($0, "identifier") } == account }
            if tags.isEmpty || tags.contains(where: { $0.get("markedForDeletion") as? Bool != true }) { continue }
            dead[key] = tags.map { string($0, "identifier") }
        }
        guard !dead.isEmpty else { return false }
        let context = try writeContext()
        var revived = false
        for ids in dead.values {
            // One live tag of the name is enough.
            guard let id = ids.first, let tag = try object("ICHashtag", id: id, in: context) else { continue }
            context.refresh(tag, mergeChanges: false)
            try shim { try ANNotes.unmark(forDeletion: tag) }
            revived = true
        }
        if revived, context.hasChanges {
            do {
                try context.save()
            } catch {
                context.rollback()
                throw .failed("saving the tags failed: \(error.localizedDescription)")
            }
        }
        return revived
    }

    /// The notes outside Recently Deleted that have a tag, and the tag's name as written.
    func notes(taggedWith tag: String) throws(NotesError) -> (name: String, notes: [NoteInfo]) {
        let key = Self.tagKey(tag)
        let facts = try inlineFacts()
        let notes = try self.notes(inFolders: nil).filter { facts.tags[$0.id]?[key] != nil }
        guard let first = notes.first, let name = facts.tags[first.id]?[key] else {
            let known = try tagSummary().map { "#" + $0.name }.joined(separator: ", ")
            throw .notFound("the tag #\(tag) in any note" + (known.isEmpty ? "" : "; tags in use: \(known)"))
        }
        return (name, notes)
    }

    /// Renames a tag in every note that has it; returns the notes and whether Notes uploaded the change.
    func renameTag(_ tag: String, to new: String) async throws(NotesError) -> (old: String, notes: Int, uploaded: Bool) {
        var name = new.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("#") { name.removeFirst() }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }), name.contains(where: \.isLetter) else {
            throw .refused("a tag's name is letters, digits, _ and -, with at least one letter")
        }
        let (old, notes) = try self.notes(taggedWith: tag)
        if let writeGuard, let other = notes.first(where: { !$0.title.hasPrefix(writeGuard) }) {
            throw .refused("Refused by the write guard: \"\(other.title)\" has the tag")
        }
        for note in notes { _ = try repairTags(note.id) }
        if Self.tagKey(name) != Self.tagKey(old), try tagSummary().contains(where: { Self.tagKey($0.name) == Self.tagKey(name) }) {
            throw .refused("#\(name) is already a tag; notes cannot be moved from one tag to another here")
        }
        let context = try writeContext()
        let account = try notes.first.flatMap { n throws(NotesError) in try note(n.id, in: context).get("account") as? NSManagedObject }
        let hashtag = try fetch("ICHashtag", NSPredicate(format: "markedForDeletion == NO AND standardizedContent ==[c] %@", Self.tagKey(old).uppercased()), in: context)
            .first { account == nil || ($0.get("account") as? NSManagedObject) == account }
        guard let hashtag else { throw .notFound("the tag #\(old) in Notes' data") }
        do {
            try shim { try ANNotes.renameTag(hashtag, to: name) }
            try context.save()
        } catch let error as NotesError {
            context.rollback()
            throw error
        } catch {
            context.rollback()
            throw .failed("saving the new name failed: \(error.localizedDescription)")
        }
        // Each use of the tag is a record of its own; uploading each note takes its uses along.
        refresh()
        let uses = try fetch("ICInlineAttachment", NSPredicate(format: "markedForDeletion == NO AND typeUTI == %@ AND altText ==[c] %@", Self.tagType, "#" + name))
        var uploaded = true
        for note in notes {
            let mine = uses.filter { ($0.get("note") as? NSManagedObject).map { string($0, "identifier") } == note.id }.map { string($0, "identifier") }
            if !(try await upload(note.id, watching: mine).uploaded) { uploaded = false }
        }
        return (old, notes.count, uploaded)
    }

    /// Takes a tag out of every note that has it. `expected` is the number of notes the caller saw
    /// with it, so a call never changes more notes than were looked at.
    func removeTag(_ tag: String, expected: Int) throws(NotesError) -> (name: String, written: [WriteResult], failed: [String]) {
        let (name, notes) = try self.notes(taggedWith: tag)
        guard notes.count == expected else {
            throw .refused("#\(name) is in \(notes.count) notes, not \(expected). Look again (overview lists the tags with their notes). Nothing was changed.")
        }
        if let writeGuard, let other = notes.first(where: { !$0.title.hasPrefix(writeGuard) }) {
            throw .refused("Refused by the write guard: \"\(other.title)\" has the tag")
        }
        let key = Self.tagKey(name)
        var written: [WriteResult] = [], failed: [String] = []
        for note in notes {
            do throws(NotesError) {
                written.append(try update(note.id, version: try version(of: note.id)) { blocks in Self.removing(tag: key, from: blocks) })
            } catch {
                failed.append("\(ShortID.of(note.id)) \"\(note.title)\": \(error)")
            }
        }
        return (name, written, failed)
    }

    /// The blocks without a tag, and without the space it leaves doubled.
    nonisolated static func removing(tag key: String, from blocks: [Block]) -> [Block] {
        blocks.map { block in
            guard case .paragraph(var p) = block else { return block }
            var pieces: [Piece] = []
            for piece in p.pieces {
                if case .attachment(let a) = piece, a.kind == "tag", tagKey(a.label) == key {
                    // "a #tag b" becomes "a b"; a tag at the end takes the space before it along.
                    if case .text(var run)? = pieces.last, run.text.hasSuffix(" ") {
                        run.text.removeLast()
                        pieces[pieces.count - 1] = .text(run)
                    }
                    continue
                }
                pieces.append(piece)
            }
            p.pieces = pieces.normalized()
            return .paragraph(p)
        }
    }

    /// The tags in use outside Recently Deleted, with how many notes have each, most used first.
    func tagSummary() throws(NotesError) -> [(name: String, notes: Int)] {
        let visible = Set(try notes(inFolders: nil).map(\.id))
        var counts: [String: (name: String, notes: Int)] = [:]
        for (note, tags) in try inlineFacts().tags where visible.contains(note) {
            for (key, name) in tags { counts[key, default: (name, 0)].notes += 1 }
        }
        return counts.values.sorted { ($0.notes, $1.name) > ($1.notes, $0.name) }
    }
}
