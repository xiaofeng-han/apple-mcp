import Foundation

/// Which tools agents may see, as the user chose them: a JSON file that maps tool names to true
/// or false, {"tools": {"create_note": true, "delete_note": false}}. No file means every
/// tool. It is read afresh whenever it is needed, so a change reaches every running server.
///
/// The format only grows: a later version may add top-level keys, but an entry under "tools" always
/// means what it means now. Saving keeps keys and tool names this version does not know.
public struct ToolExposure: Sendable {
    public let file: URL
    /// Where the user changes the choice, for messages to the model ("the Tools tab of …").
    public let changedIn: String

    public init(file: URL, changedIn: String) {
        self.file = file
        self.changedIn = changedIn
    }

    /// A file that is there but is not {"tools": {name: true or false}}.
    public struct Unreadable: Error, CustomStringConvertible, Sendable, Equatable {
        public enum Reason: Sendable, Equatable {
            /// What an edit in place leaves for a moment; offering every tool then would be wrong.
            case empty
            case notJSON
            case wrongShape
            case notTrueOrFalse(String)
            case cannotOpen(String)
        }

        public let reason: Reason

        public init(reason: Reason) { self.reason = reason }

        public var description: String {
            switch reason {
            case .empty: "it is empty"
            case .notJSON: "it is not valid JSON"
            case .wrongShape: #"it needs to be {"tools": {"tool_name": true or false, …}}"#
            case .notTrueOrFalse(let name): "\"\(name)\" needs to be true or false"
            case .cannotOpen(let error): error
            }
        }
    }

    /// The choices in the file; empty when there is no file.
    public func choices() throws -> [String: Bool] {
        try load()?.choices ?? [:]
    }

    /// The whole document and its choices; nil when there is no file.
    private func load() throws -> (document: [String: JSON], choices: [String: Bool])? {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw Unreadable(reason: .cannotOpen(error.localizedDescription))
        }
        let text = String(decoding: data, as: UTF8.self)
        if text.allSatisfy(\.isWhitespace) { throw Unreadable(reason: .empty) }
        guard let parsed = JSON.parse(text) else { throw Unreadable(reason: .notJSON) }
        guard let document = parsed.object, let tools = document["tools"]?.object else { throw Unreadable(reason: .wrongShape) }
        var choices: [String: Bool] = [:]
        for (name, value) in tools {
            guard let exposed = value.bool else { throw Unreadable(reason: .notTrueOrFalse(name)) }
            choices[name] = exposed
        }
        return (document, choices)
    }

    /// Writes `choices` over the ones in the file. A file that can't be read is kept beside it as
    /// tools.json.bak-<date and time>, then replaced; one that can't even be copied is left alone,
    /// and saving fails. Through a symbolic link, the file it points to is written.
    public func save(_ choices: [String: Bool]) throws {
        // resolvingSymlinksInPath leaves a link to a file that isn't there yet alone.
        var target = file
        for _ in 0..<8 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) else { break }
            target = URL(fileURLWithPath: destination, relativeTo: target.deletingLastPathComponent()).standardizedFileURL
        }
        var document: [String: JSON] = [:]
        do {
            document = try load()?.document ?? [:]
        } catch {
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            stamp.locale = Locale(identifier: "en_US_POSIX")
            try FileManager.default.copyItem(at: target, to: target.appendingPathExtension("bak-\(stamp.string(from: Date()))"))
        }
        var tools = document["tools"]?.object ?? [:]
        for (name, exposed) in choices { tools[name] = .bool(exposed) }
        document["tools"] = .object(tools)
        var data = try JSONSerialization.data(withJSONObject: JSON.object(document).any, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    /// Whether `tool` is offered under `choices`. A tool the file does not name (one added by a
    /// later version) is, unless the file turns off another tool with the same effect: after a
    /// read-only choice, new tools that write stay off as well.
    public static func exposes(_ tool: Tool, among tools: [Tool], choices: [String: Bool]) -> Bool {
        if let exposed = choices[tool.name] { return exposed }
        return !tools.contains { $0.effect == tool.effect && choices[$0.name] == false }
    }

    /// The tools offered now, in the order given.
    public func offered(_ tools: [Tool]) throws -> [Tool] {
        let choices = try choices()
        return tools.filter { Self.exposes($0, among: tools, choices: choices) }
    }

    /// Why `tool` may not run now, or nil when it is offered: for the server and the command line,
    /// which both re-read the file first.
    public func refusal(_ tool: Tool, among tools: [Tool]) -> String? {
        do {
            return try offered(tools).contains { $0.name == tool.name } ? nil : turnedOff(tool.name)
        } catch {
            return unreadable(error)
        }
    }

    func turnedOff(_ name: String) -> String {
        "\(name) is turned off. The user can turn it on in \(changedIn)."
    }

    var mayBeTurnedOff: String {
        "The user chooses which of these tools are offered, in \(changedIn). A tool named here that is not in your tool list is turned off there."
    }

    func unreadable(_ error: Error) -> String {
        "No tools are offered: \(file.path) can't be read (\(error)). The user can choose the tools again in \(changedIn), or fix or delete the file."
    }
}
