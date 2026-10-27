import Foundation
import SQLite3

/// Recently Deleted as Reminders' own database records it, read only, when the user gave the app
/// Full Disk Access. ReminderKit can restore a soft-deleted reminder by id but cannot list them;
/// the database can, including ones deleted on other devices. Only a few long-standing columns are
/// read, since the schema changes with macOS releases (ReminderData_v2026_A on macOS 27).
enum DeletedDatabase {
    struct Row: Sendable {
        let id: String
        let title: String
        let parentID: String?
        let deletedAt: Date
    }

    static var storesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.reminders/Container_v1/Stores")
    }

    /// Whether the app can read the database (Full Disk Access).
    static var available: Bool {
        (try? FileManager.default.contentsOfDirectory(at: storesDirectory, includingPropertiesForKeys: nil)) != nil
    }

    /// Soft-deleted reminders from the last 30 days, newest first; nil without Full Disk Access.
    static func recentlyDeleted() -> [Row]? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: storesDirectory, includingPropertiesForKeys: nil) else { return nil }
        var rows: [Row] = []
        let cutoff = Date().addingTimeInterval(-30 * 86_400).timeIntervalSinceReferenceDate
        for file in files where file.lastPathComponent.hasPrefix("Data-") && file.pathExtension == "sqlite" {
            var db: OpaquePointer?
            guard sqlite3_open_v2("file:\(file.path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
                sqlite3_close(db)
                continue
            }
            defer { sqlite3_close(db) }
            let sql = """
                SELECT r.ZCKIDENTIFIER, r.ZTITLE, p.ZCKIDENTIFIER, r.ZLASTMODIFIEDDATE
                FROM ZREMCDREMINDER r LEFT JOIN ZREMCDREMINDER p ON p.Z_PK = r.ZPARENTREMINDER
                WHERE r.ZMARKEDFORDELETION = 1 AND r.ZCKIDENTIFIER IS NOT NULL AND r.ZLASTMODIFIEDDATE > ?
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, cutoff)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = sqlite3_column_text(statement, 0) else { continue }
                rows.append(Row(
                    id: String(cString: id).uppercased(),
                    title: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
                    parentID: sqlite3_column_text(statement, 2).map { String(cString: $0).uppercased() },
                    deletedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3))))
            }
        }
        return rows.sorted { $0.deletedAt > $1.deletedAt }
    }
}
