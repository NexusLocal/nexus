import Foundation

// One live URL of a WordPress dump and the URL that it gets in a workspace (owner, 2026-11-09,
// docs/dump-url-rewrite.md).
public struct LiveURLRule: Codable, Equatable, Sendable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

// Changes the links of the live URLs in one value. A link matches with https, http or without a
// scheme (//shop.com), with or without www., plain, with the escaped slashes of JSON, or
// URL-encoded. The scheme and the host match without a difference between capitals and small
// letters. The value is read once from left to right, and a changed place is never read again. So
// a new URL that starts with the old URL does not change twice.
public struct LiveURLRewriter: Sendable {
    struct Target: Sendable {
        let host: [UInt8]
        let port: [UInt8]?
        let path: [UInt8]
        let newScheme: [UInt8]
        let newHost: [UInt8]
        let newPath: [UInt8]
    }

    enum Form {
        case plain
        case json
        case encoded(lowercase: Bool)
    }

    let targets: [Target]
    let hosts: [[UInt8]]

    // The longest live URL comes first, so a rule with a path wins over the rule of its host.
    public init?(rules: [LiveURLRule]) {
        var targets: [Target] = []

        for rule in rules {
            guard let from = URLParts(rule.from), let to = URLParts(rule.to), from.scheme == nil || from.isWeb, to.isWeb else {
                continue
            }

            let host = from.host.hasPrefix("www.") ? String(from.host.dropFirst(4)) : from.host
            let target = Target(
                host: Array(host.utf8),
                port: from.port.map { Array($0.utf8) },
                path: Array(from.path.utf8),
                newScheme: Array((to.scheme ?? "https").utf8),
                newHost: Array((to.port.map { "\(to.host):\($0)" } ?? to.host).utf8),
                newPath: Array(to.path.utf8)
            )

            if !targets.contains(where: { $0.host == target.host && $0.port == target.port && $0.path == target.path }) {
                targets.append(target)
            }
        }

        guard !targets.isEmpty else {
            return nil
        }

        self.targets = targets.sorted { first, second in
            if first.path.count != second.path.count {
                return first.path.count > second.path.count
            }

            return (first.port != nil) && second.port == nil
        }

        hosts = targets.reduce(into: []) { hosts, target in
            if !hosts.contains(target.host) {
                hosts.append(target.host)
            }
        }
    }

    // A fast check before the value is decoded. Each form of a link holds the host as plain text.
    public func mayContain(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        hosts.contains { host in Self.find(host, in: bytes) }
    }

    public func mayContain(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer(mayContain)
    }

    // nil when the value has no link of a live URL.
    public func rewrite(_ text: [UInt8]) -> (bytes: [UInt8], links: Int)? {
        guard mayContain(text) else {
            return nil
        }

        var output: [UInt8] = []
        var links = 0
        var copied = 0
        var index = 0

        while index < text.count {
            let byte = text[index]

            if byte == Byte.h || byte == Byte.capitalH || byte == Byte.slash || byte == Byte.backslash || byte == Byte.percent, let found = match(text, at: index) {
                output.append(contentsOf: text[copied..<index])
                output.append(contentsOf: found.replacement)
                links += 1
                index = found.end
                copied = index
                continue
            }

            index += 1
        }

        guard links > 0 else {
            return nil
        }

        output.append(contentsOf: text[copied...])
        return (output, links)
    }

    private func match(_ text: [UInt8], at start: Int) -> (end: Int, replacement: [UInt8])? {
        var index = start
        let hasScheme = Byte.lower(text[start]) == Byte.h
        let form: Form

        if hasScheme {
            guard start == 0 || !Byte.isSchemeByte(text[start - 1]), Self.has(text, at: index, Pattern.http) else {
                return nil
            }

            index += 4

            if index < text.count, Byte.lower(text[index]) == UInt8(ascii: "s") {
                index += 1
            }

            if Self.has(text, at: index, Pattern.colonSlashes) {
                form = .plain
                index += 3
            } else if Self.has(text, at: index, Pattern.jsonColonSlashes) {
                form = .json
                index += 5
            } else if Self.has(text, at: index, Pattern.encodedColonSlashes) {
                form = .encoded(lowercase: text[index + 2] == UInt8(ascii: "a"))
                index += 9
            } else {
                return nil
            }
        } else {
            guard start == 0 || !Byte.isBeforeSlashes(text[start - 1]) else {
                return nil
            }

            if Self.has(text, at: index, Pattern.slashes) {
                form = .plain
                index += 2
            } else if Self.has(text, at: index, Pattern.jsonSlashes) {
                form = .json
                index += 4
            } else if Self.has(text, at: index, Pattern.encodedSlashes) {
                form = .encoded(lowercase: text[index + 2] == UInt8(ascii: "f"))
                index += 6
            } else {
                return nil
            }
        }

        if Self.has(text, at: index, Pattern.www) {
            index += 4
        }

        for target in targets where Self.has(text, at: index, target.host) {
            var end = index + target.host.count
            let afterColon = Self.colon(in: text, at: end, form: form)

            if let port = target.port {
                guard let afterColon, Self.hasExactly(text, at: afterColon, port) else {
                    continue
                }

                end = afterColon + port.count

                if end < text.count, Byte.isDigit(text[end]) {
                    continue
                }
            } else if let afterColon, afterColon < text.count, Byte.isDigit(text[afterColon]) {
                continue
            }

            if !target.path.isEmpty {
                let path = Self.encoded(target.path, form: form)

                guard Self.hasExactly(text, at: end, path) else {
                    continue
                }

                end += path.count
            }

            guard Self.endsAtBoundary(text, at: end) else {
                continue
            }

            return (end, replacement(for: target, hasScheme: hasScheme, form: form))
        }

        return nil
    }

    private func replacement(for target: Target, hasScheme: Bool, form: Form) -> [UInt8] {
        var bytes: [UInt8] = []

        if hasScheme {
            bytes += target.newScheme
            bytes += Self.encoded(Array(":".utf8), form: form)
        }

        bytes += Self.encoded(Array("//".utf8), form: form)
        bytes += Self.encoded(target.newHost, form: form, slashes: false)
        bytes += Self.encoded(target.newPath, form: form)
        return bytes
    }

    // The colon and the slashes of a form. JSON escapes only the slashes.
    private static func encoded(_ bytes: [UInt8], form: Form, slashes: Bool = true) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count + 8)

        for byte in bytes {
            switch (form, byte) {
            case (.json, Byte.slash) where slashes:
                result += [Byte.backslash, Byte.slash]
            case (.encoded(let lowercase), Byte.slash) where slashes:
                result += Array((lowercase ? "%2f" : "%2F").utf8)
            case (.encoded(let lowercase), Byte.colon):
                result += Array((lowercase ? "%3a" : "%3A").utf8)
            default:
                result.append(byte)
            }
        }

        return result
    }

    private static func colon(in text: [UInt8], at index: Int, form: Form) -> Int? {
        switch form {
        case .plain, .json:
            return index < text.count && text[index] == Byte.colon ? index + 1 : nil
        case .encoded:
            return has(text, at: index, Pattern.encodedColon) ? index + 3 : nil
        }
    }

    // After the host: no letter, digit, - or _. A dot ends a sentence only without a letter or a
    // digit after it.
    private static func endsAtBoundary(_ text: [UInt8], at index: Int) -> Bool {
        guard index < text.count else {
            return true
        }

        let byte = text[index]

        if Byte.isAlphanumeric(byte) || byte == Byte.hyphen || byte == Byte.underscore {
            return false
        }

        if byte == Byte.dot, index + 1 < text.count, Byte.isAlphanumeric(text[index + 1]) {
            return false
        }

        return true
    }

    // The pattern is in small letters. Capitals in the text match too.
    static func has(_ text: [UInt8], at index: Int, _ pattern: [UInt8]) -> Bool {
        guard index + pattern.count <= text.count else {
            return false
        }

        for offset in 0..<pattern.count where Byte.lower(text[index + offset]) != pattern[offset] {
            return false
        }

        return true
    }

    private static func hasExactly(_ text: [UInt8], at index: Int, _ pattern: [UInt8]) -> Bool {
        guard index + pattern.count <= text.count else {
            return false
        }

        for offset in 0..<pattern.count where text[index + offset] != pattern[offset] {
            return false
        }

        return true
    }

    static func find(_ pattern: [UInt8], in bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let first = pattern.first, bytes.count >= pattern.count else {
            return false
        }

        let last = bytes.count - pattern.count
        var index = 0

        while index <= last {
            if Byte.lower(bytes[index]) == first {
                var offset = 1

                while offset < pattern.count, Byte.lower(bytes[index + offset]) == pattern[offset] {
                    offset += 1
                }

                if offset == pattern.count {
                    return true
                }
            }

            index += 1
        }

        return false
    }
}

// The scheme, the host in small letters, the port when it is not the standard port, and the path
// without a slash at the end.
struct URLParts {
    let scheme: String?
    let host: String
    let port: String?
    let path: String

    var isWeb: Bool {
        scheme == "http" || scheme == "https"
    }

    init?(_ url: String) {
        var text = Substring(url.trimmingCharacters(in: .whitespaces))
        var scheme: String?

        if let separator = text.range(of: "://") {
            scheme = text[..<separator.lowerBound].lowercased()
            text = text[separator.upperBound...]
        } else if text.hasPrefix("//") {
            text = text.dropFirst(2)
        }

        let authorityEnd = text.firstIndex { "/?#".contains($0) } ?? text.endIndex
        let authority = text[..<authorityEnd]
        var path = text[authorityEnd...].prefix { $0 != "?" && $0 != "#" }

        while path.hasSuffix("/") {
            path = path.dropLast()
        }

        var host = authority
        var port: String?

        if let colon = authority.lastIndex(of: ":"), !authority[authority.index(after: colon)...].isEmpty, authority[authority.index(after: colon)...].allSatisfy(\.isASCIIDigit) {
            host = authority[..<colon]
            port = String(authority[authority.index(after: colon)...])
        }

        guard !host.isEmpty, host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            return nil
        }

        let standardPort = ["https": "443", "http": "80"][scheme ?? ""]

        self.scheme = scheme
        self.host = host.lowercased()
        self.port = port == standardPort ? nil : port
        self.path = String(path)
    }
}

// The parts of a link, in small letters, made once.
enum Pattern {
    static let http = Array("http".utf8)
    static let colonSlashes = Array("://".utf8)
    static let jsonColonSlashes = Array(#":\/\/"#.utf8)
    static let encodedColonSlashes = Array("%3a%2f%2f".utf8)
    static let slashes = Array("//".utf8)
    static let jsonSlashes = Array(#"\/\/"#.utf8)
    static let encodedSlashes = Array("%2f%2f".utf8)
    static let encodedColon = Array("%3a".utf8)
    static let www = Array("www.".utf8)
}

enum Byte {
    static let h = UInt8(ascii: "h")
    static let capitalH = UInt8(ascii: "H")
    static let slash = UInt8(ascii: "/")
    static let backslash = UInt8(ascii: "\\")
    static let percent = UInt8(ascii: "%")
    static let colon = UInt8(ascii: ":")
    static let hyphen = UInt8(ascii: "-")
    static let underscore = UInt8(ascii: "_")
    static let dot = UInt8(ascii: ".")
    static let plus = UInt8(ascii: "+")

    @inline(__always) static func lower(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    @inline(__always) static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
    }

    @inline(__always) static func isAlphanumeric(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }

    // A letter before http belongs to another word or scheme.
    static func isSchemeByte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == plus || byte == dot || byte == hyphen
    }

    // ftp://shop.com and the // inside https:// do not count as a link without a scheme.
    static func isBeforeSlashes(_ byte: UInt8) -> Bool {
        isSchemeByte(byte) || byte == colon
    }
}
