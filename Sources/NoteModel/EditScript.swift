/// The changes that turn one note body into another, block by block. Each block is one line of
/// the note (a table is a line holding only its attachment). Unchanged blocks are left alone;
/// blocks that differ pair up as edits in place where they can, so a changed line keeps its
/// identity and its hidden formatting.
public enum EditStep: Sendable, Equatable {
    /// Removes line `line`.
    case delete(line: Int, Block)
    /// Puts `blocks` before line `line`; `line` equal to the line count appends.
    case insert(line: Int, [Block])
    /// Edits a paragraph in place.
    case change(line: Int, from: Paragraph, to: Paragraph)
    /// Edits a table in place: the same attachment, with its cells brought to the new rows.
    case changeTable(line: Int, from: Table, to: Table)
}

public enum EditScript {
    /// Steps ordered from the end of the note to the start, so each step's line numbers are still
    /// right when it runs.
    public static func steps(from old: [Block], to new: [Block]) -> [EditStep] {
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head, old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        let a = Array(old[head..<(old.count - tail)]), b = Array(new[head..<(new.count - tail)])

        // Unmatched stretches of the middle, by a longest common subsequence. A very large rewrite
        // skips the table and is one stretch.
        var stretches: [(Range<Int>, Range<Int>)] = []
        if a.isEmpty && b.isEmpty {
            return []
        } else if a.count * b.count > 4_000_000 {
            stretches = [(0..<a.count, 0..<b.count)]
        } else {
            let common = Alignment.common(a, b)
            var i = 0, j = 0
            for (x, y) in common + [(a.count, b.count)] {
                if x > i || y > j { stretches.append((i..<x, j..<y)) }
                i = x + 1
                j = y + 1
            }
        }
        var steps: [EditStep] = []
        for (oldRange, newRange) in stretches.reversed() {
            let paired = min(oldRange.count, newRange.count)
            let base = head + oldRange.lowerBound
            if newRange.count > paired {
                steps.append(.insert(line: base + paired, Array(b[(newRange.lowerBound + paired)..<newRange.upperBound])))
            }
            for k in stride(from: oldRange.count - 1, through: paired, by: -1) {
                steps.append(.delete(line: base + k, a[oldRange.lowerBound + k]))
            }
            for k in stride(from: paired - 1, through: 0, by: -1) {
                switch (a[oldRange.lowerBound + k], b[newRange.lowerBound + k]) {
                case (.paragraph(let from), .paragraph(let to)):
                    steps.append(.change(line: base + k, from: from, to: to))
                case (.table(let from), .table(let to)) where !from.id.isEmpty:
                    steps.append(.changeTable(line: base + k, from: from, to: to))
                case (let from, let to):
                    steps.append(.insert(line: base + k + 1, [to]))
                    steps.append(.delete(line: base + k, from))
                }
            }
        }
        return steps
    }
}

public enum Alignment {
    /// Index pairs of a longest common subsequence of `a` and `b`, in order.
    public static func common<T: Equatable>(_ a: [T], _ b: [T]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var length = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                length[i][j] = a[i] == b[j] ? length[i + 1][j + 1] + 1 : max(length[i + 1][j], length[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if length[i + 1][j] >= length[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    /// How to bring a list of rows (or columns) from `old` to `new` by removing and inserting
    /// whole items: items outside a longest common subsequence go, except that inside each
    /// unmatched stretch old and new items pair up one to one, as items edited in place.
    /// `removed` holds old positions, ascending, to remove from the last; `inserted` new positions,
    /// ascending, to insert from the first after all removals.
    public static func rows<T: Equatable>(_ old: [T], _ new: [T]) -> (removed: [Int], inserted: [Int]) {
        var removed: [Int] = [], inserted: [Int] = []
        var i = 0, j = 0
        for (x, y) in common(old, new) + [(old.count, new.count)] {
            let paired = min(x - i, y - j)
            removed += Array((i + paired)..<x)
            inserted += Array((j + paired)..<y)
            i = x + 1
            j = y + 1
        }
        return (removed, inserted)
    }

    /// The changed middle of two strings, never splitting a character: the length of the common
    /// prefix and of the old middle, in UTF-16 units, and the new middle.
    public static func middle(_ old: String, _ new: String) -> (prefix: Int, removed: Int, inserted: String) {
        let a = Array(old), b = Array(new)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        return (String(a[..<p]).utf16.count, String(a[p..<(a.count - s)]).utf16.count, String(b[p..<(b.count - s)]))
    }
}
