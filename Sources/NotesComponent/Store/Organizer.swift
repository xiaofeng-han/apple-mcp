import CoreData
import Foundation
import NoteModel
import NotesShim

// Moving and deleting notes, and managing folders, through Notes' AppleScript:
// - `delete note` moves a note to Recently Deleted; deleting one already there erases it for good,
//   so that is checked first, against Notes' own view.
// - `move note … to folder …` keeps the note's id (it is also what makes Notes upload a change).
// - `make new folder`, `set name of folder` and `delete folder` on an empty folder are safe.
// - `move folder` is never used: it reports success, and Notes deletes the folder.
// The store can lag Notes by minutes while Notes is in the background, so every change is
// confirmed through Notes' view (`exists folder id`, `id of notes of folder id`), and this process
// remembers what it changed until the store catches up.

struct Moved {
    var title: String
    var from: String
    var to: String
    var restored: Bool
}

extension NotesStore {
    // MARK: Notes

    func delete(_ id: String, version: String) async throws(NotesError) {
        let note = try noteInfo(id)
        try checkVersion(id, version)
        if note.inTrash { throw .refused("the note is already in Recently Deleted; deleting it again would erase it for good") }
        if note.shared {
            throw .refused("shared notes are not deleted here: deleting one can remove it for everyone it is shared with. Delete it in Notes")
        }
        try guardTitle(note.title)
        let trash = try trashURI(sameAccountAs: try self.note(id).get("folder") as? NSManagedObject)
        func inTrash() throws(NotesError) -> Bool { try AppleScript.notesList("id of notes of folder id \"\(trash)\"").contains(note.uri) }
        if try inTrash() { throw .refused("Notes already has this note in Recently Deleted; deleting it again would erase it for good") }
        try AppleScript.notes("delete note id \"\(note.uri)\"")
        guard try await waitFor(5, inTrash) else {
            throw .failed("Notes did not confirm the delete within 5 seconds; look in Recently Deleted before trying again")
        }
        deletedNotes.insert(id)
        saveNotes(trash: trash)
    }

    /// Moves a note to another folder of its account, or back from Recently Deleted. Moving into or
    /// out of a shared folder changes who sees the note, so it needs `allowShared`.
    func move(_ id: String, to reference: String, allowShared: Bool, version: String) async throws(NotesError) -> Moved {
        let target = try destination(reference)
        let note = try self.note(id)
        let info = info(note)
        try guardTitle(info.title)
        try checkVersion(id, version)
        if note.get("markedForDeletion") as? Bool == true { throw .refused("this note is deleted") }
        if info.locked { throw .refused("locked notes are moved in Notes") }
        let source = note.get("folder") as? NSManagedObject
        let restoring = try isInTrash(info, source: source)
        if !restoring, let source, source.objectID.uriRepresentation().absoluteString == target.uri {
            throw .refused("the note is already in \(target.path)")
        }
        if !restoring, let source, let from = Self.accountID(of: source), let to = target.accountID, from != to {
            throw .refused("notes move only within their account (Notes would copy the note under a new id)")
        }
        let fromShared = !restoring && (source.map(Self.isShared) ?? false)
        if (fromShared || target.shared), !allowShared {
            throw .refused("this move changes who can see the note (a shared folder is involved). Ask the user, then pass allow_shared: true")
        }
        let from = restoring ? "Recently Deleted" : source.map { FolderPath.join(names(of: $0)) } ?? "?"
        try AppleScript.notes("move note id \"\(info.uri)\" to folder id \"\(target.uri)\"")
        let moved = try await waitFor(5) { () throws(NotesError) in
            try AppleScript.notesList("id of notes of folder id \"\(target.uri)\"").contains(info.uri)
        }
        guard moved else { throw .failed("Notes did not confirm the move within 5 seconds; look at the note in Notes before trying again") }
        deletedNotes.remove(id)
        return Moved(title: info.title, from: from, to: target.path, restored: restoring)
    }

    /// Whether Notes has the note in Recently Deleted, by its own view.
    private func isInTrash(_ note: NoteInfo, source: NSManagedObject?) throws(NotesError) -> Bool {
        if note.inTrash { return true }
        for trash in try fetch("ICFolder", NSPredicate(format: "folderType == 1 AND markedForDeletion == NO")) {
            let uri = trash.objectID.uriRepresentation().absoluteString
            if try AppleScript.notesList("id of notes of folder id \"\(uri)\"").contains(note.uri) { return true }
        }
        return false
    }

    /// Makes Notes write out what it holds in memory. AppleScript deletes and renames stay in
    /// Notes' memory until it next saves, which in the background can take a long time, and until
    /// then every other reader of the database (another agent's server, a new one) still sees the
    /// old state. Moving a note that is in Recently Deleted into Recently Deleted makes Notes save
    /// and changes nothing else; a note this process deleted is used when there is one. With
    /// Recently Deleted empty, nothing is done.
    func saveNotes(trash: String) {
        guard let notes = try? AppleScript.notesList("id of notes of folder id \"\(trash)\""), !notes.isEmpty else { return }
        let ours = Set(deletedNotes.compactMap { try? note($0) }.map { $0.objectID.uriRepresentation().absoluteString })
        let pick = notes.first(where: ours.contains) ?? notes[0]
        _ = try? AppleScript.notes("move note id \"\(pick)\" to folder id \"\(trash)\"")
    }

    /// Recently Deleted of a folder's account, as an AppleScript id.
    func trashURI(sameAccountAs folder: NSManagedObject?) throws(NotesError) -> String {
        let account = folder.flatMap(Self.accountID(of:))
        let trash = try fetch("ICFolder", NSPredicate(format: "folderType == 1 AND markedForDeletion == NO"))
            .first { account == nil || Self.accountID(of: $0) == account }
        guard let trash else { throw .failed("Recently Deleted cannot be found") }
        return trash.objectID.uriRepresentation().absoluteString
    }

    struct Destination {
        var uri: String
        var path: String
        var accountID: String?
        var shared: Bool
    }

    /// A folder to move a note into: from the store, or for a folder Notes made moments ago and
    /// has not saved yet, from Notes' view by path.
    private func destination(_ reference: String) throws(NotesError) -> Destination {
        do throws(NotesError) {
            let found = try folder(reference)
            return Destination(uri: found.uri, path: found.path, accountID: found.accountID, shared: found.shared)
        } catch .notFound {
            // Notes' own view by path can find a smart folder; it is never a destination.
            if try smartFolder(reference) != nil { _ = try folder(reference) }
            let names = FolderPath.split(reference)
            guard !names.isEmpty else { throw .notFound("folder \"\(reference)\"") }
            let specifier = names.reversed().map { "folder \(AppleScript.quoted($0))" }.joined(separator: " of ") + " of default account"
            guard let uri = try? AppleScript.notes("get id of \(specifier)") else {
                throw .notFound("folder \"\(reference)\" (overview lists the folders)")
            }
            let parentShared = names.count > 1 ? ((try? folder(FolderPath.join(Array(names.dropLast())))).map(\.shared) ?? false) : false
            return Destination(uri: uri, path: FolderPath.join(names), accountID: nil, shared: parentShared)
        }
    }

    // MARK: Folders

    /// Creates a folder from its path ("Projects/Ideas"); the parent must exist.
    func createFolder(_ path: String) async throws(NotesError) -> String {
        let names = FolderPath.split(path)
        guard let name = names.last else { throw .refused("give the new folder's path, such as \"Projects/Ideas\"") }
        try checkFolderName(name)
        try guardTitle(name, what: "folder names")
        let container: String
        let siblings: [String]
        if names.count > 1 {
            let parentPath = FolderPath.join(Array(names.dropLast()))
            let parent: FolderInfo
            do throws(NotesError) {
                parent = try folder(parentPath)
            } catch .notFound {
                throw .notFound("folder \"\(parentPath)\": create it first, one level at a time")
            }
            if parent.shared { throw .refused("folders are not created inside shared folders here") }
            container = "folder id \"\(parent.uri)\""
            siblings = try folders().filter { $0.parentID == parent.id }.map(\.name)
        } else {
            var account = try object("ICFolder", id: Self.defaultFolderID)?.get("account") as? NSManagedObject
            if account == nil { account = try fetch("ICAccount", NSPredicate(format: "markedForDeletion == NO")).first }
            guard let account else { throw .failed("no Notes account was found") }
            container = "account id \"\(account.objectID.uriRepresentation().absoluteString)\""
            let accountID = string(account, "identifier")
            siblings = try folders().filter { $0.parentID == nil && $0.accountID == accountID }.map(\.name)
        }
        if siblings.contains(where: { $0.lowercased() == name.lowercased() }) { throw .refused("there is already a folder named \"\(name)\" there") }
        guard let uri = try AppleScript.notes("get id of (make new folder at \(container) with properties {name:\(AppleScript.quoted(name))})") else {
            throw .failed("Notes did not return the new folder")
        }
        let made = try await waitFor(5) { () throws(NotesError) in try AppleScript.notes("name of folder id \"\(uri)\"") == name }
        guard made else { throw .failed("Notes did not confirm the new folder within 5 seconds; look in Notes before trying again") }
        if let trash = try? trashURI(sameAccountAs: nil) { saveNotes(trash: trash) }
        return FolderPath.join(names)
    }

    func renameFolder(_ reference: String, to name: String, allowShared: Bool) async throws(NotesError) -> (old: String, new: String) {
        try checkFolderName(name)
        let found = try folder(reference)
        try checkChangeable(found, allowShared: allowShared)
        try guardTitle(name, what: "folder names")
        let siblings = try folders().filter { $0.parentID == found.parentID && $0.accountID == found.accountID && $0.id != found.id }
        if siblings.contains(where: { $0.name.lowercased() == name.lowercased() }) { throw .refused("there is already a folder named \"\(name)\" there") }
        try AppleScript.notes("set name of folder id \"\(found.uri)\" to \(AppleScript.quoted(name))")
        let renamed = try await waitFor(5) { () throws(NotesError) in try AppleScript.notes("name of folder id \"\(found.uri)\"") == name }
        guard renamed else { throw .failed("Notes did not confirm the new name within 5 seconds; look in Notes before trying again") }
        renamedFolders[found.id] = (name, Date())
        if let trash = try? trashURI(sameAccountAs: try object("ICFolder", id: found.id)) { saveNotes(trash: trash) }
        return (found.path, FolderPath.join(Array(found.names.dropLast()) + [name]))
    }

    // MARK: Smart folders

    /// Makes a smart folder of the notes with any (or all) of these tags; they must be in use.
    func createSmartFolder(_ name: String, tags: [String], matchAll: Bool) async throws(NotesError) -> NotesStore.SmartFolder {
        try checkFolderName(name)
        try guardTitle(name, what: "folder names")
        guard !tags.isEmpty else { throw .refused("a smart folder needs tags") }
        for tag in tags {
            if let first = try? notes(taggedWith: tag).notes.first { _ = try repairTags(first.id) }
        }
        let smartNames = try smartFolders().map { $0.name.lowercased() }
        let topNames = try folders().filter { $0.parentID == nil }.map { $0.name.lowercased() }
        if (smartNames + topNames).contains(name.lowercased()) {
            throw .refused("there is already a folder named \"\(name)\"")
        }
        let context = try writeContext()
        var account = try object("ICFolder", id: Self.defaultFolderID, in: context)?.get("account") as? NSManagedObject
        if account == nil { account = try fetch("ICAccount", NSPredicate(format: "markedForDeletion == NO"), in: context).first }
        guard let account else { throw .failed("no Notes account was found") }
        let hashtags = try fetch("ICHashtag", NSPredicate(format: "markedForDeletion == NO AND account == %@", account), in: context)
        var chosen: [NSManagedObject] = []
        for tag in tags {
            let key = Self.tagKey(tag)
            guard let found = hashtags.first(where: { Self.tagKey(string($0, "displayText")) == key || string($0, "standardizedContent") == key.uppercased() }) else {
                let known = try tagSummary().map { "#" + $0.name }.joined(separator: ", ")
                throw .notFound("the tag #\(tag) in use" + (known.isEmpty ? " (no note has tags)" : "; tags in use: \(known)"))
            }
            chosen.append(found)
        }
        let id: String
        do {
            id = try shim { try ANNotes.newSmartFolder(named: name, tags: chosen, matchAll: matchAll, account: account) }
            try context.save()
        } catch let error as NotesError {
            context.rollback()
            throw error
        } catch {
            context.rollback()
            throw .failed("saving the smart folder failed: \(error.localizedDescription)")
        }
        refresh()
        guard let made = try smartFolder(id) else { throw .failed("the new smart folder cannot be found") }
        return made
    }

    /// Renames or deletes a smart folder: it holds no notes, so a delete removes only the folder.
    func changeSmartFolder(_ smart: NotesStore.SmartFolder, renameTo name: String?) async throws(NotesError) -> String {
        if let name {
            try checkFolderName(name)
            try guardTitle(name, what: "folder names")
        }
        try guardTitle(smart.name, what: "folders named")
        let context = try writeContext()
        guard let folder = try object("ICFolder", id: smart.id, in: context) else { throw .notFound("smart folder \(smart.name) in Notes' data") }
        do {
            if let name { try shim { try ANNotes.renameFolder(folder, to: name) } } else { try shim { try ANNotes.mark(forDeletion: folder) } }
            try context.save()
        } catch let error as NotesError {
            context.rollback()
            throw error
        } catch {
            context.rollback()
            throw .failed("saving the change failed: \(error.localizedDescription)")
        }
        refresh()
        return name ?? smart.name
    }

    /// Puts a folder, with everything in it, inside another folder of its account, or at the top
    /// (`parent` nil). Done in Notes' data rather than by AppleScript (whose `move folder` deletes
    /// the folder), then confirmed in Notes' own view.
    func moveFolder(_ reference: String, into parentReference: String?, allowShared: Bool) async throws(NotesError) -> (old: String, new: String) {
        let found = try folder(reference)
        try checkChangeable(found, allowShared: allowShared)
        let parent = try parentReference.map { reference throws(NotesError) in try folder(reference) }
        if let parent {
            if parent.id == found.id || parent.names.starts(with: found.names) { throw .refused("a folder cannot go inside itself") }
            if parent.accountID != found.accountID { throw .refused("folders move only within their account") }
            if parent.shared != found.shared || parent.shared, !allowShared {
                throw .refused("this move changes who can see the folder's notes (a shared folder is involved). Ask the user, then pass allow_shared: true")
            }
            try guardTitle(parent.name, what: "folders named")
        }
        if parent?.id == found.parentID { throw .refused("\(found.path) is already there") }
        let siblings = try folders().filter { $0.parentID == parent?.id && $0.accountID == found.accountID && $0.id != found.id }
        if siblings.contains(where: { $0.name.lowercased() == found.name.lowercased() }) {
            throw .refused("there is already a folder named \"\(found.name)\" there")
        }
        let depth = (parent?.names.count ?? (multipleAccountsShown ? 1 : 0)) + (try folders().filter { $0.names.starts(with: found.names) }.map { $0.names.count - found.names.count + 1 }.max() ?? 1)
        if depth > 10 + (multipleAccountsShown ? 1 : 0) { throw .refused("Notes nests folders at most 10 deep") }
        let context = try writeContext()
        guard let object = try self.object("ICFolder", id: found.id, in: context) else { throw .notFound("folder \(found.path) in Notes' data") }
        let parentObject = try parent.map { p throws(NotesError) -> NSManagedObject in
            guard let o = try self.object("ICFolder", id: p.id, in: context) else { throw .notFound("folder \(p.path) in Notes' data") }
            return o
        }
        do {
            try shim { try ANNotes.moveFolder(object, into: parentObject) }
            try context.save()
        } catch let error as NotesError {
            context.rollback()
            throw error
        } catch {
            context.rollback()
            throw .failed("saving the move failed: \(error.localizedDescription)")
        }
        let container: String
        if let parent { container = "folder id \"\(parent.uri)\"" } else { container = try accountSpecifier(of: found) }
        let arrived = try await waitFor(10) { () throws(NotesError) in
            try AppleScript.notesList("id of folders of \(container)").contains(found.uri)
        }
        refresh()
        let new = FolderPath.join((parent?.names ?? (multipleAccountsShown ? Array(found.names.prefix(1)) : [])) + [found.name])
        guard arrived else {
            throw .failed("the move is saved in Notes' data, but Notes does not show \(found.name) in \(parent?.path ?? "the top level") yet; "
                + "look in Notes (quitting and opening Notes shows it) before trying again")
        }
        return (found.path, new)
    }

    private var multipleAccountsShown: Bool { (try? fetch("ICAccount", NSPredicate(format: "markedForDeletion == NO")).count) ?? 1 > 1 }

    /// The AppleScript specifier of a folder's account.
    private func accountSpecifier(of folder: FolderInfo) throws(NotesError) -> String {
        guard let object = try object("ICFolder", id: folder.id), let account = object.get("account") as? NSManagedObject else {
            throw .failed("the folder's account cannot be found")
        }
        return "account id \"\(account.objectID.uriRepresentation().absoluteString)\""
    }

    /// Deletes an empty folder. A folder that still holds anything is refused, so one call never
    /// sends many notes to Recently Deleted by surprise.
    func deleteFolder(_ reference: String, save: Bool = true) async throws(NotesError) -> String {
        let found = try folder(reference)
        try checkChangeable(found, allowShared: false)
        if found.shared { throw .refused("shared folders are not deleted here; delete it in Notes") }
        // Notes' view decides: the store can lag notes just moved in or out. `folders of folder`
        // keeps listing subfolders Notes deleted, so each one is checked with `exists`.
        let notes = Int(try AppleScript.notes("count notes of folder id \"\(found.uri)\"") ?? "") ?? 0
        let candidates = Set(try AppleScript.notesList("id of folders of folder id \"\(found.uri)\"")
            + (try folders()).filter { $0.parentID == found.id }.map(\.uri))
        var subfolders = 0
        for uri in candidates where try AppleScript.notes("exists folder id \"\(uri)\"") == "true" { subfolders += 1 }
        if notes > 0 || subfolders > 0 {
            throw .refused("\(found.path) is not empty (\(notes) notes and \(subfolders) folders directly in it). To delete it with "
                + "everything in it, after the user agrees: recursive: true and expected_notes, the number of notes in it and its folders")
        }
        try AppleScript.notes("delete folder id \"\(found.uri)\"")
        let gone = try await waitFor(5) { () throws(NotesError) in try AppleScript.notes("exists folder id \"\(found.uri)\"") == "false" }
        guard gone else { throw .failed("Notes did not confirm the delete within 5 seconds; look in Notes before trying again") }
        deletedFolders.insert(found.id)
        if save, let trash = try? trashURI(sameAccountAs: try object("ICFolder", id: found.id)) { saveNotes(trash: trash) }
        return found.path
    }

    /// Deletes a folder with everything in it: every note goes to Recently Deleted, then the
    /// folders go, deepest first. `expected` is the number of notes the caller saw, so a call never
    /// removes more than was looked at. Everything is checked before the first change: no shared or
    /// locked notes, no shared or smart folders, and Notes' view must agree with the store.
    func deleteFolderTree(_ reference: String, expected: Int) async throws(NotesError) -> (path: String, notes: Int, folders: Int) {
        let root = try folder(reference)
        try checkChangeable(root, allowShared: false)
        if root.shared { throw .refused("shared folders are not deleted here; delete it in Notes") }
        let all = try folders()
        var tree = [root]
        var next = 0
        while next < tree.count {
            tree += all.filter { $0.parentID == tree[next].id }
            next += 1
        }
        let rootObject = try object("ICFolder", id: root.id)
        let trash = try trashURI(sameAccountAs: rootObject)
        var problems: [String] = []
        var targets: [(id: String, uri: String)] = []
        for folder in tree {
            if folder.id != root.id, folder.shared { problems.append("\(folder.path) is shared") }
            if let writeGuard, !folder.name.hasPrefix(writeGuard) { problems.append("\(folder.path) is not named \"\(writeGuard)…\" (write guard)") }
            let stored = try fetch("ICNote", NSPredicate(format: "markedForDeletion == NO AND folder.identifier == %@", folder.id))
                .map(info).filter { !deletedNotes.contains($0.id) }
            for note in stored {
                let label = "\"\(note.title)\" in \(folder.path)"
                if note.locked { problems.append("\(label) is locked") }
                if note.shared { problems.append("\(label) is shared") }
                if let writeGuard, !note.title.hasPrefix(writeGuard) { problems.append("\(label) is not titled \"\(writeGuard)…\" (write guard)") }
                targets.append((note.id, note.uri))
            }
            // Only what both Notes and the store show is deleted; where they differ, Notes has
            // changes it has not saved yet.
            let live = Set(try AppleScript.notesList("id of notes of folder id \"\(folder.uri)\""))
            var liveFolders: Set<String> = []
            for uri in try AppleScript.notesList("id of folders of folder id \"\(folder.uri)\"")
            where try AppleScript.notes("exists folder id \"\(uri)\"") == "true" {
                liveFolders.insert(uri)
            }
            if live != Set(stored.map(\.uri)) || liveFolders != Set(all.filter { $0.parentID == folder.id }.map(\.uri)) {
                throw .refused("Notes has changes in \(folder.path) that it has not saved yet; try again in a minute. Nothing was deleted.")
            }
        }
        if !problems.isEmpty {
            let shown = problems.prefix(10).joined(separator: "; ") + (problems.count > 10 ? "; and \(problems.count - 10) more" : "")
            throw .refused("\(root.path) cannot be deleted with its contents: \(shown). Move these out or change them in Notes first. Nothing was deleted.")
        }
        guard targets.count == expected else {
            throw .refused("\(root.path) holds \(targets.count) notes (its folders included), not \(expected). Look at it again with overview. Nothing was deleted.")
        }
        func trashed() throws(NotesError) -> Set<String> { Set(try AppleScript.notesList("id of notes of folder id \"\(trash)\"")) }
        let wanted = Set(targets.map(\.uri))
        if !wanted.isDisjoint(with: try trashed()) {
            throw .refused("Notes already has some of these notes in Recently Deleted; deleting them again would erase them for good. Nothing was deleted.")
        }
        var failure: NotesError?
        for start in stride(from: 0, to: targets.count, by: 50) {
            let commands = targets[start..<min(start + 50, targets.count)].map { "delete note id \"\($0.uri)\"" }
            do throws(NotesError) {
                _ = try AppleScript.run("tell application \"Notes\"\n" + commands.joined(separator: "\n") + "\nend tell")
            } catch {
                failure = error
                break
            }
        }
        var moved: Set<String> = []
        _ = try await waitFor(failure == nil ? 5 + 0.1 * Double(targets.count) : 5) { () throws(NotesError) in
            moved = wanted.intersection((try? trashed()) ?? [])
            return moved.count == wanted.count
        }
        deletedNotes.formUnion(targets.filter { moved.contains($0.uri) }.map(\.id))
        if moved.count < wanted.count {
            throw .failed("\(moved.count) of \(wanted.count) notes went to Recently Deleted"
                + (failure.map { ", then Notes reported: \($0)" } ?? "; Notes did not confirm the rest in time")
                + ". No folder was deleted. Look at \(root.path) in Notes before trying again.")
        }
        var deleted = 0
        for folder in tree.reversed() {
            do throws(NotesError) {
                _ = try await deleteFolder(folder.id, save: false)
                deleted += 1
            } catch {
                throw .failed("All \(wanted.count) notes went to Recently Deleted and \(deleted) of \(tree.count) folders were deleted, then: \(error) Look at \(root.path) in Notes before trying again.")
            }
        }
        saveNotes(trash: trash)
        return (root.path, wanted.count, deleted)
    }

    private func checkFolderName(_ name: String) throws(NotesError) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw .refused("the folder name is empty") }
        guard !name.contains("/") else { throw .refused("a folder name cannot contain \"/\", which separates folders in a path") }
        guard name.count <= 100 else { throw .refused("folder names are limited to 100 characters here") }
    }

    private func checkChangeable(_ folder: FolderInfo, allowShared: Bool) throws(NotesError) {
        if folder.id == Self.defaultFolderID { throw .refused("Notes' own \"\(folder.name)\" folder cannot be renamed or deleted") }
        if folder.shared, !allowShared {
            throw .refused("this folder is shared, so a new name changes it for everyone. Ask the user, then pass allow_shared: true")
        }
        try guardTitle(folder.name, what: "folders named")
    }

    /// The write guard, for a note title or a folder name.
    func guardTitle(_ title: String, what: String = "notes titled") throws(NotesError) {
        if let writeGuard, !title.hasPrefix(writeGuard) {
            throw .refused("Refused by the write guard: only \(what) \"\(writeGuard)…\" may be changed.")
        }
    }
}
