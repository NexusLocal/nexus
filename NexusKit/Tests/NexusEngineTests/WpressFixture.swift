import CBzip2
import CommonCrypto
import Foundation
import NexusCore
import zlib

// Writes a .wpress file as Ai1wm_Compressor::add_file of All-in-One WP Migration 7.113 does.
enum WpressFixture {
    struct Failure: Error {
        let step: String
    }

    static let partSize = 512_000
    static let headerLength = 4377

    static func write(_ files: [(path: String, data: Data)], to url: URL, password: String?, compression: BackupCompression?, pluginVersion: String = "7.113", compressionType: String? = nil, signs: Bool = true) throws {
        var package: [String: Any] = [
            "SiteURL": "https://shop.example",
            "HomeURL": "https://shop.example",
            "Database": ["Prefix": "wp_"],
            "Plugin": ["Version": pluginVersion],
            "Plugins": [String](),
            "Template": "twentytwentyfive",
            "Stylesheet": "twentytwentyfive",
        ]

        if let password {
            package["Encrypted"] = true
            package["EncryptedSignature"] = signs ? try encrypt(Data(WpressCipher.signText.utf8), password: password).base64EncodedString() : ""
        }

        if let compression {
            package["Compression"] = ["Enabled": true, "Type": compressionType ?? compression.rawValue]
        }

        let before7102 = pluginVersion.compare("7.102", options: .numeric) == .orderedAscending
        var archive = Data()

        for file in [(path: "package.json", data: try JSONSerialization.data(withJSONObject: package))] + files {
            let staysPlain = before7102 ? (file.path as NSString).lastPathComponent == "package.json" : ["package.json", "multisite.json"].contains(file.path)
            var stored = Data()

            for start in stride(from: 0, to: file.data.count, by: partSize) {
                var part = file.data.subdata(in: start..<min(start + partSize, file.data.count))

                if !staysPlain {
                    switch compression {
                    case .gzip: part = try gzcompress(part)
                    case .bzip2: part = try bzcompress(part)
                    case nil: break
                    }

                    if let password {
                        part = try encrypt(part, password: password)
                    }

                    if compression != nil {
                        part = withUnsafeBytes(of: UInt32(part.count).bigEndian) { Data($0) } + part
                    }
                }

                stored += part
            }

            archive += header(path: file.path, size: stored.count, crc: crc(file.data))
            archive += stored
        }

        archive += Data(count: headerLength)
        try archive.write(to: url)
    }

    static func header(path: String, size: Int, crc: UInt) -> Data {
        let folder = (path as NSString).deletingLastPathComponent
        var header = Data(count: headerLength)

        func put(_ text: String, at offset: Int) {
            let bytes = Data(text.utf8)
            header.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        }

        put((path as NSString).lastPathComponent, at: 0)
        put(String(size), at: 255)
        put("1763150000", at: 269)
        put(folder.isEmpty ? "." : folder, at: 281)
        put(String(format: "%08x", crc), at: 4369)
        return header
    }

    static func crc(_ data: Data) -> UInt {
        data.withUnsafeBytes { bytes in
            crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
        }
    }

    static func gzcompress(_ data: Data) throws -> Data {
        var length = compressBound(uLong(data.count))
        var output = Data(count: Int(length))
        let status = output.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                compress2(target.bindMemory(to: Bytef.self).baseAddress, &length, source.bindMemory(to: Bytef.self).baseAddress, uLong(source.count), 9)
            }
        }

        guard status == Z_OK else {
            throw Failure(step: "compress2")
        }

        return output.prefix(Int(length))
    }

    static func bzcompress(_ data: Data) throws -> Data {
        var input = data
        var length = UInt32(data.count + data.count / 100 + 600)
        var output = Data(count: Int(length))
        let status = output.withUnsafeMutableBytes { target in
            input.withUnsafeMutableBytes { source in
                BZ2_bzBuffToBuffCompress(target.bindMemory(to: CChar.self).baseAddress, &length, source.bindMemory(to: CChar.self).baseAddress, UInt32(source.count), 9, 0, 0)
            }
        }

        guard status == BZ_OK else {
            throw Failure(step: "BZ2_bzBuffToBuffCompress")
        }

        return output.prefix(Int(length))
    }

    static func encrypt(_ data: Data, password: String) throws -> Data {
        let key = WpressKey(password: password).bytes
        let iv = Data((0..<WpressCipher.ivLength).map { _ in UInt8.random(in: .min ... .max) })
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                iv.withUnsafeBytes { vector in
                    key.withUnsafeBytes { keyBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, kCCKeySizeAES256, vector.baseAddress, source.baseAddress, source.count, target.baseAddress, target.count, &moved)
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw Failure(step: "CCCrypt")
        }

        return iv + output.prefix(moved)
    }
}
