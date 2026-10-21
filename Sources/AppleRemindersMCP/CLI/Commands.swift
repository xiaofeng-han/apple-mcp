import Foundation
import Wire

/// One command: a noun and a verb that run a tool. The command can fill some of the tool's fields
/// itself (a manage tool's action), take others as bare words, and offer the rest as flags (see
/// Flags).
struct Route {
    let noun: String
    let verb: String
    let tool: String
    /// One line, for the command tree and the skill.
    let about: String
    /// More, for the command's own help.
    var detail: String?
    var fixed: [String: JSON] = [:]
    var positional: [(key: String, label: String)] = []
    /// The fields offered as flags, in order; nil offers all of them.
    var only: [String]?
    var required: [String] = []
    /// Whether --no-name clears a field (not when creating).
    var clears = true
    /// Flag descriptions in place of the tool's, where its description covers other actions.
    var abouts: [String: String] = [:]

    var command: String { "\(noun) \(verb)" }

    func flags(_ tool: Tool) -> Flags {
        var abouts = ["new_name": "New name"]
        // A manage tool describes its name field for every action ("New list name for create; list
        // name or id otherwise"); a command takes the half that is about it.
        for (key, property) in tool.input["properties"]?.object ?? [:] {
            guard let about = property["description"]?.string, let split = about.range(of: " for create; ") else { continue }
            let other = about[split.upperBound...].replacingOccurrences(of: " otherwise", with: "")
            abouts[key] = verb == "create" ? String(about[..<split.lowerBound]) : other.prefix(1).uppercased() + other.dropFirst()
        }
        abouts.merge(self.abouts) { _, own in own }
        return Flags(schema: tool.input, positional: positional, fixed: fixed, only: only, required: required, clears: clears, abouts: abouts)
    }

    /// What the command reads itself, besides the tool's fields.
    var extra: [(String, String)] {
        tool == "read_image" ? [("--output string", "Where to save the image; default a file in the temporary folder")] : []
    }
}

/// The tools on the command line: `apple-reminders-mcp reminders find --list Groceries`. Commands
/// print exactly what the tool answers (JSON, sometimes after a short lead such as "Created.").
/// Exit status: 0 done; 1 the tool failed (not found, conflict, not allowed), with the reason on
/// stderr; 2 the command or a flag was wrong.
enum Commands {
    static let program = "apple-reminders-mcp"

    static let routes: [Route] = [
        Route(noun: "reminders", verb: "find", tool: "find_reminders",
              about: "Find reminders across lists, open ones first by due date; QUERY matches the title or notes",
              detail: """
                  Filters combine. --due-before is exclusive: --due-before with tomorrow's date gives everything due \
                  today or overdue. Each reminder appears once, with smart_lists naming the smart lists that show it. \
                  The answer also gives now and time_zone.
                  """,
              positional: [("query", "QUERY")]),
        Route(noun: "reminders", verb: "get", tool: "get_reminder",
              about: "Read one reminder in full: alarms, early alerts, images, subtasks, and its current version",
              positional: [("id", "ID")]),
        Route(noun: "reminders", verb: "create", tool: "create_reminder",
              about: "Create a reminder; without --list it goes to the default list (or the parent's list)",
              positional: [("title", "TITLE")], clears: false),
        Route(noun: "reminders", verb: "update", tool: "update_reminder",
              about: "Change only the fields given; --no-FIELD clears one",
              detail: """
                  Pass the --version that find or get gave; a reminder changed elsewhere since then is refused, so \
                  read it again. --completed checks it off: a repeating reminder leaves a completed copy and moves \
                  to its next date (unless that is turned off in the app's settings). --list moves it to another list.
                  """,
              positional: [("id", "ID")]),
        Route(noun: "reminders", verb: "delete", tool: "delete_reminder",
              about: "Move a reminder and its subtasks to Recently Deleted", positional: [("id", "ID")]),
        Route(noun: "reminders", verb: "deleted", tool: "list_deleted",
              about: "List reminders in Recently Deleted that restore can bring back, newest first",
              detail: "With Full Disk Access for the app this is everything in Recently Deleted; without it, what this app deleted."),
        Route(noun: "reminders", verb: "restore", tool: "restore_reminder",
              about: "Bring a reminder back from Recently Deleted, with the subtasks deleted along with it",
              detail: "Without --list it returns to the list it was deleted from, or the default list.",
              positional: [("id", "ID")]),
        Route(noun: "reminders", verb: "image", tool: "read_image",
              about: "Save an image on a reminder (ids from get) and print where; needs Full Disk Access",
              positional: [("reminder_id", "REMINDER_ID"), ("image_id", "IMAGE_ID")]),

        Route(noun: "lists", verb: "list", tool: "list_lists",
              about: "The lists (with counts, sections and the people on shared ones), groups, smart lists and templates"),
        Route(noun: "lists", verb: "create", tool: "manage_list", about: "Create a list",
              fixed: ["action": "create"], positional: [("list", "NAME")],
              only: ["color", "icon", "group", "pinned", "type", "sort", "position"], clears: false),
        Route(noun: "lists", verb: "update", tool: "manage_list",
              about: "Change a list's name, color, icon, group, pin, type, sort order or place in the sidebar",
              detail: "A groceries list sorts its items into aisles.",
              fixed: ["action": "update"], positional: [("list", "LIST")],
              only: ["new_name", "color", "icon", "group", "pinned", "type", "sort", "position"]),
        Route(noun: "lists", verb: "clear-completed", tool: "manage_list", about: "Move a list's completed reminders to Recently Deleted",
              fixed: ["action": "clear_completed"], positional: [("list", "LIST")], only: []),
        Route(noun: "lists", verb: "delete", tool: "manage_list",
              about: "Delete a list; one with reminders needs --confirm-delete-reminders (ask the user first)",
              detail: "Its reminders go to Recently Deleted.",
              fixed: ["action": "delete"], positional: [("list", "LIST")], only: ["confirm_delete_reminders"]),

        Route(noun: "groups", verb: "create", tool: "manage_group",
              about: "Create a group, which holds lists in the sidebar (put lists in it with lists update --group)",
              fixed: ["action": "create"], positional: [("group", "NAME")], only: []),
        Route(noun: "groups", verb: "rename", tool: "manage_group", about: "Rename a group",
              fixed: ["action": "rename"], positional: [("group", "GROUP"), ("new_name", "NEW_NAME")], only: [], required: ["new_name"]),
        Route(noun: "groups", verb: "delete", tool: "manage_group", about: "Delete an empty group",
              fixed: ["action": "delete"], positional: [("group", "GROUP")], only: []),

        Route(noun: "sections", verb: "create", tool: "manage_section",
              about: "Create a section in a list (put reminders in it with --section)",
              fixed: ["action": "create"], positional: [("list", "LIST"), ("section", "NAME")], only: []),
        Route(noun: "sections", verb: "rename", tool: "manage_section", about: "Rename a section",
              fixed: ["action": "rename"], positional: [("list", "LIST"), ("section", "SECTION"), ("new_name", "NEW_NAME")], only: [],
              required: ["new_name"]),
        Route(noun: "sections", verb: "move", tool: "manage_section", about: "Move a section next to another one",
              fixed: ["action": "move"], positional: [("list", "LIST"), ("section", "SECTION")], only: ["position"], required: ["position"]),
        Route(noun: "sections", verb: "delete", tool: "manage_section", about: "Delete a section; its reminders stay in the list",
              fixed: ["action": "delete"], positional: [("list", "LIST"), ("section", "SECTION")], only: []),

        Route(noun: "smart-lists", verb: "create", tool: "manage_smart_list",
              about: "Create a smart list, which shows the reminders matching its filters",
              fixed: ["action": "create"], positional: [("smart_list", "NAME")], only: ["filters", "match", "color", "icon"],
              required: ["filters"], clears: false),
        Route(noun: "smart-lists", verb: "update", tool: "manage_smart_list",
              about: "Change a smart list's name, color, icon, match or filters (--filters replaces them all)",
              fixed: ["action": "update"], positional: [("smart_list", "SMART_LIST")], only: ["new_name", "filters", "match", "color", "icon"]),
        Route(noun: "smart-lists", verb: "delete", tool: "manage_smart_list", about: "Delete a smart list; no reminders are deleted",
              fixed: ["action": "delete"], positional: [("smart_list", "SMART_LIST")], only: []),

        Route(noun: "tags", verb: "list", tool: "list_tags", about: "Every tag in use, with how many open and how many reminders in all have it"),
        Route(noun: "tags", verb: "rename", tool: "manage_tag",
              about: "Rename a tag on every reminder that has it, merging into a tag of that name if there is one",
              fixed: ["action": "rename"], positional: [("tag", "TAG"), ("new_name", "NEW_NAME")], only: [], required: ["new_name"]),
        Route(noun: "tags", verb: "delete", tool: "manage_tag", about: "Remove a tag from every reminder",
              fixed: ["action": "delete"], positional: [("tag", "TAG")], only: []),

        Route(noun: "templates", verb: "create", tool: "manage_template",
              about: "Save a list as a template (Reminders copies its reminders in the background)",
              fixed: ["action": "create"], positional: [("template", "NAME")], only: ["list", "include_completed"], required: ["list"],
              abouts: ["list": "The list to save (name or id)", "include_completed": "Keep completed reminders too; default false"]),
        Route(noun: "templates", verb: "use", tool: "manage_template", about: "Make a new list from a template",
              fixed: ["action": "use"], positional: [("template", "TEMPLATE")], only: ["list"],
              abouts: ["list": "The new list's name; default the template's"]),
        Route(noun: "templates", verb: "delete", tool: "manage_template", about: "Delete a template",
              fixed: ["action": "delete"], positional: [("template", "TEMPLATE")], only: []),
    ]

    /// The nouns in order, and the verb each runs without one.
    static let nouns: [String] = routes.reduce(into: []) { nouns, route in if !nouns.contains(route.noun) { nouns.append(route.noun) } }
    static let defaultVerbs = ["lists": "list", "tags": "list"]

    /// Everything that is not the server, setup, agents or skill: help, the tool commands, and call.
    static func run(_ words: [String], tools: [Tool]) async -> Int32 {
        let first = words.first ?? "help"
        switch first {
        case "help", "--help", "-h":
            return help(Array(words.dropFirst()), tools: tools)
        case "call":
            return await call(Array(words.dropFirst()), tools: tools)
        case _ where nouns.contains(first):
            var rest = Array(words.dropFirst())
            if rest.first.map({ $0.hasPrefix("-") && !["-h", "--help"].contains($0) }) ?? true, let verb = defaultVerbs[first] {
                rest.insert(verb, at: 0)
            }
            guard let verb = rest.first, !["-h", "--help"].contains(verb) else {
                print(tree(only: first, tools: tools))
                return rest.isEmpty ? 2 : 0
            }
            guard let route = routes.first(where: { $0.noun == first && $0.verb == verb }), let tool = tools.first(where: { $0.name == route.tool })
            else { return fail("\(first) has no command \"\(verb)\"", hint: "\(program) help \(first)") }
            return await run(route, tool, Array(rest.dropFirst()))
        default:
            return fail("unknown command \"\(first)\"", hint: "\(program) help")
        }
    }

    static func run(_ route: Route, _ tool: Tool, _ words: [String]) async -> Int32 {
        let flags = route.flags(tool)
        let hint = "\(program) \(route.command) --help"
        let flagWords = words.prefix { $0 != "--" }
        if flagWords.contains("-h") || flagWords.contains("--help") {
            print(help(route, flags))
            return 0
        }
        var words = words
        var output: String?
        if route.tool == "read_image", let index = flagWords.firstIndex(where: { $0 == "--output" || $0.hasPrefix("--output=") }) {
            let word = words.remove(at: index)
            if word == "--output" {
                guard index < words.count else { return fail("--output needs a value", hint: hint) }
                output = words.remove(at: index)
            } else {
                output = String(word.dropFirst("--output=".count))
            }
        }
        do {
            return await execute(tool, try flags.parse(words), hint: hint, output: output)
        } catch {
            return fail("\(error)", hint: hint)
        }
    }

    /// `call TOOL [JSON | -]`: any tool, on a JSON object of its arguments.
    static func call(_ words: [String], tools: [Tool]) async -> Int32 {
        guard let name = words.first else {
            for tool in tools { print("\(tool.name.padding(toLength: 18, withPad: " ", startingAt: 0))\(tool.title)") }
            return 0
        }
        guard let tool = tools.first(where: { $0.name == name }) else { return fail("there is no tool named \(name)", hint: "\(program) call") }
        if words.count == 2, ["-h", "--help"].contains(words[1]) {
            print("\(tool.title): \(tool.summary)\n\nInput schema: \(tool.input.text)")
            return 0
        }
        guard words.count <= 2 else { return fail("call takes a tool and one JSON object", hint: "\(program) call") }
        var text = words.count == 2 ? words[1] : "{}"
        if text == "-" { text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
        guard let arguments = JSON.parse(text)?.object else { return fail("the arguments must be a JSON object", hint: "\(program) call \(name) --help") }
        return await execute(tool, arguments, hint: "\(program) call \(name) --help", output: nil)
    }

    /// Runs the tool and prints its answer. A tool turned off in the settings window's Tools tab is
    /// refused here too: agents set up with the skill run these commands.
    static func execute(_ tool: Tool, _ arguments: [String: JSON], hint: String, output: String?) async -> Int32 {
        if let refusal = Settings.exposure.refusal(tool, among: tools) { return fail(reword(refusal), status: 1) }
        let answer: ToolAnswer
        do {
            answer = try await tool.run(arguments)
        } catch let error as BadInput {
            return fail(reword(error.description), hint: hint)
        } catch {
            answer = ToolAnswer("\(error)", failed: true)
        }
        var lines: [String] = []
        for content in answer.content {
            switch content {
            case .text(let text):
                lines.append(text)
            case .image(let data, let mime):
                let id = (arguments["image_id"]?.string ?? "image").map { $0.isLetter || $0.isNumber ? $0 : "-" }
                let fileExtension = ["image/png": "png", "image/heic": "heic", "image/gif": "gif"][mime] ?? "jpg"
                let url = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent("apple-reminders-\(String(id)).\(fileExtension)")
                do {
                    try data.write(to: url, options: .atomic)
                    lines.append("Saved to \(url.path)")
                } catch {
                    return fail("cannot save the image to \(url.path): \(error.localizedDescription)", status: 1)
                }
            }
        }
        let text = lines.joined(separator: "\n")
        guard !answer.failed else {
            FileHandle.standardError.write(Data((reword(text) + "\n").utf8))
            return 1
        }
        print(text)
        return 0
    }

    /// The tools' messages name tools and fields; here they name commands and flags. Only for
    /// messages: answers hold the user's own text.
    static func reword(_ message: String) -> String {
        var message = message
            .replacingOccurrences(of: "manage_list (group: null)", with: "lists update --no-group")
            .replacingOccurrences(of: "confirm_delete_reminders: true", with: "--confirm-delete-reminders")
        for route in routes where route.fixed.isEmpty {
            message = message.replacingOccurrences(of: route.tool, with: defaultVerbs[route.noun] == route.verb ? route.noun : route.command)
        }
        return message
    }

    static func fail(_ message: String, hint: String? = nil, status: Int32 = 2) -> Int32 {
        FileHandle.standardError.write(Data("\(program): \(message)\n\(hint.map { "See: \($0)\n" } ?? "")".utf8))
        return status
    }

    // MARK: Help

    static func help(_ route: Route, _ flags: Flags) -> String {
        flags.help(command: "\(program) \(route.command)", about: [route.about + ".", route.detail].compactMap { $0 }.joined(separator: " "),
                   extra: route.extra)
    }

    /// `help`, `help NOUN`, `help NOUN VERB`.
    static func help(_ words: [String], tools: [Tool]) -> Int32 {
        guard let noun = words.first else {
            print(tree(tools: tools))
            return 0
        }
        guard nouns.contains(noun) else {
            if ["agents", "setup", "skill", "call"].contains(noun) {
                print(tree(tools: tools))
                return 0
            }
            return fail("unknown command \"\(noun)\"", hint: "\(program) help")
        }
        guard words.count > 1 else {
            print(tree(only: noun, tools: tools))
            return 0
        }
        guard let route = routes.first(where: { $0.noun == noun && $0.verb == words[1] }), let tool = tools.first(where: { $0.name == route.tool })
        else { return fail("\(noun) has no command \"\(words[1])\"", hint: "\(program) help \(noun)") }
        print(help(route, route.flags(tool)))
        return 0
    }

    /// Everything the program takes, as a tree; `only` limits it to one noun's commands.
    static func tree(only: String? = nil, tools: [Tool]) -> String {
        let width = 32
        var lines: [String] = []
        func row(_ prefix: String, _ label: String, _ about: String) {
            let head = prefix + label
            lines.append(head.count >= width ? "\(head)  \(about)" : head.padding(toLength: width, withPad: " ", startingAt: 0) + about)
        }
        /// Flags under a row, wrapped.
        func flagLines(_ prefix: String, _ items: [String]) {
            var line = ""
            for item in items {
                if !line.isEmpty, prefix.count + 4 + line.count + 1 + item.count > 110 {
                    lines.append(prefix + "    " + line)
                    line = ""
                }
                line += (line.isEmpty ? "" : " ") + item
            }
            if !line.isEmpty { lines.append(prefix + "    " + line) }
        }
        var groups: [(name: String, rows: [(label: String, about: String, flags: [String])])] = []
        if only == nil {
            groups.append(("", [
                ("--stdio", "Serve MCP on stdin and stdout (what agents start)", []),
                ("--settings", "Open the settings window (also what opening the app does)", []),
                ("--self-check", "Print a diagnosis", []),
                ("--version", "Print the version", []),
                ("help [COMMAND…]", "This tree, or a command's flags (also --help, -h)", []),
                ("setup", "Ask for access to Reminders (alias: authorize)", []),
                ("skill", "Print the SKILL.md that teaches an agent this command line", []),
            ]))
            groups.append(("agents", [
                ("list", "Which agents are here and set up (the default)", ["[--skill]", "[--folder DIR]"]),
                ("set-up (ID… | --all)", "Register the server with them, or install the skill", ["[--restart]", "[--skill]", "[--folder DIR]"]),
                ("install ID…", "Install them, then set them up", ["[--dry-run]", "[--restart]", "[--skill]", "[--folder DIR]"]),
            ]))
        }
        for noun in nouns where only == nil || only == noun {
            groups.append((noun, routes.filter { $0.noun == noun }.map { route in
                let flags = tools.first { $0.name == route.tool }.map(route.flags)
                let label = [route.verb, flags?.requiredUsage ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
                let about = route.about + (defaultVerbs[noun] == route.verb ? " (the default)" : "")
                return (label, about, (flags?.optional.map(\.usage) ?? []) + route.extra.map(\.0))
            }))
        }
        if only == nil { groups.append(("call TOOL [JSON | -]", [])) }

        lines.append(only.map { "\(program) \($0)" } ?? program)
        for (index, group) in groups.enumerated() {
            let last = index == groups.count - 1
            if group.name.isEmpty {
                for (offset, item) in group.rows.enumerated() {
                    row(last && offset == group.rows.count - 1 ? "└── " : "├── ", item.label, item.about)
                }
                continue
            }
            if only == nil {
                if group.rows.isEmpty {
                    row(last ? "└── " : "├── ", group.name, "Run any tool on a JSON object of its arguments; call alone lists the tools")
                    continue
                }
                lines.append((last ? "└── " : "├── ") + group.name)
            }
            let indent = only == nil ? (last ? "    " : "│   ") : ""
            for (offset, item) in group.rows.enumerated() {
                let end = offset == group.rows.count - 1
                row(indent + (end ? "└── " : "├── "), item.label, item.about)
                if !item.flags.isEmpty { flagLines(indent + (end ? "    " : "│   "), item.flags) }
            }
        }
        lines.append("")
        lines.append("Every \(only ?? "reminders, lists, …") command also takes --json OBJECT (or --json - for stdin) and --help.")
        lines.append("Flags: --no-NAME turns a flag off or clears a field; a flag ending in … repeats.")
        if only == nil {
            lines.append("Output is the tool's JSON answer. Exit status: 1 the request failed (reason on stderr), 2 a wrong command or flag.")
        }
        return lines.joined(separator: "\n")
    }
}
