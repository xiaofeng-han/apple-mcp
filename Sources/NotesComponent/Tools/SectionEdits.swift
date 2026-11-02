import NoteModel

/// edit_note's replace_section and replace_before: changes made by whole paragraphs around a
/// heading, which is found as read_note's section finds it (Sections.find: its text, ignoring case
/// and leading #, and only one heading may read so). The heading stays, and so do the blank
/// paragraphs before the next heading, which are the gap the note leaves there. The title is not
/// a heading here: replacing it, or what is under it, is a rewrite.
enum SectionEdits {
    /// Replaces what is under the heading, up to the next heading of the same or a higher level,
    /// with `replacement`; the blank paragraphs at the end of the old section stay.
    static func replaceSection(_ heading: String, with replacement: [Block], in blocks: [Block]) throws(NotesError) -> [Block] {
        let section = try find(heading, in: blocks)
        var end = section.upperBound
        while end > section.lowerBound + 1, isBlank(blocks[end - 1]) { end -= 1 }
        var changed = blocks
        changed.replaceSubrange(section.lowerBound + 1..<end, with: replacement)
        return changed
    }

    /// Replaces everything after the title line and before the heading with `replacement`; the
    /// blank paragraphs just before the heading stay.
    static func replaceBefore(_ heading: String, with replacement: [Block], in blocks: [Block]) throws(NotesError) -> [Block] {
        let section = try find(heading, in: blocks)
        var end = section.lowerBound
        while end > 1, isBlank(blocks[end - 1]) { end -= 1 }
        var changed = blocks
        changed.replaceSubrange(1..<end, with: replacement)
        return changed
    }

    /// The heading's section, refusing the note's first line (its title).
    private static func find(_ heading: String, in blocks: [Block]) throws(NotesError) -> Range<Int> {
        let section = try Sections.find(heading, in: blocks)
        guard section.lowerBound > 0 else {
            throw .refused("\"\(heading)\" is the note's title, not a heading under it: use rewrite to replace the whole note")
        }
        return section
    }

    private static func isBlank(_ block: Block) -> Bool {
        if case .paragraph(let p) = block { p.isBlank } else { false }
    }
}
