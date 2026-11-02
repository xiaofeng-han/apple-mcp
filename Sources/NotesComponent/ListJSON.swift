import Foundation

/// What `--list-json` reads: the store, or a stand-in in tests.
@MainActor
protocol NoteListing {
    func notes(inFolders ids: Set<String>?) throws(NotesError) -> [NoteInfo]
    func search(_ query: String, matchAll: Bool, in scope: NotesStore.Scope?, modified: DateWindow, created: DateWindow,
                filter: NoteFilter, order: NoteOrder?, limit: Int) throws(NotesError) -> (total: Int, hits: [SearchHit])
    /// The version read_note gives each note; "?" for one that cannot be read.
    func versions(_ ids: [String]) -> [String: String]
}

extension NotesStore: NoteListing {}

/// `--list-json [QUERY]`, for editor pickers and scripts: one JSON object per line, with the full
/// ids and titles that the text lists cut, each note's version and its saved description. Every
/// note that is not locked, newest first; or, with a query, the notes that have all its words, best
/// first, each with a snippet.
@MainActor
enum ListJSON {
    struct Row: Encodable, Equatable {
        let id, title, folder, modified, version: String
        /// The description saved with describe_note, whether or not the note changed since; left
        /// out when there is none.
        let description: String?
        let snippet: String?
    }

    /// The most notes a query lists.
    static let limit = 100

    /// The rows for the program's words (the first is `--list-json`). A query of only spaces is no
    /// query.
    static func rows(_ words: [String], from listing: some NoteListing,
                     descriptions: [String: Descriptions.Entry] = [:]) throws(NotesError) -> [Row] {
        let query = words.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let found: [(note: NoteInfo, snippet: String?)]
        if query.isEmpty {
            var notes = try listing.notes(inFolders: nil).filter { !$0.locked }
            NoteOrder.modified.sort(&notes)
            found = notes.map { ($0, nil) }
        } else {
            let hits = try listing.search(query, matchAll: true, in: nil, modified: DateWindow(), created: DateWindow(),
                                          filter: NoteFilter(), order: nil, limit: limit).hits
            found = hits.map { ($0.note, $0.snippet) }
        }
        let versions = listing.versions(found.map(\.note.id))
        return found.map { note, snippet in
            Row(id: note.id, title: note.title, folder: note.folderPath, modified: Output.minute(note.modified),
                version: versions[note.id] ?? "?", description: descriptions[note.id]?.text, snippet: snippet)
        }
    }

    /// A row as one line of JSON. Strings always encode. The line and paragraph separators (Notes
    /// breaks lines within a paragraph with U+2028) and NEL are escaped too, as JSONEncoder leaves
    /// them, because many readers end a line at them.
    static func line(_ row: Row) -> String {
        String(decoding: try! JSONEncoder().encode(row), as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "\u{85}", with: "\\u0085")
    }

    /// Writes each row as one line of JSON and returns 0, or tells why it could not and returns 1.
    static func run(_ words: [String], from listing: some NoteListing, descriptions: [String: Descriptions.Entry] = [:],
                    write: (String) -> Void, fail: (String) -> Void) -> Int32 {
        do throws(NotesError) {
            for row in try rows(words, from: listing, descriptions: descriptions) { write(line(row)) }
            return 0
        } catch {
            fail(Output.explain(error))
            return 1
        }
    }
}
