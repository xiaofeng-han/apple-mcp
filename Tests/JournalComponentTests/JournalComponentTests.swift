import Foundation
import NoteModel
import Testing
import Wire
@testable import AppCore
@testable import JournalComponent

/// What the shared base takes from Journal agrees with Journal's tools. Made without Product.current
/// (other suites set it), and without opening Journal's data.
@MainActor
@Suite struct JournalComponentTests {
    let tools: [Tool]

    init() {
        let store = JournalStore(writeGuard: nil)
        tools = readTools(store) + writeTools(store)
    }

    var names: [String] { tools.map(\.name) }

    @Test func toolNamesAreUnique() {
        #expect(Set(names).count == names.count)
    }

    @Test func everyCommandRunsATool() {
        for route in JournalComponent.cli.routes {
            guard let tool = tools.first(where: { $0.name == route.tool }) else {
                Issue.record("\(route.command) runs \(route.tool), which is not a tool")
                continue
            }
            let fields = Set((tool.input["properties"]?.object ?? [:]).keys)
            let named = Set(route.fixed.keys).union(route.positional.map(\.key)).union(route.only ?? []).union(route.required)
                .union(route.abouts.keys).union(route.stdin).union(route.fallback.fields.keys).union(route.fallback.unless)
            #expect(named.isSubset(of: fields), "\(route.command): \(named.subtracting(fields).sorted())")
        }
    }

    @Test func everyToolHasAChineseTitle() {
        #expect(Set(JournalComponent.chineseToolTitles.keys) == Set(names))
    }

    @Test func defaultVerbsAreCommands() {
        for (noun, verb) in JournalComponent.cli.defaultVerbs {
            #expect(JournalComponent.cli.routes.contains { $0.noun == noun && $0.verb == verb }, "\(noun) \(verb)")
        }
    }

    @Test func identity() {
        let product = JournalComponent.product
        #expect([product.command, product.serverName, product.bundleID, product.appName, product.environmentPrefix]
            == ["apple-journal-mcp", "apple-journal", "com.xiaofeng.apple-journal-mcp", "AppleJournalMCP", "APPLE_JOURNAL_MCP"])
    }
}

/// Markdown to the canonical form Journal's text formats convert to, and back: the part of the
/// text codec that does not need Journal's frameworks.
@Suite struct EntryTextTests {
    func roundTrip(_ markdown: String) throws -> String {
        let canonical = try EntryText.canonical(Markdown.parse(markdown))
        return EntryText.markdown(canonical, attachments: [:])
    }

    @Test func formattingAndListsReadBack() throws {
        let markdown = """
            Plain **bold** *italic* <u>under</u> ~~strike~~
            * one
              * nested
            - dash
            1. first
            1. second
            > quoted
            """
        #expect(try roundTrip(markdown) == markdown.replacingOccurrences(of: "1. second", with: "2. second"))
    }

    @Test func whatJournalCannotShowBecomesWhatItCan() throws {
        #expect(try roundTrip("# Heading\n- [ ] task\n#tag and [a link](https://example.com)")
            == "**Heading**\n* task\n\\#tag and a link (https://example.com)")
    }

    @Test func tablesAreRefused() {
        #expect(throws: JournalError.self) { try EntryText.canonical(Markdown.parse("| a | b |\n|---|---|\n| 1 | 2 |")) }
    }

    @Test func paragraphKindsFromJournalMarkers() {
        #expect(EntryText.ParagraphKind(markers: ["{disc}", "{circle}"], quote: false) == EntryText.ParagraphKind(list: .bullet, level: 1))
        #expect(EntryText.ParagraphKind(markers: ["{decimal}"], quote: true) == EntryText.ParagraphKind(list: .numbered, quote: true))
        #expect(EntryText.ParagraphKind(markers: ["{hyphen}"], quote: false).style == .dash)
        #expect(EntryText.ParagraphKind(list: .bullet, level: 3).markers == ["{disc}", "{circle}", "{square}", "{square}"])
    }

    @Test func editsFindTheOneSpanThatDiffers() throws {
        let old = try EntryText.canonical(Markdown.parse("Hello **world**, again"))
        let new = try EntryText.canonical(Markdown.parse("Hello **brave world**, again"))
        let edit = try #require(EntryText.Edit(old: old, new: new))
        #expect(edit.oldRange == NSRange(location: 6, length: 0))
        #expect(edit.newRange == NSRange(location: 6, length: 6))
        #expect(EntryText.Edit(old: old, new: old) == nil)
    }

    @Test func editsNeverSplitASurrogatePair() throws {
        let old = NSAttributedString(string: "a😀b"), new = NSAttributedString(string: "a😃b")
        let edit = try #require(EntryText.Edit(old: old, new: new))
        #expect(edit.oldRange == NSRange(location: 1, length: 2))
    }

    @Test func legacyTextReadsItsFormatting() throws {
        let canonical = try EntryText.canonical(Markdown.parse("**Bold** text\n* item"))
        let rtf = try EntryText.rtf(try EntryText.legacy(canonical))
        let back = EntryText.canonical(legacy: try #require(EntryText.fromRTF(rtf)))
        #expect(EntryText.markdown(back, attachments: [:]) == "**Bold** text\n* item")
    }
}

@Suite struct InsightsTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    func day(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text + "T12:00:00Z")!
    }

    @Test func streaksCountUpToYesterday() {
        let dates = ["2026-10-20", "2026-10-21", "2026-10-21", "2026-10-23", "2026-10-24", "2026-10-25"].map(day)
        let insights = Insights(dates: dates, now: day("2026-10-26"), calendar: calendar)
        #expect(insights.entries == 6)
        #expect(insights.daysJournaled == 5)
        #expect(insights.currentDailyStreak == 3)
        #expect(insights.longestDailyStreak == 3)
        #expect(insights.currentWeeklyStreak == 1)
    }

    @Test func aMissedDayEndsTheStreak() {
        let insights = Insights(dates: [day("2026-10-20")], now: day("2026-10-26"), calendar: calendar)
        #expect(insights.currentDailyStreak == 0)
        #expect(insights.longestDailyStreak == 1)
        #expect(insights.currentWeeklyStreak == 1)
    }

    @Test func noEntriesNoInsights() {
        #expect(Insights(dates: [], calendar: calendar) == Insights(dates: [], calendar: calendar))
        #expect(Insights(dates: [], calendar: calendar).entries == 0)
    }
}

@Suite struct AssetDetailsTests {
    @Test func stateOfMindInWords() {
        let json = #"{"valenceClassification":6,"labels":[17,15],"domains":[5],"reflectiveInterval":2}"#
        let details = AssetDetails.details(type: "stateOfMind", metadata: Data([1]) + Data(json.utf8))
        #expect(details["feeling"] == "pleasant")
        #expect(details["describes_it"] == ["happy", "grateful"])
        #expect(details["because_of"] == ["family"])
        #expect(details["kind"] == "daily mood")
    }

    @Test func placesFromAMultiPinMap() {
        let json = #"{"visitsData":[{"placeName":"Lighthouse","city":"Seattle","latitude":47.628217537,"longitude":-122.3}]}"#
        let details = AssetDetails.details(type: "multiPinMap", metadata: Data([1]) + Data(json.utf8))
        #expect(details["places"] == [["place": "Lighthouse", "city": "Seattle", "latitude": 47.62822, "longitude": -122.3]])
        #expect(AssetDetails.kind("multiPinMap") == "place")
    }

    @Test func transcriptsAreJoined() {
        let json = #"{"duration":61.4,"transcriptSegments":[{"text":"Good"},{"text":"morning"}]}"#
        let details = AssetDetails.details(type: "audio", metadata: Data([1]) + Data(json.utf8))
        #expect(details["transcript"] == "Good morning")
        #expect(details["duration_seconds"] == 61)
    }
}
