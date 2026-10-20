import Foundation

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

    var json: JSON {
        switch self {
        case .text(let text): ["type": "text", "text": .string(text)]
        case .image(let data, let mime): ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mime)]
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
/// one at a time, in order.
public final class Service: Sendable {
    public static let sessionVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let statelessVersion = "2026-07-28"
    static let versionKey = "io.modelcontextprotocol/protocolVersion"

    let name: String
    let version: String
    let instructions: String
    let tools: [Tool]

    public init(name: String, version: String, instructions: String, tools: [Tool]) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
    }

    /// The reply to one message, or nil for a notification.
    public func reply(to line: String) async -> String? {
        guard let message = JSON.parse(line), case .object(let fields) = message else {
            return Self.failure(nil, -32700, "Parse error")
        }
        guard fields["jsonrpc"] == "2.0", let method = fields["method"]?.string else {
            return Self.failure(fields["id"], -32600, "Invalid Request")
        }
        guard let id = fields["id"] else { return nil }
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
            case "tools/list": result = ["tools": .array(tools.map(\.listing))]
            case "tools/call": result = try await call(params)
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
        return Self.success(id, .object(completed))
    }

    var serverInfo: JSON { ["name": .string(name), "version": .string(version)] }

    func initialize(_ params: [String: JSON]) -> JSON {
        let asked = params["protocolVersion"]?.string ?? ""
        let agreed = Self.sessionVersions.contains(asked) ? asked : Self.sessionVersions[0]
        return [
            "protocolVersion": .string(agreed), "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": serverInfo, "instructions": .string(instructions),
        ]
    }

    func discover() -> JSON {
        [
            "supportedVersions": [.string(Self.statelessVersion)], "capabilities": ["tools": [:]],
            "serverInfo": serverInfo, "instructions": .string(instructions),
            // The tool set only changes with a new build, which is a new process.
            "ttlMs": 3_600_000, "cacheScope": "public",
        ]
    }

    func call(_ params: [String: JSON]) async throws -> JSON {
        guard let toolName = params["name"]?.string else { throw BadInput("tools/call needs a tool name") }
        guard let tool = tools.first(where: { $0.name == toolName }) else { throw BadInput("There is no tool named \(toolName)") }
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
        let log = ProcessInfo.processInfo.environment["APPLE_REMINDERS_MCP_WIRE_LOG"].flatMap { path -> FileHandle? in
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)
        }
        do {
            for try await line in FileHandle.standardInput.bytes.lines where !line.isEmpty {
                log?.write(Data("<- \(line)\n".utf8))
                guard let reply = await service.reply(to: line) else { continue }
                log?.write(Data("-> \(reply)\n".utf8))
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("apple-reminders-mcp: reading stdin failed: \(error)\n".utf8))
        }
    }
}
