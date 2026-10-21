import AppKit
import Foundation
import Launcher
import NoteModel
import Wire

/// Runs a tool against the store. Problems with the notes themselves (not found, refused, a
/// conflict, a missing permission) become failed answers the model can read and act on.
@MainActor
func withNotes(_ store: NotesStore, _ body: @MainActor () async throws -> ToolAnswer) async throws -> ToolAnswer {
    store.refresh()
    do {
        return try await body()
    } catch let error as NotesError {
        return ToolAnswer(Output.explain(error), failed: true)
    }
}

/// How tools word their answers.
@MainActor
enum Output {
    private static var settingsOpened = false

    /// A missing permission also opens the settings window on the Mac, once per server: a window
    /// already open (another copy of the app, with a Dock icon) is brought forward instead. In a
    /// sandbox the permissions are out of reach whatever the settings say, so it asks for the
    /// command to be run outside instead.
    static func explain(_ error: NotesError) -> String {
        if case .noAccess = error, launcher_is_sandboxed() != 0 { return Permissions.sandboxHelp }
        guard case .noAccess = error, !settingsOpened, Bundle.main.bundleURL.pathExtension == "app" else { return error.description }
        settingsOpened = true
        let window = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        if let window {
            window.activate()
            return error.description + " The Apple Notes MCP window is open on the Mac to grant it."
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", Bundle.main.bundleURL.path, "--args", "--settings"]
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        try? open.run()
        return error.description + " The Apple Notes MCP window is now open on the Mac to grant it."
    }

    /// The local day, YYYY-MM-DD.
    static func day(_ date: Date) -> String { Input.dayFormat.string(from: date) }

    static func minute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// Titles are cut in lists; the id names the note anyway.
    static func title(_ title: String, limit: Int = 40) -> String {
        title.count > limit ? String(title.prefix(limit - 1)) + "…" : title
    }

    /// "2.3k chars, 3 images, 1 table": enough to judge a note before reading it.
    static func size(characters: Int, attachments: [String: Int]) -> String {
        let text = characters < 1000 ? "\(characters) chars" : String(format: "%.1fk chars", Double(characters) / 1000)
        let extra = AttachmentKind.summary(attachments)
        return extra.isEmpty ? text : text + ", " + extra
    }

    static func range(_ window: DateWindow, _ field: String) -> String? {
        switch (window.from, window.until) {
        case (let from?, let until?):
            let last = day(until.addingTimeInterval(-1))
            return day(from) == last ? "\(field) on \(last)" : "\(field) \(day(from)) to \(last)"
        case (let from?, nil): return "\(field) since \(day(from))"
        case (nil, let until?): return "\(field) before \(day(until))"
        case (nil, nil): return nil
        }
    }

    /// Lines of notes under a "[folder]" line wherever the folder changes. Inside a listed folder
    /// (`root`) the labels are relative to it, "[.]" being the folder itself. With `group`, each
    /// folder's notes are gathered under its first appearance; otherwise the order is kept.
    static func sections(_ items: [(folder: [String], lines: [String])], root: [String]?, rootPath: String, group: Bool) -> [String] {
        guard root == nil || Set(items.map(\.folder)).count > 1 else { return items.flatMap(\.lines) }
        var ordered = items
        if group {
            var folders: [[String]] = []
            for item in items where !folders.contains(item.folder) { folders.append(item.folder) }
            ordered = folders.flatMap { folder in items.filter { $0.folder == folder } }
        }
        func label(_ names: [String]) -> String {
            guard let root, names.count >= root.count, Array(names.prefix(root.count)) == root else { return FolderPath.join(names) }
            let relative = Array(names.dropFirst(root.count))
            return relative.isEmpty ? "." : FolderPath.join(relative)
        }
        var lines = [root == nil ? "[folder] heads the notes under it." : "[folder] heads the notes under it, relative to \(rootPath); [.] is \(rootPath) itself."]
        var last: [String]?
        for item in ordered {
            if item.folder != last {
                lines.append("[\(label(item.folder))]")
                last = item.folder
            }
            lines += item.lines
        }
        return lines
    }
}
