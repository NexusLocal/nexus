import Foundation
import NexusCore
import Synchronization

// Gives each mail of the receiver to the inbox (Mailpit). While the inbox does not run or does not
// answer, the mail waits in the outbox. A mail that the inbox refuses for good goes to the folder
// of the refused mails with its reason. So the receiver loses no mail after its "250" answer.
public final class MailRouter: Sendable {
    public struct DeliveryResult: Sendable, Equatable {
        public var delivered = 0
        public var refused = 0
        public var waiting = 0
    }

    private struct DeliveryTurn {
        var running = false
        var again = false
    }

    public let outbox: MailOutbox
    private let inboxPort = Mutex<Int?>(nil)
    private let limits = Mutex(MailOutbox.Limits.standard)
    private let hostsByFolder = Mutex<[String: String]>([:])
    private let turn = Mutex(DeliveryTurn())
    private let timeout: TimeInterval

    public init(outbox: MailOutbox, timeout: TimeInterval = 30) {
        self.outbox = outbox
        self.timeout = timeout
    }

    // nil while the inbox does not run.
    public func setInbox(port: Int?) {
        inboxPort.withLock { $0 = port }
    }

    public var currentInboxPort: Int? {
        inboxPort.withLock { $0 }
    }

    public func setLimits(_ new: MailOutbox.Limits) {
        limits.withLock { $0 = new }
    }

    public var currentLimits: MailOutbox.Limits {
        limits.withLock { $0 }
    }

    // The real folder of each site and each workspace, with its host.
    public func setSiteFolders(_ folders: [String: String]) {
        hostsByFolder.withLock { $0 = folders }
    }

    // PHP gives no host to a sendmail, so nexus sendmail logs in with the folder of the script or
    // of the worker. The longest folder of a site or a workspace that holds it gives the host. A
    // folder outside every site gives no tag. Each other user name is the tag itself.
    public func tag(for user: String?) -> String? {
        guard let user, user.hasPrefix("/") else {
            return user
        }

        let folders = hostsByFolder.withLock { $0 }

        return folders
            .filter { folder, _ in user == folder || user.hasPrefix(folder.hasSuffix("/") ? folder : "\(folder)/") }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    private func tagged(_ message: MailMessage) -> MailMessage {
        MailMessage(from: message.from, recipients: message.recipients, user: tag(for: message.user), received: message.received, data: message.data)
    }

    public func deliver(_ message: MailMessage) -> MailAcceptance {
        if let port = currentInboxPort {
            do {
                try SMTPClient(port: port, timeout: timeout).send(tagged(message))
                return .accepted
            } catch let error as SMTPClientError where error.isPermanent {
                return keepRefused(message, reason: error.description)
            } catch {
                // The inbox does not take the mail now, so it waits in the outbox.
            }
        }

        do {
            switch try outbox.store(message, limits: currentLimits) {
            case .stored:
                return .accepted
            case .full:
                return .refused("The outbox of Nexus is full")
            }
        } catch {
            return .refused("Nexus could not keep the mail: \(ErrorText.plain(error))")
        }
    }

    // Gives the waiting mails to the inbox, the oldest first, and removes each mail that the inbox
    // takes. It stops at the first mail that the inbox does not take now, so the order stays. A
    // second call during a run makes the run go through the outbox once more.
    @discardableResult
    public func deliverWaiting() -> DeliveryResult {
        let starts = turn.withLock { current in
            guard !current.running else {
                current.again = true
                return false
            }

            current.running = true
            return true
        }

        guard starts else {
            return DeliveryResult(waiting: outbox.summary().count)
        }

        var result = DeliveryResult()

        repeat {
            turn.withLock { $0.again = false }
            deliverOnce(into: &result)
        } while turn.withLock { current in
            current.running = current.again
            return current.again
        }

        result.waiting = outbox.summary().count
        return result
    }

    // A mail that Mailpit refuses for now, with a 4xx answer, stays and does not stop the mails
    // behind it. A Mailpit that does not answer stops the run. A file that another process removed
    // during the run, such as a clear of the outbox, counts as nothing.
    private func deliverOnce(into result: inout DeliveryResult) {
        _ = outbox.removeExpired(limits: currentLimits)

        for file in outbox.waiting() {
            guard let port = currentInboxPort else {
                return
            }

            let message: MailMessage
            do {
                message = try outbox.read(file)
            } catch {
                guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
                    continue
                }

                outbox.refuse(file, reason: "Nexus cannot read this mail: \(ErrorText.plain(error))")
                result.refused += 1
                continue
            }

            do {
                try SMTPClient(port: port, timeout: timeout).send(tagged(message))
                outbox.remove(file)
                result.delivered += 1
            } catch let error as SMTPClientError where error.isPermanent {
                outbox.refuse(file, reason: error.description)
                result.refused += 1
            } catch SMTPClientError.refused {
                continue
            } catch {
                return
            }
        }
    }

    private func keepRefused(_ message: MailMessage, reason: String) -> MailAcceptance {
        do {
            try outbox.keepRefused(message, reason: reason)
            return .accepted
        } catch {
            return .refused("Nexus could not keep the mail: \(ErrorText.plain(error))")
        }
    }
}
