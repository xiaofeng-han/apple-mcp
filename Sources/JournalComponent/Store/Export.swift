import Foundation
import JournalModel

/// Journal's own export makes an archive only Journal opens; this writes entries as Markdown
/// files anyone can read, with their photos, videos and recordings next to them.
struct ExportResult {
    var entries = 0
    var files = 0
    /// Attachment files Journal has not downloaded to this Mac.
    var missing: [String] = []
}

extension JournalStore {
    func export(_ entries: [EntryInfo], to folder: URL) throws(JournalError) -> ExportResult {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: folder.path) else { throw .refused("\(folder.path) exists already; give a new folder") }
        let attachments = folder.appendingPathComponent("attachments")
        do {
            try manager.createDirectory(at: attachments, withIntermediateDirectories: true)
        } catch {
            throw .failed("Could not create \(folder.path): \(error.localizedDescription)")
        }
        let journals = Dictionary(uniqueKeysWithValues: ((try? journalObjects()) ?? []).map { (Self.id($0), name($0)) })
        var result = ExportResult()
        var names: Set<String> = []
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            let object = try entryObject(entry.id)
            let (markdown, _) = self.markdown(object)
            var lines = ["# " + (entry.title.isEmpty ? Output.day(entry.date) : entry.title), ""]
            var facts = [Output.stamp(entry.date).replacingOccurrences(of: "T", with: " ")]
            let named = entry.journals.compactMap { journals[$0] }
            if !named.isEmpty { facts.append("Journal: " + named.joined(separator: ", ")) }
            if entry.bookmarked { facts.append("Bookmarked") }
            lines.append(facts.joined(separator: " · "))
            if let prompt = entry.prompt, !prompt.isEmpty { lines += ["", "> " + prompt] }
            if !markdown.isEmpty { lines += ["", markdown] }
            let shown = entry.assets.filter { !$0.hidden }
            if !shown.isEmpty {
                lines += ["", "## Attachments", ""]
                for asset in shown {
                    var line = "- " + asset.kind
                    let summary = asset.details.compactMap { key, value -> String? in
                        guard let text = value.string ?? value.int.map(String.init) else { return nil }
                        return "\(key.replacingOccurrences(of: "_", with: " ")): \(text)"
                    }.sorted()
                    if !summary.isEmpty { line += " (" + summary.joined(separator: "; ") + ")" }
                    for (index, file) in asset.files.enumerated() where file.name != "thumbnail" {
                        let target = "\(asset.id)-\(index + 1).\(file.url.pathExtension.isEmpty ? "bin" : file.url.pathExtension)"
                        guard file.exists else {
                            result.missing.append(file.url.lastPathComponent)
                            continue
                        }
                        do {
                            try manager.copyItem(at: file.url, to: attachments.appendingPathComponent(target))
                        } catch {
                            throw .failed("Could not copy \(file.url.lastPathComponent): \(error.localizedDescription)")
                        }
                        result.files += 1
                        line += " ![\(file.name)](attachments/\(target))"
                    }
                    lines.append(line)
                }
            }
            var base = Output.day(entry.date) + " " + Self.fileName(entry.title.isEmpty ? "Entry" : entry.title)
            if names.contains(base.lowercased()) { base += " " + entry.id.prefix(8) }
            names.insert(base.lowercased())
            do {
                try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent(base + ".md"), atomically: true, encoding: .utf8)
            } catch {
                throw .failed("Could not write \(base).md: \(error.localizedDescription)")
            }
            result.entries += 1
        }
        if (try? manager.contentsOfDirectory(atPath: attachments.path))?.isEmpty ?? false { try? manager.removeItem(at: attachments) }
        return result
    }

    /// A title as a file name: no slashes or colons, not too long.
    static func fileName(_ title: String) -> String {
        let cleaned = title.map { "/:\\\n\r\t".contains($0) ? "-" : $0 }
        return String(String(cleaned).trimmingCharacters(in: .whitespaces).prefix(80))
    }
}
