import Foundation
import Testing
@testable import NotesComponent

/// `--list-json` on a stand-in for the store: which notes it lists and in what order, what it asks
/// the search for, the JSON it writes, and its exit status.
@MainActor
@Suite struct ListJSONTests {
    /// The notes and search hits it holds, or the error it throws; it keeps what it was asked.
    final class Listing: NoteListing {
        struct Search: Equatable {
            let query: String
            let matchAll: Bool
            let scoped, dated, filtered: Bool
            let order: NoteOrder?
            let limit: Int
        }

        var notes: [NoteInfo] = []
        var hits: [SearchHit] = []
        var error: NotesError?
        var listed: [Set<String>?] = []
        var searches: [Search] = []

        func notes(inFolders ids: Set<String>?) throws(NotesError) -> [NoteInfo] {
            listed.append(ids)
            if let error { throw error }
            return notes
        }

        func search(_ query: String, matchAll: Bool, in scope: NotesStore.Scope?, modified: DateWindow, created: DateWindow,
                    filter: NoteFilter, order: NoteOrder?, limit: Int) throws(NotesError) -> (total: Int, hits: [SearchHit]) {
            searches.append(Search(query: query, matchAll: matchAll, scoped: scope != nil, dated: !modified.isEmpty || !created.isEmpty,
                                   filtered: !filter.isEmpty, order: order, limit: limit))
            if let error { throw error }
            return (hits.count, hits)
        }
    }

    /// A local time on a day of October 2026.
    static func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    static func note(_ id: String, _ title: String = "A note", in folder: [String] = ["Notes"], modified: Date = at(27, 9, 5),
                     locked: Bool = false) -> NoteInfo {
        NoteInfo(id: id, title: title, folderID: "F1", folderNames: folder, modified: modified, created: modified, pinned: false,
                 locked: locked, shared: false, sharedReadOnly: false, inTrash: false, uri: "x-coredata://\(id)", quickNote: false,
                 host: nil, hasChecklist: false, checklistInProgress: false, opened: nil)
    }

    /// What `run` writes and fails with, and its status.
    static func run(_ words: [String], _ listing: Listing) -> (status: Int32, lines: [String], failures: [String]) {
        var lines: [String] = [], failures: [String] = []
        let status = ListJSON.run(words, from: listing, write: { lines.append($0) }, fail: { failures.append($0) })
        return (status, lines, failures)
    }

    static func object(_ line: String) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(line.utf8))
    }

    @Test func listsEveryNoteNotLockedNewestFirst() throws {
        let listing = Listing()
        listing.notes = [Self.note("A", modified: Self.at(20, 9, 0)), Self.note("B", modified: Self.at(27, 9, 5), locked: true),
                         Self.note("C", modified: Self.at(25, 18, 30)), Self.note("D", modified: Self.at(26, 7, 0))]
        let rows = try ListJSON.rows(["--list-json"], from: listing)
        #expect(rows.map(\.id) == ["D", "C", "A"])
        #expect(listing.listed.count == 1 && listing.listed[0] == nil, "every folder")
        #expect(listing.searches.isEmpty)
    }

    @Test func aListedNoteHasItsWholeValuesAndNoSnippet() throws {
        let id = "134264EA-767E-4723-8F0B-2C3D4E5F6A7B"
        let title = "Quarterly plan | \"draft\" " + String(repeating: "x", count: 80)
        let listing = Listing()
        listing.notes = [Self.note(id, title, in: ["Work", "Q3/Q4"], modified: Self.at(27, 9, 5))]
        let rows = try ListJSON.rows(["--list-json"], from: listing)
        #expect(rows == [ListJSON.Row(id: id, title: title, folder: "Work/Q3\\/Q4", modified: "2026-10-27 09:05", snippet: nil)])
    }

    @Test(arguments: [["--list-json", ""], ["--list-json", "  "], ["--list-json", " ", "\t"]])
    func aQueryOfOnlySpacesListsEveryNote(words: [String]) throws {
        let listing = Listing()
        listing.notes = [Self.note("A")]
        #expect(try ListJSON.rows(words, from: listing).map(\.id) == ["A"])
        #expect(listing.searches.isEmpty)
    }

    @Test(arguments: [(["--list-json", "tax", "return"], "tax return"), (["--list-json", "  tax return "], "tax return"),
                      (["--list-json", "setup"], "setup")])
    func aQuerySearchesEveryNoteForAllItsWords(words: [String], query: String) throws {
        let listing = Listing()
        _ = try ListJSON.rows(words, from: listing)
        #expect(listing.searches == [Listing.Search(query: query, matchAll: true, scoped: false, dated: false, filtered: false,
                                                    order: nil, limit: 100)])
        #expect(listing.listed.isEmpty)
    }

    @Test func searchResultsKeepTheirOrderAndSnippets() throws {
        let listing = Listing()
        listing.hits = [SearchHit(note: Self.note("OLD", "Taxes", in: ["Finance"], modified: Self.at(1, 8, 0)), snippet: "…the tax return is due…", length: 40),
                        SearchHit(note: Self.note("NEW", "Scan", modified: Self.at(27, 9, 5)), snippet: "in the text of image: tax return", length: 0)]
        let rows = try ListJSON.rows(["--list-json", "tax", "return"], from: listing)
        #expect(rows == [ListJSON.Row(id: "OLD", title: "Taxes", folder: "Finance", modified: "2026-10-01 08:00", snippet: "…the tax return is due…"),
                         ListJSON.Row(id: "NEW", title: "Scan", folder: "Notes", modified: "2026-10-27 09:05", snippet: "in the text of image: tax return")])
    }

    @Test func eachRowIsOneLineOfJSON() throws {
        let listing = Listing()
        let title = "Plan | \"Q4\" / 计划 \\ ⏎"
        listing.notes = [Self.note("A", title, in: ["Work"], modified: Self.at(27, 9, 5)), Self.note("B", modified: Self.at(26, 9, 5))]
        let (status, lines, failures) = Self.run(["--list-json"], listing)
        #expect(status == 0 && failures.isEmpty)
        #expect(lines.count == 2 && lines.allSatisfy { !$0.contains("\n") })
        #expect(try Self.object(lines[0]) == ["id": "A", "title": title, "folder": "Work", "modified": "2026-10-27 09:05"])
        #expect(try Self.object(lines[1])["id"] == "B")

        listing.hits = [SearchHit(note: Self.note("A", title), snippet: "line one ⏎ line two", length: 20)]
        let found = Self.run(["--list-json", "plan"], listing)
        #expect(found.status == 0 && found.lines.count == 1)
        #expect(try Self.object(found.lines[0])["snippet"] == "line one ⏎ line two")
    }

    /// Notes breaks lines within a paragraph with U+2028; a reader that ends lines there (Python's
    /// splitlines, say) must still get one row per line.
    @Test func lineBreaksInValuesStayOnTheirLine() throws {
        let title = "first\u{2028}second\nthird\r", snippet = "a\u{2029}b\u{85}c"
        let line = ListJSON.line(ListJSON.Row(id: "A", title: title, folder: "Notes", modified: "2026-10-27 09:05", snippet: snippet))
        #expect(line.split(whereSeparator: \.isNewline).count == 1, "\(line)")
        #expect(try Self.object(line) == ["id": "A", "title": title, "folder": "Notes", "modified": "2026-10-27 09:05", "snippet": snippet])
    }

    @Test(arguments: [["--list-json"], ["--list-json", "nothing", "matches"]])
    func nothingToListWritesNothing(words: [String]) {
        let (status, lines, failures) = Self.run(words, Listing())
        #expect(status == 0 && lines.isEmpty && failures.isEmpty)
    }

    @Test(arguments: [(["--list-json"], NotesError.noAccess("Apple Notes MCP needs Full Disk Access.")),
                      (["--list-json"], NotesError.failed("The Notes database could not be read.")),
                      (["--list-json", "tax"], NotesError.refused("the search has no words"))])
    func aStoreErrorIsToldAndExits1(words: [String], error: NotesError) {
        let listing = Listing()
        listing.notes = [Self.note("A")]
        listing.hits = [SearchHit(note: Self.note("A"), snippet: "tax", length: 3)]
        listing.error = error
        let (status, lines, failures) = Self.run(words, listing)
        #expect(status == 1 && lines.isEmpty)
        #expect(failures == [error.description])
    }
}
