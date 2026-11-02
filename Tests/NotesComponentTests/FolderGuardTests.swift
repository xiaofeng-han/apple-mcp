import Testing
@testable import NotesComponent

/// APPLE_NOTES_MCP_WRITE_FOLDERS: which folders are inside the folder guard, and how a write outside
/// it is refused.
@MainActor
@Suite struct FolderGuardTests {
    func inside(_ names: [String], _ folders: [String]) -> Bool { NotesStore.insideGuard(names, folders) }

    @Test func aListedFolderAndWhatIsInIt() {
        #expect(inside(["KB", "Wiki"], ["KB/Wiki"]))
        #expect(inside(["KB", "Wiki", "Topics"], ["KB/Wiki"]), "a child")
        #expect(inside(["KB", "Wiki", "Topics", "Swift"], ["KB/Wiki"]), "a grandchild")
        #expect(inside(["KB", "Inbox"], ["KB/Wiki", "KB/Inbox"]), "any of the list")
    }

    @Test func notItsSiblingsOrParents() {
        #expect(!inside(["KB", "Wiki2"], ["KB/Wiki"]), "a sibling whose name starts the same")
        #expect(!inside(["KB", "Wiki 2", "x"], ["KB/Wiki"]))
        #expect(!inside(["KB"], ["KB/Wiki"]), "the parent")
        #expect(!inside(["Notes"], ["KB/Wiki"]))
        #expect(!inside([], ["KB/Wiki"]), "the top level")
    }

    @Test func caseDoesNotMatter() {
        #expect(inside(["kb", "WIKI"], ["KB/Wiki"]))
        #expect(inside(["KB", "Wiki", "Child"], ["kb/wiki"]))
    }

    /// A folder whose name has a "/" is written with "\/" in a path.
    @Test func aNameWithASlash() {
        #expect(inside(["Work", "Q3/Q4"], ["Work/Q3\\/Q4"]))
        #expect(inside(["Work", "Q3/Q4", "Jan"], ["Work/Q3\\/Q4"]))
        #expect(!inside(["Work", "Q3"], ["Work/Q3\\/Q4"]))
        #expect(!inside(["Work", "Q3/Q4"], ["Work/Q3"]), "Q3/Q4 is one folder, not inside Q3")
    }

    @Test func anEmptyListHasNothingInside() {
        #expect(!inside(["KB", "Wiki"], []))
    }

    @Test func aWriteOutsideIsRefused() {
        let store = NotesStore(writeGuard: nil, writeFolders: ["KB/Wiki", "KB/Inbox"])
        #expect(throws: Never.self) { try store.guardFolder(names: ["KB", "Wiki", "Topics"], what: "notes") }
        do {
            try store.guardFolder(names: ["Notes"], what: "notes")
            Issue.record("a note in Notes was let through")
        } catch {
            #expect(error.description == "Refused by the folder guard: only notes in KB/Wiki, KB/Inbox may be changed.")
        }
        do {
            try store.guardSmartFolder()
            Issue.record("a smart folder was let through")
        } catch {
            #expect(error.description == "Refused by the folder guard: only folders in KB/Wiki, KB/Inbox may be changed.")
        }
    }

    @Test func withoutTheGuardEverythingPasses() {
        let store = NotesStore(writeGuard: nil)
        #expect(throws: Never.self) {
            try store.guardFolder(names: ["Anything"], what: "folders")
            try store.guardSmartFolder()
        }
    }
}
