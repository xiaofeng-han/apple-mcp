import Foundation
import Wire

/// A tool's arguments, read by type. A wrong type or unknown value is BadInput (a JSON-RPC
/// error); absent and null both read as nil.
struct Input {
    let fields: [String: JSON]

    init(_ fields: [String: JSON]) { self.fields = fields }

    private func value(_ key: String) -> JSON? {
        guard let value = fields[key], value != .null else { return nil }
        return value
    }

    /// Text; empty text reads as nil.
    func text(_ key: String) throws -> String? {
        guard let value = value(key) else { return nil }
        guard let text = value.string else { throw BadInput("\(key) must be text") }
        return text.isEmpty ? nil : text
    }

    /// Text that may be empty (a replacement with nothing, say).
    func rawText(_ key: String) throws -> String? {
        guard let value = value(key) else { return nil }
        guard let text = value.string else { throw BadInput("\(key) must be text") }
        return text
    }

    func requiredText(_ key: String) throws -> String {
        guard let text = try text(key) else { throw BadInput("\(key) is required") }
        return text
    }

    func flag(_ key: String) throws -> Bool? {
        guard let value = value(key) else { return nil }
        guard let flag = value.bool else { throw BadInput("\(key) must be true or false") }
        return flag
    }

    func number(_ key: String, _ allowed: ClosedRange<Int>) throws -> Int? {
        guard let value = value(key) else { return nil }
        guard let number = value.int else { throw BadInput("\(key) must be a whole number") }
        guard allowed.contains(number) else { throw BadInput("\(key) must be from \(allowed.lowerBound) to \(allowed.upperBound)") }
        return number
    }

    func pick(_ key: String, from options: [String]) throws -> String? {
        guard let text = try text(key) else { return nil }
        guard options.contains(text) else { throw BadInput("\(key) must be one of: \(options.joined(separator: ", "))") }
        return text
    }

    func texts(_ key: String) throws -> [String]? {
        guard let value = value(key) else { return nil }
        guard let items = value.array else { throw BadInput("\(key) must be a list of text") }
        return try items.map { item in
            guard let text = item.string else { throw BadInput("\(key) must be a list of text") }
            return text
        }
    }

    /// A list of objects, each with only the given keys.
    func objects(_ key: String, keys: Set<String>) throws -> [Input]? {
        guard let value = value(key) else { return nil }
        guard let items = value.array else { throw BadInput("\(key) must be a list of objects") }
        return try items.map { item in
            guard let fields = item.object else { throw BadInput("\(key) must be a list of objects") }
            if let unknown = fields.keys.sorted().first(where: { !keys.contains($0) }) {
                throw BadInput("\(key)[].\(unknown) is not known; use \(keys.sorted().joined(separator: ", "))")
            }
            return Input(fields)
        }
    }

    /// `<field>_after` (inclusive) and `<field>_before` (exclusive) as local days, YYYY-MM-DD.
    func window(_ field: String) throws -> DateWindow {
        func day(_ key: String) throws -> Date? {
            guard let text = try text(key) else { return nil }
            guard let date = Self.dayFormat.date(from: text) else { throw BadInput("\(key) must look like 2026-10-21") }
            return date
        }
        return DateWindow(from: try day(field + "_after"), until: try day(field + "_before"))
    }

    /// The notes a change is for: id and version, or notes, a list of {id, version}.
    func targets() throws -> [(id: String, version: String)] {
        let id = try text("id"), version = try text("version")
        if let items = try objects("notes", keys: ["id", "version"]) {
            guard id == nil, version == nil else { throw BadInput("give id and version, or notes, not both") }
            guard (1...100).contains(items.count) else { throw BadInput("notes takes 1 to 100 notes") }
            return try items.map { (try $0.requiredText("id"), try $0.requiredText("version")) }
        }
        guard let id else { throw BadInput("id is required (or notes)") }
        guard let version else { throw BadInput("version is required: the one read_note, overview or search gave") }
        return [(id, version)]
    }

    /// tags, only and attachments: what overview and search narrow notes to.
    func filter() throws -> NoteFilter {
        var filter = NoteFilter()
        filter.tags = try (texts("tags") ?? []).map { name in
            let key = name.trimmingCharacters(in: .whitespaces)
            let bare = key.hasPrefix("#") ? String(key.dropFirst()) : key
            guard !bare.isEmpty else { throw BadInput("tags must not be empty") }
            return bare
        }
        filter.groups = try (texts("only") ?? []).map { value in
            guard let group = NoteFilter.Group(rawValue: value.lowercased()) else {
                throw BadInput("only takes " + NoteFilter.Group.allCases.map(\.rawValue).joined(separator: ", "))
            }
            return group
        }
        filter.attachments = try (texts("attachments") ?? []).map { value in
            guard let kind = NoteFilter.attachmentKinds.first(where: { $0.lowercased() == value.lowercased() }) else {
                throw BadInput("attachments takes " + NoteFilter.attachmentKinds.joined(separator: ", "))
            }
            return kind
        }
        if filter.attachments.count > 1, filter.attachments.contains(where: { $0 == "any" || $0 == "none" }) {
            throw BadInput("attachments any and none go alone")
        }
        return filter
    }

    /// The schema of the filter's fields.
    static let filterSchema: [String: JSON] = [
        "tags": Schema.texts("Only notes with all these tags (# optional)"),
        "only": Schema.list(of: ["type": "string", "enum": .array(NoteFilter.Group.allCases.map { .string($0.rawValue) })],
                            "Only notes in all of these groups (unchecked: with unticked checklist items; calls: call recordings)"),
        "attachments": Schema.list(of: ["type": "string", "enum": .array(NoteFilter.attachmentKinds.map { .string($0) })],
                                   "Only notes with an attachment of one of these kinds; any, or none"),
    ]

    func order() throws -> NoteOrder? {
        try pick("sort", from: NoteOrder.allCases.map(\.rawValue)).flatMap(NoteOrder.init(rawValue:))
    }

    static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.isLenient = false
        return formatter
    }()
}
