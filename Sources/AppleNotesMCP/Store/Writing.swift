import CoreData
import Foundation
import NoteModel
import NotesShim

extension NotesStore {
    /// Notes' own read-write context, for writes.
    func writeContext() throws(NotesError) -> NSManagedObjectContext {
        guard Permissions.fullDiskAccess else { throw .noAccess(Permissions.fullDiskHelp) }
        return try shim { try ANNotes.sharedContext() }
    }

    /// Changes a note: reads it through the write context, checks the version the caller saw,
    /// lets `change` make the new body, and writes the difference in place. The stored body is
    /// backed up first, and read back afterwards.
    func update(_ id: String, version expected: String?, _ change: ([Block]) throws(NotesError) -> [Block]) throws(NotesError) -> WriteResult {
        let context = try writeContext()
        let note = try note(id, in: context)
        context.refresh(note, mergeChanges: false)
        try checkWritable(note)
        let writer = try BodyWriter(note: note, context: context)
        let current = try writer.currentBlocks()
        let version = Self.version(of: current)
        if let expected, expected != version {
            throw .conflict("The note changed after it was read (version \(version), not \(expected)). Read it again, then make the change.")
        }
        // Tools show attachment ids shortened; give them their full ids back.
        let known = current.attachments.map(\.id)
        let target = try change(current).mappingAttachmentIDs { id in
            if case .found(let full) = ShortID.resolve(id, in: known) { return full }
            return id
        }
        if let writeGuard, !target.title.hasPrefix(writeGuard) {
            throw .refused("Refused by the write guard: the title must keep starting with \"\(writeGuard)\".")
        }
        try backUp(note, id: id)
        do {
            try writer.write(target)
            try save(context)
        } catch {
            // Drop the half-made change at once, so Notes' autosave cannot keep it.
            context.rollback()
            context.refresh(note, mergeChanges: false)
            for table in writer.tablesEdited { context.refresh(table, mergeChanges: false) }
            throw error
        }
        var result = try readBack(id, expecting: target)
        result.tablesEdited = writer.tablesEdited.map { string($0, "identifier") }
        return result
    }

    /// Creates a note in a folder (by default Notes' own "Notes" folder).
    func create(in folderID: String?, _ blocks: [Block]) throws(NotesError) -> WriteResult {
        if let writeGuard, !blocks.title.hasPrefix(writeGuard) {
            throw .refused("Refused by the write guard: the title must start with \"\(writeGuard)\".")
        }
        let context = try writeContext()
        guard let folder = try object("ICFolder", id: folderID ?? Self.defaultFolderID, in: context) else {
            throw .notFound("the folder in Notes' data yet; Notes saves a new folder within a minute, try again then")
        }
        if Self.isShared(folder) && folder.get("isSharedReadOnly") as? Bool == true {
            throw .refused("that folder is shared with you read-only")
        }
        let note = try shim { try ANNotes.newNote(inFolder: folder) }
        let id = string(note, "identifier")
        do {
            try BodyWriter(note: note, context: context).write(blocks)
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
        return try readBack(id, expecting: blocks)
    }

    /// Replaces tables of a note with new tables of the same content.
    ///
    /// The way out when a table changed in place does not upload: that happens when the table was
    /// edited in Notes itself during the current Notes session, because Notes keeps its own copy of
    /// the table's sync state and does not see that this change needs uploading. A new attachment
    /// has no such copy. Formatting inside the cells is lost.
    func rebuildTables(_ id: String, tables: Set<String>) throws(NotesError) -> WriteResult {
        let context = try writeContext()
        let note = try note(id, in: context)
        context.refresh(note, mergeChanges: false)
        try checkWritable(note)
        let writer = try BodyWriter(note: note, context: context)
        let blocks = try writer.currentBlocks()
        try backUp(note, id: id)
        do {
            try writer.rebuild(tables: tables)
            try save(context)
        } catch {
            context.rollback()
            context.refresh(note, mergeChanges: false)
            throw error
        }
        return try readBack(id, expecting: blocks)
    }

    private func save(_ context: NSManagedObjectContext) throws(NotesError) {
        do {
            try context.save()
        } catch {
            throw .failed("saving the note failed: \(error.localizedDescription)")
        }
    }

    /// Reads the note again from the store and compares it with what was written.
    private func readBack(_ id: String, expecting target: [Block]) throws(NotesError) -> WriteResult {
        refresh()
        let written = try blocks(id)
        let info = try noteInfo(id)
        var result = WriteResult(id: id, title: info.title, version: Self.version(of: written))
        if written != target {
            let line = zip(written, target).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(written.count, target.count)
            let got = line < written.count ? Markdown.render([written[line]]) : "nothing"
            let wanted = line < target.count ? Markdown.render([target[line]]) : "nothing"
            result.mismatch = "line \(line + 1) reads \"\(got)\" instead of \"\(wanted)\""
        }
        return result
    }

    func checkWritable(_ note: NSManagedObject) throws(NotesError) {
        let id = string(note, "identifier")
        if deletedNotes.contains(id) { throw .refused("this note was moved to Recently Deleted") }
        if note.get("isPasswordProtected") as? Bool == true { throw .refused("locked notes cannot be changed") }
        if note.get("markedForDeletion") as? Bool == true { throw .refused("this note is deleted") }
        if Self.isTrash(note.get("folder") as? NSManagedObject) { throw .refused("this note is in Recently Deleted; move it back to a folder first (move_note)") }
        // Shared notes are edited like any other: changes are character-level CRDT edits that merge
        // with what the other people write.
        if note.get("isSharedReadOnly") as? Bool == true { throw .refused("this note is shared with you read-only") }
        if let writeGuard, !string(note, "title").hasPrefix(writeGuard) {
            throw .refused("Refused by the write guard: only notes titled \"\(writeGuard)…\" may be changed.")
        }
    }

    /// Keeps the last 20 copies of a note's stored body, so any write can be undone by hand.
    private func backUp(_ note: NSManagedObject, id: String) throws(NotesError) {
        guard let data = (note.get("noteData") as? NSManagedObject)?.get("data") as? Data else { return }
        let folder = Settings.supportDirectory.appendingPathComponent("backups/\(id)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try data.write(to: folder.appendingPathComponent("\(stamp).bin"))
            let old = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "bin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.dropLast(20)
            for file in old { try FileManager.default.removeItem(at: file) }
        } catch {
            throw .failed("could not back up the note before changing it: \(error.localizedDescription)")
        }
    }

    // MARK: iCloud

    /// Gets a change uploaded. Notes does not upload what was saved through NotesShared on its
    /// own; asking it to move the note into the folder it is already in makes it save and upload
    /// the note, silently, without moving it. Then waits for the note to report it is uploaded.
    /// Tables go up with the note when they go up at all, so once the note is up, tables still
    /// waiting after a few seconds are reported rather than waited for.
    func upload(_ id: String, timeout: Double = 20, tableGrace: Double = 8) async throws(NotesError) -> CloudState {
        refresh()
        let note = info(try note(id))
        guard let folderURI = (try self.note(id).get("folder") as? NSManagedObject)?.objectID.uriRepresentation().absoluteString else {
            throw .failed("the note has no folder")
        }
        try AppleScript.notes("move note id \"\(note.uri)\" to folder id \"\(folderURI)\"")
        let start = Date()
        var noteUpAt: Date?
        while true {
            let state = try cloudState(id)
            if state.uploaded { return state }
            if state.noteSynced, noteUpAt == nil { noteUpAt = Date() }
            if let noteUpAt, Date().timeIntervalSince(noteUpAt) >= tableGrace { return state }
            if Date().timeIntervalSince(start) >= timeout { return state }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
