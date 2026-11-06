import Foundation
import Synchronization
import Testing
@testable import NexusMail

struct SMTPSessionTests {
    @Test func aMailWithAPlainLoginGetsTheUserAsItsTag() {
        var session = SMTPSession(maxSize: 1000)
        let credentials = Data("\0shop.test\0secret".utf8).base64EncodedString()

        let steps = [
            session.handle("EHLO laravel"),
            session.handle("AUTH PLAIN \(credentials)"),
            session.handle("MAIL FROM:<shop@example.com> SIZE=200"),
            session.handle("RCPT TO:<customer@example.com>"),
            session.handle("DATA"),
        ]
        let message = session.message(Data("Subject: Hi\r\n".utf8), received: Date(timeIntervalSince1970: 0))

        #expect(steps.last == .startData("354 End data with <CR><LF>.<CR><LF>"))
        #expect(message == MailMessage(from: "shop@example.com", recipients: ["customer@example.com"], user: "shop.test", received: Date(timeIntervalSince1970: 0), data: Data("Subject: Hi\r\n".utf8)))
    }

    @Test func aLoginInTwoStepsGetsTheUser() {
        var session = SMTPSession(maxSize: 1000)

        let first = session.handle("AUTH LOGIN")
        let second = session.handle(Data("fix.shop.test".utf8).base64EncodedString())
        let third = session.handle(Data("secret".utf8).base64EncodedString())

        #expect(first == .reply("334 VXNlcm5hbWU6"))
        #expect(second == .reply("334 UGFzc3dvcmQ6"))
        #expect(third == .reply("235 2.7.0 Authentication successful"))
        #expect(session.user == "fix.shop.test")
    }

    @Test func dataBeforeARecipientIsRefused() {
        var session = SMTPSession(maxSize: 1000)

        _ = session.handle("HELO wordpress")
        _ = session.handle("MAIL FROM:<>")

        #expect(session.handle("DATA") == .reply("503 5.5.1 Send MAIL and RCPT first"))
    }

    @Test func aMailAboveTheLimitIsRefusedAtMail() {
        var session = SMTPSession(maxSize: 1000)

        #expect(session.handle("MAIL FROM:<a@b.test> SIZE=5000") == .reply("552 5.3.4 The mail is larger than 1000 bytes"))
    }

    @Test func quitClosesTheConnection() {
        var session = SMTPSession(maxSize: 1000)

        #expect(session.handle("quit") == .close("221 2.0.0 Bye"))
    }
}

final class ReceivedMails: Sendable {
    private let messages = Mutex<[MailMessage]>([])

    func append(_ message: MailMessage) {
        messages.withLock { $0.append(message) }
    }

    func withLock<Result>(_ body: ([MailMessage]) -> Result) -> Result {
        messages.withLock { body($0) }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SMTPReceiverTests {
    private func receiver(answer: MailAcceptance = .accepted, maxSize: Int = SMTPReceiver.standardMaxSize) throws -> (SMTPReceiver, ReceivedMails) {
        let received = ReceivedMails()
        let receiver = SMTPReceiver(port: 0, maxSize: maxSize) { message in
            received.append(message)
            return answer
        }
        try receiver.start()
        return (receiver, received)
    }

    @Test func theClientGivesAMailToTheReceiver() throws {
        let (receiver, received) = try receiver()
        defer { receiver.stop() }
        let body = Data("Subject: Reset\n\n.hidden line\nBye\n".utf8)

        try SMTPClient(port: receiver.port).send(MailMessage(from: "shop@example.com", recipients: ["a@example.com", "b@example.com"], user: "shop.test", data: body))

        let message = try #require(received.withLock { $0.first })
        #expect(message.from == "shop@example.com")
        #expect(message.recipients == ["a@example.com", "b@example.com"])
        #expect(message.user == "shop.test")
        #expect(message.data == Data("Subject: Reset\r\n\r\n.hidden line\r\nBye\r\n".utf8))
    }

    @Test func aRefusalOfTheReceiverReachesTheClient() throws {
        let (receiver, _) = try receiver(answer: .refused("The outbox is full."))
        defer { receiver.stop() }

        #expect(throws: SMTPClientError.refused("452 4.3.1 The outbox is full.")) {
            try SMTPClient(port: receiver.port).send(MailMessage(from: "a@b.test", recipients: ["c@d.test"], user: nil, data: Data("Hi\n".utf8)))
        }
    }

    @Test func aMailAboveTheLimitGetsNoDelivery() throws {
        let (receiver, received) = try receiver(maxSize: 10)
        defer { receiver.stop() }

        #expect(throws: SMTPClientError.refused("552 5.3.4 The mail is larger than 10 bytes")) {
            try SMTPClient(port: receiver.port).send(MailMessage(from: "a@b.test", recipients: ["c@d.test"], user: nil, data: Data("A long line of text\n".utf8)))
        }
        #expect(received.withLock { $0.isEmpty })
    }

    @Test func aClientWithoutAServerGetsUnreachable() throws {
        let (receiver, _) = try receiver()
        let port = receiver.port
        receiver.stop()

        do {
            try SMTPClient(port: port, timeout: 2).send(MailMessage(from: "a@b.test", recipients: ["c@d.test"], user: nil, data: Data("Hi\n".utf8)))
            Issue.record("The mail arrived without a server.")
        } catch let error as SMTPClientError {
            #expect(!error.isPermanent)
            if case .unreachable = error {} else { Issue.record("not unreachable: \(error)") }
        }
    }
}

struct MailOutboxTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "Nexus Outbox \(UUID().uuidString)/outbox", directoryHint: .isDirectory)

    private func mail(_ number: Int, size: Int = 10, at date: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> MailMessage {
        MailMessage(from: "shop@example.com", recipients: ["a@example.com"], user: "shop.test", received: date.addingTimeInterval(Double(number)), data: Data(repeating: UInt8(ascii: "x"), count: size))
    }

    private var now: Date {
        Date(timeIntervalSince1970: 1_800_000_100)
    }

    @Test func aStoredMailReadsBackTheSame() throws {
        let outbox = MailOutbox(folder: folder)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let result = try outbox.store(mail(1), now: now)
        let file = try #require(outbox.waiting().first)

        #expect(result == .stored(removed: 0))
        #expect(try outbox.read(file) == mail(1))
        #expect(outbox.summary() == MailOutbox.Summary(count: 1, bytes: try Data(contentsOf: file).count))
    }

    @Test func aFullOutboxRemovesTheOldestMail() throws {
        let outbox = MailOutbox(folder: folder)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let limits = MailOutbox.Limits(count: 2, bytes: 1_000_000, age: 86_400, whenFull: .removeOldest)

        _ = try outbox.store(mail(1), limits: limits, now: now)
        _ = try outbox.store(mail(2), limits: limits, now: now)
        let third = try outbox.store(mail(3), limits: limits, now: now)

        #expect(third == .stored(removed: 1))
        #expect(try outbox.waiting().map { try outbox.read($0).received } == [mail(2).received, mail(3).received])
    }

    @Test func aFullOutboxCanRefuseTheNewMail() throws {
        let outbox = MailOutbox(folder: folder)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let limits = MailOutbox.Limits(count: 1, bytes: 1_000_000, age: 86_400, whenFull: .refuseNew)

        _ = try outbox.store(mail(1), limits: limits, now: now)
        let second = try outbox.store(mail(2), limits: limits, now: now)

        #expect(second == .full)
        #expect(try outbox.waiting().map { try outbox.read($0).received } == [mail(1).received])
    }

    @Test func theSizeLimitRemovesOldMailsToo() throws {
        let outbox = MailOutbox(folder: folder)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let limits = MailOutbox.Limits(count: 100, bytes: 800, age: 86_400, whenFull: .removeOldest)

        _ = try outbox.store(mail(1, size: 200), limits: limits, now: now)
        _ = try outbox.store(mail(2, size: 200), limits: limits, now: now)
        let third = try outbox.store(mail(3, size: 200), limits: limits, now: now)

        #expect(third == .stored(removed: 1))
        #expect(outbox.summary().count == 2)
    }

    @Test func anOldMailGoesAway() throws {
        let outbox = MailOutbox(folder: folder)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let limits = MailOutbox.Limits(count: 100, bytes: 1_000_000, age: 60, whenFull: .removeOldest)

        _ = try outbox.store(mail(1, at: now.addingTimeInterval(-3600)), limits: limits, now: now)
        let removed = outbox.removeExpired(limits: limits, now: now)

        #expect(removed == 1)
        #expect(outbox.waiting().isEmpty)
    }

    @Test func aRefusedMailMovesOutWithItsReason() throws {
        let outbox = MailOutbox(folder: folder)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        _ = try outbox.store(mail(1), now: now)
        let file = try #require(outbox.waiting().first)

        outbox.refuse(file, reason: "554 bad mail")

        let reason = outbox.refusedFolder.appending(path: file.lastPathComponent).appendingPathExtension("reason")
        #expect(outbox.waiting().isEmpty)
        #expect(try String(contentsOf: reason, encoding: .utf8) == "554 bad mail")
    }
}
