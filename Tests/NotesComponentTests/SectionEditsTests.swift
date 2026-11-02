import NoteModel
import Testing
@testable import NotesComponent

/// edit_note's replace_section and replace_before, from Markdown to Markdown.
@Suite struct SectionEditsTests {
    static let note = """
        # Plan
        Intro line

        ## Goals
        - one
        - two

        ## Notes
        ### Detail
        text

        ## Last
        end
        """

    func section(_ heading: String, _ markdown: String, in note: String = note) throws(NotesError) -> String {
        Markdown.render(try SectionEdits.replaceSection(heading, with: parseInserted(markdown), in: Markdown.parse(note)))
    }

    func before(_ heading: String, _ markdown: String, in note: String = note) throws(NotesError) -> String {
        Markdown.render(try SectionEdits.replaceBefore(heading, with: parseInserted(markdown), in: Markdown.parse(note)))
    }

    /// The kind of NotesError `body` throws, or nil when it throws none.
    func failure(_ body: () throws(NotesError) -> String) -> String? {
        do {
            _ = try body()
            return nil
        } catch {
            switch error {
            case .notFound: return "notFound"
            case .refused: return "refused"
            case .noAccess, .conflict, .failed: return "\(error)"
            }
        }
    }

    @Test func replacesAMiddleSectionAndKeepsTheGapBeforeTheNext() throws {
        #expect(try section("Goals", "- three\n- four") == """
            # Plan
            Intro line

            ## Goals
            - three
            - four

            ## Notes
            ### Detail
            text

            ## Last
            end
            """)
    }

    /// A section runs to the next heading of its level or higher, so subheadings go with it.
    @Test func replacesASectionWithItsSubsections() throws {
        #expect(try section("notes", "Only this") == """
            # Plan
            Intro line

            ## Goals
            - one
            - two

            ## Notes
            Only this

            ## Last
            end
            """)
    }

    @Test func replacesTheLastSection() throws {
        #expect(try section("## Last", "the end\nreally") == """
            # Plan
            Intro line

            ## Goals
            - one
            - two

            ## Notes
            ### Detail
            text

            ## Last
            the end
            really
            """)
    }

    @Test func emptyMarkdownEmptiesTheSectionAndKeepsItsHeading() throws {
        #expect(try section("Goals", "") == """
            # Plan
            Intro line

            ## Goals

            ## Notes
            ### Detail
            text

            ## Last
            end
            """)
    }

    /// Blank lines at the end of the new Markdown do not add to the gap the note already has.
    @Test func theGapBeforeTheNextHeadingSurvivesOnce() throws {
        let note = "# T\n## A\nold\n\n\n## B\nb"
        #expect(try section("A", "new\n\n", in: note) == "# T\n## A\nnew\n\n\n## B\nb")
        #expect(try section("A", "", in: note) == "# T\n## A\n\n\n## B\nb")
    }

    @Test func aSubheadingIsASectionToo() throws {
        #expect(try section("Detail", "more", in: Self.note).contains("### Detail\nmore\n\n## Last"))
    }

    @Test func replacesWhatIsBeforeAHeading() throws {
        #expect(try before("Goals", "New intro\nwith two lines") == """
            # Plan
            New intro
            with two lines

            ## Goals
            - one
            - two

            ## Notes
            ### Detail
            text

            ## Last
            end
            """)
        #expect(try before("Goals", "").hasPrefix("# Plan\n\n## Goals\n"))
    }

    /// Before a later heading, the sections in between go too.
    @Test func replacesEverythingUpToALaterHeading() throws {
        #expect(try before("Last", "Summary") == "# Plan\nSummary\n\n## Last\nend")
    }

    @Test func replaceBeforeWithNothingBeforeTheHeading() throws {
        let note = "# Plan\n## Goals\n- one"
        #expect(try before("Goals", "Intro", in: note) == "# Plan\nIntro\n## Goals\n- one")
        #expect(try before("Goals", "", in: note) == note)
    }

    @Test func anUnknownHeadingIsNotFound() {
        #expect(failure { () throws(NotesError) in try section("Missing", "x") } == "notFound")
        #expect(failure { () throws(NotesError) in try before("Missing", "x") } == "notFound")
        // Body text is no heading.
        #expect(failure { () throws(NotesError) in try section("Intro line", "x") } == "notFound")
    }

    @Test func theTitleIsRefused() {
        #expect(failure { () throws(NotesError) in try section("Plan", "x") } == "refused")
        #expect(failure { () throws(NotesError) in try before("# plan", "x") } == "refused")
    }

    @Test func aHeadingThatIsThereTwiceIsRefused() {
        let note = "# T\n## Same\na\n## Same\nb"
        #expect(failure { () throws(NotesError) in try section("Same", "x", in: note) } == "refused")
    }
}
