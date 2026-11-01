import AppKit
import Foundation
import NoteModel

/// An entry's text in one form that both of Journal's formats convert to and from, and that
/// Markdown maps onto: a string whose characters carry only what Markdown shows of their formatting
/// (`Canonical`). Journal 3.0 keeps text as a mergeable attributed string (Coherence's CRDT, with
/// typed attributes: font traits, underline, strikethrough, lists, block quotes, inline assets);
/// entries written before it keep RTF. Writes change the mergeable text in place, only where it
/// differs, so the rest keeps its formatting (colors, alignment) and its history for merging with
/// edits made on other devices.
package enum EntryText {
    /// What Markdown shows of a character's formatting, on each character.
    package static let marksKey = NSAttributedString.Key("AppleJournalMCP.marks")
    /// What Markdown shows of a paragraph (list kind and level, quote), on each of its characters.
    package static let paragraphKey = NSAttributedString.Key("AppleJournalMCP.paragraph")
    /// The placeholder id of an inline attachment, on its U+FFFC.
    package static let attachmentKey = NSAttributedString.Key("AppleJournalMCP.attachment")

    package static let shown: Marks = [.bold, .italic, .strike, .underline]

    /// A paragraph as Markdown shows it.
    package struct ParagraphKind: Equatable {
        package enum List: String { case bullet, dash, numbered }
        package var list: List?
        package var level = 0
        package var quote = false

        package var key: String { (list.map { "\($0.rawValue)\(level)" } ?? "") + (quote ? "q" : "") }

        package init(list: List? = nil, level: Int = 0, quote: Bool = false) {
            self.list = list
            self.level = list == nil ? 0 : level
            self.quote = quote
        }

        /// From the marker formats of a paragraph's lists, outermost first ("{disc}", "{decimal}").
        package init(markers: [String], quote: Bool) {
            guard let last = markers.last else {
                self.init(quote: quote)
                return
            }
            let list: List
            switch last {
            case "{hyphen}": list = .dash
            case let marker where ["decimal", "alpha", "roman", "octal", "hexadecimal"].contains(where: marker.contains): list = .numbered
            default: list = .bullet
            }
            self.init(list: list, level: markers.count - 1, quote: quote)
        }

        /// The marker formats Journal's own editor uses for a new list item at this level.
        package var markers: [String] {
            guard let list else { return [] }
            return (0...level).map { depth in
                switch list {
                case .dash: "{hyphen}"
                case .numbered: "{decimal}"
                case .bullet: ["{disc}", "{circle}", "{square}"][min(depth, 2)]
                }
            }
        }

        package var style: Style {
            switch list {
            case .bullet: .bullet
            case .dash: .dash
            case .numbered: .numbered
            case nil: .body
            }
        }
    }

    // MARK: Reading

    /// The canonical form of an entry kept as RTF (written before Journal 3.0).
    package static func canonical(legacy: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var count = 0
        legacy.enumerateAttributes(in: NSRange(location: 0, length: legacy.length)) { attrs, range, _ in
            var marks: Marks = []
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { marks.insert(.bold) }
                if traits.contains(.italic) { marks.insert(.italic) }
            }
            if let style = attrs[.underlineStyle] as? Int, style != 0 { marks.insert(.underline) }
            if let style = attrs[.strikethroughStyle] as? Int, style != 0 { marks.insert(.strike) }
            let markers = (attrs[.paragraphStyle] as? NSParagraphStyle)?.textLists.map(\.markerFormat.rawValue) ?? []
            let base: [NSAttributedString.Key: Any] = [marksKey: marks.rawValue, paragraphKey: ParagraphKind(markers: markers, quote: false).key]
            let text = (legacy.string as NSString).substring(with: range)
            for character in text.map(String.init) {
                var own = base
                if character == "\u{FFFC}" {
                    count += 1
                    own[attachmentKey] = "inline-\(count)"
                }
                out.append(NSAttributedString(string: character, attributes: own))
            }
        }
        return normalized(out)
    }

    /// Every character of a paragraph carries the paragraph's kind, as its first character has it
    /// (or its line end, for an empty paragraph): the formats keep paragraph formatting on all of a
    /// paragraph, or on part of it.
    package static func normalized(_ text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        let string = text.string as NSString
        var start = 0
        while start < string.length {
            let line = string.lineRange(for: NSRange(location: start, length: 0))
            let key = out.attribute(paragraphKey, at: line.location, effectiveRange: nil) ?? ""
            out.addAttribute(paragraphKey, value: key, range: line)
            start = line.location + line.length
        }
        return out
    }

    /// Markdown's model of the text: one paragraph per line.
    package static func blocks(_ canonical: NSAttributedString, attachments: [String: Attachment]) -> [Block] {
        let string = canonical.string as NSString
        var blocks: [Block] = []
        var start = 0
        repeat {
            let line = string.lineRange(for: NSRange(location: start, length: 0))
            var content = line
            if content.length > 0, string.character(at: content.location + content.length - 1) == 10 { content.length -= 1 }
            let key = line.length > 0 ? canonical.attribute(paragraphKey, at: line.location, effectiveRange: nil) as? String ?? "" : ""
            let kind = kind(key)
            var pieces: [Piece] = []
            if content.length > 0 {
                canonical.enumerateAttributes(in: content) { attrs, range, _ in
                    if let id = attrs[attachmentKey] as? String {
                        for _ in 0..<range.length { pieces.append(.attachment(attachments[id] ?? Attachment(id: id, kind: "attachment"))) }
                        return
                    }
                    let marks = Marks(rawValue: attrs[marksKey] as? Int ?? 0)
                    let text = string.substring(with: range)
                    if case .text(var last)? = pieces.last, last.marks == marks {
                        last.text += text
                        pieces[pieces.count - 1] = .text(last)
                    } else {
                        pieces.append(.text(Run(text, marks: marks)))
                    }
                }
            }
            blocks.append(.paragraph(Paragraph(kind.style, indent: kind.level, quote: kind.quote ? 1 : 0, pieces)))
            start = line.location + line.length
        } while start < string.length
        // The empty line after a final line end is not a paragraph of its own.
        if string.length > 0, string.hasSuffix("\n"), case .paragraph(let p)? = blocks.last, p.isBlank { blocks.removeLast() }
        return blocks
    }

    package static func kind(_ key: String) -> ParagraphKind {
        var rest = Substring(key)
        let quote = rest.hasSuffix("q")
        if quote { rest = rest.dropLast() }
        for list in [ParagraphKind.List.bullet, .dash, .numbered] where rest.hasPrefix(list.rawValue) {
            return ParagraphKind(list: list, level: Int(rest.dropFirst(list.rawValue.count)) ?? 0, quote: quote)
        }
        return ParagraphKind(quote: quote)
    }

    package static func markdown(_ canonical: NSAttributedString, attachments: [String: Attachment]) -> String {
        Markdown.render(blocks(canonical, attachments: attachments)) { attachment in
            switch attachment.kind {
            case "asset": "![asset](attachment:\(attachment.id))"
            case "prompt": "![prompt: \(Markdown.escape(attachment.label))](attachment:\(attachment.id))"
            default: nil
            }
        }
    }

    // MARK: Writing

    /// The canonical form of Markdown's model, for writing. What Journal cannot show is said so:
    /// tables are refused; headings become bold text and checklist items bullets.
    package static func canonical(_ blocks: [Block]) throws(JournalError) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            guard case .paragraph(let p) = block else {
                throw .refused("Journal has no tables; write the rows as lines or a list")
            }
            var kind = ParagraphKind(quote: p.quote > 0)
            var extra: Marks = []
            switch p.style {
            case .bullet, .checkbox: kind = ParagraphKind(list: .bullet, level: p.indent, quote: p.quote > 0)
            case .dash: kind = ParagraphKind(list: .dash, level: p.indent, quote: p.quote > 0)
            case .numbered: kind = ParagraphKind(list: .numbered, level: p.indent, quote: p.quote > 0)
            case .title, .heading, .subheading: extra = .bold
            case .body, .monospaced: break
            }
            let paragraph: [NSAttributedString.Key: Any] = [paragraphKey: kind.key]
            func append(_ text: String, _ marks: Marks) {
                var attributes = paragraph
                attributes[marksKey] = marks.union(extra).intersection(shown).rawValue
                out.append(NSAttributedString(string: text, attributes: attributes))
            }
            for piece in p.pieces {
                switch piece {
                case .text(let run):
                    append(run.text, run.marks)
                    if let link = run.link, link != run.text, !link.isEmpty { append(" (\(link))", run.marks) }
                case .attachment(let attachment):
                    switch attachment.kind {
                    case "tag": append(attachment.label, [])
                    case "note link": append(attachment.linkParts?.text ?? attachment.label, [])
                    case "divider": append("---", [])
                    case Attachment.newFile, Attachment.newLinkCard:
                        throw .refused("Markdown cannot add attachments to a Journal entry: \(Markdown.placeholder(attachment)). Use the attach field (files) instead")
                    default:
                        var attributes = paragraph
                        attributes[marksKey] = 0
                        attributes[attachmentKey] = attachment.id
                        out.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
                    }
                }
            }
            if index < blocks.count - 1 {
                var attributes = paragraph
                attributes[marksKey] = 0
                out.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        return out
    }

    /// Markdown has no empty line at the end of a text; an old text's line ends there are kept.
    package static func keepingLineEnds(of old: NSAttributedString, in new: NSAttributedString) -> NSAttributedString {
        let oldEnds = old.string.reversed().prefix { $0 == "\n" }.count
        guard oldEnds > 0, !new.string.hasSuffix("\n") else { return new }
        let out = NSMutableAttributedString(attributedString: new)
        let attributes = new.length > 0 ? new.attributes(at: new.length - 1, effectiveRange: nil) : [paragraphKey: "", marksKey: 0]
        out.append(NSAttributedString(string: String(repeating: "\n", count: oldEnds), attributes: attributes.filter { $0.key != attachmentKey }))
        return out
    }

    package static func containsAttachment(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(attachmentKey, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// The one span where two texts differ: what lies between their common start and end, the
    /// characters and the formatting Markdown shows both counting (UTF-16, as Coherence counts).
    package struct Edit {
        package let oldRange: NSRange
        package let newRange: NSRange

        package init?(old: NSAttributedString, new: NSAttributedString) {
            let a = old.string as NSString, b = new.string as NSString
            func same(_ i: Int, _ j: Int) -> Bool {
                a.character(at: i) == b.character(at: j)
                    && (old.attributes(at: i, effectiveRange: nil) as NSDictionary).isEqual(to: new.attributes(at: j, effectiveRange: nil))
            }
            var prefix = 0
            while prefix < a.length, prefix < b.length, same(prefix, prefix) { prefix += 1 }
            if prefix == a.length, prefix == b.length { return nil }
            // Never split a surrogate pair.
            if prefix > 0, prefix < a.length, UTF16.isTrailSurrogate(a.character(at: prefix)) { prefix -= 1 }
            var suffix = 0
            while suffix < a.length - prefix, suffix < b.length - prefix, same(a.length - 1 - suffix, b.length - 1 - suffix) { suffix += 1 }
            if suffix > 0, a.length - suffix > prefix, UTF16.isTrailSurrogate(a.character(at: a.length - suffix)) { suffix -= 1 }
            oldRange = NSRange(location: prefix, length: a.length - suffix - prefix)
            newRange = NSRange(location: prefix, length: b.length - suffix - prefix)
        }
    }

    // MARK: Titles and RTF

    /// An entry written before Journal 3.0 keeps RTF: the text in the formatting RTF has for it.
    /// Block quotes have none there and are written as plain paragraphs.
    package static func legacy(_ canonical: NSAttributedString) throws(JournalError) -> NSAttributedString {
        if containsAttachment(canonical) { throw .refused("This entry predates Journal 3.0 and holds no inline attachments") }
        let out = NSMutableAttributedString()
        let base = NSFont.systemFont(ofSize: 17)
        canonical.enumerateAttributes(in: NSRange(location: 0, length: canonical.length)) { attrs, range, _ in
            let marks = Marks(rawValue: attrs[marksKey] as? Int ?? 0)
            var font = base
            if marks.contains(.bold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if marks.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if marks.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if marks.contains(.strike) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let kind = kind(attrs[paragraphKey] as? String ?? "")
            if !kind.markers.isEmpty {
                let style = NSMutableParagraphStyle()
                style.textLists = kind.markers.map { NSTextList(markerFormat: NSTextList.MarkerFormat(rawValue: $0), options: 0) }
                attributes[.paragraphStyle] = style
            }
            out.append(NSAttributedString(string: (canonical.string as NSString).substring(with: range), attributes: attributes))
        }
        return out
    }

    package static func rtf(_ text: NSAttributedString) throws(JournalError) -> Data {
        do {
            return try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        } catch {
            throw .failed("Could not write the entry as RTF: \(error.localizedDescription)")
        }
    }

    package static func fromRTF(_ data: Data?) -> NSAttributedString? {
        guard let data, !data.isEmpty else { return nil }
        return try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    }
}
