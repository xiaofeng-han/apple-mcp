import AppCore
import Foundation

/// What this server deleted, so list_deleted can show it and restore_reminder can put it back in
/// its old list: ReminderKit forgets a soft-deleted reminder's list, and without Full Disk Access
/// there is no other way to enumerate Recently Deleted. Kept for 31 days, a little longer than
/// Reminders keeps deleted items.
final class DeletionLog: @unchecked Sendable {
    struct Entry: Codable, Sendable {
        let id: String
        let title: String
        let listID: String
        let listName: String
        let parentID: String?
        let deletedAt: Date
    }

    private let url: URL
    private let lock = NSLock()

    init(url: URL = AppSettings.supportDirectory.appendingPathComponent("deleted.json")) {
        self.url = url
    }

    func entries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    func record(_ new: [Entry]) {
        lock.lock()
        defer { lock.unlock() }
        let ids = Set(new.map(\.id))
        save(load().filter { !ids.contains($0.id) } + new)
    }

    func forget(_ ids: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        save(load().filter { !ids.contains($0.id) })
    }

    private func load() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cutoff = Date().addingTimeInterval(-31 * 86_400)
        return ((try? decoder.decode([Entry].self, from: data)) ?? []).filter { $0.deletedAt > cutoff }
    }

    private func save(_ entries: [Entry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) { try? data.write(to: url, options: .atomic) }
    }
}
