import AppKit
import Coherence
import Foundation
import JournalModel
import JournalShared
import NoteModel

typealias EntryCRText = CRAttributedString<MergeableTextAttributeScope>
typealias EntryCRTitle = CRAttributedString<MergeableTitleAttributeScope>

/// Journal 3.0's mergeable text to and from the canonical form (see JournalModel's EntryText).
extension EntryText {
    /// The canonical form of Journal 3.0's text, and its inline attachments by placeholder id.
    static func canonical(_ text: EntryCRText) -> (NSAttributedString, [String: Attachment]) {
        let plain = text.attributedString.string as NSString
        let out = NSMutableAttributedString()
        var attachments: [String: Attachment] = [:]
        var index = 0
        while index < plain.length {
            var range = NSRange()
            let a = text.attributes(at: index, effectiveRange: &range)
            if range.length <= 0 { range = NSRange(location: index, length: 1) }
            let end = min(range.location + range.length, plain.length)
            var marks: Marks = []
            if let traits = a.font?.traits.rawValue {
                if traits & MergeableFont.Traits.bold.rawValue != 0 { marks.insert(.bold) }
                if traits & MergeableFont.Traits.italic.rawValue != 0 { marks.insert(.italic) }
            }
            if (a.underline ?? 0) != 0 { marks.insert(.underline) }
            if (a.strikethrough ?? 0) != 0 { marks.insert(.strike) }
            let paragraph = ParagraphKind(markers: a.textLists?.textLists.map(\.markerFormatString) ?? [], quote: a.blockQuote ?? false)
            let start = out.length
            out.append(NSAttributedString(string: plain.substring(with: NSRange(location: index, length: end - index)),
                                          attributes: [marksKey: marks.rawValue, paragraphKey: paragraph.key]))
            for offset in index..<end where plain.character(at: offset) == 0xFFFC {
                let number = attachments.count + 1
                let attachment: Attachment
                if let asset = a.assetAttachment {
                    attachment = Attachment(id: asset.assetID.uuidString, kind: "asset")
                } else if let prompt = a.followUpPromptAttachment {
                    attachment = Attachment(id: "prompt-\(number)", kind: "prompt", label: prompt.prompt)
                } else if a.adaptiveImageGlyph != nil {
                    attachment = Attachment(id: "genmoji-\(number)", kind: "genmoji")
                } else {
                    attachment = Attachment(id: "inline-\(number)", kind: "attachment")
                }
                attachments[attachment.id] = attachment
                out.addAttributes([attachmentKey: attachment.id, marksKey: 0], range: NSRange(location: start + offset - index, length: 1))
            }
            index = end
        }
        return (normalized(out), attachments)
    }

    /// Changes Journal 3.0's text to `new`, only where it differs from it. Inline attachments
    /// (photos placed in the text, Genmoji, follow-up prompts) cannot be made from Markdown, so a
    /// change that would remove, move or add one is refused.
    static func apply(_ new: NSAttributedString, to text: inout EntryCRText) throws(JournalError) {
        let (old, _) = canonical(text)
        let target = keepingLineEnds(of: old, in: new)
        guard let edit = Edit(old: old, new: target) else { return }
        let oldMiddle = old.attributedSubstring(from: edit.oldRange), newMiddle = target.attributedSubstring(from: edit.newRange)
        if containsAttachment(oldMiddle) || containsAttachment(newMiddle) {
            throw .refused("""
                The change would remove, move or add an attachment placeholder ![…](attachment:…); keep each where \
                read_entry shows it, and change the text around it only
                """)
        }
        // Text inserted into a paragraph that goes on before or after it takes that paragraph's own
        // lists and quote (Journal's markers, which Markdown does not show).
        let newString = target.string as NSString, middle = newMiddle.string as NSString
        let startsInside = edit.newRange.location > 0 && newString.character(at: edit.newRange.location - 1) != 10
        let endsInside = edit.oldRange.location + edit.oldRange.length < old.length && !newMiddle.string.hasSuffix("\n")
        // A paragraph's own formatting is read at its first character.
        let oldString = old.string as NSString
        func paragraphStart(_ index: Int) -> Int { oldString.lineRange(for: NSRange(location: index, length: 0)).location }
        let end = edit.oldRange.location + edit.oldRange.length
        let before = startsInside ? text.attributes(at: paragraphStart(edit.oldRange.location - 1), effectiveRange: nil) : nil
        let after = endsInside
            ? text.attributes(at: paragraphStart(end) < edit.oldRange.location ? paragraphStart(end) : end, effectiveRange: nil) : nil
        if edit.oldRange.length > 0 { text.removeSubrange(edit.oldRange.location..<(edit.oldRange.location + edit.oldRange.length)) }
        guard newMiddle.length > 0 else { return }
        text.insert(contentsOf: NSAttributedString(string: newMiddle.string), at: edit.newRange.location)
        var lineStart = 0
        while lineStart < middle.length {
            let line = middle.lineRange(for: NSRange(location: lineStart, length: 0))
            let isFirst = lineStart == 0, isLast = line.location + line.length >= middle.length
            let inherited = isFirst && before != nil ? before : (isLast && after != nil ? after : nil)
            newMiddle.enumerateAttributes(in: line) { attrs, range, _ in
                let marks = Marks(rawValue: attrs[marksKey] as? Int ?? 0)
                let kind = kind(attrs[paragraphKey] as? String ?? "")
                var typed = EntryCRText.Attributes()
                var traits = 0
                if marks.contains(.bold) { traits |= MergeableFont.Traits.bold.rawValue }
                if marks.contains(.italic) { traits |= MergeableFont.Traits.italic.rawValue }
                if traits != 0 { typed.font = MergeableFont(traits: MergeableFont.Traits(rawValue: traits), unknownProperties: UnknownValueProperties()) }
                if marks.contains(.underline) { typed.underline = 1 }
                if marks.contains(.strike) { typed.strikethrough = 1 }
                if let inherited {
                    typed.textLists = inherited.textLists
                    typed.blockQuote = inherited.blockQuote
                } else {
                    if !kind.markers.isEmpty {
                        typed.textLists = MergeableTextLists(
                            textLists: kind.markers.map {
                                MergeableTextList(startingItemNumber: 1, markerFormatString: $0, listOptions: 0, unknownProperties: UnknownValueProperties())
                            },
                            unknownProperties: UnknownValueProperties())
                    }
                    if kind.quote { typed.blockQuote = true }
                }
                text.setAttributes(typed, range: NSRange(location: edit.newRange.location + range.location, length: range.length))
            }
            lineStart = line.location + line.length
        }
    }

    /// Changes a title in place, only where it differs.
    static func apply(title: String, to text: inout EntryCRTitle) {
        let old = NSAttributedString(string: text.attributedString.string)
        guard let edit = Edit(old: old, new: NSAttributedString(string: title)) else { return }
        if edit.oldRange.length > 0 { text.removeSubrange(edit.oldRange.location..<(edit.oldRange.location + edit.oldRange.length)) }
        if edit.newRange.length > 0 {
            text.insert(contentsOf: NSAttributedString(string: (title as NSString).substring(with: edit.newRange)), at: edit.newRange.location)
        }
    }

}
