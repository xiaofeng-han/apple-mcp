import Foundation
import Synchronization

/// A bad request: wrong argument types, unknown values, missing fields. Reported to the client
/// as a JSON-RPC error, so the model sees that the call itself was malformed.
public struct BadInput: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// One block of a tool's answer.
public enum Content: Sendable {
    case text(String)
    case image(Data, mimeType: String)
    case audio(Data, mimeType: String)
    /// A file, as an embedded resource.
    case file(Data, uri: String, mimeType: String)

    var json: JSON {
        switch self {
        case .text(let text): ["type": "text", "text": .string(text)]
        case .image(let data, let mime): ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mime)]
        case .audio(let data, let mime): ["type": "audio", "data": .string(data.base64EncodedString()), "mimeType": .string(mime)]
        case .file(let data, let uri, let mime):
            ["type": "resource", "resource": ["uri": .string(uri), "mimeType": .string(mime), "blob": .string(data.base64EncodedString())]]
        }
    }
}

public struct ToolAnswer: Sendable {
    public var content: [Content]
    /// The work failed in a way the model can act on (not found, not allowed, conflict).
    public var failed: Bool

    public init(_ text: String, failed: Bool = false) {
        content = [.text(text)]
        self.failed = failed
    }

    public init(content: [Content], failed: Bool = false) {
        self.content = content
        self.failed = failed
    }
}

public struct Tool: Sendable {
    public enum Effect: Sendable { case reads, writes, deletes }

    public let name: String
    public let title: String
    public let summary: String
    public let input: JSON
    public let effect: Effect
    public let run: @Sendable ([String: JSON]) async throws -> ToolAnswer

    public init(_ name: String, title: String, summary: String, input: JSON, effect: Effect,
                run: @escaping @Sendable ([String: JSON]) async throws -> ToolAnswer) {
        self.name = name
        self.title = title
        self.summary = summary
        self.input = input
        self.effect = effect
        self.run = run
    }

    var listing: JSON {
        [
            "name": .string(name), "title": .string(title), "description": .string(summary), "inputSchema": input,
            "annotations": [
                "title": .string(title), "readOnlyHint": .bool(effect == .reads), "destructiveHint": .bool(effect == .deletes),
                "idempotentHint": .bool(effect == .reads), "openWorldHint": false,
            ],
        ]
    }
}

/// An MCP server over JSON-RPC 2.0. It speaks the session protocol (initialize, then requests;
/// versions 2024-11-05 to 2025-11-25) and the stateless 2026-07-28 protocol, where every request
/// names its version in `_meta` and `server/discover` replaces initialize. Requests are answered
/// one at a time, in order. Tools are listed by name; with an exposure, only the ones the user
/// chose are offered, and the client is told when that changes: a session client with
/// notifications/tools/list_changed, a stateless one on the subscriptions/listen stream it opened.
public final class Service: Sendable {
    public static let sessionVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let statelessVersion = "2026-07-28"
    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let subscriptionKey = "io.modelcontextprotocol/subscriptionId"

    let name: String
    let version: String
    let instructions: String
    let tools: [Tool]
    let exposure: ToolExposure?

    /// What the client has said and been shown, for notifications/tools/list_changed.
    struct Session {
        /// A session client has finished initializing.
        var initialized = false
        /// The tool names the client last listed, or a session client was last told about.
        var known: Set<String>?
        /// A stateless client's subscriptions/listen streams for tool changes, by request id.
        var streams: [JSON: Stream] = [:]
        /// A tools/list reply is on its way; a change goes out after it, never before.
        var listing = false
    }

    struct Stream {
        /// The tool names it was opened with or last told about.
        var told: Set<String>
        /// Its acknowledgment has been written; nothing else may go on it before.
        var open = false
    }

    let session = Mutex(Session())

    public init(name: String, version: String, instructions: String, tools: [Tool], exposure: ToolExposure? = nil) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools.sorted { $0.name < $1.name }
        self.exposure = exposure
    }

    /// The reply to one message, or nil for a notification.
    public func reply(to line: String) async -> String? {
        guard let message = JSON.parse(line), case .object(let fields) = message else {
            return Self.failure(nil, -32700, "Parse error")
        }
        guard fields["jsonrpc"] == "2.0", let method = fields["method"]?.string else {
            return Self.failure(fields["id"], -32600, "Invalid Request")
        }
        guard let id = fields["id"] else {
            switch method {
            case "notifications/initialized": session.withLock { $0.initialized = true }
            case "notifications/cancelled":
                if let request = fields["params"]?["requestId"] { _ = session.withLock { $0.streams.removeValue(forKey: request) } }
            default: break
            }
            return nil
        }
        guard id.string != nil || id.int != nil else { return Self.failure(nil, -32600, "The id must be a string or a number") }
        let params = fields["params"]?.object ?? [:]

        // A stateless request says which protocol it speaks.
        var stateless = false
        if let requested = params["_meta"]?[Self.versionKey]?.string {
            guard requested == Self.statelessVersion else {
                return Self.failure(id, -32022, "Unsupported protocol version",
                                    data: ["supported": [.string(Self.statelessVersion)], "requested": .string(requested)])
            }
            stateless = true
        }

        let result: JSON
        do {
            switch method {
            case "initialize": result = initialize(params)
            case "ping": result = [:]
            case "server/discover": result = discover()
            case "tools/list":
                // Read under the lock, so a change announced meanwhile is not undone. A stdio
                // process serves one client: what it lists is what each of its streams knows.
                // `listing` holds changes back until notices(afterReply:) follows the reply.
                let offered = session.withLock { session in
                    let offered = self.offered().tools
                    let names = Set(offered.map(\.name))
                    session.known = names
                    for id in session.streams.keys { session.streams[id]?.told = names }
                    session.listing = true
                    return offered
                }
                result = ["tools": .array(offered.map(\.listing))]
            case "tools/call": result = try await call(params)
            case "subscriptions/listen" where stateless:
                // Held open with no reply; the acknowledgment goes first, then the changes.
                let wanted = exposure != nil && params["notifications"]?["toolsListChanged"]?.bool == true
                if wanted {
                    session.withLock { session in session.streams[id] = Stream(told: session.known ?? Set(offered().tools.map(\.name))) }
                }
                return Self.notification("notifications/subscriptions/acknowledged", subscription: id,
                                         ["notifications": wanted ? ["toolsListChanged": true] : [:]])
            default: return Self.failure(id, -32601, "Method not found: \(method)")
            }
        } catch let error as BadInput {
            return Self.failure(id, -32602, error.description)
        } catch {
            return Self.failure(id, -32603, "Internal error: \(error)")
        }
        guard stateless, case .object(var completed) = result else { return Self.success(id, result) }
        completed["resultType"] = "complete"
        completed["_meta"] = ["io.modelcontextprotocol/serverInfo": serverInfo]
        if method == "tools/list" {
            // The list follows the user's choice, which can change at any time.
            completed["ttlMs"] = 0
            completed["cacheScope"] = "private"
        }
        return Self.success(id, .object(completed))
    }

    var serverInfo: JSON { ["name": .string(name), "version": .string(version)] }

    /// The tools offered now, and why there are none when the user's choice can't be read.
    func offered() -> (tools: [Tool], problem: String?) {
        guard let exposure else { return (tools, nil) }
        do {
            return (try exposure.offered(tools), nil)
        } catch {
            return ([], exposure.unreadable(error))
        }
    }

    /// The instructions, and that the user may have turned tools off: the text names some. It never
    /// changes, since clients keep the instructions for as long as they are connected.
    var fullInstructions: String {
        guard let exposure else { return instructions }
        return instructions + "\n\n" + exposure.mayBeTurnedOff
    }

    /// The notifications to send because the tools offered changed since the client last listed
    /// them or was last told: notifications/tools/list_changed to a session client that has
    /// initialized and listed them, and on each subscriptions/listen stream. Call it after writing
    /// each reply with `afterReply`, which opens the streams acknowledged by it, and whenever the
    /// choice may have changed.
    public func notices(afterReply: Bool = false) -> [String] {
        guard exposure != nil else { return [] }
        return session.withLock { session in
            if afterReply {
                for id in session.streams.keys { session.streams[id]?.open = true }
                session.listing = false
            } else if session.listing {
                return []
            }
            let streams = session.streams.filter(\.value.open).keys.sorted { $0.text < $1.text }
            guard (session.initialized && session.known != nil) || !streams.isEmpty else { return [] }
            let now = Set(offered().tools.map(\.name))
            var notices: [String] = []
            if session.initialized, let known = session.known, known != now {
                session.known = now
                notices.append(JSON.object(["jsonrpc": "2.0", "method": "notifications/tools/list_changed"]).text)
            }
            for id in streams where session.streams[id]?.told != now {
                session.streams[id]?.told = now
                notices.append(Self.notification("notifications/tools/list_changed", subscription: id))
            }
            return notices
        }
    }

    func initialize(_ params: [String: JSON]) -> JSON {
        let asked = params["protocolVersion"]?.string ?? ""
        let agreed = Self.sessionVersions.contains(asked) ? asked : Self.sessionVersions[0]
        return [
            "protocolVersion": .string(agreed), "capabilities": ["tools": ["listChanged": .bool(exposure != nil)]],
            "serverInfo": serverInfo, "instructions": .string(fullInstructions),
        ]
    }

    func discover() -> JSON {
        [
            "supportedVersions": [.string(Self.statelessVersion)], "capabilities": ["tools": ["listChanged": .bool(exposure != nil)]],
            "serverInfo": serverInfo, "instructions": .string(fullInstructions),
            // This only changes with a new build, which is a new process.
            "ttlMs": 3_600_000, "cacheScope": "public",
        ]
    }

    func call(_ params: [String: JSON]) async throws -> JSON {
        guard let toolName = params["name"]?.string else { throw BadInput("tools/call needs a tool name") }
        guard let tool = tools.first(where: { $0.name == toolName }) else { throw BadInput("There is no tool named \(toolName)") }
        if let exposure {
            let (offered, problem) = offered()
            if let problem { throw BadInput(problem) }
            guard offered.contains(where: { $0.name == toolName }) else { throw BadInput(exposure.turnedOff(toolName)) }
        }
        let arguments: [String: JSON]
        switch params["arguments"] {
        case nil, .null?: arguments = [:]
        case .object(let fields)?: arguments = fields
        default: throw BadInput("Tool arguments must be an object")
        }
        let answer: ToolAnswer
        do {
            answer = try await tool.run(arguments)
        } catch let error as BadInput {
            throw error
        } catch {
            answer = ToolAnswer("\(error)", failed: true)
        }
        return ["content": .array(answer.content.map(\.json)), "isError": .bool(answer.failed)]
    }

    /// A notification; on a subscriptions/listen stream, tagged with the stream's request id.
    static func notification(_ method: String, subscription: JSON? = nil, _ params: [String: JSON] = [:]) -> String {
        var params = params
        if let subscription { params["_meta"] = [Self.subscriptionKey: subscription] }
        var message: [String: JSON] = ["jsonrpc": "2.0", "method": .string(method)]
        if !params.isEmpty { message["params"] = .object(params) }
        return JSON.object(message).text
    }

    static func success(_ id: JSON, _ result: JSON) -> String {
        JSON.object(["jsonrpc": "2.0", "id": id, "result": result]).text
    }

    static func failure(_ id: JSON?, _ code: Int, _ message: String, data: JSON? = nil) -> String {
        var error: [String: JSON] = ["code": .int(code), "message": .string(message)]
        if let data { error["data"] = data }
        return JSON.object(["jsonrpc": "2.0", "id": id ?? .null, "error": .object(error)]).text
    }
}

/// Serves newline-delimited JSON-RPC on stdin and stdout until stdin closes.
public enum StdioServer {
    public static func run(_ service: Service) async {
        let output = Output(log: ProcessInfo.processInfo.environment["APPLE_NOTES_MCP_WIRE_LOG"])
        let watch = service.exposure.map { exposure in
            FileWatch(exposure.file) { service.notices().forEach(output.send) }
        }
        do {
            for try await line in FileHandle.standardInput.bytes.lines where !line.isEmpty {
                output.received(line)
                guard let reply = await service.reply(to: line) else { continue }
                output.send(reply)
                service.notices(afterReply: true).forEach(output.send)
            }
        } catch {
            FileHandle.standardError.write(Data("apple-notes-mcp: reading stdin failed: \(error)\n".utf8))
        }
        watch?.stop()
    }

    /// stdout, shared by replies and notifications, one whole line at a time; and the wire log.
    final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private let log: FileHandle?

        init(log path: String?) {
            log = path.flatMap { path in
                FileManager.default.createFile(atPath: path, contents: nil)
                return FileHandle(forWritingAtPath: path)
            }
        }

        func received(_ line: String) {
            lock.withLock { log?.write(Data("<- \(line)\n".utf8)) }
        }

        func send(_ line: String) {
            lock.withLock {
                log?.write(Data("-> \(line)\n".utf8))
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            }
        }
    }
}
