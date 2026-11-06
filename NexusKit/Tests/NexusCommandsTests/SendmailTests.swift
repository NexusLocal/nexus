import Foundation
import NexusMail
import Synchronization
import Testing
@testable import NexusCommands

@Suite(.timeLimit(.minutes(1)))
struct SendmailTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "Nexus Sendmail \(UUID().uuidString)", directoryHint: .isDirectory)

    private var outbox: MailOutbox {
        MailOutbox(folder: root.appending(path: "mail/outbox", directoryHint: .isDirectory))
    }

    private func input(_ text: String) throws -> FileHandle {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try pipe.fileHandleForWriting.close()
        return pipe.fileHandleForReading
    }

    private func freePort() throws -> Int {
        let holder = SMTPReceiver(port: 0) { _ in .accepted }
        try holder.start()
        defer { holder.stop() }
        return holder.port
    }

    @Test func aMailGoesToTheReceiverWithTheFolderAsTheLogin() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let received = Mutex<[MailMessage]>([])
        let receiver = SMTPReceiver(port: 0) { message in
            received.withLock { $0.append(message) }
            return .accepted
        }
        try receiver.start()
        defer { receiver.stop() }

        let code = SendmailRun.run(["-S", "127.0.0.1:\(receiver.port)", "-t", "-i"], input: try input("To: a@example.com\nSubject: Hi\n\nBody\n"), folder: "/Sites/shop/public", outbox: outbox) { _ in }

        #expect(code == 0)
        #expect(received.withLock { $0.map(\.user) } == ["/Sites/shop/public"])
        #expect(received.withLock { $0.map(\.recipients) } == [["a@example.com"]])
    }

    @Test func aMailWaitsInTheOutboxWhenNexusdDoesNotAnswer() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try freePort()

        let code = SendmailRun.run(["-S", "127.0.0.1:\(port)"], input: try input("To: a@example.com\n\nBody\n"), folder: "/Sites/shop", outbox: outbox) { _ in }
        let waiting = try outbox.waiting().map { try outbox.read($0) }

        #expect(code == 0)
        #expect(waiting.map(\.user) == ["/Sites/shop"])
    }

    @Test func aFullOutboxThatRefusesNewMailMakesMailFail() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try freePort()
        try outbox.saveLimits(MailOutbox.Limits(count: 1, bytes: 1_000_000, age: 86_400, whenFull: .refuseNew))
        var reports: [String] = []

        let first = SendmailRun.run(["-S", "127.0.0.1:\(port)"], input: try input("To: a@example.com\n\nOne\n"), folder: "/", outbox: outbox) { _ in }
        let second = SendmailRun.run(["-S", "127.0.0.1:\(port)"], input: try input("To: a@example.com\n\nTwo\n"), folder: "/", outbox: outbox) { reports.append($0) }

        #expect(first == 0)
        #expect(second == SendmailRun.refused)
        #expect(reports == ["The outbox of Nexus is full. The settings refuse new mail."])
    }

    @Test func aRefusalOfTheReceiverMakesMailFail() throws {
        let receiver = SMTPReceiver(port: 0) { _ in .refused("The outbox of Nexus is full") }
        try receiver.start()
        defer { receiver.stop() }

        let code = SendmailRun.run(["-S", "127.0.0.1:\(receiver.port)"], input: try input("To: a@example.com\n\nBody\n"), folder: "/", outbox: outbox) { _ in }

        #expect(code == SendmailRun.refused)
    }

    @Test func withoutAPortTheMailIsRefused() throws {
        let code = SendmailRun.run(["-t"], input: try input("To: a@example.com\n\nBody\n"), folder: "/", outbox: outbox) { _ in }

        #expect(code == SendmailRun.usageError)
    }
}
