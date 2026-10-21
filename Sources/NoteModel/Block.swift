import Foundation

// A note body as far as Markdown can show it. What Markdown cannot show (colors, fonts,
// alignment, edit timestamps) is not in this model; it stays in the note, because writes edit the
// note in place instead of replacing it from this model.

public enum Block: Sendable, Equatable {
    case paragraph(Paragraph)
    case table(Table)
}

/// Notes' paragraph styles. The raw numbers are what Notes stores.
public enum Style: Sendable, Hashable {
    case title, heading, subheading, body, monospaced, bullet, dash, numbered
    case checkbox(checked: Bool)

    public var number: Int {
        switch self {
        case .title: 0
        case .heading: 1
        case .subheading: 2
        case .body: 3
        case .monospaced: 4
        case .bullet: 100
        case .dash: 101
        case .numbered: 102
        case .checkbox: 103
        }
    }

    public init(number: Int, checked: Bool) {
        switch number {
        case 0: self = .title
        case 1: self = .heading
        case 2: self = .subheading
        case 4: self = .monospaced
        case 100: self = .bullet
        case 101: self = .dash
        case 102: self = .numbered
        case 103: self = .checkbox(checked: checked)
        default: self = .body
        }
    }

    /// 1 for the title, 2 for a heading, 3 for a subheading.
    public var headingLevel: Int? {
        switch self {
        case .title: 1
        case .heading: 2
        case .subheading: 3
        default: nil
        }
    }

    /// Items that read as one list when they follow each other.
    public var listFamily: String? {
        switch self {
        case .checkbox: "checkbox"
        case .bullet: "bullet"
        case .dash: "dash"
        case .numbered: "numbered"
        default: nil
        }
    }
}

public struct Marks: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let bold = Marks(rawValue: 1)
    public static let italic = Marks(rawValue: 2)
    public static let strike = Marks(rawValue: 4)
    public static let underline = Marks(rawValue: 8)
    public static let highlight = Marks(rawValue: 16)
}

/// Text with the same marks and link.
public struct Run: Sendable, Equatable {
    public var text: String
    public var marks: Marks
    public var link: String?

    public init(_ text: String, marks: Marks = [], link: String? = nil) {
        self.text = text
        self.marks = marks
        self.link = link
    }
}

/// An attachment inside a paragraph, kept as an opaque placeholder. It is identified by its id;
/// kind and label only describe it.
public struct Attachment: Sendable, Equatable {
    public var id: String
    public var kind: String
    public var label: String

    public init(id: String, kind: String, label: String = "") {
        self.id = id
        self.kind = kind
        self.label = label
    }

    public static func == (a: Attachment, b: Attachment) -> Bool { a.id == b.id }

    /// "image", or "link card: https://…".
    public var caption: String { label.isEmpty ? kind : kind + ": " + label }
}

public enum Piece: Sendable, Equatable {
    case text(Run)
    case attachment(Attachment)
}

public struct Paragraph: Sendable, Equatable {
    public var style: Style
    public var indent: Int
    public var quote: Int
    public var pieces: [Piece]

    public init(_ style: Style = .body, indent: Int = 0, quote: Int = 0, _ pieces: [Piece] = []) {
        self.style = style
        self.indent = indent
        self.quote = quote
        self.pieces = pieces
    }

    /// The text, with U+FFFC where an attachment sits, as in the note.
    public var plainText: String {
        pieces.map { piece in
            switch piece {
            case .text(let run): run.text
            case .attachment: "\u{FFFC}"
            }
        }.joined()
    }

    public var isBlank: Bool { style == .body && pieces.isEmpty }

    public var attachments: [Attachment] {
        pieces.compactMap { if case .attachment(let a) = $0 { a } else { nil } }
    }
}

/// A Notes table. Cells are plain text: Markdown tables have no cell formatting.
public struct Table: Sendable, Equatable {
    /// The attachment's id; empty for a table that only exists in Markdown so far.
    public var id: String
    public var rows: [[String]]

    public init(id: String = "", rows: [[String]]) {
        self.id = id
        self.rows = rows
    }

    /// Markdown shows no table ids, so tables compare by content.
    public static func == (a: Table, b: Table) -> Bool { a.rows == b.rows }

    public var width: Int { rows.map(\.count).max() ?? 0 }
}

extension Array where Element == Block {
    /// Attachments in paragraphs, in order. Tables are blocks of their own and are not included.
    public var attachments: [Attachment] {
        flatMap { block -> [Attachment] in
            if case .paragraph(let p) = block { return p.attachments }
            return []
        }
    }

    /// The same blocks with each attachment id passed through `change`.
    public func mappingAttachmentIDs(_ change: (String) -> String) -> [Block] {
        map { block in
            guard case .paragraph(var p) = block else { return block }
            p.pieces = p.pieces.map { piece in
                guard case .attachment(var a) = piece else { return piece }
                a.id = change(a.id)
                return .attachment(a)
            }
            return .paragraph(p)
        }
    }

    /// The title: the first line's text.
    public var title: String {
        guard case .paragraph(let p)? = first else { return "" }
        return p.plainText
    }
}

extension Array where Element == Piece {
    /// The one form of a paragraph's content that reading a note and parsing Markdown both
    /// produce. Neighbouring runs that look the same are joined (hidden attributes such as fonts
    /// split runs in the note), empty runs go, and whitespace at either edge of a bold, italic or
    /// strikethrough span loses that mark: Markdown cannot open `**`, `*` or `~~` before a space or
    /// close it after one, so `**word **` would show its asterisks in other Markdown readers.
    /// Underline and highlight are HTML tags, which may hold spaces.
    public func normalized() -> [Piece] {
        var units: [NormalizationUnit] = []
        for piece in self {
            switch piece {
            case .text(let run): units += run.text.map { .character($0, run.marks, run.link) }
            case .attachment(let a): units.append(.attachment(a))
            }
        }
        func marks(_ i: Int) -> Marks? {
            if case .character(_, let m, _) = units[i] { return m }
            return nil
        }
        for mark in [Marks.bold, .italic, .strike] {
            var i = 0
            while i < units.count {
                guard marks(i)?.contains(mark) == true else {
                    i += 1
                    continue
                }
                var end = i
                while end + 1 < units.count, marks(end + 1)?.contains(mark) == true { end += 1 }
                // Strip the mark from whitespace at the start, then at the end, of this span.
                func strip(_ k: Int) -> Bool {
                    guard case .character(let c, var m, let link) = units[k], c.isWhitespace else { return false }
                    m.remove(mark)
                    units[k] = .character(c, m, link)
                    return true
                }
                var low = i
                while low <= end, strip(low) { low += 1 }
                var high = end
                while high > low, strip(high) { high -= 1 }
                i = end + 1
            }
        }
        var out: [Piece] = []
        var current: Run?
        for unit in units {
            switch unit {
            case .character(let c, let m, let link):
                if let run = current, run.marks == m, run.link == link {
                    current!.text.append(c)
                } else {
                    if let run = current { out.append(.text(run)) }
                    current = Run(String(c), marks: m, link: link)
                }
            case .attachment(let a):
                if let run = current { out.append(.text(run)) }
                current = nil
                out.append(.attachment(a))
            }
        }
        if let run = current { out.append(.text(run)) }
        return out
    }
}

private enum NormalizationUnit {
    case character(Character, Marks, String?)
    case attachment(Attachment)
}

/// Ids as tools show them: the first 8 characters of a UUID, which is plenty to tell a few
/// thousand notes apart and costs far fewer tokens than the whole id in every line of a list.
/// Tools accept any unique prefix and refuse an ambiguous one.
public enum ShortID {
    public static func of(_ id: String) -> String {
        id.count == 36 && UUID(uuidString: id) != nil ? String(id.prefix(8)) : id
    }

    /// The one id in `ids` that `reference` names, in full or by a prefix of at least 4 characters.
    public static func resolve(_ reference: String, in ids: [String]) -> Resolution {
        let wanted = reference.trimmingCharacters(in: .whitespaces)
        if ids.contains(wanted) { return .found(wanted) }
        guard wanted.count >= 4 else { return .none }
        let matches = Set(ids.filter { $0.lowercased().hasPrefix(wanted.lowercased()) })
        switch matches.count {
        case 0: return .none
        case 1: return .found(matches.first!)
        default: return .ambiguous(matches.sorted())
        }
    }

    public enum Resolution: Equatable {
        case found(String)
        case none
        case ambiguous([String])
    }
}

/// Folder paths join folder names with "/". Notes allows "/" inside a name, which a path writes
/// as "\/".
public enum FolderPath {
    public static func join(_ names: [String]) -> String {
        names.map { $0.replacingOccurrences(of: "/", with: "\\/") }.joined(separator: "/")
    }

    public static func split(_ path: String) -> [String] {
        var names: [String] = []
        var name = ""
        var escaped = false
        for c in path {
            if escaped {
                name.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "/" {
                names.append(name)
                name = ""
            } else {
                name.append(c)
            }
        }
        names.append(name)
        return names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
