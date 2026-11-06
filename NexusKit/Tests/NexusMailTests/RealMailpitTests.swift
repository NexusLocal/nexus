import Darwin
import Foundation
import Testing
@testable import NexusMail

// Runs only when NEXUS_MAILPIT names a mailpit binary. The test starts its own Mailpit on free
// ports with a temporary database, so it does not touch a Mailpit that runs already.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_MAILPIT"] != nil), .timeLimit(.minutes(1)))
struct RealMailpitTests {
    // Both receivers hold their port at the same time, so the two ports differ.
    private func freePorts() -> (Int, Int) {
        let first = SMTPReceiver(port: 0) { _ in .accepted }
        let second = SMTPReceiver(port: 0) { _ in .accepted }
        try? first.start()
        try? second.start()
        defer {
            first.stop()
            second.stop()
        }
        return (first.port, second.port)
    }

    private func messages(on port: Int) async throws -> [[String: Any]] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/api/v1/messages")!)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["messages"] as? [[String: Any]] ?? []
    }

    private func whileMailpitRuns(_ body: (_ smtpPort: Int, _ webPort: Int) async throws -> Void) async throws {
        let (smtpPort, webPort) = freePorts()
        try await Task.sleep(for: .milliseconds(100))
        let database = FileManager.default.temporaryDirectory.appending(path: "mailpit-\(UUID().uuidString).db")
        let mailpit = Process()
        mailpit.executableURL = URL(filePath: ProcessInfo.processInfo.environment["NEXUS_MAILPIT"]!)
        mailpit.arguments = [
            "--smtp", "127.0.0.1:\(smtpPort)", "--listen", "127.0.0.1:\(webPort)", "--database", database.path(percentEncoded: false),
            "--smtp-auth-accept-any", "--smtp-auth-allow-insecure", "--tags-username", "--disable-version-check",
        ]
        mailpit.standardOutput = FileHandle.nullDevice
        mailpit.standardError = FileHandle.nullDevice
        try mailpit.run()
        defer {
            mailpit.terminate()
            try? FileManager.default.removeItem(at: database)
        }

        try await body(smtpPort, webPort)
    }

    // Mailpit needs some time after its start before it accepts mail.
    private func send(_ subject: String, to smtpPort: Int) async throws -> Bool {
        let client = SMTPClient(port: smtpPort, timeout: 5)
        let mail = MailMessage(from: "shop@example.com", recipients: ["customer@example.com"], user: "fix.shop.test", data: Data("Subject: \(subject)\n\nHello\n".utf8))

        for _ in 0..<50 {
            do {
                try client.send(mail)
                return true
            } catch {
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        return false
    }

    @Test func mailpitTagsAMailWithTheUserOfTheLogin() async throws {
        try await whileMailpitRuns { smtpPort, webPort in
            let sent = try await send("Reset your password", to: smtpPort)

            let first = try #require(try await messages(on: webPort).first)

            #expect(sent)
            #expect(first["Subject"] as? String == "Reset your password")
            #expect(first["Tags"] as? [String] == ["fix.shop.test"])
        }
    }

    @Test func aRemovalRemovesOnlyTheMailWithItsIDAndNoIDsRemoveNothing() async throws {
        try await whileMailpitRuns { smtpPort, webPort in
            let api = MailpitAPI(port: webPort)
            let sent = try await send("First", to: smtpPort)
            _ = try await send("Second", to: smtpPort)
            let first = try #require(try await api.messages().first { $0.subject == "First" })

            try await api.remove(ids: [])
            let afterNoIDs = try await api.messages()
            try await api.remove(ids: [first.id])
            let afterRemoval = try await api.messages()

            #expect(sent)
            #expect(afterNoIDs.count == 2)
            #expect(afterRemoval.map(\.subject) == ["Second"])
            await #expect(throws: MailpitAPIError.noMail(first.id)) {
                try await api.message(id: first.id)
            }
        }
    }
}
