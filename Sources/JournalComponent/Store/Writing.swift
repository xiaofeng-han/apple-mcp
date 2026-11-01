import CoreData
import Foundation
import JournalModel
import JournalShared
import NoteModel

/// What a create or an edit sets; nil leaves a field as it is.
struct EntryChange {
    var title: String?
    var body: [Block]?
    var date: Date?
    var bookmarked: Bool?
    /// The custom journal it belongs to: a journal's name or id, or "" for none.
    var journal: String?
    /// Photos, videos and recordings to add, read already; attachments (ids) to take off.
    var attach: [NewAttachment] = []
    var detach: [String] = []

    var isEmpty: Bool {
        title == nil && body == nil && date == nil && bookmarked == nil && journal == nil && attach.isEmpty && detach.isEmpty
    }
}

/// What a write did, for the answer: the entry or journal, and whether Journal uploaded it to
/// iCloud before the tool answered (nil: Journal does not sync on this Mac).
struct Written {
    var entry: EntryInfo?
    var journal: JournalInfo?
    var uploaded: Bool?
}

extension JournalStore {
    // MARK: Entries

    func create(_ change: EntryChange) throws(JournalError) -> (JournalEntryMO, [Attached]) {
        let title = change.title ?? ""
        try allow(title: title)
        let context = try context()
        let entry = JournalEntryMO.create(type: .blankEntry, context: context, uuid: UUID())
        var attached: [Attached] = []
        do {
            attached = try apply(change, to: entry)
            if change.date == nil { entry.setValue("creation", forKey: "dateSource") }
            try save(entry)
        } catch {
            context.rollback()
            removeFolders(attached.map(\.folder))
            throw error
        }
        return (entry, attached)
    }

    func edit(_ reference: String, version: String, _ change: EntryChange) throws(JournalError) -> (JournalEntryMO, [Attached]) {
        let entry = try entryObject(reference)
        try check(entry, version: version)
        try allow(title: title(entry))
        if let title = change.title { try allow(title: title) }
        var attached: [Attached] = []
        do {
            attached = try apply(change, to: entry)
            try save(entry)
        } catch {
            try context().rollback()
            removeFolders(attached.map(\.folder))
            throw error
        }
        return (entry, attached)
    }

    /// Moves an entry to Recently Deleted, or deletes one that is there for good.
    func delete(_ reference: String, version: String, permanently: Bool) throws(JournalError) -> JournalEntryMO {
        let entry = try entryObject(reference)
        try check(entry, version: version)
        try allow(title: title(entry))
        if permanently {
            guard entry.isRecentlyDeleted else {
                throw .refused("Only an entry in Recently Deleted can be deleted for good; delete it once first (without permanently)")
            }
            entry.markAsPermanentlyDeleted()
            try save(entry, touch: false)
        } else {
            guard !entry.isRecentlyDeleted else { throw .refused("The entry is already in Recently Deleted") }
            entry.markAsRecentlyDeleted()
            try save(entry)
        }
        return entry
    }

    func restore(_ reference: String) throws(JournalError) -> JournalEntryMO {
        let entry = try entryObject(reference)
        try allow(title: title(entry))
        guard entry.isRecentlyDeleted else { throw .refused("The entry is not in Recently Deleted") }
        entry.recoverRecentlyDeleted()
        try save(entry)
        return entry
    }

    func duplicate(_ reference: String) throws(JournalError) -> JournalEntryMO {
        let entry = try entryObject(reference)
        try allow(title: title(entry))
        let copy: JournalEntryMO
        do {
            guard let made = try entry.deepCopy() else { throw JournalError.failed("Journal could not copy the entry") }
            copy = made
        } catch let error as JournalError {
            throw error
        } catch {
            throw .failed("Journal could not copy the entry: \(error.localizedDescription)")
        }
        try save(copy)
        return copy
    }

    func check(_ entry: JournalEntryMO, version: String) throws(JournalError) {
        let current = info(entry)
        guard current.version == version else {
            throw .conflict("The entry changed since it was read (its version is now \(current.version)); read it again with read_entry, then make the change")
        }
    }

    /// Makes the change; files are written last, so a change that fails earlier writes none.
    private func apply(_ change: EntryChange, to entry: JournalEntryMO) throws(JournalError) -> [Attached] {
        if let title = change.title { try setTitle(title, of: entry) }
        if let body = change.body { try setBody(body, of: entry) }
        if let date = change.date {
            entry.setValue(date, forKey: "entryDate")
            entry.setValue("custom", forKey: "dateSource")
            entry.updateSortingColumns()
        }
        if let bookmarked = change.bookmarked { entry.setValue(bookmarked, forKey: "flagged") }
        if let journal = change.journal { try move(entry, to: journal) }
        try detach(change.detach, from: entry)
        return try attach(change.attach, to: entry)
    }

    private func setTitle(_ title: String, of entry: JournalEntryMO) throws(JournalError) {
        if Self.isLegacy(entry) {
            entry.setValue(title.isEmpty ? nil : try EntryText.rtf(NSAttributedString(string: title)), forKey: "title")
            return
        }
        guard var text = entry.mergeableAttributedTitle else {
            entry.mergeableAttributedTitle = EntryCRTitle(NSAttributedString(string: title))
            return
        }
        EntryText.apply(title: title, to: &text)
        entry.mergeableAttributedTitle = text
    }

    private func setBody(_ body: [Block], of entry: JournalEntryMO) throws(JournalError) {
        let canonical = try EntryText.canonical(body)
        if Self.isLegacy(entry) {
            entry.setValue(try EntryText.rtf(try EntryText.legacy(canonical)), forKey: "text")
        } else {
            guard var text = entry.mergeableAttributedText else { throw .failed("Journal gave no text for the entry") }
            try EntryText.apply(canonical, to: &text)
            entry.mergeableAttributedText = text
            entry.computeAndSetAggregateMinimumVersion()
        }
        // Journal keeps the length in 16 bits.
        entry.setValue(min(canonical.length, Int(Int16.max)), forKey: "textLength")
    }

    private func move(_ entry: JournalEntryMO, to reference: String) throws(JournalError) {
        let target = reference.isEmpty ? nil : try journalObject(reference)
        if let target, !target.isDefaultJournal { try allow(journal: name(target)) }
        for journal in entry.value(forKey: "journals") as? Set<JournalMO> ?? [] where !journal.isDefaultJournal && journal != target {
            entry.remove(from: journal)
        }
        if let target, !target.isDefaultJournal, !(entry.value(forKey: "journals") as? Set<JournalMO> ?? []).contains(target) {
            entry.add(to: target)
        }
    }

    // MARK: Journals

    func createJournal(_ name: String, color: MergeableColor?, icon: MergeableJournalAttributes.Icon?) throws(JournalError) -> JournalMO {
        try allow(journal: name)
        if (try journalObjects()).contains(where: { self.name($0).localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            throw .refused("A journal called \"\(name)\" exists already")
        }
        let journal = JournalMO.create(context: try context(), title: name, color: color ?? .random, icon: icon ?? .sfSymbol("book.closed"), id: UUID())
        try save(journal)
        return journal
    }

    func updateJournal(_ reference: String, name: String?, color: MergeableColor?, icon: MergeableJournalAttributes.Icon?) throws(JournalError) -> JournalMO {
        let journal = try journalObject(reference)
        guard !journal.isDefaultJournal else { throw .refused("The default journal cannot be changed; only the journals the user made can") }
        try allow(journal: self.name(journal))
        if let name {
            try allow(journal: name)
            if (try journalObjects()).contains(where: { $0 != journal && self.name($0).localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                throw .refused("A journal called \"\(name)\" exists already")
            }
            journal.title = name
        }
        if let color { journal.color = color }
        if let icon { journal.icon = icon }
        try save(journal)
        return journal
    }

    /// Deletes a journal the user made. Its entries move to another journal (`moveTo`), stay in
    /// All Entries only (`moveTo` ""), or go to Recently Deleted with it (`deleteEntries`).
    func deleteJournal(_ reference: String, moveTo: String?, deleteEntries: Bool, expectedEntries: Int?) throws(JournalError) -> (JournalMO, JournalInfo, Int) {
        let journal = try journalObject(reference)
        guard !journal.isDefaultJournal else { throw .refused("The default journal cannot be deleted") }
        // Journal clears a deleted journal's name and color; what it was is told from before.
        let before = info(journal)
        try allow(journal: name(journal))
        let entries = (journal.value(forKey: "entries") as? Set<JournalEntryMO> ?? []).filter {
            Self.visible.evaluate(with: $0) && !$0.isRecentlyDeleted
        }
        if deleteEntries {
            guard let expectedEntries else {
                throw .refused("Deleting the journal's entries too needs expected_entries: the \(entries.count) entries it holds (ask the user first)")
            }
            guard expectedEntries == entries.count else {
                throw .conflict("The journal holds \(entries.count) entries, not \(expectedEntries); nothing was deleted")
            }
            for entry in entries { try allow(title: title(entry)) }
            JournalMO.delete(journal, shouldDeleteEntries: true)
            for entry in entries { touch(entry) }
        } else {
            var target: JournalMO?
            if let moveTo, !moveTo.isEmpty { target = try journalObject(moveTo) }
            if let target {
                guard target != journal else { throw .refused("Move the entries to another journal than the one being deleted") }
                if !target.isDefaultJournal { try allow(journal: name(target)) }
            }
            JournalMO.delete(journal, moveEntriesToJournalID: target.flatMap { $0.isDefaultJournal ? nil : $0.value(forKey: "id") as? UUID }, context: try context())
            for entry in entries { touch(entry) }
        }
        try save(journal)
        return (journal, before, entries.count)
    }

    // MARK: Saving

    /// Journal uploads what is marked as not uploaded, with the date it changed.
    func touch(_ object: NSManagedObject) {
        object.setValue(Date(), forKey: "updatedDate")
        object.setValue(false, forKey: "isUploadedToCloud")
    }

    func save(_ object: NSManagedObject, touch: Bool = true) throws(JournalError) {
        if touch { self.touch(object) }
        let context = try context()
        do {
            try context.save()
        } catch {
            context.rollback()
            let code = (error as NSError).code
            if code == NSManagedObjectMergeError || code == NSPersistentStoreSaveConflictsError {
                throw .conflict("Journal changed this while it was being written; nothing was saved. Read it again, then make the change")
            }
            throw .failed("Journal's data could not be saved: \(error.localizedDescription)")
        }
    }

    /// Waits for Journal to upload `objects` to iCloud (starting it hidden if it was quit), up to
    /// `seconds`. Nil when Journal does not sync on this Mac.
    func waitForUpload(_ objects: [NSManagedObject], seconds: Double = 15) async -> Bool? {
        guard syncsWithICloud() else { return nil }
        Permissions.startJournalHidden()
        let wanted = objects.map { ($0.entity, $0.objectID) }
        return (try? await waitFor(seconds) { () throws(JournalError) -> Bool in
            for (entity, objectID) in wanted {
                // Read the row itself: objects in the context keep the values they were saved with, and
                // one Journal deleted (an entry deleted for good) is gone.
                let request = NSFetchRequest<NSDictionary>(entityName: entity.name ?? "")
                request.predicate = NSPredicate(format: "SELF == %@", objectID)
                request.resultType = .dictionaryResultType
                let removable = entity.attributesByName["isRemovedFromCloud"] != nil
                request.propertiesToFetch = ["isUploadedToCloud"] + (removable ? ["isRemovedFromCloud"] : [])
                guard let row = try fetch(request).first else { continue }
                if (row["isRemovedFromCloud"] as? Bool) == true { return false }
                if !((row["isUploadedToCloud"] as? Bool) ?? false) { return false }
            }
            return true
        }) ?? false
    }

    // MARK: The write guard

    func allow(title: String) throws(JournalError) {
        guard let writeGuard, !title.hasPrefix(writeGuard) else { return }
        throw .refused("While APPLE_JOURNAL_MCP_WRITE_GUARD is set, only entries titled \"\(writeGuard)…\" may be written")
    }

    func allow(journal name: String) throws(JournalError) {
        guard let writeGuard, !name.hasPrefix(writeGuard) else { return }
        throw .refused("While APPLE_JOURNAL_MCP_WRITE_GUARD is set, only journals named \"\(writeGuard)…\" may be changed")
    }
}
