import Foundation

/// What Notes' Format → Checklist menu does, on blocks: tick or untick items, tick or untick
/// them all, move ticked items to the bottom of their checklist, delete ticked items.
public enum Checklist {
    public enum Action: String, CaseIterable, Sendable {
        case checkAll = "check_all", uncheckAll = "uncheck_all", moveCheckedDown = "move_checked_down", deleteChecked = "delete_checked"
    }

    /// An item's text as it is matched: its Markdown after the checkbox, or its plain text.
    static func matches(_ p: Paragraph, _ text: String) -> Bool {
        let wanted = text.trimmingCharacters(in: .whitespaces)
        return Markdown.inline(p.pieces) == wanted || p.plainText.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces) == wanted
    }

    /// Ticks (or unticks) every item with one of these texts; returns the texts no item has.
    public static func set(_ texts: [String], checked: Bool, in blocks: inout [Block]) -> [String] {
        var missing: [String] = []
        for text in texts {
            var found = false
            for index in blocks.indices {
                guard case .paragraph(var p) = blocks[index], case .checkbox = p.style, matches(p, text) else { continue }
                p.style = .checkbox(checked: checked)
                blocks[index] = .paragraph(p)
                found = true
            }
            if !found { missing.append(text) }
        }
        return missing
    }

    public static func apply(_ action: Action, to blocks: [Block]) -> [Block] {
        switch action {
        case .checkAll, .uncheckAll:
            return blocks.map { block in
                guard case .paragraph(var p) = block, case .checkbox = p.style else { return block }
                p.style = .checkbox(checked: action == .checkAll)
                return .paragraph(p)
            }
        case .deleteChecked:
            return blocks.filter { block in
                if case .paragraph(let p) = block, case .checkbox(true) = p.style { return false }
                return true
            }
        case .moveCheckedDown:
            var out: [Block] = []
            var index = 0
            while index < blocks.count {
                guard isItem(blocks[index]) else {
                    out.append(blocks[index])
                    index += 1
                    continue
                }
                var end = index
                while end < blocks.count, isItem(blocks[end]) { end += 1 }
                out += moveCheckedDown(Array(blocks[index..<end]))
                index = end
            }
            return out
        }
    }

    static func isItem(_ block: Block) -> Bool {
        if case .paragraph(let p) = block, case .checkbox = p.style { return true }
        return false
    }

    /// One checklist (consecutive items): each item at its outermost level with the items under
    /// it, the ticked ones after the rest, each side in its own order.
    static func moveCheckedDown(_ items: [Block]) -> [Block] {
        func paragraph(_ block: Block) -> Paragraph? { if case .paragraph(let p) = block { p } else { nil } }
        let top = items.compactMap { paragraph($0)?.indent }.min() ?? 0
        var groups: [[Block]] = []
        for block in items {
            if paragraph(block)?.indent == top || groups.isEmpty { groups.append([block]) } else { groups[groups.count - 1].append(block) }
        }
        func ticked(_ group: [Block]) -> Bool {
            if let p = paragraph(group[0]), case .checkbox(true) = p.style { return true }
            return false
        }
        return (groups.filter { !ticked($0) } + groups.filter(ticked)).flatMap { $0 }
    }
}
