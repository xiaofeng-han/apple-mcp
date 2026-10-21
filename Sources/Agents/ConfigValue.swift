import Foundation

/// A value in an agent's config file: what an MCP server entry is made of.
public indirect enum ConfigValue: Sendable {
    case string(String)
    case bool(Bool)
    case array([ConfigValue])
    /// Members in the order they are written.
    case object([(String, ConfigValue)])

    /// As JSONSerialization reads it, for comparing with what a file holds.
    var foundation: Any {
        switch self {
        case .string(let value): value
        case .bool(let value): value
        case .array(let items): items.map(\.foundation)
        case .object(let fields): Dictionary(fields.map { ($0.0, $0.1.foundation) }, uniquingKeysWith: { $1 })
        }
    }

    /// Whether `value` (as JSONSerialization or TOMLText reads it) is this value; members of an
    /// object may come in any order.
    func matches(_ value: Any?) -> Bool {
        guard let value else { return false }
        return (foundation as AnyObject).isEqual(value)
    }
}

/// A config file that could not be read or changed.
public struct ConfigError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

extension UInt8 {
    static let tab: UInt8 = 0x09, newline: UInt8 = 0x0A, carriageReturn: UInt8 = 0x0D, space: UInt8 = 0x20
    static let quote = UInt8(ascii: "\""), apostrophe = UInt8(ascii: "'"), backslash = UInt8(ascii: "\\")
    static let slash = UInt8(ascii: "/"), star = UInt8(ascii: "*"), hash = UInt8(ascii: "#")
    static let comma = UInt8(ascii: ","), colon = UInt8(ascii: ":"), equals = UInt8(ascii: "="), dot = UInt8(ascii: ".")
    static let openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")
    static let openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]")

    var isBlank: Bool { self == .space || self == .tab }
    var isWhitespace: Bool { isBlank || self == .newline || self == .carriageReturn }
}

/// Text helpers shared by the JSON and TOML editors.
enum Lines {
    /// "\r\n" when the text uses it, else "\n".
    static func ending(of bytes: [UInt8]) -> String {
        bytes.firstIndex(of: .newline).map { $0 > 0 && bytes[$0 - 1] == .carriageReturn } == true ? "\r\n" : "\n"
    }

    /// The indentation step the text uses: the leading whitespace of its first indented line, or
    /// two spaces.
    static func indentUnit(of bytes: [UInt8]) -> String {
        var lineStart = 0
        while lineStart < bytes.count {
            var end = lineStart
            while end < bytes.count, bytes[end].isBlank { end += 1 }
            if end > lineStart, end < bytes.count, !bytes[end].isWhitespace {
                return bytes[lineStart] == .tab ? "\t" : String(repeating: " ", count: end - lineStart)
            }
            while end < bytes.count, bytes[end] != .newline { end += 1 }
            lineStart = end + 1
        }
        return "  "
    }

    /// The whitespace before `index` on its line, or nil if something else comes first on it.
    static func indent(before index: Int, in bytes: [UInt8]) -> String? {
        var start = index
        while start > 0, bytes[start - 1].isBlank { start -= 1 }
        guard start == 0 || bytes[start - 1] == .newline else { return nil }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    /// The leading whitespace of the line that `index` is on.
    static func indent(ofLineWith index: Int, in bytes: [UInt8]) -> String {
        var start = min(index, bytes.count)
        while start > 0, bytes[start - 1] != .newline { start -= 1 }
        var end = start
        while end < bytes.count, bytes[end].isBlank { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    static func number(of index: Int, in bytes: [UInt8]) -> Int {
        bytes[..<min(index, bytes.count)].reduce(1) { $1 == .newline ? $0 + 1 : $0 }
    }
}

extension Array where Element == UInt8 {
    /// Applies replacements given as (range, text), which must not overlap.
    mutating func splice(_ edits: [(Range<Int>, String)]) {
        for (range, text) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            replaceSubrange(range, with: Array(text.utf8))
        }
    }
}
