import CoreData
import Foundation
import NoteModel
import NotesShim

/// Runs a call into NotesShim, turning its NSError into a NotesError.
@MainActor
func shim<T>(_ body: () throws -> T) throws(NotesError) -> T {
    do {
        return try body()
    } catch let error as NotesError {
        throw error
    } catch {
        throw .failed(error.localizedDescription)
    }
}

/// Brings a note body to target blocks in place, changing only what differs.
///
/// Unchanged lines are not touched. A changed line is edited character by character, then given
/// its paragraph style and the marks Markdown shows; every other attribute (color, font,
/// alignment) stays, on unchanged text and next to new text. New lines get a fresh style, like
/// text typed into Notes.
///
/// The edit runs twice. First on a mirror of the body only, whose result must read exactly as the
/// target; only then on the note. The mirror is also how the note is read during the edit: the
/// mergeable string's own attributed string is a snapshot until the session ends.
@MainActor
final class BodyWriter {
    let note: NSManagedObject
    let context: NSManagedObjectContext
    let edit: ANBodyEdit
    let original: NSAttributedString
    private var mirror: NSMutableAttributedString
    private var rehearsing = false
    /// Tables of the rehearsal, by placeholder id (new) or attachment id (changed).
    private var rehearsalTables: [String: [[String]]] = [:]
    /// Tables made for the real run, in the order the run places them.
    private var newTables: [String] = []
    private var removedTables: [String] = []
    /// Table attachments this write changed in place.
    private(set) var tablesEdited: [NSManagedObject] = []
    /// Attachments that are part of the text (tags) the rehearsal added, in order, and the ones
    /// made for the real run, which adds them in the same order.
    private var rehearsalInline: [String: Attachment] = [:]
    private var inlineWanted: [Attachment] = []
    private var newInline: [(id: String, type: String)] = []
    /// The tag attachments this write made, and everything it added.
    private(set) var tagsMade: [String] = []
    private(set) var added: [String] = []
    /// The rehearsal's stand-in ids, in the order the real ones are made.
    private var rehearsalIDs: [String] = []
    /// What the note reads as once written, with the ids of what this write added; nil until written.
    private(set) var expected: [Block]?
    /// Each attachment's attributes in the body, so one moved within its line keeps them.
    private let attachmentAttributes: [String: [NSAttributedString.Key: Any]]

    init(note: NSManagedObject, context: NSManagedObjectContext) throws(NotesError) {
        self.note = note
        self.context = context
        let edit = try shim { try ANBodyEdit(note: note) }
        let body = edit.original
        self.edit = edit
        original = body
        mirror = NSMutableAttributedString(attributedString: body)
        var kept: [String: [NSAttributedString.Key: Any]] = [:]
        body.enumerateAttribute(NoteKey.attachment, in: NSRange(location: 0, length: body.length)) { value, range, _ in
            guard let marker = value as? NSObject, let id = ANNotes.markerID(marker) else { return }
            var attributes = body.attributes(at: range.location, effectiveRange: nil)
            attributes[NoteKey.timestamp] = nil
            kept[id] = attributes
        }
        attachmentAttributes = kept
    }

    func currentBlocks() throws(NotesError) -> [Block] {
        try BodyReader(context: context).blocks(original)
    }

    func write(_ target: [Block]) throws(NotesError) {
        let old = try currentBlocks()
        try Self.checkAttachments(old, target)
        try perform(EditScript.steps(from: old, to: target), expecting: target)
    }

    /// Replaces these tables with new tables of the same content (see NotesStore.rebuildTables).
    func rebuild(tables ids: Set<String>) throws(NotesError) {
        let blocks = try currentBlocks()
        var steps: [EditStep] = []
        for (line, block) in blocks.enumerated().reversed() {
            guard case .table(let table) = block, ids.contains(table.id) else { continue }
            steps += [.insert(line: line + 1, [.table(Table(rows: table.rows))]), .delete(line: line, block)]
        }
        try perform(steps, expecting: blocks)
    }

    private func perform(_ steps: [EditStep], expecting target: [Block]) throws(NotesError) {
        guard !steps.isEmpty else { return }

        rehearsing = true
        try run(steps)
        let rehearsed = try BodyReader(context: context, tables: rehearsalTables, inline: rehearsalInline).blocks(mirror)
        guard rehearsed == target else {
            let line = zip(rehearsed, target).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(rehearsed.count, target.count)
            throw .failed("internal check failed before writing (line \(line + 1) would not come out as asked); the note was not changed")
        }
        rehearsing = false
        mirror = NSMutableAttributedString(attributedString: original)

        // Tables are documents of their own, changed outside the body's editing session.
        for case .changeTable(_, let from, let to) in steps {
            guard let attachment = try fetchAttachment(from.id) else { throw .notFound("table \(ShortID.of(from.id))") }
            tablesEdited.append(attachment)
            try TableWriter.write(to.rows, into: attachment)
        }
        // New tables must exist before the session opens: one made inside it cuts the saved body short.
        for case .insert(_, let blocks) in steps {
            for case .table(let table) in blocks { newTables.append(try makeTable(table)) }
        }
        for wanted in inlineWanted { newInline.append(try makeInline(wanted)) }
        tagsMade = newInline.filter { $0.type == Self.textTypes["tag"] }.map(\.id)
        added = newInline.map(\.id)
        // Files and link cards read back as what they became, by their new ids.
        let made = Dictionary(uniqueKeysWithValues: zip(rehearsalIDs, newInline))
        expected = rehearsed.mappingAttachments { a in
            guard let real = made[a.id], a.kind == Attachment.newFile || a.kind == Attachment.newLinkCard else { return a }
            return Attachment(id: real.id, kind: AttachmentKind.of(type: real.type))
        }

        try shim { try edit.begin() }
        try run(steps)
        try shim { try edit.end() }
        for id in removedTables {
            if let attachment = try fetchAttachment(id) { try shim { try ANNotes.mark(forDeletion: attachment) } }
        }
        // Tags taken out of the text go, as when they are deleted in Notes.
        let kept = Set(Self.markers(in: mirror).map(\.id))
        for (id, type) in Self.markers(in: original) where !kept.contains(id) && Self.isTextType(type) {
            if let attachment = try fetchObject("ICInlineAttachment", id) { try shim { try ANNotes.mark(forDeletion: attachment) } }
        }
    }

    /// The attachment markers in a body, in order.
    static func markers(in body: NSAttributedString) -> [(id: String, type: String)] {
        var found: [(String, String)] = []
        body.enumerateAttribute(NoteKey.attachment, in: NSRange(location: 0, length: body.length)) { value, _, _ in
            guard let marker = value as? NSObject, let id = ANNotes.markerID(marker) else { return }
            found.append((id, ANNotes.markerType(marker) ?? ""))
        }
        return found
    }

    /// Types of the attachments that are part of the text, which a write may add and remove.
    static let textTypes = [
        "tag": "com.apple.notes.inlinetextattachment.hashtag", "note link": "com.apple.notes.inlinetextattachment.link",
        "divider": "com.apple.notes.inlinetextattachment.dividerline",
    ]
    static func isTextType(_ type: String) -> Bool { textTypes.values.contains(type) }

    /// The marker for an attachment that is part of the text and new in this write: a stand-in in
    /// the rehearsal, which notes what the real run needs; the one made for it in the real run.
    private func newInlineMarker(_ a: Attachment) throws(NotesError) -> NSObject {
        let id: String, type: String
        if rehearsing {
            id = "rehearsal-" + UUID().uuidString
            type = Self.textTypes[a.kind] ?? "public.data"
            var standIn = a
            standIn.id = id
            rehearsalInline[id] = standIn
            rehearsalIDs.append(id)
            inlineWanted.append(a)
        } else {
            guard !newInline.isEmpty else { throw .failed("internal error: a new \(a.kind) was not made") }
            (id, type) = newInline.removeFirst()
        }
        guard let marker = ANNotes.attachmentMarker(withID: id, type: type) as? NSObject else {
            throw .failed("NotesShared cannot make an attachment marker in this version of macOS")
        }
        return marker
    }

    private func makeInline(_ a: Attachment) throws(NotesError) -> (id: String, type: String) {
        switch a.kind {
        case "tag":
            let name = String(a.label.dropFirst())
            return (try shim { try ANNotes.newTag(named: name, in: note) }, Self.textTypes["tag"]!)
        case "note link":
            guard let (text, reference) = a.linkParts else { throw .refused("a note link needs the note's id: [text](note:ID)") }
            let target = try linkTarget(reference)
            return (try shim { try ANNotes.newLink(to: target, text: text, in: note) }, Self.textTypes["note link"]!)
        case "divider":
            return (try shim { try ANNotes.newDivider(in: note) }, Self.textTypes["divider"]!)
        case Attachment.newFile:
            let (path, title) = Self.split(a.label)
            let file = try Self.attachable(path)
            var type: NSString?
            let id = try shim { try ANNotes.addFile(file, title: title, to: note, type: &type) }
            return (id, (type as String?) ?? "public.data")
        case Attachment.newLinkCard:
            let (address, _) = Self.split(a.label)
            guard let url = URL(string: address), url.host != nil else { throw .refused("\(address) is not a web address") }
            var type: NSString?
            let id = try shim { try ANNotes.addLinkCard(url, to: note, type: &type) }
            return (id, (type as String?) ?? "public.url")
        default:
            throw .failed("internal error: \(a.kind) cannot be added")
        }
    }

    /// Attachments are placeholders: an edit may move one within its line but not drop it, and
    /// Markdown cannot add one. Tables and what is part of the text (tags) are the exception; they
    /// can be added and removed.
    static func checkAttachments(_ old: [Block], _ new: [Block]) throws(NotesError) {
        let oldOnes = old.attachments.filter { !$0.isText }, newOnes = new.attachments.filter { !$0.isText }
        let before = Dictionary(oldOnes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let after = Set(newOnes.map(\.id))
        if let lost = oldOnes.first(where: { !after.contains($0.id) }) {
            throw .refused("the change would remove an attachment (\(lost.caption), id \(ShortID.of(lost.id))). Keep its \(Markdown.placeholder(lost)) placeholder; attachments cannot be removed here")
        }
        if let unknown = newOnes.first(where: { before[$0.id] == nil }) {
            throw .refused("attachment:\(unknown.id) is not in this note; attachments cannot be added from Markdown")
        }
    }

    // MARK: Steps

    private func run(_ steps: [EditStep]) throws(NotesError) {
        for step in steps {
            switch step {
            case .delete(let line, let block):
                try deleteLine(line)
                if !rehearsing, case .table(let table) = block, !table.id.isEmpty { removedTables.append(table.id) }
            case .insert(let line, let blocks):
                try insertLines(blocks, at: line)
            case .change(let line, let from, let to):
                try changeParagraph(line, from: from, to: to)
            case .changeTable(_, let from, let to):
                // Same attachment in the body; the rehearsal reads the new rows for it.
                if rehearsing { rehearsalTables[from.id] = to.rows }
            }
        }
    }

    /// The range of each line, without its newline.
    private func lines() -> [NSRange] {
        let text = mirror.string as NSString
        var ranges: [NSRange] = []
        var start = 0
        while true {
            let newline = text.range(of: "\n", range: NSRange(location: start, length: text.length - start))
            guard newline.location != NSNotFound else {
                ranges.append(NSRange(location: start, length: text.length - start))
                return ranges
            }
            ranges.append(NSRange(location: start, length: newline.location - start))
            start = newline.location + 1
        }
    }

    /// The style a line has: on its text, or on its newline when it is empty.
    private func style(of line: NSRange) -> NSObject? {
        if line.length > 0 { return mirror.attribute(NoteKey.style, at: line.location, effectiveRange: nil) as? NSObject }
        if NSMaxRange(line) < mirror.length { return mirror.attribute(NoteKey.style, at: NSMaxRange(line), effectiveRange: nil) as? NSObject }
        return nil
    }

    private func deleteLine(_ index: Int) throws(NotesError) {
        let all = lines()
        if all.count == 1 {
            try remove(all[0])
        } else if index < all.count - 1 {
            try remove(NSRange(location: all[index].location, length: all[index + 1].location - all[index].location))
        } else {
            // The last line goes with the newline before it.
            let start = NSMaxRange(all[index - 1])
            try remove(NSRange(location: start, length: NSMaxRange(all[index]) - start))
        }
    }

    private func insertLines(_ blocks: [Block], at index: Int) throws(NotesError) {
        let all = lines()
        let text = NSMutableAttributedString()
        if index < all.count {
            // "a\nb\n" before the line; each newline carries its own line's style.
            for block in blocks {
                let (line, style) = try newLine(block)
                text.append(line)
                text.append(NSAttributedString(string: "\n", attributes: [NoteKey.style: style]))
            }
            try put(text, at: all[index].location)
        } else {
            // After the last line, whose newline this adds and so has its style.
            let last = all[all.count - 1]
            var joining: NSObject
            if let existing = style(of: last) { joining = existing } else { joining = try paragraphStyle(Paragraph(), basedOn: nil) }
            for block in blocks {
                text.append(NSAttributedString(string: "\n", attributes: [NoteKey.style: joining]))
                let (line, style) = try newLine(block)
                text.append(line)
                joining = style
            }
            try put(text, at: NSMaxRange(last))
        }
    }

    /// A new line, formatted like text typed into Notes: a fresh style and the marks Markdown
    /// shows, nothing hidden. Returns the style too, for the newline that ends it.
    private func newLine(_ block: Block) throws(NotesError) -> (NSAttributedString, NSObject) {
        switch block {
        case .table(let table):
            let id: String
            if rehearsing {
                id = "rehearsal-" + UUID().uuidString
                rehearsalTables[id] = table.rows
            } else {
                guard !newTables.isEmpty else { throw .failed("internal error: a new table was not made") }
                id = newTables.removeFirst()
            }
            guard let marker = ANNotes.attachmentMarker(withID: id, type: "com.apple.notes.table") else {
                throw .failed("NotesShared cannot make a table marker in this version of macOS")
            }
            let style = try paragraphStyle(Paragraph(), basedOn: nil)
            return (NSAttributedString(string: "\u{FFFC}", attributes: [NoteKey.style: style, NoteKey.attachment: marker]), style)
        case .paragraph(let p):
            let style = try paragraphStyle(p, basedOn: nil)
            let line = NSMutableAttributedString()
            for piece in p.pieces {
                switch piece {
                case .text(let run):
                    var attributes: [NSAttributedString.Key: Any] = [NoteKey.style: style]
                    if p.style != .monospaced { Self.setMarks(run, on: &attributes) }
                    line.append(NSAttributedString(string: run.text, attributes: attributes))
                case .attachment(let a) where a.isText:
                    var attributes: [NSAttributedString.Key: Any] = [NoteKey.style: style]
                    attributes[NoteKey.attachment] = try newInlineMarker(a)
                    line.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
                case .attachment(let a):
                    throw .refused("attachment:\(ShortID.of(a.id)) cannot move to a new line; keep it in the line it is in")
                }
            }
            return (line, style)
        }
    }

    private func changeParagraph(_ index: Int, from: Paragraph, to: Paragraph) throws(NotesError) {
        let before = lines()[index]
        let existing = style(of: before)
        let old = Self.tokens(from), new = Self.tokens(to)
        let textChanged = old != new
        if textChanged { try editText(start: before.location, old, new) }
        let line = lines()[index]
        let styleRange = NSRange(location: line.location, length: line.length + (NSMaxRange(line) < mirror.length ? 1 : 0))
        let styleChanged = from.style != to.style || from.indent != to.indent || from.quote != to.quote
        if styleRange.length > 0, styleChanged || textChanged || existing == nil {
            let style = !styleChanged && existing != nil ? existing! : try paragraphStyle(to, basedOn: existing)
            try update(styleRange) { $0[NoteKey.style] = style }
        }
        if to.style != .monospaced, line.length > 0 {
            var offset = line.location
            for piece in to.pieces {
                switch piece {
                case .attachment:
                    offset += 1
                case .text(let run):
                    let length = (run.text as NSString).length
                    try update(NSRange(location: offset, length: length)) { Self.setMarks(run, on: &$0) }
                    offset += length
                }
            }
        }
    }

    // MARK: Text

    /// One Unicode scalar, or an attachment (one U+FFFC in the note): by its id, or for one that
    /// is part of the text, by what it shows.
    enum Token: Equatable {
        case scalar(UInt32)
        case attachment(String)
        case text(Attachment)

        var length: Int {
            switch self {
            case .scalar(let value): value > 0xFFFF ? 2 : 1
            case .attachment, .text: 1
            }
        }
    }

    static func tokens(_ paragraph: Paragraph) -> [Token] {
        paragraph.pieces.flatMap { piece -> [Token] in
            switch piece {
            case .text(let run): run.text.unicodeScalars.map { .scalar($0.value) }
            case .attachment(let a): [a.isText ? .text(a) : .attachment(a.id)]
            }
        }
    }

    /// Replaces only what changed in a line's text: the common start and end stay, and in the
    /// middle, characters kept by a longest common subsequence stay too.
    private func editText(start: Int, _ old: [Token], _ new: [Token]) throws(NotesError) {
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head, old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        let a = Array(old[head..<(old.count - tail)]), b = Array(new[head..<(new.count - tail)])
        let kept = a.count * b.count <= 4_000_000 ? Alignment.common(a, b) : []
        var gaps: [(old: Range<Int>, new: Range<Int>)] = []
        var i = 0, j = 0
        for (x, y) in kept + [(a.count, b.count)] {
            if x > i || y > j { gaps.append((i..<x, j..<y)) }
            i = x + 1
            j = y + 1
        }
        // UTF-16 offset of each old token.
        var offsets = [0]
        for token in old { offsets.append(offsets.last! + token.length) }
        for gap in gaps.reversed() {
            let from = offsets[head + gap.old.lowerBound], to = offsets[head + gap.old.upperBound]
            let location = start + from
            let base = neighbourAttributes(at: location, lineStart: start, removing: to - from)
            try remove(NSRange(location: location, length: to - from))
            let inserted = NSMutableAttributedString()
            var scalars = String.UnicodeScalarView()
            func flush() {
                if !scalars.isEmpty { inserted.append(NSAttributedString(string: String(scalars), attributes: base)) }
                scalars = String.UnicodeScalarView()
            }
            for token in b[gap.new] {
                switch token {
                case .scalar(let value):
                    if let scalar = Unicode.Scalar(value) { scalars.append(scalar) }
                case .attachment(let id):
                    flush()
                    inserted.append(NSAttributedString(string: "\u{FFFC}", attributes: attachmentAttributes[id] ?? base))
                case .text(let a):
                    flush()
                    var attributes = base
                    attributes[NoteKey.attachment] = try newInlineMarker(a)
                    inserted.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
                }
            }
            flush()
            try put(inserted, at: location)
        }
    }

    /// What new text in a line starts with: the attributes of the character before it in the
    /// line (else after it), without the marks Markdown sets, so it matches its neighbour's font.
    private func neighbourAttributes(at location: Int, lineStart: Int, removing: Int) -> [NSAttributedString.Key: Any] {
        guard mirror.length > 0 else { return [:] }
        let index: Int
        if location > lineStart {
            index = location - 1
        } else if location + removing < mirror.length {
            index = location + removing
        } else {
            index = min(location, mirror.length - 1)
        }
        var attributes = mirror.attributes(at: index, effectiveRange: nil)
        for key in [NoteKey.attachment, NoteKey.timestamp, NoteKey.hints, NoteKey.strike, NoteKey.underline, NoteKey.highlight, NoteKey.link] {
            attributes[key] = nil
        }
        return attributes
    }

    // MARK: Attributes

    /// Sets bold, italic, strikethrough, underline, highlight and link; other attributes stay.
    static func setMarks(_ run: Run, on attributes: inout [NSAttributedString.Key: Any]) {
        let hints = ((attributes[NoteKey.hints] as? Int) ?? 0) & ~3 | (run.marks.contains(.bold) ? 1 : 0) | (run.marks.contains(.italic) ? 2 : 0)
        attributes[NoteKey.hints] = hints == 0 ? nil : hints
        attributes[NoteKey.strike] = run.marks.contains(.strike) ? 1 : nil
        attributes[NoteKey.underline] = run.marks.contains(.underline) ? 1 : nil
        attributes[NoteKey.highlight] = run.marks.contains(.highlight) ? run.color : nil
        let link = (attributes[NoteKey.link] as? URL)?.absoluteString ?? attributes[NoteKey.link] as? String
        if link != run.link {
            attributes[NoteKey.link] = run.link.map { URL(string: $0) ?? $0 as Any }
        }
    }

    /// Changes attributes over `range` one attribute run at a time, so keys `change` leaves alone
    /// keep their values run by run. Runs that come out the same are not written.
    private func update(_ range: NSRange, _ change: (inout [NSAttributedString.Key: Any]) -> Void) throws(NotesError) {
        var writes: [(NSRange, [NSAttributedString.Key: Any])] = []
        mirror.enumerateAttributes(in: range) { attributes, run, _ in
            var updated = attributes
            change(&updated)
            if !NSDictionary(dictionary: updated).isEqual(to: attributes) { writes.append((run, updated)) }
        }
        for (run, attributes) in writes {
            if !rehearsing { try shim { try edit.setAttributes(attributes, range: run) } }
            mirror.setAttributes(attributes, range: run)
        }
    }

    func paragraphStyle(_ paragraph: Paragraph, basedOn existing: NSObject?) throws(NotesError) -> NSObject {
        let checked: Int
        if case .checkbox(let done) = paragraph.style { checked = done ? 1 : 0 } else { checked = -1 }
        let style = try shim {
            try ANNotes.paragraphStyle(paragraph.style.number, indent: paragraph.indent, quote: paragraph.quote, checked: checked, basedOn: existing)
        }
        guard let object = style as? NSObject else { throw .failed("NotesShared made no paragraph style") }
        return object
    }

    private func remove(_ range: NSRange) throws(NotesError) {
        guard range.length > 0 else { return }
        if !rehearsing { try shim { try edit.deleteRange(range) } }
        mirror.deleteCharacters(in: range)
    }

    private func put(_ text: NSAttributedString, at index: Int) throws(NotesError) {
        guard text.length > 0 else { return }
        if !rehearsing { try shim { try edit.insert(text, at: UInt(index)) } }
        mirror.insert(text, at: index)
    }

    // MARK: Tables

    private func fetchAttachment(_ id: String) throws(NotesError) -> NSManagedObject? {
        try fetchObject("ICAttachment", id)
    }

    /// A new attachment's path or address, and the name it is to show.
    static func split(_ label: String) -> (String, String) {
        let parts = label.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
    }

    /// Largest file a note takes from Markdown.
    static let maxFile = 200 * 1024 * 1024

    /// A file that may go into a note. This app can read any file (it has Full Disk Access), so
    /// a file is taken only from where a user keeps files: the home folder outside ~/Library and
    /// hidden folders, a temporary folder, or an external drive.
    static func attachable(_ path: String) throws(NotesError) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let temporary = [NSTemporaryDirectory(), "/tmp", "/private/tmp", "/private/var/folders"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let p = url.path
        func inside(_ root: String) -> Bool { p.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
        let underHome = inside(home) && !inside(home + "/Library")
            && !p.dropFirst(home.count + 1).split(separator: "/").contains { $0.hasPrefix(".") }
        guard underHome || temporary.contains(where: inside) || inside("/Volumes") else {
            throw .refused("\(path) is not in a place notes take files from: the home folder (not ~/Library or a hidden folder), a temporary folder, or an external drive")
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &directory) else { throw .notFound("the file \(path)") }
        guard !directory.boolValue else { throw .refused("\(path) is a folder; attach the files in it one by one, or zip it") }
        guard FileManager.default.isReadableFile(atPath: p) else { throw .refused("\(path) cannot be read") }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFile else { throw .refused("\(path) is larger than \(maxFile / 1024 / 1024) MB") }
        return url
    }

    /// The note a new link goes to, by its id or the start of it.
    private func linkTarget(_ reference: String) throws(NotesError) -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ICNote")
        request.predicate = NSPredicate(format: "identifier BEGINSWITH[c] %@ AND markedForDeletion == NO", reference)
        let found: [NSManagedObject]
        do {
            found = try context.fetch(request)
        } catch {
            throw .failed("finding the linked note failed: \(error.localizedDescription)")
        }
        guard reference.count >= 4, found.count == 1 else {
            throw found.isEmpty ? .notFound("the note \(reference) to link to") : .refused("\(reference) names several notes; give more of its id")
        }
        if found[0] == note { throw .refused("a note cannot link to itself") }
        return found[0]
    }

    /// After the save: Notes counts a tag's uses while saving and marks a tag it finds unused as
    /// deleted, which a new tag's first use is to it. Brings such tags back; true when it did.
    func reviveTags() throws(NotesError) -> Bool {
        var revived = false
        for id in tagsMade {
            guard let attachment = try fetchObject("ICInlineAttachment", id) else { continue }
            try shim { try ANNotes.reviveTag(of: attachment) }
            revived = true
        }
        return revived
    }

    private func fetchObject(_ entity: String, _ id: String) throws(NotesError) -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "identifier == %@", id)
        request.fetchLimit = 1
        do {
            return try context.fetch(request).first
        } catch {
            throw .failed("reading attachment \(id) failed: \(error.localizedDescription)")
        }
    }

    /// Makes a table attachment with the given rows and returns its id. Notes makes it from text
    /// with tabs between cells and newlines between rows, so cells holding either are set again
    /// afterwards through the table itself.
    private func makeTable(_ table: Table) throws(NotesError) -> String {
        let width = table.width
        guard width > 0, !table.rows.isEmpty else { throw .refused("a table needs at least one cell") }
        let rows = table.rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        let text = rows.map { row in
            row.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")
        }.joined(separator: "\n")
        let id = try shim { try edit.addTable(withText: text) }
        guard let attachment = try fetchAttachment(id) else { throw .failed("the new table cannot be found") }
        if ANNotes.rowsOfTableAttachment(attachment) != rows { try TableWriter.write(rows, into: attachment) }
        return id
    }
}

/// Brings a table to target rows in place. Columns are matched by their header when their number
/// changes, rows by content; only real insertions and removals add or drop rows and columns, and
/// only cells whose text differs are edited (inside the cell, so the rest keeps its formatting).
@MainActor
enum TableWriter {
    static func write(_ target: [[String]], into attachment: NSManagedObject) throws(NotesError) {
        let width = target.map(\.count).max() ?? 0
        guard !target.isEmpty, width > 0 else { throw .refused("a table needs at least one cell") }
        let target = target.map { $0 + Array(repeating: "", count: width - $0.count) }
        let table = try shim { try ANTableEdit(attachment: attachment) }
        func rows() -> [[String]] {
            (0..<table.rowCount).map { r in (0..<table.columnCount).map { c in table.text(atColumn: c, row: r) } }
        }
        if table.columnCount != width {
            let (removed, inserted) = Alignment.rows(rows().first ?? [], target[0])
            for column in removed.reversed() { try shim { try table.removeColumn(at: column) } }
            for column in inserted { try shim { try table.insertColumn(at: column) } }
        }
        let (removed, inserted) = Alignment.rows(rows(), target)
        for row in removed.reversed() { try shim { try table.removeRow(at: row) } }
        for row in inserted { try shim { try table.insertRow(at: row) } }
        let style = try shim { try ANNotes.paragraphStyle(3, indent: 0, quote: 0, checked: -1, basedOn: nil) }
        for row in 0..<target.count {
            for column in 0..<width {
                let old = table.text(atColumn: column, row: row)
                guard old != target[row][column] else { continue }
                let (prefix, removed, inserted) = Alignment.middle(old, target[row][column])
                try shim {
                    try table.replace(inColumn: column, row: row, range: NSRange(location: prefix, length: removed), withText: inserted, style: style)
                }
            }
        }
        guard rows() == target else { throw .failed("internal check failed while changing a table; nothing was saved") }
        try shim { try table.save() }
    }
}
