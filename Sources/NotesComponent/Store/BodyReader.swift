import CoreData
import Foundation
import NoteModel
import NotesShim

/// The attribute keys Notes uses in a note body.
enum NoteKey {
    static let style = NSAttributedString.Key("TTStyle")
    static let hints = NSAttributedString.Key("TTHints")  // bit 1 bold, bit 2 italic
    static let strike = NSAttributedString.Key("TTStrikethrough")
    static let underline = NSAttributedString.Key("TTUnderline")
    static let highlight = NSAttributedString.Key("TTEmphasis")  // a highlight color number (Highlight)
    static let link = NSAttributedString.Key("NSLink")
    static let attachment = NSAttributedString.Key("NSAttachment")
    static let timestamp = NSAttributedString.Key("TTTimestamp")
}

/// Reads a note body (Notes' attributed string) as blocks: one per line. Only what Markdown can
/// show is read.
@MainActor
struct BodyReader {
    let context: NSManagedObjectContext
    /// Tables known by id without reading the note (a write's rehearsal has some).
    var tables: [String: [[String]]] = [:]
    /// Attachments that are part of the text, known by id without reading the note (a write's
    /// rehearsal makes stand-ins for the ones it adds).
    var inline: [String: Attachment] = [:]

    func blocks(_ body: NSAttributedString) throws(NotesError) -> [Block] {
        let text = body.string as NSString
        var blocks: [Block] = []
        var start = 0
        while true {
            let newline = text.range(of: "\n", range: NSRange(location: start, length: text.length - start))
            let end = newline.location == NSNotFound ? text.length : newline.location
            // A paragraph's style is on its characters and on its newline; an empty last line has
            // neither and reads as body.
            let styleAt = end > start ? start : (end < text.length ? end : nil)
            blocks.append(try block(body, NSRange(location: start, length: end - start), styleAt: styleAt))
            if newline.location == NSNotFound { return blocks }
            start = end + 1
        }
    }

    private func block(_ body: NSAttributedString, _ range: NSRange, styleAt: Int?) throws(NotesError) -> Block {
        var kind = Style.body
        var indent = 0, quote = 0
        if let at = styleAt, let style = body.attribute(NoteKey.style, at: at, effectiveRange: nil) as? NSObject {
            let todo = ANNotes.value(forKey: "todo", of: style) as? NSObject
            let checked = todo.flatMap { ANNotes.value(forKey: "done", of: $0) as? Bool } ?? false
            kind = Style(number: (ANNotes.value(forKey: "style", of: style) as? Int) ?? 3, checked: checked)
            indent = (ANNotes.value(forKey: "indent", of: style) as? Int) ?? 0
            quote = (ANNotes.value(forKey: "blockQuoteLevel", of: style) as? Int) ?? 0
        }

        // A line holding only a table is a table block.
        if range.length == 1, let marker = body.attribute(NoteKey.attachment, at: range.location, effectiveRange: nil) as? NSObject,
            ANNotes.markerType(marker) == "com.apple.notes.table", let id = ANNotes.markerID(marker),
            let rows = tables[id] ?? ANNotes.rowsOfTableMarker(marker, context: context)
        {
            return .table(Table(id: id, rows: rows))
        }

        var pieces: [Piece] = []
        var failure: NotesError?
        body.enumerateAttributes(in: range) { attributes, run, stop in
            if let marker = attributes[NoteKey.attachment] as? NSObject {
                do throws(NotesError) {
                    pieces.append(.attachment(try attachment(marker)))
                } catch {
                    failure = error
                    stop.pointee = true
                }
                return
            }
            let text = (body.string as NSString).substring(with: run)
            // Monospaced paragraphs show no inline formatting in Markdown.
            guard kind != .monospaced else {
                pieces.append(.text(Run(text)))
                return
            }
            var marks: Marks = []
            let hints = (attributes[NoteKey.hints] as? Int) ?? 0
            if hints & 1 != 0 { marks.insert(.bold) }
            if hints & 2 != 0 { marks.insert(.italic) }
            if ((attributes[NoteKey.strike] as? Int) ?? 0) != 0 { marks.insert(.strike) }
            if ((attributes[NoteKey.underline] as? Int) ?? 0) != 0 { marks.insert(.underline) }
            let color = (attributes[NoteKey.highlight] as? Int) ?? 0
            if color != 0 { marks.insert(.highlight) }
            let link = (attributes[NoteKey.link] as? URL)?.absoluteString ?? attributes[NoteKey.link] as? String
            pieces.append(.text(Run(text, marks: marks, link: link, color: color)))
        }
        if let failure { throw failure }
        return .paragraph(Paragraph(kind, indent: indent, quote: quote, pieces.normalized()))
    }

    private func attachment(_ marker: NSObject) throws(NotesError) -> Attachment {
        let id = ANNotes.markerID(marker) ?? ""
        let type = ANNotes.markerType(marker) ?? ""
        if let known = inline[id] { return known }
        if type.hasPrefix("com.apple.notes.inlinetextattachment") {
            let inline = try fetch("ICInlineAttachment", id: id)
            let text = ((inline.flatMap { ANNotes.value(forKey: "altText", of: $0) }) as? String ?? "").trimmingCharacters(in: .whitespaces)
            switch type {
            case "com.apple.notes.inlinetextattachment.hashtag":
                return Attachment(id: id, kind: "tag", label: text)
            case "com.apple.notes.inlinetextattachment.mention":
                return Attachment(id: id, kind: "mention", label: text)
            case "com.apple.notes.inlinetextattachment.dividerline":
                return Attachment(id: id, kind: "divider")
            case "com.apple.notes.inlinetextattachment.calculateresult", "com.apple.notes.inlinetextattachment.calculategraphexpression":
                return Attachment(id: id, kind: "calculation", label: text)
            case "com.apple.notes.inlinetextattachment.link":
                // The target, "applenotes:note/<id>?…", so the model can open it with read_note.
                let token = (inline.flatMap { ANNotes.value(forKey: "tokenContentIdentifier", of: $0) }) as? String ?? ""
                var label = text
                if let path = token.split(separator: "?").first, path.hasPrefix("applenotes:note/") {
                    label += " → " + ShortID.of(path.dropFirst("applenotes:note/".count).uppercased())
                }
                return Attachment(id: id, kind: "note link", label: label)
            default:
                return Attachment(id: id, kind: "inline", label: text)
            }
        }
        let object = try fetch("ICAttachment", id: id)
        let kind = AttachmentKind.of(type: type.isEmpty ? (object.flatMap { ANNotes.value(forKey: "typeUTI", of: $0) } as? String ?? "") : type)
        func string(_ key: String) -> String {
            ((object.flatMap { ANNotes.value(forKey: key, of: $0) }) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch kind {
        case "link": return Attachment(id: id, kind: kind, label: string("urlString"))
        case "image", "scan", "drawing", "table": return Attachment(id: id, kind: kind)
        default:
            let title = string("title")
            return Attachment(id: id, kind: kind, label: title.isEmpty ? string("userTitle") : title)
        }
    }

    private func fetch(_ entity: String, id: String) throws(NotesError) -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "identifier == %@", id)
        request.fetchLimit = 1
        do {
            return try context.fetch(request).first
        } catch {
            throw .failed("reading \(entity) \(id) failed: \(error.localizedDescription)")
        }
    }
}

/// Plain names for attachment types.
enum AttachmentKind {
    static func of(type: String) -> String {
        switch type {
        case "com.apple.notes.table": return "table"
        case "public.url": return "link"
        case "com.apple.notes.gallery": return "scan"
        case "com.adobe.pdf", "com.apple.paper.doc.pdf": return "PDF"
        case "com.apple.drawing", "com.apple.drawing.2", "com.apple.paper": return "drawing"
        default:
            if ["public.png", "public.jpeg", "public.heic", "public.heif", "public.tiff", "com.compuserve.gif", "public.image",
                "org.webmproject.webp", "public.webp"].contains(type) { return "image" }
            if type.contains("audio") || type == "com.apple.m4a-audio" { return "audio" }
            if type.contains("movie") || type.contains("video") || type == "public.mpeg-4" { return "video" }
            return "file"
        }
    }

    /// "3 images, 1 table", in a fixed order.
    static func summary(_ counts: [String: Int]) -> String {
        ["image", "scan", "drawing", "table", "PDF", "audio", "video", "link", "file"].compactMap { kind in
            guard let n = counts[kind], n > 0 else { return nil }
            if n == 1 { return "1 \(kind)" }
            return "\(n) \(kind == "PDF" ? "PDFs" : kind + "s")"
        }.joined(separator: ", ")
    }
}
