import AppCore
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
    func update(_ id: String, version expected: String, _ change: ([Block]) throws(NotesError) -> [Block]) throws(NotesError) -> WriteResult {
        let context = try writeContext()
        let note = try note(id, in: context)
        context.refresh(note, mergeChanges: false)
        try checkWritable(note)
        let writer = try BodyWriter(note: note, context: context)
        let current = try writer.currentBlocks()
        let version = Self.version(of: current)
        if expected.trimmingCharacters(in: .whitespaces).lowercased() != version {
            throw .conflict("\"\(string(note, "title"))\" changed after it was read (version \(version), not \(expected)). Read it again, then make the change.")
        }
        // Tools show attachment ids shortened; give them their full ids back.
        let known = current.attachments.map(\.id)
        let target = try resolveLinks(try change(current).mappingAttachmentIDs { id in
            if case .found(let full) = ShortID.resolve(id, in: known) { return full }
            return id
        })
        if let writeGuard, !target.title.hasPrefix(writeGuard) {
            throw .refused("Refused by the write guard: the title must keep starting with \"\(writeGuard)\".")
        }
        try backUp(note, id: id)
        do {
            try writer.write(target)
            try save(context)
            if try writer.reviveTags(), context.hasChanges { try save(context) }
        } catch {
            // Drop the half-made change at once, so Notes' autosave cannot keep it.
            context.rollback()
            context.refresh(note, mergeChanges: false)
            for table in writer.tablesEdited { context.refresh(table, mergeChanges: false) }
            throw error
        }
        var result = try readBack(id, expecting: writer.expected ?? target)
        result.tablesEdited = writer.tablesEdited.map { string($0, "identifier") }
        result.added = writer.added
        return result
    }

    /// Pins or unpins a note; the version is checked by the caller's edit, or here when the pin is
    /// the whole change.
    func setPinned(_ id: String, _ pinned: Bool, version expected: String?) throws(NotesError) -> WriteResult {
        if let expected { try checkVersion(id, expected) }
        let context = try writeContext()
        let note = try note(id, in: context)
        context.refresh(note, mergeChanges: false)
        try checkWritable(note)
        if note.get("isPinned") as? Bool != pinned {
            do {
                try shim { try ANNotes.setPinned(pinned, of: note) }
                try save(context)
            } catch {
                context.rollback()
                throw error
            }
        }
        refresh()
        let info = try noteInfo(id)
        return WriteResult(id: id, title: info.title, version: try version(of: id))
    }

    /// New links to notes as the note will read back: the note's short id, and its title when the
    /// link has no text of its own.
    func resolveLinks(_ blocks: [Block]) throws(NotesError) -> [Block] {
        try blocks.map { block throws(NotesError) -> Block in
            guard case .paragraph(var p) = block else { return block }
            p.pieces = try p.pieces.map { piece throws(NotesError) -> Piece in
                guard case .attachment(let a) = piece, a.id.isEmpty, let (text, reference) = a.linkParts else { return piece }
                let target = try noteInfo(try resolveNote(reference))
                return .attachment(.noteLink(text.isEmpty ? target.title : text, to: ShortID.of(target.id)))
            }
            return .paragraph(p)
        }
    }

    /// Creates a note in a folder (by default Notes' own "Notes" folder).
    func create(in folderID: String?, _ blocks: [Block]) throws(NotesError) -> WriteResult {
        let blocks = try resolveLinks(blocks)
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
        let writer: BodyWriter
        do {
            writer = try BodyWriter(note: note, context: context)
            try writer.write(blocks)
            try save(context)
            if try writer.reviveTags(), context.hasChanges { try save(context) }
        } catch {
            context.rollback()
            throw error
        }
        var result = try readBack(id, expecting: writer.expected ?? blocks)
        result.added = writer.added
        return result
    }

    /// Copies a note with everything in it into a folder (by default the note's own), as Notes'
    /// Duplicate Note does. The copy is made by another run of this app (`--copy-note`), because
    /// Notes' code for it changes how this process would save later edits.
    func duplicate(_ id: String, into folderID: String?) throws(NotesError) -> WriteResult {
        let source = try noteInfo(id)
        if source.locked { throw .refused("locked notes are copied in Notes") }
        if source.inTrash { throw .refused("this note is deleted; move it back to a folder first") }
        try guardTitle(source.title)
        if let folderID, let folder = try object("ICFolder", id: folderID), Self.isShared(folder), folder.get("isSharedReadOnly") as? Bool == true {
            throw .refused("that folder is shared with you read-only")
        }
        guard let executable = Bundle.main.executablePath else { throw .failed("this app cannot find itself to copy the note") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--copy-note", id] + (folderID.map { [$0] } ?? [])
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw .failed("could not start the copy: \(error.localizedDescription)")
        }
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let problem = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationStatus == 0, !printed.isEmpty else { throw .failed("the copy failed: " + (problem.isEmpty ? "no reason given" : problem)) }
        let copyID = printed
        refresh()
        let copy = try note(copyID)
        let written = try blocks(copyID)
        var result = WriteResult(id: copyID, title: try noteInfo(copyID).title, version: Self.version(of: written))
        result.added = ((copy.get("attachments") as? Set<NSManagedObject>) ?? []).union((copy.get("inlineAttachments") as? Set<NSManagedObject>) ?? [])
            .map { string($0, "identifier") }
        return result
    }

    /// Waits up to `timeout` seconds for a folder changed in Notes' data to be uploaded, which
    /// Notes does on its own within half a minute or so; true when it was.
    func waitForFolderUpload(_ id: String, timeout: Double = 40) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            refresh()
            var local = 0, synced = 0
            if let folder = try? object("ICFolder", id: id), ANNotes.cloudState(of: folder, local: &local, synced: &synced), synced >= local { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// Waits up to `timeout` seconds for notes to be uploaded; returns how many are not.
    func waitForUploads(_ ids: [String], timeout: Double = 30) async -> Int {
        let start = Date()
        while true {
            let waiting = ids.filter { id in !((try? cloudState(id))?.noteSynced ?? false) }.count
            if waiting == 0 || Date().timeIntervalSince(start) >= timeout { return waiting }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// The copy itself, in the process `duplicate` starts: returns the new note's id.
    func copyHere(_ id: String, into folderID: String?) throws(NotesError) -> String {
        let context = try writeContext()
        let note = try note(id, in: context)
        let folder: NSManagedObject?
        if let folderID { folder = try object("ICFolder", id: folderID, in: context) } else { folder = note.get("folder") as? NSManagedObject }
        guard let folder else { throw .notFound("the folder in Notes' data yet; Notes saves a new folder within a minute, try again then") }
        let copy = try shim { try ANNotes.duplicate(note, into: folder) }
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
        return string(copy, "identifier")
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
        let folder = AppSettings.supportDirectory.appendingPathComponent("backups/\(id)", isDirectory: true)
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
    func upload(_ id: String, watching added: [String] = [], timeout: Double = 20, tableGrace: Double = 8) async throws(NotesError) -> CloudState {
        refresh()
        let note = info(try note(id))
        guard let folderURI = (try self.note(id).get("folder") as? NSManagedObject)?.objectID.uriRepresentation().absoluteString else {
            throw .failed("the note has no folder")
        }
        try AppleScript.notes("move note id \"\(note.uri)\" to folder id \"\(folderURI)\"")
        let start = Date()
        var noteUpAt: Date?
        while true {
            let state = try cloudState(id, watching: added)
            if state.uploaded { return state }
            if state.noteSynced, noteUpAt == nil { noteUpAt = Date() }
            if let noteUpAt, Date().timeIntervalSince(noteUpAt) >= tableGrace { return state }
            if Date().timeIntervalSince(start) >= timeout { return state }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
