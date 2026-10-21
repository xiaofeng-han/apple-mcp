import Foundation

/// A tool's arguments from command-line words, read the way its input schema says. Each property
/// is a flag, its `snake_case` name written `--kebab-case`:
///
///     text, or one of a set of words      --list Groceries, --list=Groceries
///     true or false                       --flagged, --no-flagged
///     whole number, number                --limit 20
///     a list of text or numbers           repeated, in the singular: --tag work --tag home
///     an object or a list of objects      JSON: --repeat '{"frequency":"daily"}'
///     anything (no type)                  JSON, or else text: --location getting-in-car
///     {after, before} (a position)        --after ID or --before ID
///
/// A field that takes null is cleared with `--no-name`. Bare words fill the positional fields in
/// order, and `--` ends the flags (for a word that starts with -). `--json OBJECT`, or `--json -`
/// to read it from stdin, gives fields as JSON; flags and words override them.
public struct Flags: Sendable {
    public struct Option: Sendable {
        public enum Kind: Sendable, Equatable {
            case text, choice([String]), flag, whole, number, texts, wholes, json
            /// JSON, or else text.
            case anything
            /// One side of a position: `name` is after or before.
            case position
        }

        /// The schema's property.
        public let key: String
        /// The flag, without its dashes.
        public let name: String
        public let kind: Kind
        /// Takes null, written --no-name.
        public let clearable: Bool
        public let required: Bool
        public let about: String
        /// The fields of a JSON object (or of the objects in a JSON list), with what each takes.
        public let fields: [Field]

        /// How it is written in a usage line: --list string, --[no-]flagged, --tag string…
        public var usage: String {
            switch kind {
            case .flag: "--[no-]\(name)"
            case .texts: "--\(name) string…"
            case .wholes: "--\(name) int…"
            default: "--\(name) \(placeholder)"
            }
        }

        var placeholder: String {
            switch kind {
            case .text, .position, .texts: "string"
            case .choice(let values): values.count <= 4 ? values.joined(separator: "|") : "string"
            case .flag: ""
            case .whole, .wholes: "int"
            case .number: "number"
            case .json: "json"
            case .anything: "json|string"
            }
        }
    }

    public struct Field: Sendable {
        public let name: String
        public let about: String
    }

    public struct Positional: Sendable {
        public let key: String
        /// How usage lines name it: TITLE, LIST.
        public let label: String
        public let required: Bool
        public let about: String
    }

    public let options: [Option]
    public let positional: [Positional]
    let fixed: [String: JSON]

    /// - Parameters:
    ///   - schema: the tool's input schema.
    ///   - positional: the fields bare words fill, in order, with their labels. One is required
    ///     when the schema or `required` says so.
    ///   - fixed: fields the command sets itself (a manage tool's action).
    ///   - only: the fields offered as flags, in this order; nil offers every other field, the
    ///     required ones first, then by name.
    ///   - required: fields this command needs that the schema leaves optional.
    ///   - clears: whether `--no-name` clears fields that take null (not when creating).
    ///   - abouts: descriptions that replace the schema's, for fields whose description is about
    ///     another use of the tool.
    public init(schema: JSON, positional: [(key: String, label: String)] = [], fixed: [String: JSON] = [:], only: [String]? = nil,
                required: [String] = [], clears: Bool = true, abouts: [String: String] = [:]) {
        let properties = schema["properties"]?.object ?? [:]
        let needed = Set((schema["required"]?.array ?? []).compactMap(\.string) + required)
        self.fixed = fixed
        self.positional = positional.map { field in
            Positional(key: field.key, label: field.label, required: needed.contains(field.key),
                       about: abouts[field.key] ?? properties[field.key]?["description"]?.string ?? "")
        }
        let taken = Set(fixed.keys).union(positional.map { $0.key })
        let keys = only ?? properties.keys.filter { !taken.contains($0) }
        let options = keys.flatMap { key -> [Option] in
            guard let property = properties[key] else { return [] }
            let (kind, clearable) = Self.kind(of: property)
            let name = key.replacingOccurrences(of: "_", with: "-")
            var about = abouts[key] ?? property["description"]?.string ?? (kind == .json ? "A JSON object" : "")
            if clearable && kind != .position {
                about = Self.clearing(about, with: clears ? "--no-\(kind == .texts || kind == .wholes ? Self.singular(name) : name)" : nil)
            }
            switch kind {
            case .position:
                return ["after", "before"].map { side in
                    Option(key: key, name: side, kind: .position, clearable: false, required: needed.contains(key),
                           about: (property["properties"]?[side]?["description"]?.string).map { "Put it \(side) this: \($0)" } ?? about, fields: [])
                }
            case .texts, .wholes:
                return [Option(key: key, name: Self.singular(name), kind: kind, clearable: clearable && clears, required: needed.contains(key),
                               about: about, fields: [])]
            default:
                return [Option(key: key, name: name, kind: kind, clearable: clearable && clears, required: needed.contains(key), about: about,
                               fields: Self.fields(of: property))]
            }
        }
        self.options = only != nil ? options : options.sorted { a, b in a.required != b.required ? a.required : a.name < b.name }
    }

    /// How a property's schema is read on the command line, and whether it takes null.
    static func kind(of property: JSON) -> (Option.Kind, clearable: Bool) {
        var types = property["type"]?.string.map { [$0] } ?? property["type"]?.array?.compactMap(\.string) ?? []
        let clearable = types.contains("null")
        types.removeAll { $0 == "null" }
        switch types.first {
        case nil:
            return (.anything, true)
        case "string":
            if let values = property["enum"]?.array?.compactMap(\.string) { return (.choice(values), clearable) }
            return (.text, clearable)
        case "boolean":
            return (.flag, clearable)
        case "integer":
            return (.whole, clearable)
        case "number":
            return (.number, clearable)
        case "array":
            switch property["items"]?["type"]?.string {
            case "string": return (.texts, clearable)
            case "integer": return (.wholes, clearable)
            default: return (.json, clearable)
            }
        case "object":
            let keys = Set(property["properties"]?.object?.keys.map { $0 } ?? [])
            return (keys == ["after", "before"] ? .position : .json, clearable)
        default:
            return (.json, clearable)
        }
    }

    /// The fields of an object, or of the objects in a list, sorted.
    static func fields(of property: JSON) -> [Field] {
        let properties = property["properties"]?.object ?? property["items"]?["properties"]?.object ?? [:]
        return properties.keys.sorted().map { key in
            let field = properties[key]!
            var about = field["description"]?.string ?? ""
            if let values = field["enum"]?.array?.compactMap(\.string) ?? field["items"]?["enum"]?.array?.compactMap(\.string) {
                about = values.joined(separator: "|") + (about.isEmpty ? "" : ". \(about)")
            }
            return Field(name: key, about: about)
        }
    }

    /// A field's description with "null" (how the tools clear a field) written as its --no- flag,
    /// or, where nothing is cleared, without the clauses about null.
    static func clearing(_ about: String, with flag: String?) -> String {
        guard let flag else { return about.components(separatedBy: "; ").filter { !$0.contains("null") }.joined(separator: "; ") }
        if about.contains("null") { return about.replacingOccurrences(of: "null", with: flag) }
        return about.isEmpty ? "\(flag) clears it" : "\(about); \(flag) clears it"
    }

    /// tags → tag, priorities → priority.
    static func singular(_ name: String) -> String {
        if name.hasSuffix("ies") { return String(name.dropLast(3)) + "y" }
        if name.hasSuffix("s") { return String(name.dropLast()) }
        return name
    }

    /// The tool's arguments. `stdin` reads standard input, for `--json -`.
    public func parse(_ words: [String], stdin: () -> String = { String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) })
        throws -> [String: JSON]
    {
        var base: [String: JSON] = [:]
        var given: [String: JSON] = [:]
        var repeated: [String: [JSON]] = [:]
        var bare: [String] = []
        var index = 0
        var ended = false

        func value(_ flag: String, _ inline: String?) throws -> String {
            if let inline { return inline }
            guard index < words.count else { throw BadInput("--\(flag) needs a value") }
            index += 1
            return words[index - 1]
        }
        func set(_ option: Option, _ value: JSON) throws {
            guard given[option.key] == nil else {
                throw BadInput(option.kind == .position ? "give --after or --before, once" : "--\(option.name) is given twice")
            }
            given[option.key] = value
        }

        while index < words.count {
            let word = words[index]
            index += 1
            if ended || word == "-" || !word.hasPrefix("-") {
                bare.append(word)
                continue
            }
            if word == "--" {
                ended = true
                continue
            }
            guard word.hasPrefix("--") else { throw BadInput("\(word) is not an option; put -- before a word that starts with -") }
            let body = word.dropFirst(2)
            let name = String(body.prefix { $0 != "=" })
            let inline = body.contains("=") ? String(body.drop { $0 != "=" }.dropFirst()) : nil
            if name == "json" {
                var text = try value(name, inline)
                if text == "-" { text = stdin() }
                guard let object = JSON.parse(text)?.object else { throw BadInput("--json takes a JSON object") }
                base.merge(object) { _, new in new }
                continue
            }
            if let option = options.first(where: { $0.name == name }) {
                switch option.kind {
                case .flag:
                    guard inline == nil || inline == "true" || inline == "false" else { throw BadInput("--\(name) is true or false") }
                    try set(option, .bool(inline != "false"))
                case .text:
                    try set(option, .string(try value(name, inline)))
                case .choice(let values):
                    let text = try value(name, inline)
                    guard values.contains(text) else { throw BadInput("--\(name) must be one of: \(values.joined(separator: ", "))") }
                    try set(option, .string(text))
                case .whole:
                    guard let number = Int(try value(name, inline)) else { throw BadInput("--\(name) takes a whole number") }
                    try set(option, .int(number))
                case .number:
                    guard let number = Double(try value(name, inline)) else { throw BadInput("--\(name) takes a number") }
                    try set(option, .double(number))
                case .texts:
                    repeated[option.key, default: []].append(.string(try value(name, inline)))
                case .wholes:
                    guard let number = Int(try value(name, inline)) else { throw BadInput("--\(name) takes whole numbers") }
                    repeated[option.key, default: []].append(.int(number))
                case .json:
                    guard let parsed = JSON.parse(try value(name, inline)) else { throw BadInput("--\(name) takes JSON") }
                    try set(option, parsed)
                case .anything:
                    let text = try value(name, inline)
                    try set(option, JSON.parse(text) ?? .string(text))
                case .position:
                    try set(option, .object([name: .string(try value(name, inline))]))
                }
            } else if name.hasPrefix("no-"), inline == nil, let option = options.first(where: { $0.name == name.dropFirst(3) }),
                option.kind == .flag || option.clearable
            {
                try set(option, option.kind == .flag ? false : .null)
            } else {
                let known = (options.map(\.name) + ["json"]).map { "--\($0)" }
                throw BadInput("--\(name) is not an option here; it takes \(known.joined(separator: ", "))")
            }
        }

        guard bare.count <= positional.count else {
            let extra = bare[positional.count]
            throw BadInput(positional.isEmpty ? "\"\(extra)\" is not expected; this command takes only flags"
                : "\"\(extra)\" is one word too many; quote a value that has spaces")
        }
        for (field, word) in zip(positional, bare) { given[field.key] = .string(word) }
        for (key, items) in repeated { given[key] = .array(items) }
        var arguments = base.merging(given) { _, new in new }
        arguments.merge(fixed) { _, new in new }
        for field in positional where field.required && arguments[field.key] == nil { throw BadInput("missing \(field.label)") }
        var checked = Set<String>()
        for option in options where option.required && arguments[option.key] == nil && checked.insert(option.key).inserted {
            throw BadInput(option.kind == .position ? "--after or --before is required" : "--\(option.name) is required")
        }
        return arguments
    }

    /// The words after the command name in a usage line: TITLE [QUERY].
    public var positionalUsage: String {
        positional.map { $0.required ? $0.label : "[\($0.label)]" }.joined(separator: " ")
    }

    /// The positional words and the flags that must be given: ID --version string.
    public var requiredUsage: String {
        var parts = [positionalUsage]
        var seen = Set<String>()
        for option in options where option.required && seen.insert(option.key).inserted {
            parts.append(option.kind == .position ? "(--after string | --before string)" : option.usage)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The flags that may be given.
    public var optional: [Option] { options.filter { !$0.required } }

    /// A command's help: usage, what it does, and its positional fields and flags. `extra` adds
    /// rows for flags the command reads itself.
    public func help(command: String, about: String, extra: [(String, String)] = []) -> String {
        var rows = positional.map { ($0.label, $0.about) }
        rows += options.map { option in
            var text = option.about
            if case .choice(let values) = option.kind, values.count > 4 { text += " (\(values.joined(separator: ", ")))" }
            if option.kind == .texts || option.kind == .wholes { text += " (repeat for more)" }
            if option.required && option.kind != .position { text += " (required)" }
            for field in option.fields { text += "\n    \(field.name): \(field.about)" }
            return (option.usage, text)
        }
        rows += extra
        rows += [("--json json|-", "Fields as a JSON object (- reads it from stdin); flags override them"), ("-h, --help", "Show this help")]
        let width = min(rows.map(\.0.count).max() ?? 0, 32)
        let indent = String(repeating: " ", count: width + 4)
        let lines = rows.map { label, text in
            let text = text.replacingOccurrences(of: "\n", with: "\n" + indent)
            return label.count > width ? "  \(label)\n\(indent)\(text)" : "  \(label.padding(toLength: width, withPad: " ", startingAt: 0))  \(text)"
        }
        let usage = ([command, requiredUsage] + (optional.isEmpty ? [] : ["[flags]"])).filter { !$0.isEmpty }.joined(separator: " ")
        return "usage: \(usage)\n\n\(about)\n\n\(lines.joined(separator: "\n"))\n"
    }
}
