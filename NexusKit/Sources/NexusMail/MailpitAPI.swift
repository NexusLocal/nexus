import Foundation

// The app shows localizedDescription. Without LocalizedError that is a general text of macOS.
public enum MailpitAPIError: LocalizedError, Equatable, CustomStringConvertible {
    case status(Int, String)
    case unreadable(String)
    case noMail(String)

    public var description: String {
        switch self {
        case .status(let code, let path): "Mailpit answered \(path) with HTTP status \(code)."
        case .unreadable(let path): "Nexus cannot read the answer of Mailpit to \(path)."
        case .noMail("latest"): "The inbox is empty."
        case .noMail(let id): "The inbox has no mail with the id \(id)."
        }
    }

    public var errorDescription: String? {
        description
    }
}

// The HTTP API of Mailpit on 127.0.0.1: https://mailpit.axllent.org/docs/api-v1/ . nexus mail and
// the Mail screen read the inbox with it. The id latest names the newest mail.
public struct MailpitAPI: Sendable {
    public struct Summary: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let from: String
        public let to: [String]
        public let subject: String
        public let tags: [String]
        public let created: String
        public let snippet: String

        public init(id: String, from: String, to: [String], subject: String, tags: [String], created: String, snippet: String) {
            self.id = id
            self.from = from
            self.to = to
            self.subject = subject
            self.tags = tags
            self.created = created
            self.snippet = snippet
        }
    }

    // One page of the inbox and the number of all mails in it.
    public struct Page: Sendable, Equatable {
        public let messages: [Summary]
        public let total: Int
    }

    public struct Attachment: Codable, Sendable, Equatable, Identifiable {
        public let file: String
        public let type: String
        public let size: Int
        public let part: String

        public var id: String { part }
    }

    public struct Message: Codable, Sendable, Equatable {
        public let id: String
        public let from: String
        public let to: [String]
        public let cc: [String]
        public let subject: String
        public let date: String
        public let tags: [String]
        public let text: String
        public let html: String
        public let attachments: [Attachment]
        public let headers: [String: [String]]

        public init(id: String, from: String, to: [String], cc: [String], subject: String, date: String, tags: [String], text: String, html: String, attachments: [Attachment], headers: [String: [String]]) {
            self.id = id
            self.from = from
            self.to = to
            self.cc = cc
            self.subject = subject
            self.date = date
            self.tags = tags
            self.text = text
            self.html = html
            self.attachments = attachments
            self.headers = headers
        }
    }

    private struct Address: Decodable {
        let name: String?
        let address: String

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case address = "Address"
        }

        var text: String {
            guard let name, !name.isEmpty else {
                return address
            }

            return "\(name) <\(address)>"
        }
    }

    private struct List: Decodable {
        let messages: [Item]
        let total: Int?
        let messagesCount: Int?

        enum CodingKeys: String, CodingKey {
            case messages
            case total
            case messagesCount = "messages_count"
        }

        struct Item: Decodable {
            let id: String
            let from: Address?
            let to: [Address]?
            let subject: String
            let tags: [String]?
            let created: String
            let snippet: String?

            enum CodingKeys: String, CodingKey {
                case id = "ID"
                case from = "From"
                case to = "To"
                case subject = "Subject"
                case tags = "Tags"
                case created = "Created"
                case snippet = "Snippet"
            }
        }
    }

    private struct Full: Decodable {
        let id: String
        let from: Address?
        let to: [Address]?
        let cc: [Address]?
        let subject: String
        let date: String
        let tags: [String]?
        let text: String
        let html: String
        let attachments: [Part]?

        struct Part: Decodable {
            let partID: String
            let fileName: String
            let contentType: String
            let size: Int

            enum CodingKeys: String, CodingKey {
                case partID = "PartID"
                case fileName = "FileName"
                case contentType = "ContentType"
                case size = "Size"
            }
        }

        enum CodingKeys: String, CodingKey {
            case id = "ID"
            case from = "From"
            case to = "To"
            case cc = "Cc"
            case subject = "Subject"
            case date = "Date"
            case tags = "Tags"
            case text = "Text"
            case html = "HTML"
            case attachments = "Attachments"
        }
    }

    public let port: Int

    public init(port: Int) {
        self.port = port
    }

    public var inboxURL: URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }

    // A tag filter uses the search of Mailpit. The quotes keep a host with dots as one tag.
    public func messages(tag: String? = nil, limit: Int = 50) async throws -> [Summary] {
        try await page(tag: tag, limit: limit).messages
    }

    // A search gives the number of its matches in messages_count, and the list of all mails gives
    // it in total.
    public func page(tag: String? = nil, limit: Int = 50) async throws -> Page {
        let path = tag.map { "api/v1/search?limit=\(limit)&query=" + "tag:\"\($0)\"".addingPercentEncoding(withAllowedCharacters: .alphanumerics)! } ?? "api/v1/messages?limit=\(limit)"
        let list = try JSONDecoder().decode(List.self, from: try await data(path))
        let messages = list.messages.map { item in
            Summary(id: item.id, from: item.from?.text ?? "", to: (item.to ?? []).map(\.text), subject: item.subject, tags: item.tags ?? [], created: item.created, snippet: item.snippet ?? "")
        }

        return Page(messages: messages, total: (tag == nil ? list.total : list.messagesCount) ?? messages.count)
    }

    public func message(id: String) async throws -> Message {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-"))) ?? id
        let path = "api/v1/message/\(escaped)"
        let answer: Data

        do {
            answer = try await data(path)
        } catch MailpitAPIError.status(404, path) {
            throw MailpitAPIError.noMail(id)
        }

        let full = try JSONDecoder().decode(Full.self, from: answer)
        let headers = try JSONDecoder().decode([String: [String]].self, from: try await data("api/v1/message/\(full.id)/headers"))

        return Message(
            id: full.id,
            from: full.from?.text ?? "",
            to: (full.to ?? []).map(\.text),
            cc: (full.cc ?? []).map(\.text),
            subject: full.subject,
            date: full.date,
            tags: full.tags ?? [],
            text: full.text,
            html: full.html,
            attachments: (full.attachments ?? []).map { Attachment(file: $0.fileName, type: $0.contentType, size: $0.size, part: $0.partID) },
            headers: headers
        )
    }

    // Every tag in the inbox, for the filter of the Mail screen.
    public func tags() async throws -> [String] {
        try JSONDecoder().decode([String].self, from: try await data("api/v1/tags"))
    }

    // The data of one attachment.
    public func attachment(_ attachment: Attachment, of id: String) async throws -> Data {
        try await data("api/v1/message/\(id)/part/\(attachment.part)")
    }

    // Mailpit removes every mail for a request without ids. So no ids remove nothing here.
    public func remove(ids: [String]) async throws {
        guard !ids.isEmpty else {
            return
        }

        try await delete(["IDs": ids])
    }

    public func removeAll() async throws {
        try await delete([:])
    }

    private func delete(_ body: [String: [String]]) async throws {
        var request = URLRequest(url: inboxURL.appending(path: "api/v1/messages"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        _ = try await checked(request, path: "api/v1/messages")
    }

    private func data(_ path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: inboxURL) else {
            throw MailpitAPIError.unreadable(path)
        }

        return try await checked(URLRequest(url: url), path: path)
    }

    private func checked(_ request: URLRequest, path: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MailpitAPIError.status(http.statusCode, path)
        }

        return data
    }
}
