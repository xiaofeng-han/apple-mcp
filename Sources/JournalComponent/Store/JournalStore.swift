import CoreData
import CryptoKit
import Foundation
import JournalShared
import NoteModel

/// A journal as tools show it. Journal always has a default journal ("All Entries" shows every
/// entry); the ones the user makes are its custom journals, which entries may belong to.
struct JournalInfo: Sendable {
    let id: String
    let name: String
    let color: String?
    let icon: String?
    let isDefault: Bool
}

/// An entry as tools show it.
struct EntryInfo: Sendable {
    let id: String
    var title: String
    /// The text without formatting or attachment characters.
    var text: String
    var date: Date
    var created: Date?
    var edited: Date?
    var bookmarked: Bool
    /// When it went to Recently Deleted.
    var deleted: Date?
    /// The ids of the custom journals it is in.
    var journals: [String]
    var assets: [AssetInfo]
    /// Written before Journal 3.0: its text is RTF, not mergeable text.
    var legacy: Bool
    /// The writing prompt it was started from, if any.
    var prompt: String?
    /// What edit_entry and delete_entry check: anything shown here changed since it was read.
    var version: String
}

/// Journal's data, through Journal's own data model (JournalShared). One Core Data context on the
/// main queue reads and writes Journal's store in place; Journal itself notices the changes (the
/// store posts remote change notifications) and uploads what is marked for it to iCloud.
@MainActor
final class JournalStore {
    /// APPLE_JOURNAL_MCP_WRITE_GUARD: while set, only entries whose title starts with it, and
    /// journals whose name does, may be changed.
    let writeGuard: String?
    private var coordinator: NSPersistentStoreCoordinator?
    private var openContext: NSManagedObjectContext?

    init(writeGuard: String?) {
        self.writeGuard = writeGuard
    }

    /// The context, opening the store the first time. Every tool starts from a fresh one
    /// (`refresh`), so it sees what Journal and other devices changed meanwhile.
    func context() throws(JournalError) -> NSManagedObjectContext {
        if let openContext { return openContext }
        if let problem = Compatibility.problem { throw .unsupported(problem) }
        guard Permissions.fullDiskAccess else {
            throw .noAccess(Permissions.hasData ? Permissions.fullDiskHelp : Permissions.noDataHelp)
        }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel.shared)
        let options: [String: Any] = [
            // As Journal opens it: it tracks history, and other processes' saves reach it.
            NSPersistentHistoryTrackingKey: true,
            NSPersistentStoreRemoteChangeNotificationPostOptionKey: true,
            // Never migrate Journal's data; a store in another format is reported instead.
            NSMigratePersistentStoresAutomaticallyOption: false,
            NSInferMappingModelAutomaticallyOption: false,
        ]
        do {
            try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: Permissions.store, options: options)
        } catch {
            if [NSPersistentStoreIncompatibleVersionHashError, NSMigrationMissingSourceModelError].contains((error as NSError).code) {
                throw .unsupported("""
                    Journal's data on this Mac is in a format Apple Journal MCP does not know (it was made for \
                    \(Compatibility.madeFor)); nothing was read or changed. Ask the user to update Apple Journal MCP.
                    """)
            }
            throw .failed("Could not open Journal's data: \(error.localizedDescription)")
        }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.transactionAuthor = Self.author
        context.name = Self.author
        self.coordinator = coordinator
        openContext = context
        return context
    }

    static let author = "apple-journal-mcp"

    func refresh() { openContext?.reset() }

    // MARK: Fetching

    /// Entries Journal shows: not tips, drafts or ones on their way out of iCloud.
    static let visible = NSPredicate(format: """
        (isTip == nil OR isTip == NO) AND (isDraft == nil OR isDraft == NO) AND (isFullyRemoved == nil OR isFullyRemoved == NO) \
        AND (isRemovedFromCloud == nil OR isRemovedFromCloud == NO)
        """)

    func entryObjects(deleted: Bool? = false) throws(JournalError) -> [JournalEntryMO] {
        var predicates = [Self.visible]
        if let deleted { predicates.append(NSPredicate(format: deleted ? "deletedOnDate != nil" : "deletedOnDate == nil")) }
        let request = NSFetchRequest<JournalEntryMO>(entityName: "JournalEntryMO")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        return try fetch(request)
    }

    func journalObjects() throws(JournalError) -> [JournalMO] {
        let request = NSFetchRequest<JournalMO>(entityName: "JournalMO")
        request.predicate = NSPredicate(format: "userDeleted == nil OR userDeleted == NO")
        return try fetch(request)
    }

    func fetch<T>(_ request: NSFetchRequest<T>) throws(JournalError) -> [T] {
        let context = try context()
        do {
            return try context.fetch(request)
        } catch {
            throw .failed("Could not read Journal's data: \(error.localizedDescription)")
        }
    }

    /// An entry by its id, or by the start of it (8 characters or more) when only one matches.
    func entryObject(_ reference: String) throws(JournalError) -> JournalEntryMO {
        let wanted = reference.trimmingCharacters(in: .whitespaces).uppercased()
        let request = NSFetchRequest<JournalEntryMO>(entityName: "JournalEntryMO")
        request.predicate = Self.visible
        if let uuid = UUID(uuidString: wanted) {
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [Self.visible, NSPredicate(format: "id == %@", uuid as CVarArg)])
            if let entry = try fetch(request).first { return entry }
            throw .notFound("an entry with the id \(reference)")
        }
        guard wanted.count >= 8 else { throw .notFound("an entry with the id \(reference); give its id as find_entries shows it") }
        let matches = try fetch(request).filter { Self.id($0).hasPrefix(wanted) }
        guard matches.count == 1 else {
            throw matches.isEmpty ? .notFound("an entry with the id \(reference)") : .refused("\(matches.count) entries have ids starting with \(reference); give more of it")
        }
        return matches[0]
    }

    func journalObject(_ reference: String) throws(JournalError) -> JournalMO {
        let journals = try journalObjects()
        let wanted = reference.trimmingCharacters(in: .whitespaces)
        if let match = journals.first(where: { Self.id($0) == wanted.uppercased() }) { return match }
        let named = journals.filter { name($0).localizedCaseInsensitiveCompare(wanted) == .orderedSame }
        guard let match = named.first else {
            let names = journals.filter { !$0.isDefaultJournal }.map { "\"\(name($0))\"" }
            throw .notFound("a journal \"\(reference)\"" + (names.isEmpty ? "; there are no journals besides the default one" : "; the journals are " + names.joined(separator: ", ")))
        }
        guard named.count == 1 else { throw .refused("\(named.count) journals are called \"\(reference)\"; give its id instead") }
        return match
    }

    // MARK: Reading

    static func id(_ object: NSManagedObject) -> String { (object.value(forKey: "id") as? UUID)?.uuidString ?? "" }

    func name(_ journal: JournalMO) -> String {
        if let title = journal.title, !title.isEmpty { return title }
        return journal.isDefaultJournal ? "Journal" : "Untitled"
    }

    func info(_ journal: JournalMO) -> JournalInfo {
        JournalInfo(id: Self.id(journal), name: name(journal), color: journal.color.flatMap(Appearance.describe),
                    icon: journal.icon.flatMap { $0.emoji ?? $0.sfSymbol }, isDefault: journal.isDefaultJournal)
    }

    /// Whether the entry keeps its text as mergeable text (Journal 3.0) or as RTF.
    static func isLegacy(_ entry: JournalEntryMO) -> Bool { entry.value(forKey: "mergeableAttributes") == nil }

    func title(_ entry: JournalEntryMO) -> String {
        if Self.isLegacy(entry) { return EntryText.fromRTF(entry.value(forKey: "title") as? Data)?.string ?? "" }
        return entry.mergeableAttributedTitle?.attributedString.string ?? ""
    }

    func info(_ entry: JournalEntryMO) -> EntryInfo {
        let legacy = Self.isLegacy(entry)
        let plain = legacy ? EntryText.fromRTF(entry.value(forKey: "text") as? Data)?.string ?? ""
            : entry.mergeableAttributedText?.attributedString.string ?? ""
        let journals = (entry.value(forKey: "journals") as? Set<JournalMO> ?? []).filter { !$0.isDefaultJournal && !(($0.value(forKey: "userDeleted") as? Bool) ?? false) }
        var info = EntryInfo(
            id: Self.id(entry), title: title(entry),
            text: plain.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines),
            date: entry.value(forKey: "entryDate") as? Date ?? entry.displayDate, created: entry.value(forKey: "createdDate") as? Date,
            edited: entry.value(forKey: "updatedDate") as? Date, bookmarked: entry.value(forKey: "flagged") as? Bool ?? false,
            deleted: entry.value(forKey: "deletedOnDate") as? Date, journals: journals.map(Self.id).sorted(),
            assets: assets(entry), legacy: legacy,
            prompt: (EntryText.fromRTF(entry.value(forKey: "prompt") as? Data) ?? EntryText.fromRTF(entry.value(forKey: "reflectionPrompt") as? Data))?.string,
            version: "")
        info.version = Self.version(info)
        return info
    }

    func assets(_ entry: JournalEntryMO) -> [AssetInfo] {
        entry.assetsArray.compactMap { asset in
            func flag(_ key: String) -> Bool { asset.value(forKey: key) as? Bool ?? false }
            guard !flag("isUndoablyDeleted"), !flag("isFullyRemoved"), !flag("isRemovedFromCloud") else { return nil }
            let type = asset.value(forKey: "assetType") as? String ?? "unknown"
            let files = (asset.value(forKey: "fileAttachments") as? Set<NSManagedObject> ?? [])
                .sorted { ($0.value(forKey: "index") as? Int ?? 0) < ($1.value(forKey: "index") as? Int ?? 0) }
                .compactMap { file -> AssetFile? in
                    guard let path = file.value(forKey: "filePath") as? String, !path.isEmpty else { return nil }
                    return AssetFile(name: file.value(forKey: "name") as? String ?? "file", url: Permissions.attachments.appendingPathComponent(path))
                }
            return AssetInfo(id: Self.id(asset), kind: type, hidden: flag("isHidden"),
                             details: AssetDetails.details(type: type, metadata: asset.value(forKey: "assetMetaData") as? Data), files: files)
        }
    }

    /// The entry's text as Markdown, and the attachments placed in it.
    func markdown(_ entry: JournalEntryMO) -> (String, [String: Attachment]) {
        if Self.isLegacy(entry) {
            guard let text = EntryText.fromRTF(entry.value(forKey: "text") as? Data) else { return ("", [:]) }
            let canonical = EntryText.canonical(legacy: text)
            return (EntryText.markdown(canonical, attachments: [:]), [:])
        }
        guard let text = entry.mergeableAttributedText else { return ("", [:]) }
        let (canonical, attachments) = EntryText.canonical(text)
        return (EntryText.markdown(canonical, attachments: attachments), attachments)
    }

    static func version(_ e: EntryInfo) -> String {
        let parts = [e.id, e.title, e.text, "\(e.date.timeIntervalSinceReferenceDate)", "\(e.bookmarked)", "\(e.deleted?.timeIntervalSinceReferenceDate ?? 0)",
                     e.journals.joined(separator: ","), e.assets.map(\.id).joined(separator: ","), "\(e.edited?.timeIntervalSinceReferenceDate ?? 0)"]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether this Mac's Journal syncs with iCloud (it keeps its sync engine's state then); when
    /// it does not, nothing waits for uploads.
    func syncsWithICloud() -> Bool {
        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncDataMO")
        return ((try? fetch(request)) ?? []).contains { ($0.value(forKey: "statedata") as? Data).map { !$0.isEmpty } ?? false }
    }
}

/// Journal colors and icons in words.
enum Appearance {
    /// "#3366CC" for a color of its own, or the name of one of Journal's palette ("cornflower").
    static func describe(_ color: MergeableColor) -> String? {
        if let srgb = color.sRGB, let components = srgb.cgColor?.components, components.count >= 3 {
            return hex(components[0], components[1], components[2])
        }
        // Journal's palette colors are named in the value's description: catalogColor(…AssetCatalogColor.sage…).
        let text = String(describing: color)
        guard let range = text.range(of: "AssetCatalogColor.", options: .backwards) else { return nil }
        let name = text[range.upperBound...].prefix { $0.isLetter || $0.isNumber }
        return name.isEmpty ? nil : String(name)
    }

    static func hex(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// Color names agents may give, as sRGB.
    static let named: [String: (Double, Double, Double)] = [
        "red": (1.0, 0.231, 0.188), "orange": (1.0, 0.584, 0.0), "yellow": (1.0, 0.8, 0.0), "green": (0.204, 0.78, 0.349),
        "mint": (0.0, 0.78, 0.745), "teal": (0.188, 0.69, 0.78), "cyan": (0.196, 0.678, 0.902), "blue": (0.0, 0.478, 1.0),
        "indigo": (0.345, 0.337, 0.839), "purple": (0.686, 0.322, 0.871), "pink": (1.0, 0.176, 0.333), "brown": (0.635, 0.518, 0.369),
        "gray": (0.557, 0.557, 0.576),
    ]

    /// A color from "#RRGGBB" or a name.
    static func color(_ text: String) -> MergeableColor? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let (r, g, b) = named[value] { return .sRGB(SRGBColor(red: r, green: g, blue: b, alpha: 1)) }
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard digits.count == 6, let number = Int(digits, radix: 16) else { return nil }
        return .sRGB(SRGBColor(red: Double(number >> 16 & 0xFF) / 255, green: Double(number >> 8 & 0xFF) / 255,
                               blue: Double(number & 0xFF) / 255, alpha: 1))
    }

    /// An emoji, or else an SF Symbol name ("book.closed").
    static func icon(_ text: String) -> MergeableJournalAttributes.Icon? {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if value.count == 1, value.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C }) {
            return .emoji(value)
        }
        guard value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }) else { return nil }
        return .sfSymbol(value)
    }
}
