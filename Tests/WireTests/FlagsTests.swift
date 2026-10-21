import Testing
@testable import Wire

/// A schema with one field of each kind, shaped like Apple Reminders MCP's tools, which use them all.
let schema = Schema.object([
    "title": Schema.text("Title"),
    "list": Schema.text("List name or id"),
    "notes": Schema.text("Plain text"),
    "due": Schema.clearable(Schema.text("2026-10-21 or 2026-10-21T09:00")),
    "priority": Schema.choice(["none", "low", "medium", "high"], "Priority"),
    "sort": Schema.choice(["default", "manual", "due-date", "title", "priority"], "Sort order"),
    "flagged": Schema.flag("Flag"),
    "limit": Schema.whole("At most 500"),
    "radius": Schema.decimal("Meters"),
    "tags": Schema.texts("Tags without #"),
    "days": Schema.wholes("Days of the month"),
    "repeat": Schema.clearable(["type": "object", "properties": ["frequency": Schema.text("How often")]]),
    "early_alerts": Schema.list(of: Schema.object(["before": Schema.whole("Before")]), "Early alerts"),
    "location": Schema.clearable(Schema.any("A place or getting-in-car")),
    "position": Schema.object(["after": Schema.text("Reminder id"), "before": Schema.text("Reminder id")]),
], required: ["title"])

func failure(_ flags: Flags, _ words: [String]) -> String? {
    do {
        _ = try flags.parse(words, stdin: { "" })
        return nil
    } catch {
        return (error as? BadInput)?.description ?? "\(error)"
    }
}

@Suite struct FlagsTests {
    let flags = Flags(schema: schema, positional: [(key: "title", label: "TITLE")])

    @Test func namesFollowTheSchema() {
        #expect(flags.options.map(\.name) == [
            "after", "before", "day", "due", "early-alerts", "flagged", "limit", "list", "location", "notes", "priority", "radius", "repeat",
            "sort", "tag",
        ])
        let required = Flags(schema: schema)
        #expect(required.options.first?.name == "title")
        #expect(required.requiredUsage == "--title string")
        #expect(flags.options.map(\.usage).contains("--tag string…"))
        #expect(flags.options.map(\.usage).contains("--[no-]flagged"))
        #expect(flags.options.map(\.usage).contains("--priority none|low|medium|high"))
        #expect(flags.options.map(\.usage).contains("--sort string"))
        #expect(flags.options.map(\.usage).contains("--location json|string"))
        #expect(flags.positionalUsage == "TITLE")
    }

    @Test func readsEachKind() throws {
        let arguments = try flags.parse([
            "Buy milk", "--list", "Home", "--due=2026-10-21", "--tag", "a", "--tag", "b", "--flagged", "--priority", "high",
            "--limit", "5", "--radius", "120.5", "--day", "1", "--day", "-1", "--after", "R1",
            "--repeat", #"{"frequency": "daily"}"#, "--early-alerts", #"[{"before": 15}]"#, "--location", "getting-in-car",
        ])
        #expect(arguments == [
            "title": "Buy milk", "list": "Home", "due": "2026-10-21", "tags": ["a", "b"], "flagged": true, "priority": "high",
            "limit": 5, "radius": 120.5, "days": [1, -1], "position": ["after": "R1"],
            "repeat": ["frequency": "daily"], "early_alerts": [["before": 15]], "location": "getting-in-car",
        ])
    }

    @Test func noClearsOrTurnsOff() throws {
        let arguments = try flags.parse(["T", "--no-due", "--no-flagged", "--no-location"])
        #expect(arguments == ["title": "T", "due": .null, "flagged": false, "location": .null])
        #expect(try flags.parse(["T", "--flagged=false"])["flagged"] == false)
        #expect(failure(flags, ["T", "--no-list"])?.hasPrefix("--no-list is not an option here") == true)
        let creating = Flags(schema: schema, positional: [(key: "title", label: "TITLE")], clears: false)
        #expect(failure(creating, ["T", "--no-due"]) != nil)
        #expect(try creating.parse(["T", "--no-flagged"])["flagged"] == false)
    }

    @Test func freeFormValuesTakeJSON() throws {
        #expect(try flags.parse(["T", "--location", #"{"latitude": 1, "longitude": 2}"#])["location"] == ["latitude": 1, "longitude": 2])
        #expect(failure(flags, ["T", "--repeat", "daily"]) == "--repeat takes JSON")
    }

    @Test func jsonGivesFieldsThatFlagsOverride() throws {
        let arguments = try flags.parse(["--json", #"{"title": "T", "list": "A", "notes": "n"}"#, "--list", "B"])
        #expect(arguments == ["title": "T", "list": "B", "notes": "n"])
        let piped = try flags.parse(["--json", "-"], stdin: { #"{"title": "From stdin"}"# })
        #expect(piped == ["title": "From stdin"])
        #expect(failure(flags, ["--json", "[1]"]) == "--json takes a JSON object")
    }

    @Test func fixedFieldsWin() throws {
        let fixed = Flags(schema: Schema.object(["action": Schema.text("What to do"), "list": Schema.text("List")]),
                          positional: [(key: "list", label: "LIST")], fixed: ["action": "delete"])
        #expect(fixed.options.isEmpty)
        #expect(try fixed.parse(["L", "--json", #"{"action": "create"}"#]) == ["action": "delete", "list": "L"])
    }

    @Test func doubleDashEndsFlags() throws {
        #expect(try flags.parse(["--", "-1 day"]) == ["title": "-1 day"])
        #expect(failure(flags, ["-x"]) == "-x is not an option; put -- before a word that starts with -")
    }

    @Test func onlyOffersTheseFlagsInThisOrder() {
        let some = Flags(schema: schema, only: ["notes", "list", "position"])
        #expect(some.options.map(\.name) == ["notes", "list", "after", "before"])
        #expect(failure(some, ["--tag", "a"])?.contains("it takes --notes, --list, --after, --before, --json") == true)
    }

    @Test func mistakesAreBadInput() {
        #expect(failure(flags, []) == "missing TITLE")
        #expect(failure(flags, ["A", "B"]) == "\"B\" is one word too many; quote a value that has spaces")
        #expect(failure(flags, ["T", "--list"]) == "--list needs a value")
        #expect(failure(flags, ["T", "--priority", "urgent"]) == "--priority must be one of: none, low, medium, high")
        #expect(failure(flags, ["T", "--limit", "many"]) == "--limit takes a whole number")
        #expect(failure(flags, ["T", "--list", "A", "--list", "B"]) == "--list is given twice")
        #expect(failure(flags, ["T", "--after", "A", "--before", "B"]) == "give --after or --before, once")
        #expect(failure(flags, ["T", "--flagged=yes"]) == "--flagged is true or false")
        let moving = Flags(schema: schema, positional: [(key: "title", label: "TITLE")], only: ["position"], required: ["position"])
        #expect(failure(moving, ["T"]) == "--after or --before is required")
        let none = Flags(schema: Schema.object([:]))
        #expect(failure(none, ["x"]) == "\"x\" is not expected; this command takes only flags")
    }

    @Test func optionalPositional() throws {
        let finding = Flags(schema: Schema.object(["query": Schema.text("Text")]), positional: [(key: "query", label: "QUERY")])
        #expect(finding.positionalUsage == "[QUERY]")
        #expect(try finding.parse([]) == [:])
        #expect(try finding.parse(["milk"]) == ["query": "milk"])
    }

    @Test func helpListsEverything() {
        let help = flags.help(command: "apple-reminders-mcp reminders create", about: "Creates a reminder.")
        #expect(help.hasPrefix("usage: apple-reminders-mcp reminders create TITLE [flags]\n\nCreates a reminder.\n\n"))
        #expect(help.contains("  TITLE "))
        #expect(help.contains("2026-10-21 or 2026-10-21T09:00; --no-due clears it"))
        #expect(Flags.clearing("A person; null unassigns", with: "--no-assigned-to") == "A person; --no-assigned-to unassigns")
        #expect(Flags.clearing("A person; null unassigns", with: nil) == "A person")
        #expect(help.contains("Tags without # (repeat for more)"))
        #expect(help.contains("Sort order (default, manual, due-date, title, priority)"))
        #expect(help.contains("--after string"))
        #expect(help.contains("--json json|-"))
    }
}
