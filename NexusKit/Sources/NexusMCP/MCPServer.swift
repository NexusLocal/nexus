import Foundation

// A tool as tools/list gives it. The client adds mcp__nexus__ in front of the name itself.
public struct MCPTool: Sendable, Equatable {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: JSONValue
    public let readOnly: Bool
    public let destructive: Bool

    public init(name: String, title: String, description: String, inputSchema: JSONValue, readOnly: Bool, destructive: Bool) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.destructive = destructive
    }

    // Nexus serves only this Mac. So no tool reaches the open world.
    var definition: JSONValue {
        var annotations: [String: JSONValue] = [
            "title": .string(title),
            "readOnlyHint": .bool(readOnly),
            "openWorldHint": false,
        ]

        if !readOnly {
            annotations["destructiveHint"] = .bool(destructive)
        }

        return [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": .object(annotations),
        ]
    }
}

// The answer of a tool. A result has the JSON as structured content and as text, because some
// clients read only the text. An error is a sentence that says what to do.
public struct MCPToolResult: Sendable, Equatable {
    public let text: String
    public let structured: JSONValue?
    public let isError: Bool

    public init(text: String, structured: JSONValue?, isError: Bool = false) {
        self.text = text
        self.structured = structured
        self.isError = isError
    }

    public static func value(_ value: some Encodable) throws -> MCPToolResult {
        let data = try JSONEncoder.mcp.encode(value)
        return MCPToolResult(text: String(decoding: data, as: UTF8.self), structured: try JSONDecoder().decode(JSONValue.self, from: data))
    }

    public static func error(_ message: String) -> MCPToolResult {
        MCPToolResult(text: message, structured: nil, isError: true)
    }

    var json: JSONValue {
        var result: [String: JSONValue] = [
            "content": [["type": "text", "text": .string(text)]],
            "isError": .bool(isError),
        ]

        if let structured {
            result["structuredContent"] = structured
        }

        return .object(result)
    }
}

// What the Nexus part of the server answers. agent is the name of the client, for example
// claude-code, or nil when the client gives none.
public protocol MCPHandler: Sendable {
    func instructions(agent: String?) async -> String
    func tools(agent: String?) async -> [MCPTool]
    func call(_ name: String, arguments: [String: JSONValue], agent: String?) async -> MCPToolResult
    // True for each tool of Nexus, also for one that the access level does not offer now. A call
    // of such a tool gives a result that says why. It does not give the error of an unknown tool.
    func knows(_ name: String) -> Bool
}

// The JSON-RPC id of a request: a number or a string.
enum MCPRequestID: Hashable, Sendable {
    case int(Int)
    case string(String)

    init?(_ value: JSONValue?) {
        switch value {
        case .int(let number): self = .int(number)
        case .string(let text): self = .string(text)
        case .double(let number):
            guard let whole = Int(exactly: number) else {
                return nil
            }

            self = .int(whole)
        default: return nil
        }
    }

    var json: JSONValue {
        switch self {
        case .int(let number): .int(number)
        case .string(let text): .string(text)
        }
    }
}

public struct MCPError: Error, Equatable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let unsupportedProtocolVersion = -32022
}

// The MCP server over one line for each message (stdio). It speaks two eras of the protocol. A
// legacy client opens with initialize (2025-11-25 and older). A modern client (2026-07-28) puts the
// version, its name and its capabilities in _meta of each request and can ask server/discover.
// Each request runs in its own task. A wait for a mail then does not hold back a ping.
// notifications/cancelled stops the task of its request.
public actor MCPServer {
    public static let modernVersions = ["2026-07-28"]
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static let protocolVersionKey = "io.modelcontextprotocol/protocolVersion"
    static let clientInfoKey = "io.modelcontextprotocol/clientInfo"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"

    private let handler: any MCPHandler
    private let name: String
    private let version: String
    private let write: @Sendable (Data) async -> Void
    private var legacyAgent: String?
    private var running: [MCPRequestID: Task<Void, Never>] = [:]
    private var cancelled: Set<MCPRequestID> = []

    public init(handler: any MCPHandler, name: String, version: String, write: @escaping @Sendable (Data) async -> Void) {
        self.handler = handler
        self.name = name
        self.version = version
        self.write = write
    }

    // Reads messages until the input ends. A client can close the input after its last request,
    // so the open requests still get their answer. The longest one waits 50 seconds for a mail.
    public func serve<Lines: AsyncSequence>(_ lines: Lines) async throws where Lines.Element == String {
        for try await line in lines {
            await receive(line)
        }

        await waitForRequests()
    }

    public func waitForRequests() async {
        while let task = running.values.first {
            await task.value
        }
    }

    public func receive(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return
        }

        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)), case .object(let fields) = message else {
            await send(error: MCPError(code: MCPError.parseError, message: "The message is not valid JSON."), id: nil)
            return
        }

        guard let method = fields["method"]?.string else {
            // A response of the client. This server sends no requests. So it waits for none.
            if fields["result"] == nil, fields["error"] == nil {
                await send(error: MCPError(code: MCPError.invalidRequest, message: "The message has no method."), id: MCPRequestID(fields["id"]))
            }

            return
        }

        let params = fields["params"]?.object ?? [:]

        guard let rawID = fields["id"] else {
            notify(method, params: params)
            return
        }

        guard let id = MCPRequestID(rawID) else {
            await send(error: MCPError(code: MCPError.invalidRequest, message: "The id must be a whole number or a string."), id: nil)
            return
        }

        guard running[id] == nil else {
            await send(error: MCPError(code: MCPError.invalidRequest, message: "A request with this id still runs."), id: id)
            return
        }

        running[id] = Task {
            let outcome: Result<JSONValue, MCPError>

            do {
                outcome = .success(try await self.answer(method, params: params))
            } catch let error as MCPError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(MCPError(code: -32603, message: "\(error)"))
            }

            await self.finish(id, with: outcome)
        }
    }

    private func notify(_ method: String, params: [String: JSONValue]) {
        guard method == "notifications/cancelled", let id = MCPRequestID(params["requestId"]) else {
            return
        }

        cancelled.insert(id)
        running[id]?.cancel()
    }

    private func finish(_ id: MCPRequestID, with outcome: Result<JSONValue, MCPError>) async {
        running[id] = nil

        guard cancelled.remove(id) == nil else {
            return
        }

        switch outcome {
        case .success(let result):
            await send(["jsonrpc": "2.0", "id": id.json, "result": result])
        case .failure(let error):
            await send(error: error, id: id)
        }
    }

    private func answer(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        let meta = params["_meta"]?.object ?? [:]
        let modernVersion = meta[Self.protocolVersionKey]?.string

        if method == "initialize" {
            return await initialize(params)
        }

        if let modernVersion, !Self.modernVersions.contains(modernVersion) {
            throw MCPError(
                code: MCPError.unsupportedProtocolVersion,
                message: "Unsupported protocol version",
                data: ["supported": .array((Self.modernVersions + Self.legacyVersions.prefix(1)).map(JSONValue.string)), "requested": .string(modernVersion)]
            )
        }

        if method == "server/discover", modernVersion == nil {
            throw MCPError(code: MCPError.invalidParams, message: "server/discover needs \(Self.protocolVersionKey) in _meta.")
        }

        let agent = meta[Self.clientInfoKey]?["name"]?.string ?? legacyAgent
        var result: [String: JSONValue]

        switch method {
        case "server/discover":
            result = [
                "supportedVersions": .array(Self.modernVersions.map(JSONValue.string)),
                "capabilities": ["tools": [:]],
                "instructions": .string(await handler.instructions(agent: agent)),
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": .array(await handler.tools(agent: agent).map(\.definition))]
        case "tools/call":
            guard let name = params["name"]?.string else {
                throw MCPError(code: MCPError.invalidParams, message: "tools/call needs the name of a tool.")
            }

            guard handler.knows(name) else {
                throw MCPError(code: MCPError.invalidParams, message: "Unknown tool: \(name)")
            }

            result = await handler.call(name, arguments: params["arguments"]?.object ?? [:], agent: agent).json.object ?? [:]
        default:
            throw MCPError(code: MCPError.methodNotFound, message: "Method not found: \(method)")
        }

        guard modernVersion != nil else {
            return .object(result)
        }

        result["resultType"] = "complete"
        result["_meta"] = [Self.serverInfoKey: serverInfo]
        return .object(result)
    }

    // A legacy client gets the version that it asks for when this server knows it, else the
    // newest legacy version. The client then decides if it goes on.
    private func initialize(_ params: [String: JSONValue]) async -> JSONValue {
        let requested = params["protocolVersion"]?.string ?? ""
        let chosen = Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions[0]
        legacyAgent = params["clientInfo"]?["name"]?.string

        return [
            "protocolVersion": .string(chosen),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": serverInfo,
            "instructions": .string(await handler.instructions(agent: legacyAgent)),
        ]
    }

    private var serverInfo: JSONValue {
        ["name": .string(name), "title": "Nexus", "version": .string(version)]
    }

    private func send(error: MCPError, id: MCPRequestID?) async {
        var body: [String: JSONValue] = ["code": .int(error.code), "message": .string(error.message)]
        body["data"] = error.data
        await send(["jsonrpc": "2.0", "id": id?.json ?? .null, "error": .object(body)])
    }

    // The actor writes one whole message at a time. So two answers never mix on the line.
    private func send(_ message: JSONValue) async {
        guard var data = try? JSONEncoder.mcp.encode(message) else {
            return
        }

        data.append(0x0A)
        await write(data)
    }
}
