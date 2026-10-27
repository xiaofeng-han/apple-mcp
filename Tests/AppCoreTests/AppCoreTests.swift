import Agents
import Foundation
import Testing
import Wire
@testable import AppCore

/// The app these tests stand in for: the same one the Agents tests use, so suites running at the
/// same time set Product.current to the same thing.
extension Product {
    static let testing = Product(name: "Apple Reminders MCP", bundleID: "com.xiaofeng.apple-reminders-mcp",
                                 appName: "AppleRemindersMCP", command: "apple-reminders-mcp", serverName: "apple-reminders",
                                 environmentPrefix: "APPLE_REMINDERS_MCP", subject: "Reminders", chineseSubject: "提醒事项")
}

/// A tool that answers "ok", taking `name`, `to` and `limit`, and `action` for the manage tools.
func demoTool(_ name: String) -> Tool {
    let input: JSON = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["rename", "delete"]],
            "name": ["type": "string", "description": "The item's name"],
            "to": ["type": "string", "description": "The new name"],
            "limit": ["type": "integer", "description": "At most this many"],
        ],
    ]
    return Tool(name, title: name, summary: name, input: input, effect: .reads) { _ in ToolAnswer("ok") }
}

func demoCLI(clears: Bool = true, nounsSummary: String? = nil, skillListsRequired: Bool = true) -> CLI {
    CLI(routes: [
        Route(noun: "items", verb: "list", tool: "list_items", about: "List the items", only: ["limit"]),
        Route(noun: "items", verb: "read", tool: "read_item", about: "Read an item", positional: [("name", "NAME")], only: []),
        Route(noun: "items", verb: "rename", tool: "manage_item", about: "Rename an item", fixed: ["action": "rename"],
              positional: [("name", "NAME")], only: ["to"], required: ["to"]),
        Route(noun: "items", verb: "delete", tool: "manage_item", about: "Delete an item", fixed: ["action": "delete"],
              positional: [("name", "NAME")], only: []),
        Route(noun: "items", verb: "find", tool: "find_item", about: "Find items", only: ["name"]),
        Route(noun: "boxes", verb: "find", tool: "find_item", about: "Find boxes", only: ["name"]),
        Route(noun: "boxes", verb: "show", tool: "overview", about: "Show everything", only: []),
    ], defaultVerbs: ["items": "list"], rewordings: [("pass force: true", "add --force")],
        setupAbout: "Ask for access to the items", clears: clears, answer: "JSON answer", nounsSummary: nounsSummary,
        saving: .images, skillListsRequired: skillListsRequired)
}

let demoTools = ["list_items", "read_item", "manage_item", "find_item", "overview"].map(demoTool)

@Suite struct ModeTests {
    func mode(_ words: [String], piped: Bool = false) -> AppMain.Mode {
        AppMain.mode(words, own: ["--copy-note", "authorize"], inputIsPiped: { piped })
    }

    @Test func byTheFirstWordOnly() {
        #expect(mode(["--stdio"]) == .serve)
        #expect(mode(["setup"]) == .setup)
        #expect(mode(["--self-check"]) == .check)
        #expect(mode(["agents", "list"]) == .agents)
        #expect(mode(["skill"]) == .skill)
        #expect(mode(["--version"]) == .version)
        #expect(mode(["--settings"]) == .settings)
        #expect(mode(["notes", "search", "setup"]) == .command)
        #expect(mode(["help"]) == .command)
    }

    @Test func noWordsDependsOnInput() {
        #expect(mode([], piped: true) == .serve)
        #expect(mode([], piped: false) == .settings)
    }

    @Test func theAppsOwnWords() {
        #expect(mode(["authorize"]) == .own("authorize"))
        #expect(mode(["--copy-note", "ID"]) == .own("--copy-note"))
        #expect(AppMain.mode(["authorize"], own: [], inputIsPiped: { false }) == .command)
    }
}

@Suite struct CLITests {
    @Test func rewordsToolsThatOneCommandRunsWhole() {
        let cli = demoCLI()
        #expect(cli.reword("read_item first, then pass force: true") == "items read first, then add --force")
        // A default verb's command is the noun alone.
        #expect(cli.reword("see list_items") == "see items")
        // Several commands run it, or its action is fixed, or the name could be a word.
        #expect(cli.reword("find_item, manage_item, overview") == "find_item, manage_item, overview")
    }

    @Test func clearsOnlyWhereTheAppDoes() {
        #expect(demoCLI(clears: true).routes.allSatisfy(\.clears))
        #expect(!demoCLI(clears: false).routes.contains(where: \.clears))
    }

    @Test func nounsInOrder() {
        #expect(demoCLI().nouns == ["items", "boxes"])
    }
}

@Suite struct TreeTests {
    func tree(_ cli: CLI, only: String? = nil) -> String {
        Commands(cli: cli, tools: demoTools, program: "demo").tree(only: only)
    }

    @Test func wholeTree() {
        let lines = tree(demoCLI()).components(separatedBy: "\n")
        #expect(lines.first == "demo")
        #expect(lines.contains { $0.hasPrefix("├── setup") && $0.hasSuffix("Ask for access to the items") })
        #expect(lines.contains("├── items"))
        #expect(lines.contains { $0.hasPrefix("│   ├── list") && $0.hasSuffix("List the items (the default)") })
        #expect(lines.contains { $0.hasPrefix("└── call TOOL [JSON | -]") })
        #expect(lines.suffix(3) == [
            "Every items, boxes command also takes --json OBJECT (or --json - for stdin) and --help.",
            "Flags: --no-NAME turns a flag off or clears a field; a flag ending in … repeats.",
            "Output is the tool's JSON answer. Exit status: 1 the request failed (reason on stderr), 2 a wrong command or flag.",
        ])
    }

    @Test func theAppsWording() {
        let lines = tree(demoCLI(clears: false, nounsSummary: "items, …")).components(separatedBy: "\n")
        #expect(lines.contains("Every items, … command also takes --json OBJECT (or --json - for stdin) and --help."))
        #expect(lines.contains("Flags: --no-NAME turns a flag off; a flag ending in … repeats."))
    }

    @Test func oneNoun() {
        let lines = tree(demoCLI(), only: "boxes").components(separatedBy: "\n")
        #expect(lines.first == "demo boxes")
        #expect(!lines.contains { $0.contains("setup") || $0.contains("items") })
        #expect(lines.last == "Flags: --no-NAME turns a flag off or clears a field; a flag ending in … repeats.")
    }
}

@Suite struct SkillTextTests {
    init() { Product.current = .testing }

    func text(_ cli: CLI, command: String = "/Applications/Demo.app/Contents/MacOS/Demo") -> String {
        Skill.text(for: Installation(method: .other, bundle: nil, command: command), cli: cli, tools: demoTools) { run in
            SkillText(description: "Demo items.", body: "# Demo\n\nRun `\(run)`.")
        }
    }

    @Test func frontmatterBodyAndCommands() {
        let text = text(demoCLI())
        #expect(text.hasPrefix("""
            ---
            name: apple-reminders
            description: Demo items.
            metadata:
              generated-by: apple-reminders-mcp
              command: "/Applications/Demo.app/Contents/MacOS/Demo"
            ---

            # Demo

            Run `/Applications/Demo.app/Contents/MacOS/Demo`.

            ## Commands

            ### items

            - `items list`: List the items.
            """))
        #expect(text.contains("\n### boxes\n"))
        #expect(text.hasSuffix("\n\n"))
    }

    @Test func quotesACommandWithSpaces() {
        #expect(text(demoCLI(), command: "/Apps/My Demo").contains("Run `\"/Apps/My Demo\"`."))
    }

    @Test func requiredFlagsListedOnlyWhereTheAppDoes() {
        #expect(text(demoCLI(skillListsRequired: true)).contains("(required)"))
        #expect(!text(demoCLI(skillListsRequired: false)).contains("(required)"))
    }
}
