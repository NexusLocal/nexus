import Darwin
import Foundation
import NexusCore
import NexusTestSupport
import Testing
@testable import NexusConfig

private enum RealRuntimes {
    static let folder = ProcessInfo.processInfo.environment["NEXUS_REAL_RUNTIMES"].map { URL(filePath: $0, directoryHint: .isDirectory) }
}

// The real nginx of Nexus Dev with njs, only when NEXUS_REAL_RUNTIMES names the runtimes folder.
@Suite(.serialized, .enabled(if: RealRuntimes.folder != nil), .timeLimit(.minutes(1)))
struct ShareRequestsRealTests {
    private static let id = "0123456789abcdef0123456789abcdef"

    private struct Server {
        let root: URL
        let port: Int
        let log: URL
        let process: Process
    }

    private static func freePort() -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }

        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }

        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func nginx() throws -> URL {
        let runtimes = try #require(RealRuntimes.folder)
        return runtimes.appending(path: "nginx/1.30", directoryHint: .isDirectory)
    }

    private func configuration(root: URL, port: Int, answerPort: Int, log: URL, script: URL) throws -> String {
        let nginx = try Self.nginx()
        var options = ShareOptions.standard
        options.keepsRequests = true
        let share = ShareBlock(id: Self.id, host: "shop.test", port: port, mode: .localHost, options: options, visitorLog: root.appending(path: "visitors.jsonl"), requestLog: log)
        let temp = root.appending(path: "temp", directoryHint: .isDirectory)

        var lines = [
            "load_module \(try ConfigText.quoted(nginx.appending(path: "modules/ngx_http_js_module.so")));",
            "daemon off;",
            "pid \(try ConfigText.quoted(root.appending(path: "nginx.pid")));",
            "error_log stderr warn;",
            "events {",
            "    worker_connections 64;",
            "}",
            "http {",
            "    access_log off;",
            "    client_max_body_size 64M;",
            "    client_body_temp_path \(try ConfigText.quoted(temp.appending(path: "body")));",
            "    proxy_temp_path \(try ConfigText.quoted(temp.appending(path: "proxy")));",
            "    fastcgi_temp_path \(try ConfigText.quoted(temp.appending(path: "fastcgi")));",
            "    uwsgi_temp_path \(try ConfigText.quoted(temp.appending(path: "uwsgi")));",
            "    scgi_temp_path \(try ConfigText.quoted(temp.appending(path: "scgi")));",
        ]

        let settings = NginxSettings(httpPort: 30080, httpsPort: 30443, apachePort: 30081, lanAccess: false, runtime: nginx, runFolder: root.appending(path: "run", directoryHint: .isDirectory), modules: [])
        lines += try ShareConfig.httpLines(for: [share], settings: settings, requestScript: script).map { $0.isEmpty ? "" : "    \($0)" }
        lines += [
            "    server {",
            "        listen 127.0.0.1:\(answerPort);",
            "        location / {",
            "            default_type application/json;",
            "            add_header Set-Cookie \"session=answer-secret\";",
            "            return 200 '{\"received\":true}';",
            "        }",
            "    }",
            "    server {",
            "        listen 127.0.0.1:\(port);",
        ]
        lines += ShareRequests.lines(for: share).map { "        \($0)" }
        lines += [
            "        location / {",
            "            proxy_pass http://127.0.0.1:\(answerPort);",
            "        }",
        ]
        lines += try ShareRequests.logLines(for: share).map { "        \($0)" }
        lines += ["    }", "}"]
        return lines.joined(separator: "\n") + "\n"
    }

    private func start() async throws -> Server {
        let root = URL(filePath: "/tmp/nx-\(UUID().uuidString.prefix(8))/App Support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "temp"), withIntermediateDirectories: true)
        let port = Self.freePort()
        let log = root.appending(path: "share-\(Self.id)-requests.jsonl")
        let script = root.appending(path: "requests.js")
        let config = root.appending(path: "nginx.conf")
        try Data(ShareRequests.script.utf8).write(to: script)
        try Data(try configuration(root: root, port: port, answerPort: Self.freePort(), log: log, script: script).utf8).write(to: config)

        let binary = try Self.nginx().appending(path: "sbin/nginx")
        let check = try run(binary, ["-t", "-p", root.path(percentEncoded: false), "-c", config.path(percentEncoded: false), "-e", "stderr"])
        #expect(check.status == 0, "\(check.output)")

        let process = Process()
        process.executableURL = binary
        process.arguments = ["-p", root.path(percentEncoded: false), "-c", config.path(percentEncoded: false), "-e", "stderr"]
        process.standardError = FileHandle.nullDevice
        try process.run()

        for _ in 0..<100 where !accepts(port) {
            try await Task.sleep(for: .milliseconds(50))
        }

        return Server(root: root, port: port, log: log, process: process)
    }

    private func stop(_ server: Server) {
        server.process.terminate()
        server.process.waitForEnd()
        try? FileManager.default.removeItem(at: server.root.deletingLastPathComponent())
    }

    private func accepts(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }

        return result == 0
    }

    @discardableResult
    private func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    private func lines(of server: Server, count: Int) async throws -> [ShareLogLine] {
        for _ in 0..<100 {
            let text = (try? String(contentsOf: server.log, encoding: .utf8)) ?? ""
            let decoded = try text.split(separator: "\n").map { line in try JSONDecoder().decode(ShareLogLine.self, from: Data(line.utf8)) }

            if decoded.count >= count {
                return decoded
            }

            try await Task.sleep(for: .milliseconds(50))
        }

        return []
    }

    @Test func aPostThroughTheBlockWritesOneLineWithItsDataAndWithoutTheSecrets() async throws {
        let server = try await start()
        defer { stop(server) }

        try run(URL(filePath: "/usr/bin/curl"), [
            "-s", "-o", "/dev/null",
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", "Cookie: session=request-secret",
            "-H", "Authorization: Bearer token-secret",
            "-H", "CF-Connecting-IP: 3.18.12.63",
            "--data-binary", #"{"id":"evt_1Q","type":"payment_intent.succeeded"}"#,
            "http://127.0.0.1:\(server.port)/webhooks/stripe?x=1",
        ])

        let line = try #require(try await lines(of: server, count: 1).first)
        let file = try String(contentsOf: server.log, encoding: .utf8)
        let requestHeaders = Dictionary((line.requestHeaders ?? []).map { ($0[0].lowercased(), $0[1]) }) { first, _ in first }
        let answerHeaders = Dictionary((line.responseHeaders ?? []).map { ($0[0].lowercased(), $0[1]) }) { first, _ in first }

        #expect(line.method == "POST")
        #expect(line.uri == "/webhooks/stripe?x=1")
        #expect(line.status == 200)
        #expect(line.visitor == "3.18.12.63")
        #expect(line.contentType == "application/json")
        #expect(line.body.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } == #"{"id":"evt_1Q","type":"payment_intent.succeeded"}"#)
        #expect(line.bodyBytes == 49)
        #expect(requestHeaders["cookie"] == "Hidden by Nexus")
        #expect(requestHeaders["authorization"] == "Hidden by Nexus")
        #expect(answerHeaders["set-cookie"] == "Hidden by Nexus")
        #expect(answerHeaders["content-type"] == "application/json")
        #expect(!file.contains("secret"))
    }

    @Test func aStaticFileThatLoadsWritesNoLineAndAPageAndAPostDo() async throws {
        let server = try await start()
        defer { stop(server) }

        for path in ["/build/app.css?v=2", "/img/Logo.PNG", "/fonts/a.woff2"] {
            try run(URL(filePath: "/usr/bin/curl"), ["-s", "-o", "/dev/null", "http://127.0.0.1:\(server.port)\(path)"])
        }

        try run(URL(filePath: "/usr/bin/curl"), ["-s", "-o", "/dev/null", "-X", "POST", "--data-binary", "a=1", "http://127.0.0.1:\(server.port)/upload/app.css"])
        try run(URL(filePath: "/usr/bin/curl"), ["-s", "-o", "/dev/null", "http://127.0.0.1:\(server.port)/checkout"])

        let lines = try await lines(of: server, count: 2)

        #expect(lines.map { $0.uri ?? "" } == ["/upload/app.css", "/checkout"])
    }

    @Test func aBodyAboveTheBufferHasOnlyItsSize() async throws {
        let server = try await start()
        defer { stop(server) }
        let body = server.root.appending(path: "large.json")
        try Data(repeating: UInt8(ascii: "a"), count: 2_000_000).write(to: body)

        try run(URL(filePath: "/usr/bin/curl"), ["-s", "-o", "/dev/null", "-X", "POST", "--data-binary", "@\(body.path(percentEncoded: false))", "http://127.0.0.1:\(server.port)/upload"])

        let line = try #require(try await lines(of: server, count: 1).first)

        #expect(line.body == nil)
        #expect(line.bodyBytes == 2_000_000)
    }
}
