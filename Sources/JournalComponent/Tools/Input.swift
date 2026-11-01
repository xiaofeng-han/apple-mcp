import Foundation
import JournalModel
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

    /// Text that may be empty ("no journal", "no title").
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

    /// A local day, YYYY-MM-DD, as its first moment.
    func day(_ key: String) throws -> Date? {
        guard let text = try text(key) else { return nil }
        guard let date = Stamp.dayFormat.date(from: text) else { throw BadInput("\(key) must look like 2026-10-21") }
        return date
    }

    /// An entry's date: 2026-10-21T09:30, or 2026-10-21 (at noon, so it stays on that day in
    /// every time zone the user's devices are in).
    func entryDate(_ key: String) throws -> Date? {
        guard let text = try text(key) else { return nil }
        if let date = Stamp.minuteFormat.date(from: text) { return date }
        if let day = Stamp.dayFormat.date(from: text) { return Calendar.current.date(byAdding: .hour, value: 12, to: day) }
        throw BadInput("\(key) must look like 2026-10-21 or 2026-10-21T09:30")
    }

}
