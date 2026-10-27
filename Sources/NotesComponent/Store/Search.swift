import AppCore
import CoreData
import Foundation
import NoteModel

struct SearchHit: Sendable {
    let note: NoteInfo
    let snippet: String
    let length: Int
}

/// Text Notes got out of an attachment, which search looks in besides the note's own text.
struct AttachmentText: Sendable {
    /// The attachment to open with read_attachment: for a page of a scan, the scan.
    let attachmentID: String
    /// What the text is, as search shows it: "the text of image", "the transcript of audio".
    let label: String
    let text: String
}

enum NoteOrder: String, CaseIterable {
    case modified, created, title, opened

    /// Sorts newest first by the date, or by title; notes never opened go last.
    func sort(_ notes: inout [NoteInfo]) {
        switch self {
        case .modified: notes.sort { $0.modified > $1.modified }
        case .created: notes.sort { $0.created > $1.created }
        case .title: notes.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .opened: notes.sort { ($0.opened ?? .distantPast, $0.modified) > ($1.opened ?? .distantPast, $1.modified) }
        }
    }

    /// The date a list shows for a note in this order.
    @MainActor func date(of note: NoteInfo) -> String {
        switch self {
        case .created: Output.day(note.created)
        case .opened: note.opened.map(Output.day) ?? "never"
        case .modified, .title: Output.day(note.modified)
        }
    }

    var column: String { self == .created || self == .opened ? rawValue : "modified" }
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

    /// Text Notes got out of the attachments of these notes, by note: what it recognized in images
    /// and scans, the handwriting it recognized in drawings, and the transcripts of recordings.
    /// Cached per attachment until it changes.
    func attachmentTexts(_ ids: Set<String>) throws(NotesError) -> [String: [AttachmentText]] {
        var texts: [String: [AttachmentText]] = [:]
        for attachment in try fetch("ICAttachment", NSPredicate(format: "markedForDeletion == NO AND note != nil")) {
            guard let note = attachment.get("note") as? NSManagedObject else { continue }
            let noteID = string(note, "identifier")
            guard ids.contains(noteID) else { continue }
            let id = string(attachment, "identifier")
            func text(_ key: String) -> String { (attachment.get(key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            let recognized = text("ocrSummary"), handwriting = text("handwritingSummary")
            let audio = AttachmentKind.of(type: string(attachment, "typeUTI")) == "audio"
            let data = audio ? attachment.get("mergeableData") as? Data : nil
            guard !recognized.isEmpty || !handwriting.isEmpty || data != nil else { continue }
            let modified = (attachment.get("modificationDate") as? Date)?.timeIntervalSinceReferenceDate ?? 0
            let key = "\(modified)|\(recognized.count)|\(handwriting.count)|\(data?.count ?? 0)"
            if let cached = attachmentTextCache[id], cached.key == key {
                texts[noteID, default: []] += cached.texts
                continue
            }
            // A page of a scan is opened through the scan.
            let shown = (attachment.get("parentAttachment") as? NSManagedObject) ?? attachment
            let name = AttachmentKind.of(type: string(shown, "typeUTI")) + " " + ShortID.of(string(shown, "identifier"))
            var found: [AttachmentText] = []
            if !recognized.isEmpty { found.append(AttachmentText(attachmentID: string(shown, "identifier"), label: "the text of \(name)", text: recognized)) }
            if !handwriting.isEmpty { found.append(AttachmentText(attachmentID: string(shown, "identifier"), label: "the handwriting of \(name)", text: handwriting)) }
            if let transcript = recording(attachment)?.transcript, !transcript.isEmpty {
                found.append(AttachmentText(attachmentID: id, label: "the transcript of \(name)", text: transcript))
            }
            attachmentTextCache[id] = (key, found)
            texts[noteID, default: []] += found
        }
        return texts
    }

    /// Notes whose title, text or attachment text has the words, best first (more words, words
    /// in the title, words in the note's own text), or in `order`. Notes in Recently Deleted are
    /// left out, unless the scope is Recently Deleted.
    func search(_ query: String, matchAll: Bool, in scope: Scope?, modified: DateWindow, created: DateWindow,
                filter: NoteFilter = NoteFilter(), order: NoteOrder?, limit: Int) throws(NotesError) -> (total: Int, hits: [SearchHit]) {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { throw .refused("the search has no words") }
        let candidates: [NoteInfo]
        switch scope {
        case nil: candidates = try notes(inFolders: nil)
        case .folder(let root): candidates = try notes(inFolders: Set(try folders().filter { $0.names.starts(with: root.names) }.map(\.id)))
        case .smart(let smart): candidates = try notes(in: smart)
        case .recentlyDeleted: candidates = try recentlyDeletedNotes().map(\.note)
        }
        let notes = try matching(candidates.filter { !$0.locked && modified.contains($0.modified) && created.contains($0.created) }, filter)
        let ids = Set(notes.map(\.id))
        let texts = try plainTexts(ids)
        let extras = try attachmentTexts(ids)
        func has(_ text: String, _ word: String) -> Bool { text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        var scored: [(hit: SearchHit, score: Int)] = []
        for note in notes {
            let text = texts[note.id] ?? ""
            let others = extras[note.id] ?? []
            let inText = words.filter { has(text, $0) }
            let inTitle = words.filter { has(note.title, $0) }
            let found = words.filter { word in inText.contains(word) || inTitle.contains(word) || others.contains { has($0.text, word) } }
            guard matchAll ? found.count == words.count : !found.isEmpty else { continue }
            // The text around a word in the note itself; failing that, in the attachment that has
            // the most of the words.
            var snippet = Self.snippet(text, words: found)
            if inText.isEmpty, let best = others.max(by: { a, b in found.filter { has(a.text, $0) }.count < found.filter { has(b.text, $0) }.count }),
                found.contains(where: { has(best.text, $0) })
            {
                snippet = "in \(best.label): " + Self.snippet(best.text, words: found)
            }
            let inNote = Set(inText + inTitle).count
            let score = inNote * 10 + (found.count - inNote) * 5 + inTitle.count * 100
            scored.append((SearchHit(note: note, snippet: snippet, length: text.count), score))
        }
        if let order {
            var sorted = scored.map(\.hit.note)
            order.sort(&sorted)
            let rank = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element.id, $0.offset) })
            scored.sort { rank[$0.hit.note.id]! < rank[$1.hit.note.id]! }
        } else {
            scored.sort { ($0.score, $0.hit.note.modified) > ($1.score, $1.hit.note.modified) }
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

    init(file: URL = AppSettings.supportDirectory.appendingPathComponent("descriptions.json")) {
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
