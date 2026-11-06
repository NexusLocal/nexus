import Foundation

// The mails that wait while the inbox does not run. Each mail is one file: a line with the envelope
// as JSON, and then the raw message. A file gets its name only after the write, so a reader never
// sees half a mail. The name starts with the time, so the order of the names is the order of the
// mails. More processes can write at the same time, for example nexusd and nexus sendmail.
public struct MailOutbox: Sendable {
    public enum WhenFull: String, Codable, Sendable, CaseIterable {
        case removeOldest = "remove_oldest"
        case refuseNew = "refuse_new"
    }

    public struct Limits: Codable, Sendable, Equatable {
        public var count: Int
        public var bytes: Int
        public var age: TimeInterval
        public var whenFull: WhenFull

        public static let standard = Limits(count: 500, bytes: 100 * 1024 * 1024, age: 7 * 86_400, whenFull: .removeOldest)

        public init(count: Int, bytes: Int, age: TimeInterval, whenFull: WhenFull) {
            self.count = count
            self.bytes = bytes
            self.age = age
            self.whenFull = whenFull
        }
    }

    public enum StoreResult: Sendable, Equatable {
        case stored(removed: Int)
        case full
    }

    public struct Summary: Sendable, Equatable {
        public let count: Int
        public let bytes: Int
    }

    private struct Envelope: Codable {
        let from: String
        let recipients: [String]
        let user: String?
        let received: Date
    }

    static let fileExtension = "mail"

    public let folder: URL

    public var refusedFolder: URL {
        folder.deletingLastPathComponent().appending(path: "refused", directoryHint: .isDirectory)
    }

    // The number of mails that the limits removed since the user last saw it. nexusd and nexus
    // sendmail both add to it.
    var removedCountFile: URL {
        folder.deletingLastPathComponent().appending(path: "removed-count", directoryHint: .notDirectory)
    }

    // nexusd writes the limits of the settings here. So nexus sendmail uses them too while nexusd
    // does not run.
    var limitsFile: URL {
        folder.deletingLastPathComponent().appending(path: "limits.json", directoryHint: .notDirectory)
    }

    public func storedLimits() -> Limits {
        (try? Data(contentsOf: limitsFile)).flatMap { try? JSONDecoder().decode(Limits.self, from: $0) } ?? .standard
    }

    public func saveLimits(_ limits: Limits) throws {
        try FileManager.default.createDirectory(at: limitsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(limits).write(to: limitsFile, options: .atomic)
    }

    public init(folder: URL) {
        self.folder = folder
    }

    // The old mails go first, so the new mail fits. With refuseNew, a full outbox keeps its mails
    // and refuses the new one.
    public func store(_ message: MailMessage, limits: Limits = .standard, now: Date = .now) throws -> StoreResult {
        let expired = removeExpired(limits: limits, now: now)
        var files = waiting()
        var total = files.reduce(0) { $0 + size(of: $1) }
        let contents = try fileContents(of: message)
        let needed = contents.count
        var removed = 0

        defer { countRemoved(removed) }

        while !files.isEmpty, files.count + 1 > limits.count || total + needed > limits.bytes {
            guard limits.whenFull == .removeOldest else {
                return .full
            }

            total -= size(of: files[0])
            try? FileManager.default.removeItem(at: files[0])
            files.removeFirst()
            removed += 1
        }

        guard needed <= limits.bytes else {
            return .full
        }

        try write(contents, received: message.received, in: folder)
        return .stored(removed: expired + removed)
    }

    // A mail that the inbox refuses for good keeps its reason next to it.
    public func keepRefused(_ message: MailMessage, reason: String) throws {
        let file = try write(try fileContents(of: message), received: message.received, in: refusedFolder)
        try? Data(reason.utf8).write(to: file.appendingPathExtension("reason"))
    }

    public func refusedCount() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: refusedFolder.path(percentEncoded: false))) ?? []
        return names.filter { $0.hasSuffix(".\(Self.fileExtension)") && !$0.hasPrefix(".") }.count
    }

    public func removedCount() -> Int {
        (try? String(contentsOf: removedCountFile, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    }

    public func resetRemovedCount() {
        try? FileManager.default.removeItem(at: removedCountFile)
    }

    private func countRemoved(_ number: Int) {
        guard number > 0 else {
            return
        }

        try? FileManager.default.createDirectory(at: removedCountFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(String(removedCount() + number).utf8).write(to: removedCountFile, options: .atomic)
    }

    // The files of the waiting mails, the oldest first.
    public func waiting() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []

        return names
            .filter { $0.hasSuffix(".\(Self.fileExtension)") && !$0.hasPrefix(".") }
            .sorted()
            .map { folder.appending(path: $0) }
    }

    public func summary() -> Summary {
        let files = waiting()
        return Summary(count: files.count, bytes: files.reduce(0) { $0 + size(of: $1) })
    }

    public func read(_ file: URL) throws -> MailMessage {
        let contents = try Data(contentsOf: file)

        guard let newline = contents.firstIndex(of: UInt8(ascii: "\n")) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: contents[..<newline])

        return MailMessage(from: envelope.from, recipients: envelope.recipients, user: envelope.user, received: envelope.received, data: Data(contents[contents.index(after: newline)...]))
    }

    public func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    public func removeAll() -> Int {
        let files = waiting()
        files.forEach(remove)
        return files.count
    }

    public func removeRefused() -> Int {
        let count = refusedCount()
        try? FileManager.default.removeItem(at: refusedFolder)
        return count
    }

    // A mail that the inbox refuses keeps its reason next to it, and it does not block the others.
    public func refuse(_ file: URL, reason: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: refusedFolder, withIntermediateDirectories: true)
        let target = refusedFolder.appending(path: file.lastPathComponent)

        try? manager.moveItem(at: file, to: target)
        try? Data(reason.utf8).write(to: target.appendingPathExtension("reason"))
    }

    public func removeExpired(limits: Limits, now: Date = .now) -> Int {
        let oldest = now.addingTimeInterval(-limits.age)
        let expired = waiting().filter { (Self.date(of: $0) ?? now) < oldest }

        expired.forEach(remove)
        countRemoved(expired.count)
        return expired.count
    }

    private func fileContents(of message: MailMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let envelope = try encoder.encode(Envelope(from: message.from, recipients: message.recipients, user: message.user, received: message.received))

        return envelope + Data("\n".utf8) + message.data
    }

    @discardableResult
    private func write(_ contents: Data, received: Date, in target: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: target, withIntermediateDirectories: true)

        let milliseconds = String(Int(received.timeIntervalSince1970 * 1000))
        let padded = String(repeating: "0", count: max(0, 15 - milliseconds.count)) + milliseconds
        let name = "\(padded)-\(UUID().uuidString).\(Self.fileExtension)"
        let temporary = target.appending(path: ".\(name)")
        let file = target.appending(path: name)

        try contents.write(to: temporary)
        try manager.moveItem(at: temporary, to: file)
        return file
    }

    private func size(of file: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false)))?[.size] as? Int) ?? 0
    }

    static func date(of file: URL) -> Date? {
        guard let milliseconds = file.lastPathComponent.split(separator: "-").first.flatMap({ Double($0) }) else {
            return nil
        }

        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
