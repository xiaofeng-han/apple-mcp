import Foundation

/// A TOML config file, read and edited as text, as far as agents' MCP server tables need: setting
/// keys of a table replaces just their values or adds lines, so comments, order and formatting
/// elsewhere stay as they were. Values are read when they are strings, booleans, or arrays or
/// inline tables of them.
public struct TOMLText: Sendable {
    public private(set) var text: String
    private let tables: [Table]

    /// A table's header (or the top of the file) and the key/value pairs written under it.
    struct Table: Sendable {
        let path: [String]
        let isArray: Bool
        /// Where the header's line ends (after any comment, before the line break); 0 for the top
        /// of the file.
        let headerEnd: Int
        var pairs: [Pair]
    }

    struct Pair: Sendable {
        let key: [String]
        let start: Int
        let value: Range<Int>
    }

    public init(_ text: String) throws {
        self.text = text
        var parser = Parser(bytes: Array(text.utf8))
        tables = try parser.parse()
    }

    /// Whether `[path]` is written as a table header.
    public func hasTable(_ path: [String]) -> Bool {
        tables.contains { $0.path == path && !$0.isArray }
    }

    /// The value of `key` in the table `[table]`, if it is a string, a boolean or an array of those.
    public func value(_ key: String, in table: [String]) -> Any? {
        guard let pair = tables.last(where: { $0.path == table && !$0.isArray })?.pairs.last(where: { $0.key == [key] })
        else { return nil }
        var parser = Parser(bytes: Array(text.utf8))
        parser.index = pair.value.lowerBound
        return try? parser.value()
    }

    /// `[path]` when it is written as an inline table (`name = { command = "…" }`), with the values
    /// that are strings, booleans or arrays of them.
    public func inlineTable(_ path: [String]) -> [String: Any]? {
        for table in tables where !table.isArray {
            for pair in table.pairs where table.path + pair.key == path {
                var parser = Parser(bytes: Array(text.utf8))
                parser.index = pair.value.lowerBound
                return (try? parser.value()) as? [String: Any]
            }
        }
        return nil
    }

    /// Whether keys of `[path]` are also written elsewhere than under its own header (as an inline
    /// table or dotted keys), or the path is taken by something else. Such files are not edited.
    public func isWrittenInline(_ path: [String]) -> Bool {
        // The top of the file is always there, and its keys are edited in place.
        guard !path.isEmpty else { return false }
        for table in tables {
            if table.isArray, table.path.starts(with: path) || path.starts(with: table.path) { return true }
            for pair in table.pairs {
                let full = table.path + pair.key
                if path.starts(with: full) { return true }
                if full.starts(with: path), !table.path.starts(with: path) { return true }
            }
        }
        return false
    }

    /// Sets keys of the table `[table]`, adding the table at the end of the file if it is missing.
    /// Other keys of the table, and its subtables, are kept.
    public mutating func set(_ pairs: [(String, ConfigValue)], in table: [String]) throws {
        if isWrittenInline(table) {
            throw ConfigError("[\(Self.header(table))] is written in a form this app does not edit; change it by hand")
        }
        var bytes = Array(text.utf8)
        let newline = Lines.ending(of: bytes)
        var edits: [(Range<Int>, String)] = []
        if let existing = tables.last(where: { $0.path == table && !$0.isArray }) {
            let indent = existing.pairs.first.map { Lines.indent(ofLineWith: $0.start, in: bytes) } ?? ""
            var missing: [String] = []
            for (key, value) in pairs {
                if let pair = existing.pairs.last(where: { $0.key == [key] }) {
                    edits.append((pair.value, Self.render(value)))
                } else {
                    missing.append(indent + Self.key(key) + " = " + Self.render(value))
                }
            }
            if !missing.isEmpty {
                edits.append((existing.headerEnd..<existing.headerEnd, newline + missing.joined(separator: newline)))
            }
        } else {
            var addition = "[\(Self.header(table))]" + newline
            addition += pairs.map { Self.key($0.0) + " = " + Self.render($0.1) + newline }.joined()
            if !bytes.isEmpty {
                if bytes.last != .newline { addition = newline + addition }
                addition = newline + addition
            }
            edits.append((bytes.count..<bytes.count, addition))
        }
        bytes.splice(edits)
        let result = try TOMLText(String(decoding: bytes, as: UTF8.self))
        guard pairs.allSatisfy({ $0.1.matches(result.value($0.0, in: table)) }) else {
            throw ConfigError("the change did not read back as written; the file was left as it was")
        }
        self = result
    }

    static func header(_ path: [String]) -> String { path.map(key).joined(separator: ".") }

    static func key(_ name: String) -> String {
        let bare = !name.isEmpty && name.utf8.allSatisfy { Parser.isBareKey($0) }
        return bare ? name : string(name)
    }

    static func render(_ value: ConfigValue) -> String {
        switch value {
        case .string(let text): string(text)
        case .bool(let flag): flag ? "true" : "false"
        case .array(let items): "[" + items.map(render).joined(separator: ", ") + "]"
        case .object(let fields): fields.isEmpty ? "{}" : "{ " + fields.map { key($0.0) + " = " + render($0.1) }.joined(separator: ", ") + " }"
        }
    }

    /// A basic string.
    static func string(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// Splits TOML into tables and key/value pairs, finding where each value ends.
    struct Parser {
        let bytes: [UInt8]
        var index = 0

        static func isBareKey(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }

        func failure(_ reason: String) -> ConfigError {
            ConfigError("not valid TOML: \(reason) on line \(Lines.number(of: index, in: bytes))")
        }

        var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        func peek(_ offset: Int) -> UInt8? { index + offset < bytes.count ? bytes[index + offset] : nil }

        mutating func skipBlanks() { while current?.isBlank == true { index += 1 } }

        /// Skips a comment up to the line break (which may be CRLF).
        mutating func skipComment() {
            guard current == .hash else { return }
            while let byte = current, byte != .newline, !(byte == .carriageReturn && peek(1) == .newline) { index += 1 }
        }

        /// Skips whitespace, line breaks and comments.
        mutating func skipTrivia() {
            while true {
                skipBlanks()
                skipComment()
                guard current == .newline || current == .carriageReturn else { return }
                index += 1
            }
        }

        /// Expects the end of a line after a header or a pair; returns where the line's text ends
        /// (after any comment, before the line break).
        @discardableResult
        mutating func endOfLine() throws -> Int {
            skipBlanks()
            skipComment()
            let end = index
            if current == .carriageReturn { index += 1 }
            guard current == nil || current == .newline else { throw failure("unexpected text after a value") }
            return end
        }

        mutating func parse() throws -> [Table] {
            var tables = [Table(path: [], isArray: false, headerEnd: 0, pairs: [])]
            while true {
                skipTrivia()
                guard let byte = current else { return tables }
                if byte == .openBracket {
                    let isArray = peek(1) == .openBracket
                    index += isArray ? 2 : 1
                    skipBlanks()
                    let path = try keyPath()
                    skipBlanks()
                    guard current == .closeBracket, !isArray || peek(1) == .closeBracket else { throw failure("unclosed table header") }
                    index += isArray ? 2 : 1
                    let headerEnd = try endOfLine()
                    tables.append(Table(path: path, isArray: isArray, headerEnd: headerEnd, pairs: []))
                } else {
                    let start = index
                    let key = try keyPath()
                    skipBlanks()
                    guard current == .equals else { throw failure("expected =") }
                    index += 1
                    skipBlanks()
                    let valueStart = index
                    try skipValue()
                    tables[tables.count - 1].pairs.append(Pair(key: key, start: start, value: valueStart..<index))
                    try endOfLine()
                }
            }
        }

        mutating func keyPath() throws -> [String] {
            var path = [try simpleKey()]
            while true {
                let mark = index
                skipBlanks()
                guard current == .dot else {
                    index = mark
                    return path
                }
                index += 1
                skipBlanks()
                path.append(try simpleKey())
            }
        }

        mutating func simpleKey() throws -> String {
            switch current {
            case .quote: return try basicString()
            case .apostrophe: return try literalString()
            default:
                let start = index
                while let byte = current, Self.isBareKey(byte) { index += 1 }
                guard index > start else { throw failure("expected a key") }
                return String(decoding: bytes[start..<index], as: UTF8.self)
            }
        }

        /// Moves past the value that starts here.
        mutating func skipValue() throws {
            switch current {
            case .quote, .apostrophe:
                _ = try stringValue()
            case .openBracket:
                index += 1
                skipTrivia()
                while current != .closeBracket {
                    guard current != nil else { throw failure("unclosed array") }
                    try skipValue()
                    skipTrivia()
                    if current == .comma {
                        index += 1
                        skipTrivia()
                    } else if current != .closeBracket {
                        throw failure("expected , or ]")
                    }
                }
                index += 1
            case .openBrace:
                index += 1
                skipTrivia()
                while current != .closeBrace {
                    guard current != nil else { throw failure("unclosed inline table") }
                    _ = try keyPath()
                    skipBlanks()
                    guard current == .equals else { throw failure("expected =") }
                    index += 1
                    skipBlanks()
                    try skipValue()
                    skipTrivia()
                    if current == .comma {
                        index += 1
                        skipTrivia()
                    } else if current != .closeBrace {
                        throw failure("expected , or }")
                    }
                }
                index += 1
            default:
                let start = index
                skipScalar()
                // A date and a time may be separated by a space.
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                if token.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil, current == .space, let next = peek(1), next >= 0x30, next <= 0x39 {
                    index += 1
                    skipScalar()
                }
                guard index > start else { throw failure("expected a value") }
            }
        }

        mutating func skipScalar() {
            while let byte = current, !byte.isWhitespace, ![.comma, .closeBracket, .closeBrace, .hash].contains(byte) { index += 1 }
        }

        /// Reads the value that starts here, if it is a string, a boolean or an array of those.
        mutating func value() throws -> Any? {
            switch current {
            case .quote, .apostrophe:
                return try stringValue()
            case .openBrace:
                index += 1
                skipTrivia()
                var fields: [String: Any] = [:]
                while current != .closeBrace {
                    guard current != nil else { return nil }
                    let key = try keyPath()
                    skipBlanks()
                    guard current == .equals else { return nil }
                    index += 1
                    skipBlanks()
                    let start = index
                    if let item = try value(), key.count == 1 {
                        fields[key[0]] = item
                    } else {
                        index = start
                        try skipValue()
                    }
                    skipTrivia()
                    if current == .comma {
                        index += 1
                        skipTrivia()
                    } else if current != .closeBrace {
                        return nil
                    }
                }
                index += 1
                return fields
            case .openBracket:
                index += 1
                skipTrivia()
                var items: [Any] = []
                while current != .closeBracket {
                    guard current != nil, let item = try value() else { return nil }
                    items.append(item)
                    skipTrivia()
                    if current == .comma {
                        index += 1
                        skipTrivia()
                    } else if current != .closeBracket {
                        return nil
                    }
                }
                index += 1
                return items
            default:
                let start = index
                skipScalar()
                switch String(decoding: bytes[start..<index], as: UTF8.self) {
                case "true": return true
                case "false": return false
                default: return nil
                }
            }
        }

        mutating func stringValue() throws -> String {
            let quote = bytes[index]
            if peek(1) == quote, peek(2) == quote {
                index += 3
                // A line break right after the opening quotes is not part of the string.
                if current == .carriageReturn { index += 1 }
                if current == .newline { index += 1 }
                return quote == .quote ? try basicString(closing: 3) : try literalString(closing: 3)
            }
            index += 1
            return quote == .quote ? try basicString(closing: 1) : try literalString(closing: 1)
        }

        mutating func basicString() throws -> String {
            index += 1
            return try basicString(closing: 1)
        }

        mutating func literalString() throws -> String {
            index += 1
            return try literalString(closing: 1)
        }

        /// The rest of a basic string, through `closing` quotes (3 for a multi-line one).
        mutating func basicString(closing: Int) throws -> String {
            var scalars = String.UnicodeScalarView()
            var start = index
            func flush(_ end: Int) { scalars.append(contentsOf: String(decoding: bytes[start..<end], as: UTF8.self).unicodeScalars) }
            while let byte = current {
                if byte == .quote, (0..<closing).allSatisfy({ peek($0) == .quote }) {
                    // A multi-line string may end with up to two more quotes that belong to it.
                    var end = index
                    while closing == 3, end + 3 < bytes.count, bytes[end + 3] == .quote, end - index < 2 { end += 1 }
                    flush(end)
                    index = end + closing
                    return String(scalars)
                }
                if byte == .newline, closing == 1 { throw failure("line break in a string") }
                guard byte == .backslash else {
                    index += 1
                    continue
                }
                flush(index)
                index += 1
                guard let escape = current else { break }
                index += 1
                switch escape {
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "e"): scalars.append("\u{1B}")
                case .quote: scalars.append("\"")
                case .backslash: scalars.append("\\")
                case UInt8(ascii: "u"), UInt8(ascii: "U"), UInt8(ascii: "x"):
                    let length = escape == UInt8(ascii: "u") ? 4 : escape == UInt8(ascii: "U") ? 8 : 2
                    guard index + length <= bytes.count, let code = UInt32(String(decoding: bytes[index..<(index + length)], as: UTF8.self), radix: 16),
                        let scalar = Unicode.Scalar(code)
                    else { throw failure("bad escape in a string") }
                    scalars.append(scalar)
                    index += length
                default:
                    // A backslash at the end of a line in a multi-line string trims the whitespace after it.
                    guard closing == 3, escape.isWhitespace else { throw failure("bad escape in a string") }
                    while current?.isWhitespace == true { index += 1 }
                }
                start = index
            }
            throw failure("unclosed string")
        }

        mutating func literalString(closing: Int) throws -> String {
            let start = index
            while let byte = current {
                if byte == .apostrophe, (0..<closing).allSatisfy({ peek($0) == .apostrophe }) {
                    var end = index
                    while closing == 3, end + 3 < bytes.count, bytes[end + 3] == .apostrophe, end - index < 2 { end += 1 }
                    index = end + closing
                    return String(decoding: bytes[start..<end], as: UTF8.self)
                }
                if byte == .newline, closing == 1 { throw failure("line break in a string") }
                index += 1
            }
            throw failure("unclosed string")
        }
    }
}
