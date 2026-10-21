import Foundation
import Testing

@testable import NoteModel

func text(_ s: String, _ marks: Marks = [], link: String? = nil) -> Piece { .text(Run(s, marks: marks, link: link)) }
func line(as style: Style = .body, indent: Int = 0, quote: Int = 0, _ pieces: Piece...) -> Block {
    .paragraph(Paragraph(style, indent: indent, quote: quote, pieces))
}

/// render then parse gives back the same blocks.
func roundTrips(_ blocks: [Block]) -> Bool {
    let markdown = Markdown.render(blocks)
    let back = Markdown.parse(markdown)
    if back != blocks { print("did not round-trip:\n\(markdown)\n→ \(back)") }
    return back == blocks
}

@Suite struct Rendering {
    @Test func styles() {
        let blocks: [Block] = [
            line(as: .title, text("Groceries")), line(as: .heading, text("Fruit")), line(as: .subheading, text("Red")),
            line(as: .checkbox(checked: false), text("apples")), line(as: .checkbox(checked: true), indent: 1, text("cherries")),
            line(as: .bullet, text("bullet")), line(as: .dash, text("dash")), line(as: .numbered, text("one")), line(as: .numbered, text("two")),
            line(as: .numbered, indent: 1, text("two a")), line(as: .numbered, text("three")), line(quote: 1, text("quoted")),
            line(), line(text("plain")),
        ]
        #expect(Markdown.render(blocks) == """
            # Groceries
            ## Fruit
            ### Red
            - [ ] apples
              - [x] cherries
            * bullet
            - dash
            1. one
            2. two
              1. two a
            3. three
            > quoted

            plain
            """)
        #expect(roundTrips(blocks))
    }

    @Test func inlineMarks() {
        let blocks: [Block] = [
            line(text("a "), text("bold", .bold), text(" and "), text("both", [.bold, .italic]), text(" "), text("it", .italic)),
            line(text("x", .strike), text("y", [.strike, .underline]), text("z", .highlight)),
            line(text("see "), text("site", link: "https://e.com/a_(b)"), text(" "), text("bold link", .bold, link: "https://x.y")),
            line(text("bold", .bold), text("italic", .italic), text("bold", .bold)),
            line(text("bi", [.bold, .italic]), text("b", .bold), text("bi", [.bold, .italic]), text("i", .italic)),
        ]
        #expect(roundTrips(blocks))
        #expect(Markdown.render([blocks[0]]) == "a **bold** and ***both*** *it*")
    }

    @Test func escaping() {
        let blocks: [Block] = [
            line(text("# not a heading")), line(text("- not a list")), line(text("1. not numbered")), line(text("> not quoted")),
            line(text("| not a table |")), line(text("  leading spaces")), line(text("\ttab")), line(text("```not a fence")),
            line(text("stars * and [brackets] and \\ backslash")), line(text("~tilde~ and ~~double~~ and a~b")),
            line(text("<u>not underline</u> <mark> a<b")), line(text("-")), line(text("#")), line(text("12.")),
            line(text("![x](attachment:abc) not an attachment")), line(text("MCP_Test #tag")),
        ]
        #expect(roundTrips(blocks))
        #expect(Markdown.render([blocks[0]]) == "\\# not a heading")
        #expect(Markdown.render([blocks[15]]) == "MCP_Test #tag")
    }

    @Test func monospacedAndTables() {
        let blocks: [Block] = [
            line(as: .monospaced, text("let x = 1")), line(as: .monospaced), line(as: .monospaced, text("```")),
            line(text("between")),
            .table(Table(rows: [["Name", "Qty"], ["apple", "3"], ["pipe | bar", "a<br>b"], ["two\nlines", ""]])),
            .table(Table(rows: [["adjacent"]])),
            line(as: .monospaced, quote: 1, text("quoted code")),
        ]
        #expect(roundTrips(blocks))
        #expect(Markdown.render([blocks[0], blocks[1]]) == "```\nlet x = 1\n\n```")
    }

    @Test func attachments() {
        let image = Attachment(id: "AAAA-1", kind: "image")
        let link = Attachment(id: "BBBB-2", kind: "link", label: "https://e.com")
        let blocks: [Block] = [line(text("photo "), .attachment(image), text(" and "), .attachment(link)), line(as: .monospaced, .attachment(image))]
        #expect(Markdown.render([blocks[0]]) == "photo ![image](attachment:AAAA-1) and ![link: https://e.com](attachment:BBBB-2)")
        #expect(roundTrips(blocks))
    }

    @Test func whitespaceAtEmphasisEdges() {
        let read = [text("a "), text(" bold ", .bold), text("b")].normalized()
        #expect(read == [text("a  "), text("bold", .bold), text(" b")])
        #expect(Markdown.render([.paragraph(Paragraph(.body, read))]) == "a  **bold** b")
    }
}

@Suite struct Parsing {
    @Test func lenient() {
        #expect(Markdown.parse("+ item") == [line(as: .dash, text("item"))])
        #expect(Markdown.parse("#### deep") == [line(as: .subheading, text("deep"))])
        #expect(Markdown.parse("* [ ] task") == [line(as: .checkbox(checked: false), text("task"))])
        #expect(Markdown.parse("a\r\nb") == [line(text("a")), line(text("b"))])
        #expect(Markdown.parse("5 * 3 = 15") == [line(text("5 * 3 = 15"))])
        #expect(Markdown.parse("**unclosed") == [line(text("**unclosed"))])
        #expect(Markdown.parse("x ~~y") == [line(text("x ~~y"))])
        #expect(Markdown.parse("-") == [line(as: .dash)])
        #expect(Markdown.parse("   three spaces") == [line(indent: 1, text("three spaces"))])
        #expect(Markdown.parse("|a|b|\n|-|-|\n|c|d|") == [.table(Table(rows: [["a", "b"], ["c", "d"]]))])
        #expect(Markdown.parse("```swift\ncode\n```") == [line(as: .monospaced, text("code"))])
    }
}

@Suite struct Planning {
    @Test func editsInPlace() {
        let old: [Block] = [line(as: .title, text("T")), line(text("a")), line(text("b")), line(text("c"))]
        let new: [Block] = [line(as: .title, text("T")), line(text("a")), line(text("B!")), line(text("c")), line(text("d"))]
        let steps = EditScript.steps(from: old, to: new)
        #expect(steps == [.insert(line: 4, [line(text("d"))]), .change(line: 2, from: Paragraph(.body, [text("b")]), to: Paragraph(.body, [text("B!")]))])
    }

    @Test func applyingStepsGivesTarget() {
        // Apply steps to a plain array of blocks, as the writer does to the note's lines.
        func apply(_ steps: [EditStep], to blocks: [Block]) -> [Block] {
            var out = blocks
            for step in steps {
                switch step {
                case .delete(let line, _): out.remove(at: line)
                case .insert(let line, let new): out.insert(contentsOf: new, at: line)
                case .change(let line, _, let to): out[line] = .paragraph(to)
                case .changeTable(let line, _, let to): out[line] = .table(to)
                }
            }
            return out
        }
        let words = ["a", "b", "c", "d", "e", "f"]
        var seed: UInt64 = 42
        func random(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        for _ in 0..<500 {
            let old = (0..<random(7)).map { _ in line(text(words[random(words.count)])) } + [.table(Table(id: "T", rows: [["x"]]))]
            let new = (0..<random(7)).map { _ in random(5) == 0 ? .table(Table(rows: [["y"]])) : line(text(words[random(words.count)])) }
            #expect(apply(EditScript.steps(from: old, to: new), to: old) == new)
        }
    }

    @Test func rowAlignment() {
        let (removed, inserted) = Alignment.rows(["h", "a", "b", "c"], ["h", "a", "x", "c", "d"])
        #expect(removed.isEmpty && inserted == [4])
        let (r2, i2) = Alignment.rows(["a", "b", "c"], ["c"])
        #expect(r2 == [0, 1] && i2.isEmpty)
        #expect(Alignment.middle("héllo wörld", "héllo world").prefix == 7)
    }
}

@Suite struct Stored {
    @Test func protobufAndCompression() throws {
        // document(2) → note(3) → text(2) = "hi", as gzip and as zlib.
        let message = Data([0x12, 0x06, 0x1a, 0x04, 0x12, 0x02, 0x68, 0x69])
        let deflated = try (message as NSData).compressed(using: .zlib) as Data
        var gzip = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        gzip.append(deflated)
        gzip.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        #expect(StoredBody.plainText(gzip) == "hi")
        var zlib = Data([0x78, 0x9c])
        zlib.append(deflated)
        zlib.append(contentsOf: [0, 0, 0, 0])
        #expect(StoredBody.plainText(zlib) == "hi")
    }

    @Test func folderPaths() {
        #expect(FolderPath.split("Work/A\\/B/ C ") == ["Work", "A/B", "C"])
        #expect(FolderPath.join(["Work", "A/B"]) == "Work/A\\/B")
        #expect(ShortID.of("1E58A0C2-7D3B-4F7A-9C1D-2B3C4D5E6F70") == "1E58A0C2")
        #expect(ShortID.resolve("1e58", in: ["1E58A0C2-X", "2B"]) == .found("1E58A0C2-X"))
    }
}
