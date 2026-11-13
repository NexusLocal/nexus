import Foundation
import NexusMail

// The inbox of Mailpit, or a fake inbox in a test.
public protocol MailInbox: Sendable {
    func search(_ query: String, limit: Int) async throws -> [MailpitAPI.Summary]
    func newest(limit: Int) async throws -> [MailpitAPI.Summary]
    func message(id: String) async throws -> MailpitAPI.Message
    func remove(ids: [String]) async throws
    func removeAll() async throws
}

extension MailpitAPI: MailInbox {
    public func newest(limit: Int) async throws -> [Summary] {
        try await messages(tag: nil, limit: limit)
    }
}

// One mail in a list. site is the tag of the mail: the host of the site or the workspace that
// sent it.
public struct MailRow: Codable, Sendable, Equatable {
    public let id: String
    public let time: String
    public let from: String
    public let to: [String]
    public let subject: String
    public let site: String?

    init(_ summary: MailpitAPI.Summary) {
        id = summary.id
        time = summary.created
        from = summary.from
        to = summary.to
        subject = summary.subject
        site = summary.tags.first
    }
}

public struct MailAttachmentInfo: Codable, Sendable, Equatable {
    public let file: String
    public let type: String
    public let size: Int
}

public struct AgentMail: Codable, Sendable, Equatable {
    public static let textLimit = 20_000

    public let id: String
    public let time: String
    public let from: String
    public let to: [String]
    public let cc: [String]
    public let subject: String
    public let site: String?
    public let text: String
    public let note: String?
    public let links: [MailLink]
    public let codes: [String]
    public let attachments: [MailAttachmentInfo]

    public init(_ message: MailpitAPI.Message) {
        let fullText = message.text.isEmpty ? MailContent.plainText(html: message.html) : message.text

        id = message.id
        time = message.date
        from = message.from
        to = message.to
        cc = message.cc
        subject = message.subject
        site = message.tags.first
        text = String(fullText.prefix(Self.textLimit))
        note = fullText.count > Self.textLimit ? "The text stops after \(Self.textLimit) characters. The links and codes come from the whole mail." : nil
        links = MailContent.links(html: message.html, text: message.text)
        codes = MailContent.codes(in: fullText)
        attachments = message.attachments.map { MailAttachmentInfo(file: $0.file, type: $0.type, size: $0.size) }
    }
}

// tags nil means the whole inbox. Mailpit has no OR in a search. So each tag is one search.
public struct MailReader: Sendable {
    public static let lookBack: TimeInterval = 60
    public static let defaultWait = 30
    public static let longestWait = 50
    static let searchesAtOnce = 4

    let inbox: any MailInbox

    public init(inbox: any MailInbox) {
        self.inbox = inbox
    }

    public func list(tags: [String]?, limit: Int) async throws -> [MailpitAPI.Summary] {
        try await search(terms: [], tags: tags, limit: limit)
    }

    public func read(id: String, tags: [String]?) async throws -> AgentMail {
        guard id == "latest" else {
            return AgentMail(try await inbox.message(id: id))
        }

        guard let newest = try await list(tags: tags, limit: 1).first else {
            throw MailpitAPIError.noMail("latest")
        }

        return AgentMail(try await inbox.message(id: newest.id))
    }

    // Waits for a mail that came after since and matches to and subject. An address finds the
    // mail in the whole inbox, because a mail of a site with other mail settings has no tag. It
    // asks Mailpit every half second. The newest match wins. A second reset in the same minute
    // then gives the new link and not the old one. nil means no mail came in time.
    public func wait(to: String?, subject: String?, tags: [String]?, since: Date, seconds: Int, poll: Duration = .milliseconds(500)) async throws -> AgentMail? {
        let terms = [to.map { MailpitAPI.term("to", $0) }, subject.map { MailpitAPI.term("subject", $0) }].compactMap { $0 }
        let scope = to == nil ? tags : nil
        let deadline = ContinuousClock.now + .seconds(seconds)

        while true {
            let found = try await search(terms: terms, tags: scope, limit: 20)
                .filter { (Self.date($0.created) ?? .distantFuture) >= since }

            if let newest = found.first {
                return AgentMail(try await inbox.message(id: newest.id))
            }

            guard ContinuousClock.now < deadline else {
                return nil
            }

            try await Task.sleep(for: poll)
        }
    }

    // Removes one mail, the mails of the tags or all mail. It gives the number of removed mails.
    // After a removal of all mail it gives nil.
    public func clear(id: String?, tags: [String]?) async throws -> Int? {
        if let id {
            let found = try await read(id: id, tags: tags)
            try await inbox.remove(ids: [found.id])
            return 1
        }

        guard let tags else {
            try await inbox.removeAll()
            return nil
        }

        let ids = try await search(terms: [], tags: tags, limit: 10_000).map(\.id)
        try await inbox.remove(ids: ids)
        return ids.count
    }

    private func search(terms: [String], tags: [String]?, limit: Int) async throws -> [MailpitAPI.Summary] {
        guard let tags else {
            return terms.isEmpty ? try await inbox.newest(limit: limit) : try await inbox.search(terms.joined(separator: " "), limit: limit)
        }

        // A site with workspaces has a tag for each workspace. wait asks again each half second.
        // So the searches run at the same time, with a limit for a site with many workspaces.
        let inbox = inbox

        let found = try await withThrowingTaskGroup(of: [MailpitAPI.Summary].self) { group in
            var merged: [String: MailpitAPI.Summary] = [:]

            for (index, tag) in tags.enumerated() {
                if index >= Self.searchesAtOnce, let page = try await group.next() {
                    page.forEach { summary in merged[summary.id] = summary }
                }

                let query = (terms + [MailpitAPI.term("tag", tag)]).joined(separator: " ")
                group.addTask { try await inbox.search(query, limit: limit) }
            }

            for try await page in group {
                page.forEach { summary in merged[summary.id] = summary }
            }

            return merged
        }

        let dated = found.values.map { summary in (date: Self.date(summary.created) ?? .distantPast, summary: summary) }

        return dated.sorted { $0.date > $1.date }.prefix(limit).map(\.summary)
    }

    // Mailpit gives the time with fractions of a second and a time zone.
    public static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) ?? (try? Date(text, strategy: .iso8601))
    }
}
