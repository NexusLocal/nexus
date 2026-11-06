import Foundation
import Testing
@testable import NexusMail

@Suite(.timeLimit(.minutes(1)))
struct MailRouterTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "Nexus Router \(UUID().uuidString)/outbox", directoryHint: .isDirectory)

    // Two mails in the same millisecond have no fixed order. So each mail of a test gets its own
    // second.
    private func mail(_ subject: String, second: Double = 0) -> MailMessage {
        MailMessage(from: "shop@example.com", recipients: ["a@example.com"], user: "shop.test", received: Date.now.addingTimeInterval(second - 60), data: Data("Subject: \(subject)\r\n\r\nHello\r\n".utf8))
    }

    private func inbox(maxSize: Int = SMTPReceiver.standardMaxSize) throws -> (SMTPReceiver, ReceivedMails) {
        let received = ReceivedMails()
        let receiver = SMTPReceiver(port: 0, maxSize: maxSize) { message in
            received.append(message)
            return .accepted
        }
        try receiver.start()
        return (receiver, received)
    }

    private func subjects(_ received: ReceivedMails) -> [String] {
        received.withLock { messages in
            messages.map { String(decoding: $0.data, as: UTF8.self).components(separatedBy: "\r\n")[0] }
        }
    }

    @Test func aMailGoesToTheInboxWhileItRuns() throws {
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let (inbox, received) = try inbox()
        defer { inbox.stop() }
        let router = MailRouter(outbox: MailOutbox(folder: folder))
        router.setInbox(port: inbox.port)

        let answer = router.deliver(mail("Welcome"))

        #expect(answer == .accepted)
        #expect(subjects(received) == ["Subject: Welcome"])
        #expect(received.withLock { $0.first?.user } == "shop.test")
        #expect(router.outbox.waiting().isEmpty)
    }

    @Test func aMailWaitsInTheOutboxWhileTheInboxIsStopped() throws {
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let router = MailRouter(outbox: MailOutbox(folder: folder))

        let answer = router.deliver(mail("Welcome"))

        #expect(answer == .accepted)
        #expect(router.outbox.waiting().count == 1)
    }

    @Test func aMailWaitsInTheOutboxWhenTheInboxDoesNotAnswer() throws {
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let (inbox, _) = try inbox()
        let port = inbox.port
        inbox.stop()
        let router = MailRouter(outbox: MailOutbox(folder: folder), timeout: 2)
        router.setInbox(port: port)

        let answer = router.deliver(mail("Welcome"))

        #expect(answer == .accepted)
        #expect(router.outbox.waiting().count == 1)
    }

    @Test func aFullOutboxCanRefuseTheNewMail() throws {
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let router = MailRouter(outbox: MailOutbox(folder: folder))
        router.setLimits(MailOutbox.Limits(count: 1, bytes: 1_000_000, age: 86_400, whenFull: .refuseNew))

        _ = router.deliver(mail("First"))
        let second = router.deliver(mail("Second"))

        #expect(second == .refused("The outbox of Nexus is full"))
        #expect(router.outbox.waiting().count == 1)
    }

    @Test func aMailThatTheInboxRefusesForGoodIsKeptWithItsReason() throws {
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let (inbox, received) = try inbox(maxSize: 10)
        defer { inbox.stop() }
        let router = MailRouter(outbox: MailOutbox(folder: folder))
        router.setInbox(port: inbox.port)

        let answer = router.deliver(mail("Welcome"))
        let reasons = try FileManager.default.contentsOfDirectory(atPath: router.outbox.refusedFolder.path(percentEncoded: false)).filter { $0.hasSuffix(".reason") }

        #expect(answer == .accepted)
        #expect(received.withLock { $0.isEmpty })
        #expect(router.outbox.waiting().isEmpty)
        #expect(reasons.count == 1)
    }

    @Test func theWaitingMailsGoToTheInboxTheOldestFirst() throws {
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let router = MailRouter(outbox: MailOutbox(folder: folder))
        _ = router.deliver(mail("First", second: 1))
        _ = router.deliver(mail("Second", second: 2))
        let (inbox, received) = try inbox()
        defer { inbox.stop() }
        router.setInbox(port: inbox.port)

        let result = router.deliverWaiting()

        #expect(result == MailRouter.DeliveryResult(delivered: 2, refused: 0, waiting: 0))
        #expect(subjects(received) == ["Subject: First", "Subject: Second"])
        #expect(router.outbox.waiting().isEmpty)
    }

    @Test func aWaitingMailThatTheInboxRefusesForNowDoesNotStopTheOthers() throws {
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let router = MailRouter(outbox: MailOutbox(folder: folder))
        _ = router.deliver(mail("Too many", second: 1))
        _ = router.deliver(mail("Fine", second: 2))
        let received = ReceivedMails()
        let inbox = SMTPReceiver(port: 0) { message in
            guard !String(decoding: message.data, as: UTF8.self).contains("Too many") else {
                return .refused("Try again later")
            }

            received.append(message)
            return .accepted
        }
        try inbox.start()
        defer { inbox.stop() }
        router.setInbox(port: inbox.port)

        let result = router.deliverWaiting()

        #expect(result == MailRouter.DeliveryResult(delivered: 1, refused: 0, waiting: 1))
        #expect(subjects(received) == ["Subject: Fine"])
    }

    @Test func theClientLogsInOnlyWhenTheServerOffersIt() {
        #expect(SMTPClient.offersLogin(["250-nexus", "250-SIZE 100", "250 AUTH PLAIN LOGIN"]))
        #expect(!SMTPClient.offersLogin(["250-mailpit", "250-8BITMIME", "250 SMTPUTF8"]))
    }

    @Test func theWaitingMailsStayWhileTheInboxDoesNotAnswer() throws {
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let router = MailRouter(outbox: MailOutbox(folder: folder), timeout: 2)
        _ = router.deliver(mail("First"))
        let (inbox, _) = try inbox()
        let port = inbox.port
        inbox.stop()
        router.setInbox(port: port)

        let result = router.deliverWaiting()

        #expect(result == MailRouter.DeliveryResult(delivered: 0, refused: 0, waiting: 1))
    }

    @Test func theOutboxCountsTheMailsThatTheLimitsRemoved() throws {
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let router = MailRouter(outbox: MailOutbox(folder: folder))
        router.setLimits(MailOutbox.Limits(count: 1, bytes: 1_000_000, age: 86_400, whenFull: .removeOldest))

        _ = router.deliver(mail("First", second: 1))
        _ = router.deliver(mail("Second", second: 2))
        _ = router.deliver(mail("Third", second: 3))
        let removed = router.outbox.removedCount()
        router.outbox.resetRemovedCount()

        #expect(removed == 2)
        #expect(router.outbox.removedCount() == 0)
    }
}
