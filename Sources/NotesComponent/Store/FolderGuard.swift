import CoreData
import NoteModel

// The folder guard, APPLE_NOTES_MCP_WRITE_FOLDERS: while it is set, only notes in the folders it
// lists (paths as overview shows them, "KB/Wiki,KB/Inbox") and in the folders inside them may
// change, and only those folders. It stands beside the write guard, which goes by title: with
// both set, a write has to pass both. Smart folders are in no folder, so while it is set none is
// made, renamed or deleted. Reading, export included, is never limited.

extension NotesStore {
    /// Whether a folder, by its names from the top, is one of `folders` or inside one, ignoring
    /// case. A name with "/" in it is written "\/", so "Work/Q3\/Q4" is one folder in Work, and
    /// "KB/Wiki2" is not inside "KB/Wiki".
    nonisolated static func insideGuard(_ names: [String], _ folders: [String]) -> Bool {
        let path = FolderPath.join(names).lowercased()
        return folders.contains { folder in
            let listed = folder.lowercased()
            return path == listed || path.hasPrefix(listed + "/")
        }
    }

    /// Refuses a change to `what` ("notes" or "folders") in the folder with these names, when it is
    /// outside the folder guard.
    func guardFolder(names: [String], what: String) throws(NotesError) {
        guard let writeFolders, !Self.insideGuard(names, writeFolders) else { return }
        throw Self.folderGuardRefusal(writeFolders, what: what)
    }

    /// The same for a note's folder, or a folder, as Notes' data has it.
    func guardFolder(_ folder: NSManagedObject?, what: String) throws(NotesError) {
        guard writeFolders != nil else { return }
        try guardFolder(names: try folder.map { folder throws(NotesError) in try currentNames(of: folder) } ?? [], what: what)
    }

    /// Smart folders are in no folder: none may change while the folder guard is set.
    func guardSmartFolder() throws(NotesError) {
        if let writeFolders { throw Self.folderGuardRefusal(writeFolders, what: "folders") }
    }

    nonisolated static func folderGuardRefusal(_ folders: [String], what: String) -> NotesError {
        .refused("Refused by the folder guard: only \(what) in \(folders.joined(separator: ", ")) may be changed.")
    }
}
