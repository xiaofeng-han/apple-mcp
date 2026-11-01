import AppKit
import Foundation
import JournalModel
import Launcher
import Wire

/// Runs a tool against the store. Problems with the entries themselves (not found, refused, a
/// conflict, a missing permission, a Journal this app does not know) become failed answers the
/// model can read and act on.
@MainActor
func withJournal(_ store: JournalStore, _ body: @MainActor () async throws -> ToolAnswer) async throws -> ToolAnswer {
    store.refresh()
    do {
        return try await body()
    } catch let error as JournalError {
        return ToolAnswer(Output.explain(error), failed: true)
    }
}

/// How tools word their answers: JSON, with fields at their default left out.
@MainActor
enum Output {
    private static var settingsOpened = false

    /// A missing permission also opens the settings window on the Mac, once per server: a window
    /// already open (another copy of the app, with a Dock icon) is brought forward instead. In a
    /// sandbox the permission is out of reach whatever the settings say, so it asks for the
    /// command to be run outside instead.
    static func explain(_ error: JournalError) -> String {
        if case .noAccess = error, launcher_is_sandboxed() != 0 { return Permissions.sandboxHelp }
        guard case .noAccess = error, Permissions.hasData, !settingsOpened, Bundle.main.bundleURL.pathExtension == "app" else { return error.description }
        settingsOpened = true
        let window = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        if let window {
            window.activate()
            return error.description + " The Apple Journal MCP window is open on the Mac to grant it."
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", Bundle.main.bundleURL.path, "--args", "--settings"]
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        try? open.run()
        return error.description + " The Apple Journal MCP window is now open on the Mac to grant it."
    }

    /// Local time to the minute, as the date fields take it: 2026-10-21T09:30.
    nonisolated static func stamp(_ date: Date) -> String { Stamp.minute(date) }

    /// The local day, YYYY-MM-DD.
    nonisolated static func day(_ date: Date) -> String { Stamp.day(date) }

    static let snippetLength = 160

    /// One entry in a list: enough to choose it before reading it.
    static func summary(_ entry: EntryInfo, journals: [String: String]) -> JSON {
        var o: [String: JSON] = ["id": .string(entry.id), "version": .string(entry.version), "date": .string(stamp(entry.date))]
        if !entry.title.isEmpty { o["title"] = .string(entry.title) }
        let text = entry.text.replacingOccurrences(of: "\n", with: " ")
        if !text.isEmpty { o["snippet"] = .string(text.count > snippetLength ? String(text.prefix(snippetLength - 1)) + "…" : text) }
        o.merge(common(entry, journals: journals)) { a, _ in a }
        var kinds: [String: Int] = [:]
        for asset in entry.assets where !asset.hidden { kinds[AssetDetails.kind(asset.kind), default: 0] += 1 }
        if !kinds.isEmpty { o["attachments"] = .object(kinds.mapValues { .int($0) }) }
        return .object(o)
    }

    /// One entry in full, with its text as Markdown.
    static func entry(_ entry: EntryInfo, markdown: String, journals: [String: String]) -> JSON {
        var o: [String: JSON] = ["id": .string(entry.id), "version": .string(entry.version), "date": .string(stamp(entry.date)),
                                 "title": .string(entry.title), "body": .string(markdown)]
        if let created = entry.created { o["created"] = .string(stamp(created)) }
        if let edited = entry.edited { o["edited"] = .string(stamp(edited)) }
        if let prompt = entry.prompt, !prompt.isEmpty { o["prompt"] = .string(prompt) }
        if entry.legacy { o["format"] = "rtf" }
        o.merge(common(entry, journals: journals)) { a, _ in a }
        let assets = entry.assets.map { asset -> JSON in
            var a: [String: JSON] = ["id": .string(asset.id), "kind": .string(AssetDetails.kind(asset.kind))]
            if AssetDetails.kind(asset.kind) != asset.kind { a["type"] = .string(asset.kind) }
            if asset.hidden { a["hidden"] = true }
            a.merge(asset.details) { own, _ in own }
            let files = asset.files.filter { $0.name != "thumbnail" }
            if !files.isEmpty { a["files"] = .int(files.count) }
            return .object(a)
        }
        if !assets.isEmpty { o["attachments"] = .array(assets) }
        return .object(o)
    }

    static func common(_ entry: EntryInfo, journals: [String: String]) -> [String: JSON] {
        var o: [String: JSON] = [:]
        let names = entry.journals.compactMap { journals[$0] }
        if !names.isEmpty { o["journal"] = names.count == 1 ? .string(names[0]) : .array(names.map { .string($0) }) }
        if entry.bookmarked { o["bookmarked"] = true }
        if let deleted = entry.deleted { o["deleted"] = .string(stamp(deleted)) }
        return o
    }

    static func journal(_ journal: JournalInfo, entries: Int? = nil) -> JSON {
        var o: [String: JSON] = ["id": .string(journal.id), "name": .string(journal.name)]
        if let color = journal.color { o["color"] = .string(color) }
        if let icon = journal.icon { o["icon"] = .string(icon) }
        if let entries { o["entries"] = .int(entries) }
        return .object(o)
    }

    /// What a write answers: the lead, the entry or journal, and whether Journal has uploaded it.
    static func written(_ lead: String, _ fields: [String: JSON], uploaded: Bool?) -> ToolAnswer {
        var o = fields
        switch uploaded {
        case true?: o["uploaded"] = true
        case false?: o["uploaded"] = false
            o["note"] = "Journal has not uploaded it to iCloud yet; it will the next time it syncs."
        case nil: break
        }
        return ToolAnswer(lead + " " + JSON.object(o).text)
    }
}
