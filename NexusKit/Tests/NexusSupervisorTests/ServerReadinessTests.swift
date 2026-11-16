import Darwin
import Foundation
import Testing
@testable import NexusSupervisor

struct ServerReadinessTests {
    private func temporaryFolder() throws -> URL {
        let folder = URL(filePath: "/tmp/nx-ready-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func unixListener(at path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }

        try #require(bound == 0)
        try #require(listen(descriptor, 8) == 0)
        return descriptor
    }

    private func serve(_ listener: Int32, greeting: [UInt8]) {
        Thread.detachNewThread {
            let client = accept(listener, nil, nil)

            guard client >= 0 else {
                return
            }

            if !greeting.isEmpty {
                _ = greeting.withUnsafeBytes { write(client, $0.baseAddress, greeting.count) }
            }

            Thread.sleep(forTimeInterval: 0.5)
            close(client)
        }
    }

    private func writePostmasterFile(_ lines: [String], in folder: URL) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: folder.appending(path: "postmaster.pid"))
    }

    @Test func aSocketThatWritesOneByteGreets() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "s.sock").path(percentEncoded: false)
        let listener = try unixListener(at: path)
        defer { close(listener) }

        serve(listener, greeting: [0x0A])

        #expect(ServerReadiness.greets(socket: path))
    }

    @Test func aSocketThatWritesNothingDoesNotGreetWithinTheTimeout() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "s.sock").path(percentEncoded: false)
        let listener = try unixListener(at: path)
        defer { close(listener) }

        serve(listener, greeting: [])
        let start = ContinuousClock.now

        #expect(!ServerReadiness.greets(socket: path, timeout: 0.2))
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func aPathWithoutASocketOrALongPathDoesNotGreet() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(!ServerReadiness.greets(socket: folder.appending(path: "none.sock").path(percentEncoded: false)))
        #expect(!ServerReadiness.greets(socket: "/tmp/" + String(repeating: "a", count: 99)))
    }

    @Test func postgreSQLIsReadyOnlyWhenLineEightSaysReady() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = ["4242", folder.path(percentEncoded: false), "1763200000", "50432", "/tmp", "127.0.0.1", "  1234567     65536"]

        #expect(!ServerReadiness.isReady(postgreSQLData: folder) { _ in true })

        try writePostmasterFile(start + ["ready   "], in: folder)
        #expect(ServerReadiness.isReady(postgreSQLData: folder) { $0 == 4242 })
        #expect(!ServerReadiness.isReady(postgreSQLData: folder) { _ in false })

        try writePostmasterFile(start + ["starting"], in: folder)
        #expect(!ServerReadiness.isReady(postgreSQLData: folder) { _ in true })

        try writePostmasterFile(start, in: folder)
        #expect(!ServerReadiness.isReady(postgreSQLData: folder) { _ in true })
    }

    @Test func aProcessThatIsNoPostgresDoesNotRunPostgres() {
        #expect(!ServerReadiness.runsPostgres(getpid()))
        #expect(!ServerReadiness.runsPostgres(999_999))
    }
}
