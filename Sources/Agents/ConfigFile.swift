import Foundation

/// Reading and writing agents' config files. A symbolic link is followed, so a config kept in a
/// dotfiles repository stays a link; the file keeps its permissions (new files are private to the
/// user); and before the first change of a day the old contents are copied next to it as
/// `<name>.bak-<yyyyMMdd>-apple-reminders-mcp`.
public enum ConfigFile {
    /// The file's text, or nil when there is no such file.
    public static func read(_ url: URL) throws -> String? {
        let target = try resolve(url)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        do {
            let data = try Data(contentsOf: target)
            guard let text = String(data: data, encoding: .utf8) else { throw ConfigError("\(url.path) is not UTF-8 text") }
            return text
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError("cannot read \(url.path): \(error.localizedDescription)")
        }
    }

    /// Rewrites the file with what `change` makes of its text ("" for a missing file). If the file
    /// changes on disk meanwhile (the agent saved it), the change is made again on the new text.
    /// Returns the backup, if one was made now.
    @discardableResult
    public static func update(_ url: URL, _ change: (String) throws -> String) throws -> URL? {
        let target = try resolve(url)
        let manager = FileManager.default
        for _ in 0..<3 {
            let original = try read(target)
            let changed = try change(original ?? "")
            guard try read(target) == original else { continue }
            if changed == original { return nil }
            var backup: URL?
            var permissions = 0o600
            if original != nil {
                permissions = (try? manager.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int) ?? permissions
                backup = try backUp(target)
            }
            do {
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(changed.utf8).write(to: target, options: .atomic)
                try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
            } catch {
                throw ConfigError("cannot write \(url.path): \(error.localizedDescription)")
            }
            return backup
        }
        throw ConfigError("\(url.path) keeps changing; try again")
    }

    /// Copies the file next to itself as `<name>.bak-<yyyyMMdd>-apple-reminders-mcp`, unless that
    /// day's copy exists. Returns the copy made.
    @discardableResult
    public static func backUp(_ url: URL) throws -> URL? {
        let target = try resolve(url)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let copy = target.deletingLastPathComponent()
            .appendingPathComponent("\(target.lastPathComponent).bak-\(formatter.string(from: Date()))-apple-reminders-mcp")
        guard FileManager.default.fileExists(atPath: target.path), !FileManager.default.fileExists(atPath: copy.path) else { return nil }
        try FileManager.default.copyItem(at: target, to: copy)
        return copy
    }

    /// The file a path stands for, following symbolic links. A link to nothing is refused rather
    /// than replaced by a file.
    static func resolve(_ url: URL) throws -> URL {
        let target = url.resolvingSymlinksInPath()
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) {
            throw ConfigError("\(url.path) is a link to \(destination), which does not exist")
        }
        return target
    }
}
