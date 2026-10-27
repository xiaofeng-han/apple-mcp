import Foundation

// Notes ⇄ Markdown. One note paragraph is one Markdown line, so a model can change a line and
// write the note back without anything else moving. `parse(render(blocks)) == blocks` holds for
// every note body; the parser is also lenient with what models tend to write (`+` lists, `####`,
// CRLF, unclosed emphasis).
//
//   # title   ## heading   ### subheading   * bullet   - dash   1. numbered   - [ ] / - [x] checkbox
//   > quote (per level)   two spaces per indent level   ``` monospaced lines ```
//   **bold**  *italic*  ~~strike~~  <u>underline</u>  <mark>highlight</mark>  [text](url)
//   <mark class="pink">: the other highlight colors (pink, orange, mint, blue; purple is <mark>)
//   | table | cells |   ![kind: label](attachment:id)   #tag   [text](note:id)   --- (a divider line)
//   ![name](/path/to/file) and ![](https://…) add a file or a link card

public enum Markdown {
    // MARK: Rendering

    /// `attachment` may replace an attachment's placeholder (an export links files instead);
    /// such output is for reading and does not parse back.
    public static func render(_ blocks: [Block], attachment: ((Attachment) -> String?)? = nil) -> String {
        var lines: [String] = []
        var numbers: [Int: Int] = [:]  // indent level → last number shown there
        var index = 0
        while index < blocks.count {
            switch blocks[index] {
            case .table(let table):
                numbers = [:]
                lines += tableLines(table)
                index += 1
            case .paragraph(let first) where first.style == .monospaced:
                numbers = [:]
                // Monospaced lines at one level share a fence.
                var texts: [String] = []
                while index < blocks.count, case .paragraph(let p) = blocks[index], p.style == .monospaced,
                    p.quote == first.quote, p.indent == first.indent
                {
                    texts.append(p.pieces.map { piece in
                        switch piece {
                        case .text(let run): run.text
                        case .attachment(let a): attachment?(a) ?? placeholder(a)
                        }
                    }.joined())
                    index += 1
                }
                let prefix = linePrefix(quote: first.quote, indent: first.indent)
                let fence = fence(around: texts)
                lines.append(prefix + fence)
                lines += texts.map { prefix + $0 }
                lines.append(prefix + fence)
            case .paragraph(let p) where p.style == .body && p.pieces == [.attachment(.divider)]:
                numbers = [:]
                lines.append(linePrefix(quote: p.quote, indent: p.indent) + "---")
                index += 1
            case .paragraph(let p):
                let marker: String
                switch p.style {
                case .numbered:
                    let n = (numbers[p.indent] ?? 0) + 1
                    numbers = numbers.filter { $0.key < p.indent }
                    numbers[p.indent] = n
                    marker = "\(n). "
                case .bullet, .dash, .checkbox:
                    numbers = numbers.filter { $0.key < p.indent }
                    marker = listMarker(p.style)
                default:
                    numbers = [:]
                    marker = listMarker(p.style)
                }
                var text = inline(p.pieces, attachment: attachment)
                if p.style == .body, needsLineEscape(text) { text = "\\" + text }
                lines.append(linePrefix(quote: p.quote, indent: p.indent) + marker + text)
                index += 1
            }
        }
        return lines.joined(separator: "\n")
    }

    static func listMarker(_ style: Style) -> String {
        switch style {
        case .title: "# "
        case .heading: "## "
        case .subheading: "### "
        case .bullet: "* "
        case .dash: "- "
        case .numbered: "1. "
        case .checkbox(let checked): checked ? "- [x] " : "- [ ] "
        case .body, .monospaced: ""
        }
    }

    static func linePrefix(quote: Int, indent: Int) -> String {
        String(repeating: "> ", count: quote) + String(repeating: "  ", count: indent)
    }

    /// Three backticks, or more than the longest run that starts one of the lines.
    static func fence(around texts: [String]) -> String {
        let longest = texts.map { $0.prefix(while: { $0 == "`" }).count }.max() ?? 0
        return String(repeating: "`", count: max(3, longest + 1))
    }

    /// A body line whose text would read as something else (a heading, list item, quote,
    /// fence, table row or indentation) is written with a leading backslash.
    static func needsLineEscape(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if " \t>|".contains(first) || text.hasPrefix("```") || isDivider(Substring(text)) { return true }
        return marker(in: Substring(text)) != nil
    }

    public static func placeholder(_ attachment: Attachment) -> String {
        "![" + escape(attachment.caption) + "](attachment:" + attachment.id + ")"
    }

    /// Delimiters in nesting order, outermost first. A fixed order keeps neighbouring spans from
    /// producing ambiguous runs of delimiters.
    static let delimiters: [(mark: Marks, open: String, close: String)] = [
        (.highlight, "<mark>", "</mark>"), (.underline, "<u>", "</u>"), (.strike, "~~", "~~"),
        (.italic, "*", "*"), (.bold, "**", "**"),
    ]

    /// The opening tag of a highlight of this color.
    static func markTag(_ color: Int) -> String {
        guard color != Highlight.purple, let name = Highlight.names[color] else { return "<mark>" }
        return "<mark class=\"\(name)\">"
    }

    static func inline(_ pieces: [Piece], attachment: ((Attachment) -> String?)? = nil) -> String {
        var out = ""
        var open: [Marks] = []  // innermost last
        var openColor = 0
        func switchTo(_ marks: Marks, color: Int = 0) {
            // Close from the innermost mark down to the first one that ends (or a highlight that
            // changes color), then open what is new.
            let keep = open.firstIndex { !marks.contains($0) || ($0 == .highlight && color != openColor) } ?? open.count
            for mark in open[keep...].reversed() { out += delimiters.first { $0.mark == mark }!.close }
            open.removeSubrange(keep...)
            for d in delimiters where marks.contains(d.mark) && !open.contains(d.mark) {
                out += d.mark == .highlight ? markTag(color) : d.open
                if d.mark == .highlight { openColor = color }
                open.append(d.mark)
            }
        }
        for (index, piece) in pieces.enumerated() {
            switch piece {
            case .text(let run):
                switchTo(run.marks, color: run.color)
                if let link = run.link {
                    out += "[" + escape(run.text) + "](" + escapeLink(link) + ")"
                } else {
                    out += escape(run.text)
                }
            case .attachment(let a):
                switchTo([])
                if let replaced = attachment?(a) {
                    out += replaced
                } else if let tag = tagText(a), out.last.map(canPrecedeTag) ?? true, !startsWithTagCharacter(pieces, after: index) {
                    out += tag
                } else if let (text, note) = a.linkParts, !note.contains(")"), !note.contains("\\") {
                    out += "[" + escape(text) + "](note:" + note + ")"
                } else {
                    out += placeholder(a)
                }
            }
        }
        switchTo([])
        return out
    }

    /// Escapes only what would otherwise be read as syntax, so text stays readable: `_` inside a
    /// line is left alone, and `#` only where a tag could start.
    public static func escape(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        for (i, c) in chars.enumerated() {
            switch c {
            case "\\", "*", "[", "]":
                out += "\\" + String(c)
            case "#" where tagName(chars, after: i) != nil:
                out += "\\#"
            case "~" where i == 0 || i == chars.count - 1 || chars[i - 1] == "~" || chars[i + 1] == "~":
                out += "\\~"
            case "<" where ["u>", "/u>", "mark>", "/mark>", "mark class="].contains(where: { chars[(i + 1)...].starts(with: $0) }):
                out += "\\<"
            default:
                out.append(c)
            }
        }
        return out
    }

    // MARK: Tags

    /// A tag's name is letters, digits, `_` and `-`, with at least one letter: `#1` and `C#` are
    /// not tags.
    static func isTagCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "-" }

    /// The name of a tag whose `#` is at `index`, if the characters after it make one.
    static func tagName(_ chars: [Character], after index: Int) -> String? {
        let name = chars[(index + 1)...].prefix(while: isTagCharacter)
        return name.contains(where: \.isLetter) ? String(name) : nil
    }

    /// A tag starts a word: at the start of the line, or after a space, an opening bracket or
    /// quote, a comma, semicolon or colon, or CJK punctuation ("标签：#x"). Not after a letter or
    /// digit (C#) or a slash (a web address's /#part).
    static func canPrecedeTag(_ c: Character) -> Bool {
        if c.isWhitespace || "([{\"'“‘,;:".contains(c) { return true }
        guard let scalar = c.unicodeScalars.first, c.isPunctuation else { return false }
        return (0x3000...0x303F).contains(scalar.value) || (0xFF00...0xFF65).contains(scalar.value)
    }

    /// "#name" for a tag whose name Markdown can write.
    static func tagText(_ a: Attachment) -> String? {
        guard a.kind == "tag", a.label.hasPrefix("#") else { return nil }
        let chars = Array(a.label)
        return tagName(chars, after: 0) == String(chars.dropFirst()) ? a.label : nil
    }

    /// Whether the text after piece `index` would run into a tag written there.
    static func startsWithTagCharacter(_ pieces: [Piece], after index: Int) -> Bool {
        guard index + 1 < pieces.count, case .text(let run) = pieces[index + 1], let first = run.text.first else { return false }
        return run.link == nil && isTagCharacter(first)
    }

    public static func escapeLink(_ url: String) -> String {
        url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ")", with: "\\)")
    }

    static func tableLines(_ table: Table) -> [String] {
        let width = max(table.width, 1)
        func row(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: width - cells.count)
            return "| " + padded.map(escapeCell).joined(separator: " | ") + " |"
        }
        let rows = table.rows.isEmpty ? [[]] : table.rows
        return [row(rows[0]), "|" + String(repeating: " --- |", count: width)] + rows.dropFirst().map(row)
    }

    public static func escapeCell(_ cell: String) -> String {
        cell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "<br>", with: "\\<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    // MARK: Parsing

    public static func parse(_ markdown: String) -> [Block] {
        var lines = markdown.components(separatedBy: "\n")
        // CR is dropped only from a CRLF document; a lone CR inside text is content.
        if lines.count > 1, lines.dropLast().allSatisfy({ $0.hasSuffix("\r") }) {
            lines = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        }
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            let (quote, indent, rest) = splitPrefix(lines[i])
            if rest.hasPrefix("```") {
                let fence = String(rest.prefix(while: { $0 == "`" }))
                let prefix = linePrefix(quote: quote, indent: indent)
                i += 1
                while i < lines.count {
                    let line = lines[i]
                    i += 1
                    let text: String
                    if line.hasPrefix(prefix) {
                        text = String(line.dropFirst(prefix.count))
                    } else if line + " " == prefix || prefix.hasPrefix(line) {
                        text = ""  // trailing spaces of the prefix went missing
                    } else {
                        text = line
                    }
                    if text.trimmingCharacters(in: .whitespaces) == fence { break }
                    blocks.append(.paragraph(Paragraph(.monospaced, indent: indent, quote: quote, codePieces(text))))
                }
                continue
            }
            if quote == 0, indent == 0, rest.hasPrefix("|"), i + 1 < lines.count, isSeparator(lines[i + 1]) {
                var rows = [cells(of: rest)]
                i += 2
                // A row followed by a separator starts another table: adjacent tables have no
                // line between them.
                while i < lines.count, lines[i].hasPrefix("|"), !(i + 1 < lines.count && isSeparator(lines[i + 1])) {
                    rows.append(cells(of: Substring(lines[i])))
                    i += 1
                }
                let width = rows.map(\.count).max() ?? 0
                blocks.append(.table(Table(rows: rows.map { $0 + Array(repeating: "", count: width - $0.count) })))
                continue
            }
            if isDivider(rest) {
                blocks.append(.paragraph(Paragraph(.body, indent: indent, quote: quote, [.attachment(.divider)])))
                i += 1
                continue
            }
            var style = Style.body
            var text = rest
            if let (found, length) = marker(in: rest) {
                style = found
                text = rest.dropFirst(length)
            }
            blocks.append(.paragraph(Paragraph(style, indent: indent, quote: quote, inlinePieces(String(text)))))
            i += 1
        }
        return blocks
    }

    static func splitPrefix(_ line: String) -> (quote: Int, indent: Int, rest: Substring) {
        var rest = Substring(line)
        var quote = 0
        while rest.hasPrefix(">") {
            quote += 1
            rest = rest.dropFirst()
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        }
        var indent = 0
        while true {
            if rest.hasPrefix("  ") {
                rest = rest.dropFirst(2)
            } else if rest.hasPrefix("\t") {
                rest = rest.dropFirst()
            } else {
                break
            }
            indent += 1
        }
        // An odd space left over from indenting by hand is not text.
        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        return (quote, indent, rest)
    }

    /// A divider line: three or more of `-`, `*` or `_`, alone.
    static func isDivider(_ line: Substring) -> Bool {
        guard let first = line.first, "-*_".contains(first), line.count >= 3 else { return false }
        return line.allSatisfy { $0 == first }
    }

    /// The paragraph style a line starts with, and the length of its marker.
    static func marker(in line: Substring) -> (Style, Int)? {
        let fixed: [(String, Style)] = [
            ("- [ ] ", .checkbox(checked: false)), ("- [x] ", .checkbox(checked: true)), ("- [X] ", .checkbox(checked: true)),
            ("* [ ] ", .checkbox(checked: false)), ("* [x] ", .checkbox(checked: true)),
            ("### ", .subheading), ("## ", .heading), ("# ", .title),
            ("* ", .bullet), ("- ", .dash), ("+ ", .dash),
        ]
        for (text, style) in fixed where line.hasPrefix(text) { return (style, text.count) }
        // The same markers with nothing after them, their trailing space trimmed away.
        for (text, style) in fixed where line == text.dropLast() { return (style, line.count) }
        let hashes = line.prefix(while: { $0 == "#" })
        if hashes.count > 3 {
            // Notes has no deeper headings.
            if line.dropFirst(hashes.count).hasPrefix(" ") { return (.subheading, hashes.count + 1) }
            if line.count == hashes.count { return (.subheading, hashes.count) }
        }
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty, digits.count <= 9 {
            let after = line.dropFirst(digits.count)
            if after.hasPrefix(". ") { return (.numbered, digits.count + 2) }
            if after == "." { return (.numbered, digits.count + 1) }
        }
        return nil
    }

    // MARK: Inline parsing

    private enum Token {
        case text(String)
        case stars(Int)
        case tag(Marks, opening: Bool, source: String)
        /// The opening tag of a highlight, with its color.
        case mark(Int, source: String)
        case strike
        case link(String, String)
        case attachment(Attachment)
    }

    static func codePieces(_ text: String) -> [Piece] {
        // Inside a fence only attachment placeholders mean something.
        var pieces: [Piece] = []
        var plain = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "!", i + 1 < chars.count, chars[i + 1] == "[", let (label, target, end) = bracket(chars, at: i + 1),
                target.hasPrefix("attachment:")
            {
                if !plain.isEmpty { pieces.append(.text(Run(plain))) }
                plain = ""
                pieces.append(.attachment(attachment(label: label, id: String(target.dropFirst("attachment:".count)))))
                i = end
                continue
            }
            plain.append(chars[i])
            i += 1
        }
        if !plain.isEmpty { pieces.append(.text(Run(plain))) }
        return pieces
    }

    /// An attachment to add: a file by its path (absolute, ~/…, or file://), or a card for a web
    /// address. The label is the path or address, then the name to show after a newline.
    static func addition(label: String, target: String) -> Attachment? {
        let name = label.isEmpty ? "" : "\n" + label
        if target.hasPrefix("https://") || target.hasPrefix("http://") { return Attachment(id: "", kind: Attachment.newLinkCard, label: target + name) }
        if target.hasPrefix("file://"), let path = URL(string: target)?.path, !path.isEmpty {
            return Attachment(id: "", kind: Attachment.newFile, label: path + name)
        }
        if target.hasPrefix("/") || target.hasPrefix("~/") { return Attachment(id: "", kind: Attachment.newFile, label: target + name) }
        return nil
    }

    static func attachment(label: String, id: String) -> Attachment {
        let parts = label.split(separator: ":", maxSplits: 1)
        let kind = parts.first.map(String.init) ?? ""
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return Attachment(id: id, kind: kind, label: rest)
    }

    static func inlinePieces(_ source: String) -> [Piece] {
        let tokens = tokenize(Array(source))
        // Emphasis left open at the end of the line was meant literally (`5 * 3`); read those
        // delimiters as text and try again.
        var literal: Set<Int> = []
        while true {
            let (pieces, unclosed) = build(tokens, literal: literal)
            if unclosed.isEmpty || unclosed.isSubset(of: literal) { return pieces.normalized() }
            literal.formUnion(unclosed)
        }
    }

    private static func tokenize(_ chars: [Character]) -> [Token] {
        var tokens: [Token] = []
        var plain = ""
        func flush() {
            if !plain.isEmpty { tokens.append(.text(plain)) }
            plain = ""
        }
        func at(_ i: Int, _ text: String) -> Bool { chars[i...].starts(with: text) }
        let tags: [(String, Marks, Bool)] = [("<mark>", .highlight, true), ("</mark>", .highlight, false), ("<u>", .underline, true), ("</u>", .underline, false)]
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                plain.append(chars[i + 1])
                i += 2
            } else if c == "*" {
                flush()
                let count = chars[i...].prefix(while: { $0 == "*" }).count
                tokens.append(.stars(count))
                i += count
            } else if at(i, "~~") {
                flush()
                tokens.append(.strike)
                i += 2
            } else if c == "<", let (source, mark, opening) = tags.first(where: { at(i, $0.0) }) {
                flush()
                tokens.append(.tag(mark, opening: opening, source: source))
                i += source.count
            } else if c == "<", let (color, source) = Highlight.names.lazy.map({ ($0.key, markTag($0.key)) }).first(where: { at(i, $0.1) && $0.0 != Highlight.purple }) {
                flush()
                tokens.append(.mark(color, source: source))
                i += source.count
            } else if c == "!", i + 1 < chars.count, chars[i + 1] == "[", let (label, target, end) = bracket(chars, at: i + 1),
                let added = target.hasPrefix("attachment:") ? attachment(label: label, id: String(target.dropFirst("attachment:".count)))
                    : addition(label: label, target: target)
            {
                flush()
                tokens.append(.attachment(added))
                i = end
            } else if c == "[", let (label, target, end) = bracket(chars, at: i) {
                flush()
                if target.hasPrefix("note:"), target.count > 5 {
                    tokens.append(.attachment(.noteLink(label, to: String(target.dropFirst(5)))))
                } else {
                    tokens.append(.link(label, target))
                }
                i = end
            } else if c == "#", i == 0 || canPrecedeTag(chars[i - 1]), let name = tagName(chars, after: i) {
                flush()
                tokens.append(.attachment(.tag(name)))
                i += 1 + name.count
            } else {
                plain.append(c)
                i += 1
            }
        }
        flush()
        return tokens
    }

    /// Pieces from tokens, and the indexes of delimiter tokens that opened something never closed.
    private static func build(_ tokens: [Token], literal: Set<Int>) -> ([Piece], Set<Int>) {
        var pieces: [Piece] = []
        var marks: Marks = []
        var color = 0
        var stars: [(mark: Marks, token: Int)] = []  // open italic and bold, innermost last
        var openedBy: [Int: Int] = [:]  // mark raw value → token that opened it
        func text(_ s: String) {
            guard !s.isEmpty else { return }
            pieces.append(.text(Run(s, marks: marks, color: color)))
        }
        func source(_ token: Token) -> String {
            switch token {
            case .stars(let n): String(repeating: "*", count: n)
            case .strike: "~~"
            case .tag(_, _, let s), .mark(_, let s): s
            default: ""
            }
        }
        for (index, token) in tokens.enumerated() {
            if literal.contains(index) {
                text(source(token))
                continue
            }
            switch token {
            case .text(let s):
                text(s)
            case .link(let label, let target):
                if !label.isEmpty { pieces.append(.text(Run(label, marks: marks, link: target, color: color))) }
            case .attachment(let a):
                pieces.append(.attachment(a))
            case .strike:
                if marks.contains(.strike) {
                    marks.remove(.strike)
                    openedBy[Marks.strike.rawValue] = nil
                } else {
                    marks.insert(.strike)
                    openedBy[Marks.strike.rawValue] = index
                }
            case .mark(let c, let s):
                if !marks.contains(.highlight) {
                    marks.insert(.highlight)
                    color = c
                    openedBy[Marks.highlight.rawValue] = index
                } else {
                    text(s)
                }
            case .tag(let mark, let opening, let s):
                if opening, !marks.contains(mark) {
                    marks.insert(mark)
                    if mark == .highlight { color = Highlight.purple }
                    openedBy[mark.rawValue] = index
                } else if !opening, marks.contains(mark) {
                    marks.remove(mark)
                    openedBy[mark.rawValue] = nil
                } else {
                    text(s)
                }
            case .stars(let count):
                guard let plan = starPlan(count, open: stars.map(\.mark)) else {
                    text(String(repeating: "*", count: count))
                    continue
                }
                for _ in 0..<plan.closes {
                    let closed = stars.removeLast()
                    marks.remove(closed.mark)
                    openedBy[closed.mark.rawValue] = nil
                }
                for mark in plan.opens {
                    marks.insert(mark)
                    stars.append((mark, index))
                    openedBy[mark.rawValue] = index
                }
            }
        }
        return (pieces, Set(openedBy.values))
    }

    /// How a run of `count` asterisks splits into closing the innermost open marks and opening
    /// new ones, the way `inline` writes them: closes first, then opens with italic outside bold.
    /// The fewest closes win. A mark is closed and opened again only when a mark outside it
    /// closes too, which is the only time the renderer does that.
    static func starPlan(_ count: Int, open: [Marks]) -> (closes: Int, opens: [Marks])? {
        func width(_ mark: Marks) -> Int { mark == .bold ? 2 : 1 }
        var closedWidth = 0
        for closes in 0...open.count {
            if closes > 0 { closedWidth += width(open[open.count - closes]) }
            if closedWidth > count { return nil }
            let closed = Array(open.suffix(closes))
            let stillOpen = open.prefix(open.count - closes)
            for opens in [[], [Marks.italic], [Marks.bold], [Marks.italic, Marks.bold]]
            where opens.reduce(0, { $0 + width($1) }) == count - closedWidth {
                if opens.contains(where: { stillOpen.contains($0) }) { continue }
                let reopened = opens.filter { closed.contains($0) }
                if !reopened.isEmpty, closed.allSatisfy({ opens.contains($0) }) { continue }
                return (closes, opens)
            }
        }
        return nil
    }

    /// `[label](target)` starting at an opening bracket, with backslash escapes; nil when the
    /// text there is not a complete link.
    static func bracket(_ chars: [Character], at start: Int) -> (String, String, Int)? {
        guard start < chars.count, chars[start] == "[" else { return nil }
        var label = ""
        var i = start + 1
        while i < chars.count, chars[i] != "]" {
            if chars[i] == "\\", i + 1 < chars.count { i += 1 }
            label.append(chars[i])
            i += 1
        }
        guard i + 1 < chars.count, chars[i + 1] == "(" else { return nil }
        var target = ""
        i += 2
        while i < chars.count, chars[i] != ")" {
            if chars[i] == "\\", i + 1 < chars.count { i += 1 }
            target.append(chars[i])
            i += 1
        }
        guard i < chars.count else { return nil }
        return (label, target, i + 1)
    }

    // MARK: Tables

    /// A table's separator row. It has a pipe: "---" alone is a divider line.
    static func isSeparator(_ line: String) -> Bool {
        guard line.hasPrefix("|") || line.hasPrefix(":") || line.hasPrefix("-"), line.contains("|") else { return false }
        let row = cells(of: Substring(line))
        return !row.isEmpty && row.allSatisfy { cell in
            let t = cell.trimmingCharacters(in: .whitespaces)
            return t.contains("-") && t.allSatisfy { "-:".contains($0) }
        }
    }

    static func cells(of line: Substring) -> [String] {
        var cells: [String] = []
        var cell = ""
        let chars = Array(line)
        var i = chars.first == "|" ? 1 : 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                cell.append(chars[i + 1])
                i += 2
            } else if c == "|" {
                cells.append(cell)
                cell = ""
                i += 1
            } else if chars[i...].starts(with: "<br>") {
                cell.append("\n")
                i += 4
            } else {
                cell.append(c)
                i += 1
            }
        }
        if !cell.trimmingCharacters(in: .whitespaces).isEmpty { cells.append(cell) }
        return cells.map { cell in
            var s = Substring(cell)
            if s.hasPrefix(" ") { s = s.dropFirst() }
            if s.hasSuffix(" ") { s = s.dropLast() }
            return String(s)
        }
    }
}
