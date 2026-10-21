import CoreData
import CryptoKit
import Foundation
import NoteModel
import NotesShim

struct FolderInfo: Sendable {
    let id: String
    let name: String
    /// Names from the top-level folder down to this one, with the account's name first when
    /// there is more than one account.
    let names: [String]
    let parentID: String?
    let noteCount: Int
    /// Notes' AppleScript id (an x-coredata URI).
    let uri: String
    let accountID: String?
    /// Shared through iCloud, itself or through a folder it is in.
    let shared: Bool

    var path: String { FolderPath.join(names) }
}

struct NoteInfo: Sendable {
    let id: String
    let title: String
    let folderID: String
    let folderNames: [String]
    let modified: Date
    let created: Date
    let pinned: Bool
    let locked: Bool
    let shared: Bool
    let sharedReadOnly: Bool
    let inTrash: Bool
    let uri: String

    var folderPath: String { inTrash ? "Recently Deleted" : FolderPath.join(folderNames) }
}

/// The iCloud state of a note: its local changes are uploaded once `synced` reaches `local`.
struct CloudState: Sendable {
    var local: Int
    var synced: Int
    /// Tables of the note whose latest change is not uploaded yet (each table is a record of its own).
    var pendingTables: [String]
    var noteSynced: Bool { synced >= local }
    var uploaded: Bool { noteSynced && pendingTables.isEmpty }
}

struct WriteResult: Sendable {
    var id: String
    var title: String
    var version: String
    /// Set when the note does not read back exactly as written.
    var mismatch: String?
    /// Tables this write edited in place.
    var tablesEdited: [String] = []
}

/// Apple Notes for the tools. Reads go through Notes' own data model on a read-only store; writes
/// go through Notes' shared context, in place (BodyWriter). Notes.app saves to the store lazily, so
/// this class also remembers what it changed itself until the store shows it.
@MainActor
final class NotesStore {
    /// While set (development and checks), only notes whose title starts with this, and folders
    /// whose name does, may be changed.
    let writeGuard: String?

    private var readContext: NSManagedObjectContext?
    /// Notes this process moved to Recently Deleted; the store may list them where they were for minutes.
    var deletedNotes: Set<String> = []
    /// Folders this process deleted, for the same reason.
    var deletedFolders: Set<String> = []
    /// New names of folders this process renamed, until the store has them (it kept the old name
    /// for over two minutes once), for at most ten minutes.
    var renamedFolders: [String: (name: String, at: Date)] = [:]
    /// Plain text of notes for search, by id, until the note changes.
    var textCache: [String: (key: String, text: String)] = [:]
    private var multipleAccounts = false

    init(writeGuard: String?) {
        self.writeGuard = writeGuard
    }

    static let defaultFolderID = "DefaultFolder-CloudKit"

    // MARK: The read-only store

    /// Forgets cached objects, so the next read sees what Notes (or a write here) saved since.
    func refresh() {
        readContext?.reset()
    }

    func context() throws(NotesError) -> NSManagedObjectContext {
        if let readContext { return readContext }
        // Checked first: without access, Core Data prints a page of diagnostics to stderr.
        guard Permissions.fullDiskAccess else { throw .noAccess(Permissions.fullDiskHelp) }
        let model: NSManagedObjectModel
        var options: [String: Any]
        do {
            model = try ANNotes.managedObjectModel()
            options = try ANNotes.storeOptions()
        } catch {
            throw .failed(error.localizedDescription)
        }
        options[NSReadOnlyPersistentStoreOption] = true
        options[NSMigratePersistentStoresAutomaticallyOption] = false
        options[NSInferMappingModelAutomaticallyOption] = false
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store: NSPersistentStore
        do {
            store = try coordinator.addPersistentStore(type: .sqlite, at: Permissions.store, options: options)
        } catch {
            throw .noAccess("Could not open the Notes database: \(error.localizedDescription). " + Permissions.fullDiskHelp)
        }
        guard store.isReadOnly else { throw .failed("the Notes database opened writable; stopping") }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.stalenessInterval = 0
        readContext = context
        return context
    }

    func fetch(_ entity: String, _ predicate: NSPredicate, in context: NSManagedObjectContext? = nil) throws(NotesError) -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = predicate
        do {
            return try (context ?? self.context()).fetch(request)
        } catch let error as NotesError {
            throw error
        } catch {
            throw .failed("reading \(entity) failed: \(error.localizedDescription)")
        }
    }

    func object(_ entity: String, id: String, in context: NSManagedObjectContext? = nil) throws(NotesError) -> NSManagedObject? {
        try fetch(entity, NSPredicate(format: "identifier == %@", id), in: context).first
    }

    func note(_ id: String, in context: NSManagedObjectContext? = nil) throws(NotesError) -> NSManagedObject {
        guard let note = try object("ICNote", id: id, in: context) else { throw .notFound("note \(ShortID.of(id))") }
        return note
    }

    // MARK: Folders

    /// Folders Notes shows (as its predicateForVisibleObjects): a folder that "needs initial fetch
    /// from cloud" is a placeholder for a record Notes never downloaded, which it hides.
    static let visibleFolders = "markedForDeletion == NO AND needsInitialFetchFromCloud == NO"
    static let userFolders = visibleFolders + " AND folderType != 1 AND smartFolderQueryJSON == nil"

    /// User folders (no Recently Deleted, no smart folders) in path order.
    func folders() throws(NotesError) -> [FolderInfo] {
        multipleAccounts = try fetch("ICAccount", NSPredicate(format: "markedForDeletion == NO")).count > 1
        let folders = try fetch("ICFolder", NSPredicate(format: Self.userFolders))
            .filter { !deletedFolders.contains(string($0, "identifier")) }
        var counts: [NSManagedObjectID: Int] = [:]
        for note in try fetch("ICNote", NSPredicate(format: "markedForDeletion == NO")) where !deletedNotes.contains(string(note, "identifier")) {
            if let folder = note.get("folder") as? NSManagedObject { counts[folder.objectID, default: 0] += 1 }
        }
        return folders.map { folder in
            FolderInfo(
                id: string(folder, "identifier"), name: name(of: folder), names: names(of: folder),
                parentID: (folder.get("parent") as? NSManagedObject).map { string($0, "identifier") },
                noteCount: counts[folder.objectID] ?? 0, uri: folder.objectID.uriRepresentation().absoluteString,
                accountID: Self.accountID(of: folder), shared: Self.isShared(folder))
        }.sorted { a, b in
            for (x, y) in zip(a.names, b.names) where x != y { return x.localizedStandardCompare(y) == .orderedAscending }
            return a.names.count < b.names.count
        }
    }

    /// A user folder by id, short id, or path ("Parent/Child", case-insensitive), or by its own
    /// name when that is unique.
    func folder(_ reference: String) throws(NotesError) -> FolderInfo {
        let all = try folders()
        if let byID = all.first(where: { $0.id == reference || ShortID.of($0.id) == reference }) { return byID }
        let wanted = reference.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
        let exact = all.filter { $0.path.lowercased() == wanted || $0.names.joined(separator: "/").lowercased() == wanted }
        if exact.count == 1 { return exact[0] }
        let byEnd = all.filter { f in
            f.name.lowercased() == wanted || f.path.lowercased().hasSuffix("/" + wanted) || f.names.joined(separator: "/").lowercased().hasSuffix("/" + wanted)
        }
        if byEnd.count == 1 { return byEnd[0] }
        if byEnd.isEmpty && exact.isEmpty { throw .notFound("folder \"\(reference)\" (overview lists the folders)") }
        let candidates = exact.isEmpty ? byEnd : exact
        throw .refused("\"\(reference)\" could be several folders: " + candidates.map { "\($0.path) (id \(ShortID.of($0.id)))" }.joined(separator: ", "))
    }

    func names(of folder: NSManagedObject) -> [String] {
        var names: [String] = []
        var current: NSManagedObject? = folder
        while let f = current {
            names.insert(name(of: f), at: 0)
            current = f.get("parent") as? NSManagedObject
        }
        if multipleAccounts, let account = (folder.get("account") as? NSManagedObject)?.get("name") as? String {
            names.insert(account, at: 0)
        }
        return names
    }

    /// A folder's name as Notes shows it: the store's, unless this process renamed the folder and
    /// the store has not caught up.
    func name(of folder: NSManagedObject) -> String {
        let stored = string(folder, "title")
        let id = string(folder, "identifier")
        guard let renamed = renamedFolders[id] else { return stored }
        if stored == renamed.name || Date().timeIntervalSince(renamed.at) > 600 {
            renamedFolders[id] = nil
            return stored
        }
        return renamed.name
    }

    static func isTrash(_ folder: NSManagedObject?) -> Bool { (folder?.get("folderType") as? Int) == 1 }

    static func accountID(of folder: NSManagedObject) -> String? {
        (folder.get("account") as? NSManagedObject)?.get("identifier") as? String
    }

    static func isShared(_ folder: NSManagedObject) -> Bool {
        var current: NSManagedObject? = folder
        while let f = current {
            if f.get("serverShareData") != nil { return true }
            current = f.get("parent") as? NSManagedObject
        }
        return false
    }

    // MARK: Notes

    func info(_ note: NSManagedObject) -> NoteInfo {
        let folder = note.get("folder") as? NSManagedObject
        let id = string(note, "identifier")
        return NoteInfo(
            id: id, title: string(note, "title"), folderID: folder.map { string($0, "identifier") } ?? "",
            folderNames: folder.map(names(of:)) ?? [],
            modified: note.get("modificationDate") as? Date ?? .distantPast, created: note.get("creationDate") as? Date ?? .distantPast,
            pinned: note.get("isPinned") as? Bool ?? false, locked: note.get("isPasswordProtected") as? Bool ?? false,
            shared: note.get("serverShareData") != nil || folder.map(Self.isShared) ?? false,
            sharedReadOnly: note.get("isSharedReadOnly") as? Bool ?? false,
            inTrash: Self.isTrash(folder) || deletedNotes.contains(id), uri: note.objectID.uriRepresentation().absoluteString)
    }

    func noteInfo(_ id: String) throws(NotesError) -> NoteInfo {
        info(try note(id))
    }

    /// Notes in these folders, or in every user folder when nil. Not in Recently Deleted.
    func notes(inFolders ids: Set<String>?) throws(NotesError) -> [NoteInfo] {
        _ = try folders()  // sets multipleAccounts for the paths
        let predicate = ids.map { NSPredicate(format: "markedForDeletion == NO AND folder.identifier IN %@", Array($0)) }
            ?? NSPredicate(format: "markedForDeletion == NO AND folder.folderType != 1")
        return try fetch("ICNote", predicate).map(info).filter { !$0.inTrash && !deletedFolders.contains($0.folderID) }
    }

    /// Notes titled `title` (ignoring case and surrounding spaces), newest first.
    func notes(titled title: String) throws(NotesError) -> [NoteInfo] {
        _ = try folders()
        let wanted = title.trimmingCharacters(in: .whitespaces)
        return try fetch("ICNote", NSPredicate(format: "title ==[c] %@ AND markedForDeletion == NO", wanted)).map(info)
            .filter { !$0.inTrash }.sorted { $0.modified > $1.modified }
    }

    /// A note's full id from its id or a prefix of it.
    func resolveNote(_ reference: String) throws(NotesError) -> String {
        try resolve(reference, in: ["ICNote"], what: "note")
    }

    func resolveAttachment(_ reference: String) throws(NotesError) -> String {
        try resolve(reference, in: ["ICAttachment", "ICInlineAttachment"], what: "attachment")
    }

    private func resolve(_ reference: String, in entities: [String], what: String) throws(NotesError) -> String {
        let wanted = reference.trimmingCharacters(in: .whitespaces)
        var ids: [String] = []
        for entity in entities {
            if try object(entity, id: wanted) != nil { return wanted }
            guard wanted.count >= 4 else { continue }
            ids += try fetch(entity, NSPredicate(format: "identifier BEGINSWITH[c] %@", wanted)).map { string($0, "identifier") }
        }
        switch ShortID.resolve(wanted, in: ids) {
        case .found(let id): return id
        case .none: throw .notFound("\(what) \(reference)")
        case .ambiguous(let all): throw .refused("\(reference) matches several \(what)s (\(all.joined(separator: ", "))); give more of the id")
        }
    }

    /// The note body as blocks.
    func blocks(_ id: String) throws(NotesError) -> [Block] {
        let note = try note(id)
        if note.get("isPasswordProtected") as? Bool == true { throw .refused("this note is locked; locked notes cannot be read") }
        let body: NSAttributedString
        do {
            body = try ANNotes.body(of: note)
        } catch {
            throw .failed(error.localizedDescription)
        }
        return try BodyReader(context: try context()).blocks(body)
    }

    /// A short hash of the note as Markdown, passed back on writes so a note changed since it was
    /// read is not overwritten. Content only: the store's modification dates lag Notes.app.
    nonisolated static func version(of blocks: [Block]) -> String {
        SHA256.hash(data: Data(Markdown.render(blocks).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    func cloudState(_ id: String) throws(NotesError) -> CloudState {
        refresh()
        let note = try note(id)
        var local = 0, synced = 0
        guard ANNotes.cloudState(of: note, local: &local, synced: &synced) else { throw .failed("Notes reported no iCloud state for the note") }
        var pending: [String] = []
        for attachment in (note.get("attachments") as? Set<NSManagedObject>) ?? []
        where attachment.get("typeUTI") as? String == "com.apple.notes.table" && attachment.get("markedForDeletion") as? Bool != true {
            var tableLocal = 0, tableSynced = 0
            if ANNotes.cloudState(of: attachment, local: &tableLocal, synced: &tableSynced), tableSynced < tableLocal {
                pending.append(string(attachment, "identifier"))
            }
        }
        return CloudState(local: local, synced: synced, pendingTables: pending)
    }

    func string(_ object: NSManagedObject, _ key: String) -> String {
        object.get(key) as? String ?? ""
    }
}

extension NSObject {
    /// A property of a Notes object; nil when it has none (never an exception).
    func get(_ key: String) -> Any? {
        ANNotes.value(forKey: key, of: self)
    }
}
