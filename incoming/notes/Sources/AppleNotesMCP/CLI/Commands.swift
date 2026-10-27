import Foundation
import UniformTypeIdentifiers
import Wire

/// One command: a noun and a verb that run a tool. The command can fill some of the tool's fields
/// itself (manage_folder's action), take others as bare words, and offer the rest as flags (see
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
    /// Flag descriptions in place of the tool's, where its description covers other actions.
    var abouts: [String: String] = [:]
    /// Fields whose value `-` is read from stdin: Markdown, which runs to many lines.
    var stdin: [String] = []
    /// Fields set when none of `unless` is given: overview without filters shows the folder tree,
    /// which `folders list` gives, so `notes list` lists the newest notes instead.
    var fallback: (fields: [String: JSON], unless: [String]) = ([:], [])

    var command: String { "\(noun) \(verb)" }

    func flags(_ tool: Tool) -> Flags {
        Flags(schema: tool.input, positional: positional, fixed: fixed, only: only, required: required, clears: false, abouts: abouts)
    }

    /// What the command reads itself, besides the tool's fields.
    var extra: [(String, String)] {
        tool == "read_attachment" ? [("--output-dir string", "Where to save its images, audio and files; default the temporary folder")] : []
    }
}

/// The tools on the command line: `apple-notes-mcp notes search "tax return"`. Commands print
/// exactly what the tool answers (text, often Markdown). Exit status: 0 done; 1 the tool failed
/// (not found, conflict, not allowed), with the reason on stderr; 2 the command or a flag was wrong.
enum Commands {
    static let program = "apple-notes-mcp"

    static let routes: [Route] = [
        Route(noun: "notes", verb: "list", tool: "overview",
              about: "List notes, newest first, one line each (id | version | title | date | size | description)",
              detail: """
                  --folder includes its folders, and groups the notes by folder unless --sort is given. Dates are \
                  YYYY-MM-DD; the -after ones are inclusive, the -before ones exclusive. --undescribed lists the notes \
                  that need a description, with their opening text, for notes describe.
                  """,
              only: ["folder", "tags", "only", "attachments", "modified_after", "modified_before", "created_after", "created_before", "sort", "undescribed", "limit"],
              fallback: (["sort": "modified"], ["folder", "tags", "only", "attachments", "modified_after", "modified_before", "created_after", "created_before",
                                                "sort", "undescribed"])),
        Route(noun: "notes", verb: "search", tool: "search",
              about: "Full-text search of titles, text and the text Notes found in attachments, best matches first",
              positional: [("query", "QUERY")],
              only: ["match", "folder", "tags", "only", "attachments", "modified_after", "modified_before", "created_after", "created_before", "sort", "limit"]),
        Route(noun: "notes", verb: "read", tool: "read_note",
              about: "Print notes as Markdown, each with the version that notes edit takes",
              detail: """
                  By id, several (--id repeats, up to 20), or --title. A long note can be read one --section at a \
                  time, or as an --outline first.
                  """,
              positional: [("id", "ID")], only: ["ids", "title", "section", "outline"]),
        Route(noun: "notes", verb: "create", tool: "create_note",
              about: "Create a note from Markdown; its first line is the title",
              detail: "![name](/path/to/file) in the Markdown attaches a file, ![](https://…) adds a link card.",
              positional: [("markdown", "MARKDOWN")], only: ["folder"], required: ["markdown"],
              abouts: ["markdown": "The note as Markdown; - reads it from stdin"], stdin: ["markdown"]),
        Route(noun: "notes", verb: "copy", tool: "create_note",
              about: "Copy a note with everything in it, into its own folder or --folder",
              positional: [("copy_of", "ID")], only: ["folder"], required: ["copy_of"]),
        Route(noun: "notes", verb: "edit", tool: "edit_note",
              about: "Change a note in one go: --replace pairs, --insert Markdown, or --rewrite the whole note; --[no-]pinned",
              detail: """
                  --version is the one notes read, list or search gave; a note changed elsewhere since then is \
                  refused, so read it again. --replace takes exact Markdown from notes read, applied in order. \
                  --insert adds at the end, the start, or under a heading (--at). Only what changes is written; the \
                  rest keeps all its formatting.
                  """,
              positional: [("id", "ID")], only: ["version", "replace", "insert", "at", "rewrite", "check", "uncheck", "checklist", "pinned"],
              abouts: ["version": "From notes read, list or search", "replace": "A JSON list of {old, new, all}, applied in order",
                       "insert": "Markdown to add; - reads it from stdin", "rewrite": "The whole note as Markdown; - reads it from stdin"],
              stdin: ["insert", "rewrite"]),
        Route(noun: "notes", verb: "delete", tool: "delete_note",
              about: "Move a note to Recently Deleted (notes move brings it back; notes list --folder \"Recently Deleted\" lists them)",
              detail: "--version is the one notes read, list or search gave; a note changed elsewhere since then is refused.",
              positional: [("id", "ID")]),
        Route(noun: "notes", verb: "move", tool: "move_note",
              about: "Move a note to another folder, or back from Recently Deleted",
              detail: """
                  --version is the one notes read, list or search gave; a note changed elsewhere since then is refused. \
                  A move into or out of a shared folder needs --allow-shared, after asking the user. --folder \
                  "Recently Deleted" on notes list shows the deleted notes.
                  """,
              positional: [("id", "ID"), ("folder", "FOLDER")]),
        Route(noun: "notes", verb: "describe", tool: "describe_note",
              about: "Save one-line descriptions of notes, which notes list shows; many notes at once",
              abouts: ["descriptions": "A JSON list of 1 to 200 {\"id\", \"description\"}, each under 80 characters"]),

        Route(noun: "tags", verb: "rename", tool: "manage_tag", about: "Rename a tag in every note that has it",
              fixed: ["action": "rename"], positional: [("tag", "TAG"), ("name", "NAME")], only: [], required: ["name"],
              abouts: ["tag": "The tag, # optional", "name": "The new name"]),
        Route(noun: "tags", verb: "delete", tool: "manage_tag",
              about: "Take a tag out of every note that has it (ask the user first); the notes stay",
              detail: "--expected-notes is the number of notes with the tag, which folders list shows.",
              fixed: ["action": "delete"], positional: [("tag", "TAG")], only: ["expected_notes"], required: ["expected_notes"],
              abouts: ["tag": "The tag, # optional", "expected_notes": "The number of notes with the tag"]),

        Route(noun: "attachments", verb: "read", tool: "read_attachment",
              about: "Open an attachment from a ![…](attachment:ID) placeholder: print its text, save its images, audio and files",
              positional: [("id", "ID")]),

        Route(noun: "folders", verb: "list", tool: "overview",
              about: "The folders, with how many notes each holds", only: ["depth"]),
        Route(noun: "folders", verb: "create", tool: "manage_folder", about: "Create a folder; a path such as Projects/Ideas makes it inside another",
              detail: "With --tag (repeat for more), a smart folder of the notes with any of the tags, or with --match all, all of them.",
              fixed: ["action": "create"], positional: [("folder", "PATH")], only: ["tags", "match"],
              abouts: ["folder": "The new folder's path, such as \"Projects/Ideas\""]),
        Route(noun: "folders", verb: "rename", tool: "manage_folder", about: "Rename a folder",
              detail: "A shared folder needs --allow-shared, after asking the user: the new name changes it for everyone.",
              fixed: ["action": "rename"], positional: [("folder", "FOLDER"), ("name", "NAME")], only: ["allow_shared"], required: ["name"],
              abouts: ["folder": "Path or id"]),
        Route(noun: "folders", verb: "move", tool: "manage_folder", about: "Move a folder into another, or to the top level with \"\"",
              detail: "A shared folder needs --allow-shared, after asking the user.",
              fixed: ["action": "move"], positional: [("folder", "FOLDER"), ("into", "INTO")], only: ["allow_shared"], required: ["into"],
              abouts: ["folder": "Path or id", "into": "The folder to put it in; \"\" for the top level"]),
        Route(noun: "folders", verb: "delete", tool: "manage_folder",
              about: "Delete an empty folder, or with --recursive --expected-notes N everything in it (ask the user first)",
              detail: "The notes go to Recently Deleted. --expected-notes is the number of notes you saw in it and its folders.",
              fixed: ["action": "delete"], positional: [("folder", "FOLDER")], only: ["recursive", "expected_notes"],
              abouts: ["folder": "Path or id", "recursive": "Also everything in it", "expected_notes": "With --recursive: the notes you saw in it and its folders"]),
        Route(noun: "folders", verb: "export", tool: "manage_folder",
              about: "Write a folder and its folders as Markdown with the original attachments, to a new folder or .zip",
              fixed: ["action": "export"], positional: [("folder", "FOLDER"), ("to", "TO")], only: [], required: ["to"],
              abouts: ["folder": "Path or id", "to": "A new folder or .zip path"]),
    ]

    /// The nouns in order, and the verb each runs without one.
    static let nouns: [String] = routes.reduce(into: []) { nouns, route in if !nouns.contains(route.noun) { nouns.append(route.noun) } }
    static let defaultVerbs = ["notes": "list", "folders": "list"]

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
        if route.tool == "read_attachment", let index = flagWords.firstIndex(where: { $0 == "--output-dir" || $0.hasPrefix("--output-dir=") }) {
            let word = words.remove(at: index)
            if word == "--output-dir" {
                guard index < words.count else { return fail("--output-dir needs a value", hint: hint) }
                output = words.remove(at: index)
            } else {
                output = String(word.dropFirst("--output-dir=".count))
            }
        }
        do {
            var arguments = try flags.parse(words)
            let piped = route.stdin.filter { arguments[$0]?.string == "-" }
            guard piped.count <= 1 else { return fail("only one of \(piped.map { "--\($0)" }.joined(separator: ", ")) can read stdin", hint: hint) }
            if let key = piped.first { arguments[key] = .string(String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)) }
            if !route.fallback.unless.contains(where: { arguments[$0] != nil }) { arguments.merge(route.fallback.fields) { given, _ in given } }
            return await execute(tool, arguments, hint: hint, output: output)
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

    /// Runs the tool and prints its answer; images, audio and files in it are saved, and printed
    /// as where they went. A tool turned off in the settings window's Tools tab is refused here
    /// too: agents set up with the skill run these commands.
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
        let saved = answer.content.filter { if case .text = $0 { false } else { true } }.count
        let folder = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let id = (arguments["id"]?.string ?? "attachment").map { $0.isLetter || $0.isNumber ? $0 : "-" }
        var number = 0
        for content in answer.content {
            let file: (data: Data, mime: String)
            switch content {
            case .text(let text):
                lines.append(text)
                continue
            case .image(let data, let mime), .audio(let data, let mime), .file(let data, _, let mime):
                file = (data, mime)
            }
            number += 1
            let fileExtension = UTType(mimeType: file.mime)?.preferredFilenameExtension ?? "bin"
            let url = folder.appendingPathComponent("apple-notes-\(String(id))\(saved > 1 ? "-\(number)" : "").\(fileExtension)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try file.data.write(to: url, options: .atomic)
                lines.append("Saved to \(url.path)")
            } catch {
                return fail("cannot save to \(url.path): \(error.localizedDescription)", status: 1)
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
            .replacingOccurrences(of: "overview lists the folders", with: "folders list shows them")
            .replacingOccurrences(of: "with overview", with: "with folders list")
            .replacingOccurrences(of: "pass allow_shared: true", with: "add --allow-shared")
            .replacingOccurrences(of: "recursive: true and expected_notes", with: "--recursive and --expected-notes")
            .replacingOccurrences(of: "recursive needs expected_notes", with: "--recursive needs --expected-notes")
        // Only names no word could be, of tools with one command each.
        for route in routes where route.tool.contains("_") && routes.filter({ $0.tool == route.tool }).count == 1 {
            message = message.replacingOccurrences(of: route.tool, with: route.command)
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
                ("setup", "Ask to control Notes, and show where to give Full Disk Access", []),
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
        lines.append("Every \(only ?? nouns.joined(separator: ", ")) command also takes --json OBJECT (or --json - for stdin) and --help.")
        lines.append("Flags: --no-NAME turns a flag off; a flag ending in … repeats.")
        if only == nil {
            lines.append("Output is the tool's answer. Exit status: 1 the request failed (reason on stderr), 2 a wrong command or flag.")
        }
        return lines.joined(separator: "\n")
    }
}
