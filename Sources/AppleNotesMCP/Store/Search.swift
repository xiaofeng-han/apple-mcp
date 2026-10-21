import CoreData
import Foundation
import NoteModel

struct SearchHit: Sendable {
    let note: NoteInfo
    let snippet: String
    let length: Int
}

enum NoteOrder: String, CaseIterable {
    case modified, created, title
}

/// A date range: from inclusive, until exclusive.
struct DateWindow {
    var from: Date?
    var until: Date?

    var isEmpty: Bool { from == nil && until == nil }

    func contains(_ date: Date) -> Bool {
        (from.map { date >= $0 } ?? true) && (until.map { date < $0 } ?? true)
    }
}

extension NotesStore {
    /// Plain text of notes (all readable ones when `ids` is nil), decoded from the stored body
    /// without NotesShared, which is far faster than loading each note. Cached per note until it
    /// changes. Locked notes have none.
    func plainTexts(_ ids: Set<String>? = nil) throws(NotesError) -> [String: String] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ICNote")
        request.predicate = NSPredicate(format: "markedForDeletion == NO AND isPasswordProtected == NO")
        request.relationshipKeyPathsForPrefetching = ["noteData"]
        let notes: [NSManagedObject]
        do {
            notes = try context().fetch(request)
        } catch let error as NotesError {
            throw error
        } catch {
            throw .failed("reading notes failed: \(error.localizedDescription)")
        }
        var texts: [String: String] = [:]
        for note in notes {
            let id = string(note, "identifier")
            if let ids, !ids.contains(id) { continue }
            let data = (note.get("noteData") as? NSManagedObject)?.get("data") as? Data
            let key = "\((note.get("modificationDate") as? Date)?.timeIntervalSinceReferenceDate ?? 0)|\(data?.count ?? 0)"
            if let cached = textCache[id], cached.key == key {
                texts[id] = cached.text
                continue
            }
            let text = data.flatMap(StoredBody.plainText) ?? ""
            textCache[id] = (key, text)
            texts[id] = text
        }
        return texts
    }

    /// Attachments of each note, counted by kind. Inline ones (tags, note links) are text.
    func attachmentKinds(_ ids: Set<String>) throws(NotesError) -> [String: [String: Int]] {
        var kinds: [String: [String: Int]] = [:]
        for attachment in try fetch("ICAttachment", NSPredicate(format: "markedForDeletion == NO AND note != nil AND typeUTI != nil")) {
            guard let note = attachment.get("note") as? NSManagedObject else { continue }
            let id = string(note, "identifier")
            guard ids.contains(id) else { continue }
            kinds[id, default: [:]][AttachmentKind.of(type: string(attachment, "typeUTI")), default: 0] += 1
        }
        return kinds
    }

    /// Notes whose title or text has the words, best first (more words, words in the title),
    /// or in `order`. Notes in Recently Deleted are left out.
    func search(_ query: String, matchAll: Bool, in scope: Set<String>?, modified: DateWindow, created: DateWindow,
                order: NoteOrder?, limit: Int) throws(NotesError) -> (total: Int, hits: [SearchHit]) {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { throw .refused("the search has no words") }
        let notes = try notes(inFolders: scope).filter { !$0.locked && modified.contains($0.modified) && created.contains($0.created) }
        let texts = try plainTexts(Set(notes.map(\.id)))
        func has(_ text: String, _ word: String) -> Bool { text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        var scored: [(hit: SearchHit, score: Int)] = []
        for note in notes {
            let text = texts[note.id] ?? ""
            let found = words.filter { has(note.title, $0) || has(text, $0) }
            guard matchAll ? found.count == words.count : !found.isEmpty else { continue }
            let inTitle = words.filter { has(note.title, $0) }.count
            scored.append((SearchHit(note: note, snippet: Self.snippet(text, words: found), length: text.count), found.count * 10 + inTitle * 100))
        }
        switch order {
        case nil: scored.sort { ($0.score, $0.hit.note.modified) > ($1.score, $1.hit.note.modified) }
        case .modified: scored.sort { $0.hit.note.modified > $1.hit.note.modified }
        case .created: scored.sort { $0.hit.note.created > $1.hit.note.created }
        case .title: scored.sort { $0.hit.note.title.localizedStandardCompare($1.hit.note.title) == .orderedAscending }
        }
        return (scored.count, scored.prefix(limit).map(\.hit))
    }

    /// The text around the first word found, on one line.
    static func snippet(_ text: String, words: [String]) -> String {
        let flat = text.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\n", with: " ⏎ ")
        guard let first = words.compactMap({ flat.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) })
            .min(by: { $0.lowerBound < $1.lowerBound })
        else { return String(flat.prefix(80)) }
        let start = flat.index(first.lowerBound, offsetBy: -30, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(first.upperBound, offsetBy: 50, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }
}

/// One-line descriptions of notes, written by the calling model with describe_note and shown by
/// overview. Kept in descriptions.json in the app's folder; several servers (one per agent) may
/// share it, so it is read again before each use and merged on write.
@MainActor
final class Descriptions {
    struct Entry: Codable {
        var text: String
        /// The note's modification date when the description was written.
        var noteModified: Date
        var written: Date
    }

    let file: URL

    init(file: URL = Settings.supportDirectory.appendingPathComponent("descriptions.json")) {
        self.file = file
    }

    func all() -> [String: Entry] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
    }

    func set(_ entries: [String: Entry]) throws(NotesError) {
        var merged = all()
        merged.merge(entries) { _, new in new }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(merged).write(to: file, options: .atomic)
        } catch {
            throw .failed("could not save the descriptions: \(error.localizedDescription)")
        }
    }

    /// Current while the note has not changed since it was described.
    static func isCurrent(_ entry: Entry?, modified: Date) -> Bool {
        guard let entry else { return false }
        return modified.timeIntervalSince(entry.noteModified) < 1
    }

    /// A stand-in description from the note itself: its first line after the title that has a
    /// letter or digit in it (not a row of dashes or emoji), cut to a sentence.
    static func extract(_ text: String, title: String) -> String {
        var lines = text.replacingOccurrences(of: "\u{FFFC}", with: "").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
        if lines.first == title { lines.removeFirst() }
        guard let first = lines.first else { return "" }
        let end = first.firstIndex(where: { "。！？.!?".contains($0) }).map { first.index(after: $0) } ?? first.endIndex
        let sentence = String(first[..<end])
        return sentence.count > 80 ? String(sentence.prefix(79)) + "…" : sentence
    }
}
