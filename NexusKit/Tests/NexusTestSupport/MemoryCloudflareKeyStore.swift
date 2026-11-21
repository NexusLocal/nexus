import Foundation
import NexusTLS
import Synchronization

// The keys of the own domain in memory (group 4, 4h). failure makes each call throw.
public final class MemoryCloudflareKeyStore: CloudflareKeyStore {
    private struct Contents {
        var keys: [CloudflareKey: Data] = [:]
        var failure: TLSError?
    }

    private let contents = Mutex(Contents())

    public init() {}

    public var keys: [CloudflareKey: Data] {
        contents.withLock { $0.keys }
    }

    public func fail(with error: TLSError?) {
        contents.withLock { $0.failure = error }
    }

    public func save(_ data: Data, as key: CloudflareKey) throws {
        try contents.withLock { contents in
            if let failure = contents.failure {
                throw failure
            }

            contents.keys[key] = data
        }
    }

    public func read(_ key: CloudflareKey) throws -> Data? {
        try contents.withLock { contents in
            if let failure = contents.failure {
                throw failure
            }

            return contents.keys[key]
        }
    }

    public func remove(_ key: CloudflareKey) throws {
        try contents.withLock { contents in
            if let failure = contents.failure {
                throw failure
            }

            contents.keys[key] = nil
        }
    }
}
