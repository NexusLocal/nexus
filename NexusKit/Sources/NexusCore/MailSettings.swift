import Foundation

// The settings of the mail service (Phase 3, 3b). Each limit has a range, and no limit can be
// turned off. So the outbox and the inbox cannot fill the disk (owner, 2026-11-04).
public struct MailSettings: Codable, Sendable, Equatable {
    public enum WhenFull: String, Codable, Sendable, CaseIterable {
        case removeOldest = "remove_oldest"
        case refuseNew = "refuse_new"
    }

    public static let megabyte = 1024 * 1024
    public static let outboxMailsRange = 10...10_000
    public static let outboxBytesRange = (10 * megabyte)...(2048 * megabyte)
    public static let outboxDaysRange = 1...90
    public static let inboxMailsRange = 100...50_000

    public var outboxMails = 500
    public var outboxBytes = 100 * megabyte
    public var outboxDays = 7
    public var inboxMails = 1000
    public var whenFull = WhenFull.removeOldest

    public init() {}

    public init(outboxMails: Int, outboxBytes: Int, outboxDays: Int, inboxMails: Int, whenFull: WhenFull) {
        self.outboxMails = outboxMails
        self.outboxBytes = outboxBytes
        self.outboxDays = outboxDays
        self.inboxMails = inboxMails
        self.whenFull = whenFull
    }

    // A key that an older nexusd did not write gets its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MailSettings()

        outboxMails = try container.decodeIfPresent(Int.self, forKey: .outboxMails) ?? defaults.outboxMails
        outboxBytes = try container.decodeIfPresent(Int.self, forKey: .outboxBytes) ?? defaults.outboxBytes
        outboxDays = try container.decodeIfPresent(Int.self, forKey: .outboxDays) ?? defaults.outboxDays
        inboxMails = try container.decodeIfPresent(Int.self, forKey: .inboxMails) ?? defaults.inboxMails
        whenFull = (try? container.decodeIfPresent(WhenFull.self, forKey: .whenFull)) ?? defaults.whenFull
    }

    // The first value outside its range.
    public var problem: String? {
        if !Self.outboxMailsRange.contains(outboxMails) {
            return "The outbox keeps from \(Self.outboxMailsRange.lowerBound) to \(Self.outboxMailsRange.upperBound) mails."
        }

        if !Self.outboxBytesRange.contains(outboxBytes) {
            return "The outbox can use from 10 MB to 2 GB."
        }

        if !Self.outboxDaysRange.contains(outboxDays) {
            return "The outbox keeps a mail from \(Self.outboxDaysRange.lowerBound) to \(Self.outboxDaysRange.upperBound) days."
        }

        if !Self.inboxMailsRange.contains(inboxMails) {
            return "The inbox keeps from \(Self.inboxMailsRange.lowerBound) to \(Self.inboxMailsRange.upperBound) mails."
        }

        return nil
    }

    // 100MB, 2GB or a number of bytes.
    public static func bytes(of text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespaces).uppercased()

        for (suffix, factor) in [("GB", 1024 * megabyte), ("MB", megabyte), ("KB", 1024), ("B", 1)] where value.hasSuffix(suffix) {
            return Int(value.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)).map { $0 * factor }
        }

        return Int(value)
    }

    public static func sizeText(_ bytes: Int) -> String {
        bytes % (1024 * megabyte) == 0 ? "\(bytes / (1024 * megabyte)) GB" : bytes % megabyte == 0 ? "\(bytes / megabyte) MB" : "\(bytes) bytes"
    }
}
