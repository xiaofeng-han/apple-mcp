import Foundation
import NoteModel
import UniformTypeIdentifiers

// Exporting a folder and its subfolders, for archiving: a Markdown file per note in the same
// folder layout, every attachment's original file under attachments/<id>/ (linked from the notes,
// so the archive reads offline), and manifest.md listing every note. Locked notes cannot be read
// (their body is encrypted); the manifest lists them as not exported. A destination ending in
// .zip is zipped, because clients without a shell cannot zip it themselves.

struct ExportResult {
    var path: String
    var destination: String
    /// Every note in the folders, locked ones too: what a delete with its contents expects.
    var notes: Int
    var folders: Int
    var locked: Int
    var failed: [String]
    var files: Int
    var missing: Int
}

extension NotesStore {
    func export(_ reference: String, to destination: String) async throws(NotesError) -> ExportResult {
        let target = try Exporting.destination(destination)
        let zip = target.pathExtension.lowercased() == "zip"
        let root = try folder(reference)
        let all = try folders()
        var tree = [root]
        var next = 0
        while next < tree.count {
            tree += all.filter { $0.parentID == tree[next].id }
            next += 1
        }
        let notes = try fetch("ICNote", NSPredicate(format: "markedForDeletion == NO AND folder.identifier IN %@", tree.map(\.id)))
            .map(info).filter { !$0.inTrash }

        let manager = FileManager.default
        let work: URL
        var scratch: URL?
        defer { if let scratch { try? manager.removeItem(at: scratch) } }
        do {
            if zip {
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temporary = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target.deletingLastPathComponent(), create: true)
                scratch = temporary
                work = temporary.appendingPathComponent(target.deletingPathExtension().lastPathComponent, isDirectory: true)
            } else {
                work = target
            }
            try manager.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            throw .failed("could not create \(target.path): \(error.localizedDescription)")
        }

        do throws(NotesError) {
            var manifest = Manifest(path: root.path)
            var directories: [String: [String]] = [root.id: []]
            var taken: [String: Set<String>] = ["": ["attachments", "manifest.md"]]
            for folder in tree.dropFirst() {
                let parent = directories[folder.parentID ?? ""] ?? []
                let name = Exporting.unique(Exporting.fileName(folder.name), id: folder.id, among: &taken[parent.joined(separator: "/"), default: []])
                directories[folder.id] = parent + [name]
                try Exporting.makeDirectory(work.appendingPathComponent((parent + [name]).joined(separator: "/"), isDirectory: true))
            }
            // Oldest first in each folder, so the older of two notes with one title keeps the plain name.
            let order = Dictionary(uniqueKeysWithValues: tree.enumerated().map { ($0.element.id, $0.offset) })
            for note in notes.sorted(by: { (order[$0.folderID] ?? 0, $0.created) < (order[$1.folderID] ?? 0, $1.created) }) {
                let directory = directories[note.folderID] ?? []
                let file = Exporting.unique(Exporting.fileName(note.title), suffix: ".md", id: note.id, among: &taken[directory.joined(separator: "/"), default: []])
                let relative = (directory + [file]).joined(separator: "/")
                if note.locked {
                    manifest.add(note, file: nil, attachments: 0, missing: 0, status: "locked, not exported")
                    manifest.locked += 1
                    continue
                }
                let blocks: [Block]
                do throws(NotesError) {
                    blocks = try self.blocks(note.id)
                } catch {
                    manifest.add(note, file: nil, attachments: 0, missing: 0, status: "failed: \(error)")
                    manifest.failed.append("\(note.title): \(error)")
                    continue
                }
                var links: [String: String] = [:]
                var count = 0, missing = 0
                for a in blocks.attachments where links[a.id] == nil {
                    switch a.kind {
                    case "tag", "mention", "note link", "calculation", "inline":
                        links[a.id] = Markdown.escape(a.label)
                    case "link":
                        if !a.label.isEmpty { links[a.id] = "[" + Markdown.escape(a.label) + "](" + Markdown.escapeLink(a.label) + ")" }
                    default:
                        count += 1
                        do throws(NotesError) {
                            let copied = try copyFiles(of: a, into: work, depth: directory.count)
                            links[a.id] = copied.markdown
                            manifest.files += copied.copied
                            if copied.missing > 0 {
                                missing += 1
                                manifest.problems.append("\(relative): \(a.kind) \(a.id): " + (copied.total == 1
                                    ? "its file is not on this Mac (Notes may not have downloaded it)"
                                    : "\(copied.missing) of its \(copied.total) files are not on this Mac"))
                            }
                        } catch {
                            missing += 1
                            manifest.problems.append("\(relative): \(a.kind) \(a.id): \(error)")
                        }
                    }
                }
                manifest.missing += missing
                let url = work.appendingPathComponent(relative)
                do {
                    try Data((Markdown.render(blocks) { links[$0.id] } + "\n").utf8).write(to: url)
                    try manager.setAttributes([.creationDate: note.created, .modificationDate: note.modified], ofItemAtPath: url.path)
                } catch {
                    throw .failed("could not write \(relative): \(error.localizedDescription)")
                }
                manifest.add(note, file: relative, attachments: count, missing: missing, status: "exported")
            }
            do {
                try Data(manifest.text(folders: tree.count).utf8).write(to: work.appendingPathComponent("manifest.md"))
            } catch {
                throw .failed("could not write manifest.md: \(error.localizedDescription)")
            }
            if zip { try await Exporting.zip(work, to: target) }
            return ExportResult(path: root.path, destination: target.path, notes: notes.count, folders: tree.count, locked: manifest.locked,
                                failed: manifest.failed, files: manifest.files, missing: manifest.missing)
        } catch {
            // Only what this export made goes: the destination did not exist before.
            try? manager.removeItem(at: target)
            throw error
        }
    }

    /// Copies an attachment's file (or a scan's pages) to attachments/<id>/, and returns the
    /// Markdown linking them from a note `depth` folders down.
    private func copyFiles(of a: Attachment, into root: URL, depth: Int) throws(NotesError) -> (markdown: String?, copied: Int, missing: Int, total: Int) {
        let details = try attachment(a.id)
        let sources: [(file: URL?, name: String, label: String)] = details.pages.isEmpty
            ? [(details.file, Exporting.fileName(details.fileName ?? details.file?.lastPathComponent ?? a.kind), a.caption)]
            : details.pages.enumerated().map { index, page in
                (page.file, String(format: "page-%02d", index + 1) + (page.file.map { "." + $0.pathExtension } ?? ""), "\(a.caption) page \(index + 1)")
            }
        let directory = root.appendingPathComponent("attachments/\(a.id)", isDirectory: true)
        var links: [String] = []
        var copied = 0, missing = 0
        for source in sources {
            guard let file = source.file, FileManager.default.fileExists(atPath: file.path) else {
                missing += 1
                continue
            }
            try Exporting.makeDirectory(directory)
            do {
                try FileManager.default.copyItem(at: file, to: directory.appendingPathComponent(source.name))
            } catch {
                throw .failed("could not copy \(file.lastPathComponent): \(error.localizedDescription)")
            }
            copied += 1
            let image = UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true
            links.append((image ? "!" : "") + "[" + Markdown.escape(source.label) + "](" + Exporting.link(["attachments", a.id, source.name], depth: depth) + ")")
        }
        return (links.isEmpty ? nil : links.joined(separator: " "), copied, missing, sources.count)
    }
}

private struct Manifest {
    var path: String
    var rows: [[String]] = []
    var problems: [String] = []
    var failed: [String] = []
    var locked = 0
    var files = 0
    var missing = 0

    init(path: String) { self.path = path }

    mutating func add(_ note: NoteInfo, file: String?, attachments: Int, missing: Int, status: String) {
        rows.append([file ?? "—", note.title, note.id, Exporting.stamp(note.created), Exporting.stamp(note.modified),
                     missing > 0 ? "\(attachments) (\(missing) missing)" : "\(attachments)", status])
    }

    func text(folders: Int) -> String {
        let exported = rows.count - locked - failed.count
        var summary = "\(rows.count) notes in \(folders) folder\(folders == 1 ? "" : "s"): \(exported) exported"
        if locked > 0 { summary += ", \(locked) locked (not exported: Notes keeps them encrypted)" }
        if !failed.isEmpty { summary += ", \(failed.count) could not be read" }
        summary += ". \(files) attachment files copied" + (missing > 0 ? ", \(missing) attachments missing" : "") + "."
        var lines = [
            "# \(path)", "",
            "Exported from Apple Notes on \(Exporting.stamp(Date())). \(summary)",
            "Each note is a Markdown file in the same folder layout. Attachments are in attachments/<id>/, as their original files.", "",
            "| File | Title | Id | Created | Modified | Attachments | Status |",
            "| --- | --- | --- | --- | --- | --- | --- |",
        ]
        lines += rows.sorted { $0[0].localizedStandardCompare($1[0]) == .orderedAscending }
            .map { "| " + $0.map(Markdown.escapeCell).joined(separator: " | ") + " |" }
        if !problems.isEmpty { lines += ["", "## Problems", ""] + problems.map { "- " + $0 } }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// The file-system side of an export.
enum Exporting {
    /// A file name from a title: "/" and ":" become "-", control characters spaces, no leading
    /// dots (no hidden files), at most `maxBytes` of UTF-8 (APFS allows 255 bytes; a Chinese
    /// character takes 3).
    static func fileName(_ title: String, maxBytes: Int = 200) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            if scalar == "/" || scalar == ":" {
                scalars.append("-")
            } else if CharacterSet.controlCharacters.contains(scalar) || scalar == "\u{FFFC}" {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        var name = String(scalars).trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name = String(name.dropFirst()).trimmingCharacters(in: .whitespaces) }
        while name.utf8.count > maxBytes { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Untitled" : name
    }

    /// `name` + `suffix`, or with the short id added when the folder already has that name.
    /// Names compare as APFS compares them by default: ignoring case and normalization.
    static func unique(_ name: String, suffix: String = "", id: String, among taken: inout Set<String>) -> String {
        func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }
        var candidate = name + suffix
        if taken.contains(key(candidate)) { candidate = "\(name) (\(ShortID.of(id)))\(suffix)" }
        if taken.contains(key(candidate)) { candidate = "\(name) (\(id))\(suffix)" }
        taken.insert(key(candidate))
        return candidate
    }

    /// A relative, percent-encoded link from a note `depth` folders below the export's root.
    static func link(_ components: [String], depth: Int) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return (Array(repeating: "..", count: depth) + components.map { $0.addingPercentEncoding(withAllowedCharacters: safe) ?? $0 })
            .joined(separator: "/")
    }

    /// The destination as an absolute URL. It must not exist yet, so an export never writes into or
    /// over something, and it must not be inside ~/Library: this app has Full Disk Access, and a
    /// misled model must not be able to plant files in places such as LaunchAgents.
    static func destination(_ raw: String) throws(NotesError) -> URL {
        let expanded = (raw.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw .refused("to must be an absolute path, such as ~/Documents/Archive/Work.zip") }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard url.path != "/", !FileManager.default.fileExists(atPath: url.path) else {
            throw .refused("\(url.path) already exists; export to a new folder or .zip path")
        }
        // Follow links in the part that exists, so a symbolic link cannot lead into ~/Library.
        var existing = url.deletingLastPathComponent()
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) { existing = existing.deletingLastPathComponent() }
        let rest = url.path.dropFirst(existing.path.count).split(separator: "/").map(String.init)
        let resolved = rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
        let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library").resolvingSymlinksInPath().path.lowercased()
        for path in [url.path.lowercased(), resolved.path.lowercased()] where path == library || path.hasPrefix(library + "/") {
            throw .refused("exports cannot go inside ~/Library; choose a folder such as ~/Documents/Archive")
        }
        return url
    }

    static func makeDirectory(_ url: URL) throws(NotesError) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw .failed("could not create \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Local time with its offset, such as 2026-10-21T09:30:00-07:00.
    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// Zips `directory` (named as the top folder) with ditto, then marks the names as UTF-8.
    /// ditto's output never reaches stdout, which carries the MCP messages.
    static func zip(_ directory: URL, to archive: URL) async throws(NotesError) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", directory.path, archive.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32
        do {
            status = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            throw .failed("could not start ditto to make the zip: \(error.localizedDescription)")
        }
        guard status == 0 else { throw .failed("ditto could not make the zip (exit status \(status))") }
        do {
            try ZipNames.markUTF8(archive)
        } catch {
            throw .failed("could not mark the names in the zip as UTF-8 (\(error)); nothing was exported")
        }
    }
}
