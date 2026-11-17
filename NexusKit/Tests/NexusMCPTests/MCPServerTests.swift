import Foundation
import NexusCore
import Synchronization
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

        if name == "slow" {
            try? await Task.sleep(for: .milliseconds(300))
        }

        return (try? .value(["agent": agent ?? "", "site": arguments["site"]?.string ?? ""])) ?? .error("no value")
    }

    func knows(_ name: String) -> Bool {
        ["site_info", "wait", "slow", "remove_site"].contains(name)
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
        #expect(result?["ttlMs"] == 0)
        #expect(result?["cacheScope"] == "private")
    }

    @Test func aModernToolListMustNotBeKept() async {
        let lines = await run([#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#])

        #expect(lines.first?["result"]?["ttlMs"] == 0)
        #expect(lines.first?["result"]?["cacheScope"] == "private")
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

    @Test func aLineFeedOnlyEndsAMessage() async {
        let input = MCPInput(unread: Data("{\"a\":\"x\u{2028}y\"}\n{\"b\":1}\r\nlast".utf8))
        var lines: [String] = []

        input.add([])

        while let line = await input.nextLine() {
            lines.append(line)
            input.release()
        }

        #expect(lines == ["{\"a\":\"x\u{2028}y\"}", "{\"b\":1}\r", "last"])
    }

    private static let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"claude-code"}}}"#
    private static let initialized = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
    private static let status = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"site_info","arguments":{"site":"shop.test"}}}"#
    private static let ping = #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#

    @Test func theInputKeepsEachLineUntilTheServerHandledIt() async {
        let input = MCPInput(unread: Data("one\ntw".utf8))

        let first = await input.nextLine()
        let withOpenLine = input.withUnread { $0 }
        input.hold()
        input.add(Array("o\nthree".utf8))
        let second = await input.nextLine()
        input.release()
        let withHeldLine = input.withUnread { $0 }
        let held = input.takeHeld()
        input.add([])
        let third = await input.nextLine()
        input.release()
        let end = await input.nextLine()

        #expect(first == "one")
        #expect(withOpenLine == Data("one\ntw".utf8))
        #expect(second == "two")
        #expect(withHeldLine == Data("one\nthree".utf8))
        #expect(held == ["one"])
        #expect(third == "three")
        #expect(end == nil)
        #expect(input.withUnread { $0 }.isEmpty)
    }

    @Test func aLineWaitsForItsEnd() async {
        let input = MCPInput()
        let next = Task { await input.nextLine() }

        try? await Task.sleep(for: .milliseconds(50))
        input.add(Array("{\"a\":".utf8))
        try? await Task.sleep(for: .milliseconds(50))
        input.add(Array("1}\n".utf8))

        #expect(await next.value == "{\"a\":1}")
    }

    private func newBuild(_ program: TestProgram, started: Shared<[MCPResume]>, missingWait: Duration = .milliseconds(100), onStart: @escaping @Sendable () -> Void = {}) throws -> MCPRestart {
        MCPRestart(file: try #require(ExecutableFile(path: program.path)), missingWait: missingWait) { _, resume in
            onStart()
            started.change { $0.append(resume) }
        }
    }

    @Test func aCancelOfAHeldRequestKeepsItFromTheNewBuild() async throws {
        let program = try TestProgram()
        defer { program.removeFolder() }
        let output = Shared<[JSONValue]>([])
        let server = MCPServer(handler: FakeHandler(), name: "nexus", version: "0.6.5") { data in output.change { $0.append(Self.message(data)) } }
        let input = MCPInput(unread: Data(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"slow"}}"#.utf8 + [0x0A]))
        let started = Shared<[MCPResume]>([])
        let restart = try newBuild(program, started: started)
        let serving = Task { await server.serve(input, restart: restart) }
        let held = #"{"jsonrpc":"2.0","id":4,"method":"ping"}"#

        try? await Task.sleep(for: .milliseconds(50))
        try program.replace()
        input.add(Array("\(Self.ping)\n\(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#)\n\(held)\n".utf8))
        input.add([])
        await serving.value

        #expect(started.value == [MCPResume(agent: nil, input: Data("\(held)\n".utf8))])
        #expect(output.value.map { $0["id"] } == [5, 4])
    }

    @Test func theCheckWaitsAShortTimeForAMissingFile() async throws {
        let program = try TestProgram()
        defer { program.removeFolder() }
        let restart = try newBuild(program, started: Shared([]), missingWait: .seconds(5))

        try program.remove()
        let check = Task { await restart.isNeeded() }
        try await Task.sleep(for: .milliseconds(300))
        try Data("new".utf8).write(to: URL(filePath: program.path))

        #expect(await check.value)
    }

    @Test func aChangedFileGivesTheNewBuildTheClientTheRequestAndTheRestOfTheInput() async throws {
        let program = try TestProgram()
        defer { program.removeFolder() }
        let output = Shared<[JSONValue]>([])
        let server = MCPServer(handler: FakeHandler(), name: "nexus", version: "0.6.5") { data in output.change { $0.append(Self.message(data)) } }
        let input = MCPInput(unread: Data("\(Self.initialize)\n\(Self.initialized)\n".utf8))
        let started = Shared<[MCPResume]>([])
        let restart = try newBuild(program, started: started)
        let serving = Task { await server.serve(input, restart: restart) }

        _ = await waitFor { output.value.count == 1 }
        try program.replace()
        input.add(Array("\(Self.status)\n\(Self.ping)\n{\"jsonrpc\":".utf8))
        input.add([])
        await serving.value

        #expect(started.value == [MCPResume(agent: "claude-code", input: Data("\(Self.status)\n\(Self.ping)\n{\"jsonrpc\":".utf8))])
        #expect(output.value.first { $0["id"] == 2 }?["result"]?["structuredContent"]?["agent"] == "claude-code")
        #expect(output.value.contains { $0["id"] == 3 })
    }

    @Test func aNotificationStartsNoNewBuild() async throws {
        let program = try TestProgram()
        defer { program.removeFolder() }
        let server = MCPServer(handler: FakeHandler(), name: "nexus", version: "0.6.5") { _ in }
        let input = MCPInput(unread: Data("\(Self.initialized)\n".utf8))
        let started = Shared<[MCPResume]>([])
        let restart = try newBuild(program, started: started)

        try program.replace()
        input.add([])
        await server.serve(input, restart: restart)

        #expect(started.value.isEmpty)
    }

    @Test func theNewBuildStartsAfterTheAnswerOfEachRequestThatRuns() async throws {
        let program = try TestProgram()
        defer { program.removeFolder() }
        let output = Shared<[JSONValue]>([])
        let server = MCPServer(handler: FakeHandler(), name: "nexus", version: "0.6.5") { data in output.change { $0.append(Self.message(data)) } }
        let input = MCPInput(unread: Data(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"slow"}}"#.utf8 + [0x0A]))
        let answersAtStart = Shared<Int?>(nil)
        let restart = try newBuild(program, started: Shared([])) {
            answersAtStart.change { $0 = output.value.count }
        }
        let serving = Task { await server.serve(input, restart: restart) }

        try? await Task.sleep(for: .milliseconds(50))
        try program.replace()
        input.add(Array("\(Self.ping)\n".utf8))
        input.add([])
        await serving.value

        #expect(answersAtStart.value == 1)
        #expect(output.value.map { $0["id"] } == [5, 3])
    }

    @Test func aCancelDuringTheWaitForTheNewBuildReachesTheRunningRequest() async throws {
        let program = try TestProgram()
        defer { program.removeFolder() }
        let output = Shared<[JSONValue]>([])
        let server = MCPServer(handler: FakeHandler(), name: "nexus", version: "0.6.5") { data in output.change { $0.append(Self.message(data)) } }
        let input = MCPInput(unread: Data(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"wait"}}"#.utf8 + [0x0A]))
        let started = Shared<[MCPResume]>([])
        let restart = try newBuild(program, started: started)
        let serving = Task { await server.serve(input, restart: restart) }
        let begin = ContinuousClock.now

        try? await Task.sleep(for: .milliseconds(50))
        try program.replace()
        input.add(Array("\(Self.ping)\n\(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9}}"#)\n".utf8))
        input.add([])
        await serving.value

        #expect(ContinuousClock.now - begin < .seconds(10))
        #expect(started.value == [MCPResume(agent: nil, input: Data("\(Self.ping)\n".utf8))])
        #expect(output.value.map { $0["id"] } == [3])
    }

    @Test func aFailedStartIsTriedAgainOnlyForANewFile() async throws {
        let program = try TestProgram()
        defer { program.removeFolder() }
        let output = Shared<[JSONValue]>([])
        let server = MCPServer(handler: FakeHandler(), name: "nexus", version: "0.6.5") { data in output.change { $0.append(Self.message(data)) } }
        let input = MCPInput()
        let started = Shared<[MCPResume]>([])
        let restart = try newBuild(program, started: started)
        let serving = Task { await server.serve(input, restart: restart) }

        try program.replace()
        input.add(Array(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#.utf8 + [0x0A]))
        _ = await waitFor { output.value.count == 1 }
        let failed = restart.startFailed
        input.add(Array(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#.utf8 + [0x0A]))
        _ = await waitFor { output.value.count == 2 }
        try program.replace()
        let afterTheNewFile = restart.startFailed
        input.add(Array(#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#.utf8 + [0x0A]))
        input.add([])
        await serving.value

        #expect(failed)
        #expect(!afterTheNewFile)
        #expect(started.value.count == 2)
        #expect(output.value.map { $0["id"] } == [3, 4, 5])
    }

    @Test func aMissingFileStartsNoNewBuild() async throws {
        let program = try TestProgram()
        defer { program.removeFolder() }
        let server = MCPServer(handler: FakeHandler(), name: "nexus", version: "0.6.5") { _ in }
        let input = MCPInput(unread: Data("\(Self.ping)\n".utf8))
        let started = Shared<[MCPResume]>([])
        let restart = try newBuild(program, started: started)

        try program.remove()
        input.add([])
        await server.serve(input, restart: restart)

        #expect(started.value.isEmpty)
    }

    @Test func theNewBuildKnowsTheClientWithoutASecondInitialize() async {
        let output = Shared<[JSONValue]>([])
        let server = MCPServer(handler: FakeHandler(), name: "nexus", version: "0.6.5", agent: "claude-code") { data in output.change { $0.append(Self.message(data)) } }
        let input = MCPInput(unread: Data("\(Self.status)\n".utf8))

        input.add([])
        await server.serve(input, restart: nil)

        #expect(output.value.first?["result"]?["structuredContent"]?["agent"] == "claude-code")
    }

    private static func message(_ data: Data) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }

    @Test func theStateGoesThroughTheEnvironment() throws {
        let resume = MCPResume(agent: "claude-code", input: Data("\(Self.status)\n".utf8))

        let value = try #require(resume.environmentValue)

        #expect(MCPResume(environmentValue: value) == resume)
        #expect(MCPResume(environmentValue: "not base64") == nil)
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)

        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }

            try? await Task.sleep(for: .milliseconds(10))
        }

        return false
    }
}

private struct TestProgram {
    let folder = FileManager.default.temporaryDirectory.appending(path: "Nexus MCP Program \(UUID().uuidString)", directoryHint: .isDirectory)

    var path: String {
        folder.appending(path: "nexus").path(percentEncoded: false)
    }

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: URL(filePath: path))
    }

    func replace() throws {
        let update = folder.appending(path: "nexus.new")
        try Data(UUID().uuidString.utf8).write(to: update)
        _ = try FileManager.default.replaceItemAt(URL(filePath: path), withItemAt: update)
    }

    func remove() throws {
        try FileManager.default.removeItem(atPath: path)
    }

    func removeFolder() {
        try? FileManager.default.removeItem(at: folder)
    }
}

private final class Shared<Value: Sendable>: Sendable {
    private let stored: Mutex<Value>

    init(_ value: Value) {
        stored = Mutex(value)
    }

    var value: Value {
        stored.withLock { $0 }
    }

    func change(_ body: (inout Value) -> Void) {
        stored.withLock { body(&$0) }
    }
}
