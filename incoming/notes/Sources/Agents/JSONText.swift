import Foundation

/// A JSON or JSONC config file, edited as text: setting a member replaces or adds just that member,
/// so the rest of the file (key order, indentation, comments, trailing commas) stays as the user or
/// the agent wrote it. Reading goes through JSONSerialization in JSON5 mode, which accepts what
/// JSONC files contain.
public struct JSONText: Sendable {
    public private(set) var text: String

    public init(_ text: String) { self.text = text }

    /// The whole document; an empty file reads as an empty object. Throws if it is not JSON.
    public func root() throws -> Any {
        guard text.contains(where: { !$0.isWhitespace }) else { return [String: Any]() }
        // Plain JSON first: JSON5 mode refuses some valid JSON (a \u0000 escape).
        if let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) { return value }
        do {
            return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.json5Allowed, .fragmentsAllowed])
        } catch {
            throw ConfigError("not valid JSON (\((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? "\(error)"))")
        }
    }

    /// The value at `path` (object keys from the top), or nil if there is none.
    public func value(at path: [String]) throws -> Any? {
        var value: Any? = try root()
        for key in path { value = (value as? [String: Any])?[key] }
        return value
    }

    /// Sets the member at `path` to `value`, adding the objects on the way that are missing.
    public mutating func set(_ path: [String], to value: ConfigValue) throws {
        precondition(!path.isEmpty)
        _ = try root()
        var bytes = Array(text.utf8)
        if !bytes.contains(where: { !$0.isWhitespace }) { bytes = Array("{}\n".utf8) }
        let scanner = Scanner(bytes: bytes)
        let unit = Lines.indentUnit(of: bytes), newline = Lines.ending(of: bytes)
        var object = try scanner.topLevelObject()
        var edits: [(Range<Int>, String)] = []
        for (depth, key) in path.enumerated() {
            let (members, close) = try scanner.members(of: object)
            // Readers differ on which of two equal keys counts; leave such a file to the user.
            guard members.filter({ $0.key == key }).count < 2 else {
                throw ConfigError("\"\(key)\" appears twice in the same object; remove one by hand")
            }
            if let member = members.last(where: { $0.key == key }) {
                if depth < path.count - 1 {
                    guard bytes[member.valueStart] == .openBrace else {
                        throw ConfigError("\(path[...depth].joined(separator: ".")) is not an object")
                    }
                    object = member.valueStart
                    continue
                }
                let rendered = Lines.indent(before: member.keyStart, in: bytes).map { Self.render(value, indent: $0, unit: unit, newline: newline) }
                    ?? Self.compact(value)
                edits.append((member.valueStart..<member.valueEnd, rendered))
                break
            }
            let nested = path[(depth + 1)...].reversed().reduce(value) { .object([($1, $0)]) }
            edits += Self.insert(key, nested, into: object, members: members, close: close, bytes: bytes, unit: unit, newline: newline)
            break
        }
        bytes.splice(edits)
        let result = JSONText(String(decoding: bytes, as: UTF8.self))
        guard value.matches(try? result.value(at: path)) else {
            throw ConfigError("the change did not read back as written; the file was left as it was")
        }
        text = result.text
    }

    /// The edits that add `"key": value` to the object whose brace is at `open`.
    private static func insert(_ key: String, _ value: ConfigValue, into open: Int, members: [Scanner.Member], close: Int,
                               bytes: [UInt8], unit: String, newline: String) -> [(Range<Int>, String)] {
        let objectIndent = Lines.indent(ofLineWith: open, in: bytes)
        guard let last = members.last else {
            let inner = objectIndent + unit
            let member = quoted(key) + ": " + render(value, indent: inner, unit: unit, newline: newline)
            if bytes[(open + 1)..<close].allSatisfy(\.isWhitespace) {
                return [((open + 1)..<close, newline + inner + member + newline + objectIndent)]
            }
            // Only comments inside: put the member before them.
            return [((open + 1)..<(open + 1), newline + inner + member)]
        }
        guard bytes[open..<close].contains(.newline) else {
            // A one-line object stays on one line.
            return [(last.valueEnd..<last.valueEnd, ", " + quoted(key) + ": " + compact(value))]
        }
        let inner = Lines.indent(before: last.keyStart, in: bytes) ?? objectIndent + unit
        let member = quoted(key) + ": " + render(value, indent: inner, unit: unit, newline: newline)
        if let closeIndent = Lines.indent(before: close, in: bytes) {
            // The closing brace has a line of its own: the member goes on a new line before it.
            let lineStart = close - closeIndent.utf8.count
            if last.comma != nil { return [(lineStart..<lineStart, inner + member + "," + newline)] }
            return [(last.valueEnd..<last.valueEnd, ","), (lineStart..<lineStart, inner + member + newline)]
        }
        if let comma = last.comma { return [((comma + 1)..<(comma + 1), newline + inner + member)] }
        return [(last.valueEnd..<last.valueEnd, "," + newline + inner + member)]
    }

    /// `value` as indented JSON whose first line continues a line indented by `indent`.
    static func render(_ value: ConfigValue, indent: String, unit: String, newline: String) -> String {
        guard case .object(let fields) = value, !fields.isEmpty else { return compact(value) }
        let inner = indent + unit
        let members = fields.map { inner + quoted($0.0) + ": " + render($0.1, indent: inner, unit: unit, newline: newline) }
        return "{" + newline + members.joined(separator: "," + newline) + newline + indent + "}"
    }

    static func compact(_ value: ConfigValue) -> String {
        switch value {
        case .string(let text): quoted(text)
        case .bool(let flag): flag ? "true" : "false"
        case .array(let items): "[" + items.map(compact).joined(separator: ", ") + "]"
        case .object(let fields): fields.isEmpty ? "{}" : "{ " + fields.map { quoted($0.0) + ": " + compact($0.1) }.joined(separator: ", ") + " }"
        }
    }

    static func quoted(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    /// Finds members and the ends of values in JSON with comments and trailing commas.
    struct Scanner {
        struct Member {
            let key: String
            let keyStart: Int
            let valueStart: Int
            let valueEnd: Int
            /// The comma after the value, if there is one.
            let comma: Int?
        }

        let bytes: [UInt8]

        func failure(_ reason: String, at index: Int) -> ConfigError {
            ConfigError("\(reason) on line \(Lines.number(of: index, in: bytes))")
        }

        func topLevelObject() throws -> Int {
            var start = 0
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { start = 3 }
            let open = try skipTrivia(start)
            guard open < bytes.count, bytes[open] == .openBrace else { throw failure("the file is not a JSON object", at: open) }
            return open
        }

        /// The first index at or after `start` that is not whitespace or a comment.
        func skipTrivia(_ start: Int) throws -> Int {
            var i = start
            while i < bytes.count {
                if bytes[i].isWhitespace {
                    i += 1
                } else if bytes[i] == .slash, i + 1 < bytes.count, bytes[i + 1] == .slash {
                    while i < bytes.count, bytes[i] != .newline { i += 1 }
                } else if bytes[i] == .slash, i + 1 < bytes.count, bytes[i + 1] == .star {
                    var j = i + 2
                    while j + 1 < bytes.count, !(bytes[j] == .star && bytes[j + 1] == .slash) { j += 1 }
                    guard j + 1 < bytes.count else { throw failure("unclosed comment", at: i) }
                    i = j + 2
                } else {
                    break
                }
            }
            return i
        }

        func stringEnd(_ start: Int) throws -> Int {
            var i = start + 1
            while i < bytes.count {
                switch bytes[i] {
                case .backslash: i += 2
                case .quote: return i + 1
                case .newline: throw failure("line break in a string", at: i)
                default: i += 1
                }
            }
            throw failure("unclosed string", at: start)
        }

        func valueEnd(_ start: Int) throws -> Int {
            guard start < bytes.count else { throw failure("missing value", at: start) }
            switch bytes[start] {
            case .quote:
                return try stringEnd(start)
            case .openBrace:
                return try members(of: start).close + 1
            case .openBracket:
                var i = try skipTrivia(start + 1)
                while i < bytes.count, bytes[i] != .closeBracket {
                    i = try skipTrivia(try valueEnd(i))
                    guard i < bytes.count else { break }
                    if bytes[i] == .comma {
                        i = try skipTrivia(i + 1)
                    } else if bytes[i] != .closeBracket {
                        throw failure("expected , or ]", at: i)
                    }
                }
                guard i < bytes.count else { throw failure("unclosed array", at: start) }
                return i + 1
            default:
                var i = start
                while i < bytes.count, !bytes[i].isWhitespace, ![.comma, .closeBrace, .closeBracket, .slash].contains(bytes[i]) { i += 1 }
                guard i > start else { throw failure("unexpected character", at: start) }
                return i
            }
        }

        /// The members of the object whose brace is at `open`, and the index of its closing brace.
        func members(of open: Int) throws -> (members: [Member], close: Int) {
            var members: [Member] = []
            var i = try skipTrivia(open + 1)
            while i < bytes.count, bytes[i] != .closeBrace {
                guard bytes[i] == .quote else { throw failure("expected a key in double quotes", at: i) }
                let keyStart = i
                let keyEnd = try stringEnd(i)
                let key = (try? JSONSerialization.jsonObject(with: Data(bytes[i..<keyEnd]), options: .fragmentsAllowed)) as? String
                    ?? String(decoding: bytes[(i + 1)..<(keyEnd - 1)], as: UTF8.self)
                let colon = try skipTrivia(keyEnd)
                guard colon < bytes.count, bytes[colon] == .colon else { throw failure("expected :", at: colon) }
                let valueStart = try skipTrivia(colon + 1)
                let valueEnd = try valueEnd(valueStart)
                let next = try skipTrivia(valueEnd)
                guard next < bytes.count else { throw failure("unclosed object", at: open) }
                var comma: Int?
                if bytes[next] == .comma {
                    comma = next
                    i = try skipTrivia(next + 1)
                } else if bytes[next] == .closeBrace {
                    i = next
                } else {
                    throw failure("expected , or }", at: next)
                }
                members.append(Member(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd, comma: comma))
            }
            guard i < bytes.count else { throw failure("unclosed object", at: open) }
            return (members, i)
        }
    }
}
