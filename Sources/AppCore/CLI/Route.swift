import Wire

/// One command: a noun and a verb that run a tool. The command can fill some of the tool's fields
/// itself (a manage tool's action), take others as bare words, and offer the rest as flags (see
/// Flags).
public struct Route: Sendable {
    public let noun: String
    public let verb: String
    public let tool: String
    /// One line, for the command tree and the skill.
    public let about: String
    /// More, for the command's own help.
    public var detail: String?
    public var fixed: [String: JSON] = [:]
    public var positional: [(key: String, label: String)] = []
    /// The fields offered as flags, in order; nil offers all of them.
    public var only: [String]?
    public var required: [String] = []
    /// Whether --no-name clears a field (not when creating, nor in an app whose commands never clear).
    public var clears = true
    /// Flag descriptions in place of the tool's, where its description covers other actions.
    public var abouts: [String: String] = [:]
    /// Fields whose value `-` is read from stdin: Markdown, which runs to many lines.
    public var stdin: [String] = []
    /// Fields set when none of `unless` is given: Notes' overview without filters shows the folder
    /// tree, which `folders list` gives, so `notes list` lists the newest notes instead.
    public var fallback: (fields: [String: JSON], unless: [String]) = ([:], [])
    /// The flag that says where to save what the tool answers with (see Saving), and its help.
    public var output: (flag: String, about: String)?

    public init(noun: String, verb: String, tool: String, about: String, detail: String? = nil, fixed: [String: JSON] = [:],
                positional: [(key: String, label: String)] = [], only: [String]? = nil, required: [String] = [], clears: Bool = true,
                abouts: [String: String] = [:], stdin: [String] = [], fallback: (fields: [String: JSON], unless: [String]) = ([:], []),
                output: (flag: String, about: String)? = nil) {
        self.noun = noun
        self.verb = verb
        self.tool = tool
        self.about = about
        self.detail = detail
        self.fixed = fixed
        self.positional = positional
        self.only = only
        self.required = required
        self.clears = clears
        self.abouts = abouts
        self.stdin = stdin
        self.fallback = fallback
        self.output = output
    }

    public var command: String { "\(noun) \(verb)" }

    public func flags(_ tool: Tool) -> Flags {
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
        output.map { [("\($0.flag) string", $0.about)] } ?? []
    }
}

/// What commands do with the images, audio and files a tool answers with.
public enum Saving: Sendable {
    /// Saves each of them in a folder (the route's output flag, default the temporary folder) as
    /// <serverName>-<id>[-<n>].<extension>, after the `id` argument: Notes' attachments.
    case everything
    /// Saves images only, each to a file (the route's output flag, default
    /// <serverName>-<image_id>.<extension> in the temporary folder): Reminders' images.
    case images
}

/// An app's commands: what the shared command line, `help` and the skill are made from. The
/// wording that differs between the apps is here, so each one's help and skill stay as they were.
public struct CLI: Sendable {
    public let routes: [Route]
    /// The verb each noun runs without one.
    public let defaultVerbs: [String: String]
    /// Fixed changes to the tools' messages, made in order, before tool names become commands.
    public let rewordings: [(String, String)]
    /// What `setup` does, for the command tree.
    public let setupAbout: String
    /// Whether --no-NAME also clears fields; without it, no route clears.
    public let clears: Bool
    /// What commands print, for the command tree: "answer" or "JSON answer".
    public let answer: String
    /// The nouns in the tree's "Every … command" line; nil lists them all.
    public let nounsSummary: String?
    public let saving: Saving
    /// Whether the skill lists the flags a command requires too (its usage names them either way).
    public let skillListsRequired: Bool

    public init(routes: [Route], defaultVerbs: [String: String], rewordings: [(String, String)], setupAbout: String, clears: Bool,
                answer: String, nounsSummary: String?, saving: Saving, skillListsRequired: Bool) {
        self.routes = clears ? routes : routes.map { route in
            var route = route
            route.clears = false
            return route
        }
        self.defaultVerbs = defaultVerbs
        self.rewordings = rewordings
        self.setupAbout = setupAbout
        self.clears = clears
        self.answer = answer
        self.nounsSummary = nounsSummary
        self.saving = saving
        self.skillListsRequired = skillListsRequired
    }

    /// The nouns in order.
    public var nouns: [String] { routes.reduce(into: []) { nouns, route in if !nouns.contains(route.noun) { nouns.append(route.noun) } } }

    /// The tools' messages name tools and fields; commands name commands and flags. Only for
    /// messages: answers hold the user's own text.
    public func reword(_ message: String) -> String {
        var message = message
        for (old, new) in rewordings { message = message.replacingOccurrences(of: old, with: new) }
        // Only names no word could be (they have a _), of tools that one command runs whole.
        for route in routes where route.tool.contains("_") && route.fixed.isEmpty && routes.filter({ $0.tool == route.tool }).count == 1 {
            message = message.replacingOccurrences(of: route.tool, with: defaultVerbs[route.noun] == route.verb ? route.noun : route.command)
        }
        return message
    }
}
