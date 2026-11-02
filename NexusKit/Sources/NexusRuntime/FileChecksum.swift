import CryptoKit
import Foundation

public enum FileChecksum {
    public static func sha256(of data: Data) -> String {
        hexadecimal(SHA256.hash(data: data))
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }

        return hexadecimal(hasher.finalize())
    }

    private static func hexadecimal(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
