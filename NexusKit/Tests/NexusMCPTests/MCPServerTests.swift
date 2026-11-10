import Foundation
import Testing
@testable import NexusMCP

private struct FakeHandler: MCPHandler {
    func instructions(agent: String?) async -> String {
        "Instructions for \(agent ?? "nobody")"
    }

    func tools(agent: String?) async -> [MCPTool] {
        [MCPTool(name: "site_info", title: "Site info", description: "Info", inputSchema: ["type": "object"], readOnly: true, destructive: false)]
    }

    func call(_ name: String, arguments: [String: JSONValue], agent: String?) async -> MCPToolResult {
        if name == "wait" {
            try? await Task.sleep(for: .seconds(30))
            return .error("stopped")
        }

        return (try? .value(["agent": agent ?? "", "site": arguments["site"]?.string ?? ""])) ?? .error("no value")
    }

    func knows(_ name: String) -> Bool {
        ["site_info", "wait", "remove_site"].contains(name)
    }
}

private actor Output {
    var lines: [JSONValue] = []

    func write(_ data: Data) {
        #expect(data.last == 0x0A)
        #expect(data.dropLast().contains(0x0A) == false)
        lines.append(try! JSONDecoder().decode(JSONValue.self, from: data))
    }
}

struct MCPServerTests {
    private func run(_ messages: [String]) async -> [JSONValue] {
        let output = Output()
        let server = MCPServer(handler: FakeHandler(), name: "nexus", version: "0.3.0") { await output.write($0) }

        for message in messages {
            await server.receive(message)
        }

        await server.waitForRequests()
        return await output.lines
    }

    @Test func aLegacyClientGetsTheVersionThatItAsksFor() async {
        let lines = await run([#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1"}}}"#])

        #expect(lines.first?["id"] == 1)
        #expect(lines.first?["result"]?["protocolVersion"] == "2025-06-18")
        #expect(lines.first?["result"]?["serverInfo"]?["name"] == "nexus")
        #expect(lines.first?["result"]?["instructions"] == "Instructions for claude-code")
        #expect(lines.first?["result"]?["capabilities"]?["tools"] != nil)
        #expect(lines.first?["result"]?["resultType"] == nil)
    }

    @Test func anUnknownLegacyVersionGetsTheNewestLegacyVersion() async {
        let lines = await run([#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#])

        #expect(lines.first?["result"]?["protocolVersion"] == "2025-11-25")
    }

    @Test func aLegacyClientKeepsItsNameForLaterCalls() async {
        let lines = await run([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"codex"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        ])
        let call = await run([#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"site_info","arguments":{"site":"shop.test"}}}"#])

        #expect(lines.count == 1)
        #expect(call.first?["result"]?["structuredContent"]?["site"] == "shop.test")
        #expect(call.first?["result"]?["isError"] == false)
    }

    @Test func aModernClientDiscoversTheServer() async {
        let lines = await run([#"{"jsonrpc":"2.0","id":"d1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"claude-code","version":"2.1.322"},"io.modelcontextprotocol/clientCapabilities":{}}}}"#])
        let result = lines.first?["result"]

        #expect(lines.first?["id"] == "d1")
        #expect(result?["supportedVersions"] == ["2026-07-28"])
        #expect(result?["resultType"] == "complete")
        #expect(result?["instructions"] == "Instructions for claude-code")
        #expect(result?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == "nexus")
    }

    @Test func aModernRequestCarriesTheNameOfTheClient() async {
        let lines = await run([#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"site_info","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"cursor"},"io.modelcontextprotocol/clientCapabilities":{}}}}"#])

        #expect(lines.first?["result"]?["structuredContent"]?["agent"] == "cursor")
        #expect(lines.first?["result"]?["resultType"] == "complete")
    }

    @Test func anUnknownModernVersionNamesTheSupportedVersions() async {
        let lines = await run([#"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}"#])
        let error = lines.first?["error"]

        #expect(error?["code"] == -32022)
        #expect(error?["data"]?["supported"] == ["2026-07-28", "2025-11-25"])
        #expect(error?["data"]?["requested"] == "1900-01-01")
    }

    @Test func toolsListGivesTheAnnotations() async {
        let lines = await run([#"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#])
        let tool = lines.first?["result"]?["tools"].flatMap { value -> JSONValue? in
            guard case .array(let tools) = value else {
                return nil
            }

            return tools.first
        }

        #expect(tool?["name"] == "site_info")
        #expect(tool?["annotations"]?["readOnlyHint"] == true)
        #expect(tool?["annotations"]?["openWorldHint"] == false)
    }

    @Test func anUnknownMethodIsAnError() async {
        let lines = await run([#"{"jsonrpc":"2.0","id":6,"method":"prompts/list"}"#])

        #expect(lines.first?["error"]?["code"] == -32601)
    }

    @Test func anUnknownToolIsAnErrorOfTheProtocol() async {
        let lines = await run([#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"drop_database"}}"#])

        #expect(lines.first?["error"]?["code"] == -32602)
    }

    @Test func aBadMessageGivesAParseError() async {
        let lines = await run(["{not json", ""])

        #expect(lines.count == 1)
        #expect(lines.first?["error"]?["code"] == -32700)
        #expect(lines.first?["id"] == .null)
    }

    @Test func anIdThatStillRunsIsRefused() async {
        let lines = await run([
            #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"wait"}}"#,
            #"{"jsonrpc":"2.0","id":11,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":11}}"#,
        ])

        #expect(lines.count == 1)
        #expect(lines.first?["error"]?["code"] == -32600)
    }

    @Test func anIdOutsideTheRangeOfAnIntegerIsRefused() async {
        let lines = await run([#"{"jsonrpc":"2.0","id":1e20,"method":"ping"}"#])

        #expect(lines.first?["error"]?["code"] == -32600)
    }

    @Test func pingAnswersAnEmptyResult() async {
        let lines = await run([#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#])

        #expect(lines.first?["result"] == [:])
    }

    @Test func aCancelledRequestGetsNoAnswer() async {
        let lines = await run([
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"wait"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9}}"#,
            #"{"jsonrpc":"2.0","id":10,"method":"ping"}"#,
        ])

        #expect(lines.count == 1)
        #expect(lines.first?["id"] == 10)
    }

    @Test func aLineFeedOnlyEndsAMessage() async throws {
        let text = "{\"a\":\"x\u{2028}y\"}\n{\"b\":1}\r\nlast"
        var lines: [String] = []

        for try await line in LineReader(AsyncStream { continuation in
            Array(text.utf8).forEach { continuation.yield($0) }
            continuation.finish()
        }) {
            lines.append(line)
        }

        #expect(lines == ["{\"a\":\"x\u{2028}y\"}", "{\"b\":1}\r", "last"])
    }
}
