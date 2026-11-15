import CBzip2
import Foundation
import NexusCore
import NexusRuntime
import zlib

// How All-in-One WP Migration stored the files of a .wpress archive (Ai1wm_Compressor::add_file of
// 7.113). The plugin reads each file in parts of 512,000 bytes. With compression it compresses each
// part with gzcompress or bzcompress at level 9. With a password it then encrypts the part. With
// compression, 4 bytes of length (big-endian) come before each part.
struct WpressCoding: Sendable {
    static let partSize = 512_000

    // Only the copy of the plan for one import has the key. lastBackupRead never holds it.
    var key: WpressKey?
    let compression: BackupCompression?
    // Before 7.102 the plugin kept each file with the name package.json plain, also one in a plugin.
    // Since 7.102 only package.json and multisite.json at the root stay plain (ai1wm_config_filters).
    let plainByName: Bool

    static let plain = WpressCoding(key: nil, compression: nil, plainByName: false)

    static func keepsEachPackageJSONPlain(pluginVersion: String?) -> Bool {
        pluginVersion.map { VersionLine.isOlder($0, than: "7.102") } ?? false
    }

    func isPlain(_ path: String) -> Bool {
        guard key != nil || compression != nil else {
            return true
        }

        if plainByName {
            return (path as NSString).lastPathComponent == "package.json"
        }

        return ["package.json", "multisite.json"].contains(path)
    }

    // Writes the original bytes of one entry. A stop reaches the copy at its next part. buffer holds
    // each decompressed part, for all entries of one archive.
    func copy(_ entry: WpressArchive.Entry, from file: FileHandle, to output: FileHandle, archive: String, buffer: inout Data) throws {
        let damaged = RuntimeError.unsupported("Nexus cannot unpack \(entry.header.path) from \(archive). The backup is damaged or not complete.")

        func read(_ count: Int) throws -> Data {
            let data = try file.read(upToCount: count) ?? Data()

            guard data.count == count else {
                throw damaged
            }

            return data
        }

        try file.seek(toOffset: entry.offset)
        var left = entry.header.size

        if isPlain(entry.header.path) {
            while left > 0 {
                try Task.checkCancellation()
                let chunk = try file.read(upToCount: Int(min(left, 1 << 20))) ?? Data()

                guard !chunk.isEmpty else {
                    break
                }

                try output.write(contentsOf: chunk)
                left -= Int64(chunk.count)
            }

            return
        }

        while left > 0 {
            try Task.checkCancellation()
            var part: Data

            if compression != nil {
                guard left >= 4 else {
                    throw damaged
                }

                let length = Int64(try read(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                left -= 4

                guard length > 0, length <= left else {
                    throw damaged
                }

                part = try read(Int(length))
                left -= length
            } else {
                let length = left > Int64(Self.partSize) ? min(Int64(Self.partSize + 2 * WpressCipher.ivLength), left) : left
                part = try read(Int(length))
                left -= length
            }

            if let key {
                guard let plain = WpressCipher.decrypt(part, key: key) else {
                    throw damaged
                }

                part = plain
            }

            if let compression {
                guard let length = Self.decompress(part, with: compression, into: &buffer) else {
                    throw damaged
                }

                try output.write(contentsOf: buffer.prefix(length))
            } else {
                try output.write(contentsOf: part)
            }
        }
    }

    private enum Outcome {
        case done(Int)
        case bufferFull
        case failed
    }

    // Gives the length of the decompressed part at the start of buffer. The plugin makes parts of at
    // most 512,000 bytes. A larger buffer only makes the reader safe for a later plugin with larger
    // parts.
    static func decompress(_ part: Data, with compression: BackupCompression, into buffer: inout Data) -> Int? {
        if buffer.count < partSize {
            buffer.count = partSize
        }

        while buffer.count <= 64 * partSize {
            let capacity = buffer.count
            let outcome: Outcome = buffer.withUnsafeMutableBytes { output in
                part.withUnsafeBytes { input in
                    switch compression {
                    case .gzip:
                        var length = uLongf(capacity)
                        let status = uncompress(output.bindMemory(to: Bytef.self).baseAddress, &length, input.bindMemory(to: Bytef.self).baseAddress, uLong(input.count))
                        return status == Z_OK ? .done(Int(length)) : status == Z_BUF_ERROR ? .bufferFull : .failed
                    case .bzip2:
                        var length = UInt32(capacity)
                        let source = UnsafeMutablePointer(mutating: input.bindMemory(to: CChar.self).baseAddress)
                        let status = BZ2_bzBuffToBuffDecompress(output.bindMemory(to: CChar.self).baseAddress, &length, source, UInt32(input.count), 0, 0)
                        return status == BZ_OK ? .done(Int(length)) : status == BZ_OUTBUFF_FULL ? .bufferFull : .failed
                    }
                }
            }

            switch outcome {
            case .done(let length):
                return length
            case .bufferFull:
                buffer.count = capacity * 2
            case .failed:
                return nil
            }
        }

        return nil
    }
}
