import Agents
import Foundation
import UniformTypeIdentifiers
import Wire

/// The tools on the command line: `apple-notes-mcp notes search "tax return"`, `apple-reminders-mcp
/// reminders find --list Groceries`. Commands print exactly what the tool answers (Notes: text,
/// often Markdown; Reminders: JSON, sometimes after a short lead such as "Created."). Exit status:
/// 0 done; 1 the tool failed (not found, conflict, not allowed), with the reason on stderr; 2 the
/// command or a flag was wrong.
struct Commands {
    let cli: CLI
    let tools: [Tool]
    var program = Product.current.command

    /// Everything that is not the server, setup, agents or skill: help, the tool commands, and call.
    func run(_ words: [String]) async -> Int32 {
        let first = words.first ?? "help"
        switch first {
        case "help", "--help", "-h":
            return help(Array(words.dropFirst()))
        case "call":
            return await call(Array(words.dropFirst()))
        case _ where cli.nouns.contains(first):
            var rest = Array(words.dropFirst())
            if rest.first.map({ $0.hasPrefix("-") && !["-h", "--help"].contains($0) }) ?? true, let verb = cli.defaultVerbs[first] {
                rest.insert(verb, at: 0)
            }
            guard let verb = rest.first, !["-h", "--help"].contains(verb) else {
                print(tree(only: first))
                return rest.isEmpty ? 2 : 0
            }
            guard let route = cli.routes.first(where: { $0.noun == first && $0.verb == verb }), let tool = tools.first(where: { $0.name == route.tool })
            else { return fail("\(first) has no command \"\(verb)\"", hint: "\(program) help \(first)") }
            return await run(route, tool, Array(rest.dropFirst()))
        default:
            return fail("unknown command \"\(first)\"", hint: "\(program) help")
        }
    }

    func run(_ route: Route, _ tool: Tool, _ words: [String]) async -> Int32 {
        let flags = route.flags(tool)
        let hint = "\(program) \(route.command) --help"
        let flagWords = words.prefix { $0 != "--" }
        if flagWords.contains("-h") || flagWords.contains("--help") {
            print(help(route, flags))
            return 0
        }
        var words = words
        var output: String?
        if let flag = route.output?.flag, let index = flagWords.firstIndex(where: { $0 == flag || $0.hasPrefix(flag + "=") }) {
            let word = words.remove(at: index)
            if word == flag {
                guard index < words.count else { return fail("\(flag) needs a value", hint: hint) }
                output = words.remove(at: index)
            } else {
                output = String(word.dropFirst(flag.count + 1))
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
    func call(_ words: [String]) async -> Int32 {
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

    /// Runs the tool and prints its answer; images, audio and files in it are saved (see Saving),
    /// and printed as where they went. A tool turned off in the settings window's Tools tab is
    /// refused here too: agents set up with the skill run these commands.
    func execute(_ tool: Tool, _ arguments: [String: JSON], hint: String, output: String?) async -> Int32 {
        if let refusal = AppSettings.exposure.refusal(tool, among: tools) { return fail(cli.reword(refusal), status: 1) }
        let answer: ToolAnswer
        do {
            answer = try await tool.run(arguments)
        } catch let error as BadInput {
            return fail(cli.reword(error.description), hint: hint)
        } catch {
            answer = ToolAnswer("\(error)", failed: true)
        }
        let lines: [String]
        switch cli.saving {
        case .everything:
            guard let saved = saveEverything(answer.content, arguments, output) else { return 1 }
            lines = saved
        case .images:
            guard let saved = saveImages(answer.content, arguments, output) else { return 1 }
            lines = saved
        }
        let text = lines.joined(separator: "\n")
        guard !answer.failed else {
            FileHandle.standardError.write(Data((cli.reword(text) + "\n").utf8))
            return 1
        }
        print(text)
        return 0
    }

    /// The answer's lines, with each image, audio clip and file saved in the folder `output` (or the
    /// temporary folder); nil when one cannot be saved, which has been said.
    func saveEverything(_ contents: [Content], _ arguments: [String: JSON], _ output: String?) -> [String]? {
        var lines: [String] = []
        let saved = contents.filter { if case .text = $0 { false } else { true } }.count
        let folder = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let id = (arguments["id"]?.string ?? "attachment").map { $0.isLetter || $0.isNumber ? $0 : "-" }
        var number = 0
        for content in contents {
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
            let url = folder.appendingPathComponent("\(Product.current.serverName)-\(String(id))\(saved > 1 ? "-\(number)" : "").\(fileExtension)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try file.data.write(to: url, options: .atomic)
                lines.append("Saved to \(url.path)")
            } catch {
                _ = fail("cannot save to \(url.path): \(error.localizedDescription)", status: 1)
                return nil
            }
        }
        return lines
    }

    /// The answer's lines, with each image saved to the file `output` (or one in the temporary
    /// folder); nil when one cannot be saved, which has been said.
    func saveImages(_ contents: [Content], _ arguments: [String: JSON], _ output: String?) -> [String]? {
        var lines: [String] = []
        for content in contents {
            switch content {
            case .text(let text):
                lines.append(text)
            case .image(let data, let mime):
                let id = (arguments["image_id"]?.string ?? "image").map { $0.isLetter || $0.isNumber ? $0 : "-" }
                let fileExtension = ["image/png": "png", "image/heic": "heic", "image/gif": "gif"][mime] ?? "jpg"
                let url = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent("\(Product.current.serverName)-\(String(id)).\(fileExtension)")
                do {
                    try data.write(to: url, options: .atomic)
                    lines.append("Saved to \(url.path)")
                } catch {
                    _ = fail("cannot save the image to \(url.path): \(error.localizedDescription)", status: 1)
                    return nil
                }
            case .audio, .file:
                continue
            }
        }
        return lines
    }

    func fail(_ message: String, hint: String? = nil, status: Int32 = 2) -> Int32 {
        FileHandle.standardError.write(Data("\(program): \(message)\n\(hint.map { "See: \($0)\n" } ?? "")".utf8))
        return status
    }

    // MARK: Help

    func help(_ route: Route, _ flags: Flags) -> String {
        flags.help(command: "\(program) \(route.command)", about: [route.about + ".", route.detail].compactMap { $0 }.joined(separator: " "),
                   extra: route.extra)
    }

    /// `help`, `help NOUN`, `help NOUN VERB`.
    func help(_ words: [String]) -> Int32 {
        guard let noun = words.first else {
            print(tree())
            return 0
        }
        guard cli.nouns.contains(noun) else {
            if ["agents", "setup", "skill", "call"].contains(noun) {
                print(tree())
                return 0
            }
            return fail("unknown command \"\(noun)\"", hint: "\(program) help")
        }
        guard words.count > 1 else {
            print(tree(only: noun))
            return 0
        }
        guard let route = cli.routes.first(where: { $0.noun == noun && $0.verb == words[1] }), let tool = tools.first(where: { $0.name == route.tool })
        else { return fail("\(noun) has no command \"\(words[1])\"", hint: "\(program) help \(noun)") }
        print(help(route, route.flags(tool)))
        return 0
    }

    /// Everything the program takes, as a tree; `only` limits it to one noun's commands.
    func tree(only: String? = nil) -> String {
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
        let nouns = cli.nouns
        var groups: [(name: String, rows: [(label: String, about: String, flags: [String])])] = []
        if only == nil {
            groups.append(("", [
                ("--stdio", "Serve MCP on stdin and stdout (what agents start)", []),
                ("--settings", "Open the settings window (also what opening the app does)", []),
                ("--self-check", "Print a diagnosis", []),
                ("--version", "Print the version", []),
                ("help [COMMAND…]", "This tree, or a command's flags (also --help, -h)", []),
                ("setup", cli.setupAbout, []),
                ("skill", "Print the SKILL.md that teaches an agent this command line", []),
            ]))
            groups.append(("agents", [
                ("list", "Which agents are here and set up (the default)", ["[--skill]", "[--folder DIR]"]),
                ("set-up (ID… | --all)", "Register the server with them, or install the skill", ["[--restart]", "[--skill]", "[--folder DIR]"]),
                ("install ID…", "Install them, then set them up", ["[--dry-run]", "[--restart]", "[--skill]", "[--folder DIR]"]),
            ]))
        }
        for noun in nouns where only == nil || only == noun {
            groups.append((noun, cli.routes.filter { $0.noun == noun }.map { route in
                let flags = tools.first { $0.name == route.tool }.map(route.flags)
                let label = [route.verb, flags?.requiredUsage ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
                let about = route.about + (cli.defaultVerbs[noun] == route.verb ? " (the default)" : "")
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
        lines.append("Every \(only ?? cli.nounsSummary ?? nouns.joined(separator: ", ")) command also takes --json OBJECT (or --json - for stdin) and --help.")
        lines.append("Flags: --no-NAME turns a flag off\(cli.clears ? " or clears a field" : ""); a flag ending in … repeats.")
        if only == nil {
            lines.append("Output is the tool's \(cli.answer). Exit status: 1 the request failed (reason on stderr), 2 a wrong command or flag.")
        }
        return lines.joined(separator: "\n")
    }
}
