import Foundation

// One mail as an SMTP server gets it: the envelope and the raw message. The user is the name of an
// SMTP login. Nexus uses it as the tag of the mail, for example the host of a site.
public struct MailMessage: Sendable, Equatable {
    public let from: String
    public let recipients: [String]
    public let user: String?
    public let received: Date
    public let data: Data

    public init(from: String, recipients: [String], user: String?, received: Date = .now, data: Data) {
        self.from = from
        self.recipients = recipients
        self.user = user
        self.received = received
        self.data = data
    }
}

// What a receiver tells the client after the end of the data.
public enum MailAcceptance: Sendable, Equatable {
    case accepted
    case refused(String)
}
