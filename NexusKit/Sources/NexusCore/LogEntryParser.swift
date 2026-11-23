import Foundation

// The parts of an entry that a row of the Logs screen shows (group 7).
public struct LogEntrySummary: Sendable, Equatable {
    public let message: String
    public let exceptionClass: String?
    public let sourceFile: String?
    public let sourceLine: Int?
    // Short pairs of the context, such as "order_id 1042".
    public let context: [String]

    public init(message: String, exceptionClass: String? = nil, sourceFile: String? = nil, sourceLine: Int? = nil, context: [String] = []) {
        self.message = message
        self.exceptionClass = exceptionClass
        self.sourceFile = sourceFile
        self.sourceLine = sourceLine
        self.context = context
    }
}

public struct LogFrame: Sendable, Equatable {
    public let number: Int?
    public let file: String?
    public let line: Int?
    public let call: String

    public init(number: Int?, file: String?, line: Int?, call: String) {
        self.number = number
        self.file = file
        self.line = line
        self.call = call
    }

    public var isVendor: Bool {
        file?.contains("/vendor/") ?? true
    }
}

public struct LogException: Sendable, Equatable {
    public let className: String
    public let message: String
    public let file: String?
    public let line: Int?
    public let frames: [LogFrame]

    public var shortClassName: String {
        className.split(separator: "\\").last.map(String.init) ?? className
    }

    public var namespace: String {
        className.count > shortClassName.count ? String(className.dropLast(shortClassName.count)) : ""
    }
}

// A value of request_id, trace_id and the other keys that the Logs screen can search for.
public struct LogID: Sendable, Equatable, Hashable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct LogEntryDetail: Sendable, Equatable {
    public let message: String
    public let characters: Int
    public let isCut: Bool
    public let exceptions: [LogException]
    public let context: DumpNode?
    public let ids: [LogID]
    // The channel of Monolog, such as local or testing, and the time as the log wrote it.
    public var channel: String? = nil
    public var logTime: String? = nil

    // A text for a coding agent: the message, the exception with the frames of the app, and the
    // context as JSON lines.
    public func markdown(level: String, time: String, file: String, project: String) -> String {
        var lines = ["**\(level.isEmpty ? "log" : level)** \(time) in `\(file)`", "", "```", message, "```"]

        for exception in exceptions {
            let place = exception.file.map { " at `\(LogEntryParser.relative($0, to: project)):\(exception.line ?? 0)`" } ?? ""
            lines += ["", "**\(exception.className)**\(place)", ""]

            for frame in exception.frames where !frame.isVendor {
                let file = frame.file.map { "\(LogEntryParser.relative($0, to: project)):\(frame.line ?? 0) " } ?? ""
                lines.append("- `#\(frame.number ?? 0)` \(file)`\(frame.call)`")
            }

            let vendor = exception.frames.filter(\.isVendor).count

            if vendor > 0 {
                lines.append("- \(Count.text(vendor, "frame")) in vendor/ left out")
            }
        }

        if let context, let children = context.children, !children.isEmpty {
            lines += ["", "Context:", "```"]
            lines += children.map { "\($0.key ?? ""): \(LogEntryText.plain($0))" }
            lines.append("```")
        }

        return lines.joined(separator: "\n")
    }
}

public enum LogEntryText {
    // A value of the context on one line, as JSON without quotes around the keys.
    public static func plain(_ node: DumpNode) -> String {
        switch node.kind {
        case .string:
            return "\"\(node.value ?? "")\""
        case .array:
            let children = node.children ?? []
            let keyed = children.contains { $0.index != true }
            let parts = children.map { keyed ? "\($0.key ?? ""): \(plain($0))" : plain($0) }
            return keyed ? "{\(parts.joined(separator: ", "))}" : "[\(parts.joined(separator: ", "))]"
        default:
            return node.value ?? ""
        }
    }
}

public enum LogEntryParser {
    // The detail shows this many characters of a message (owner, 2026-11-23).
    public static let shownCharacters = 10_000
    static let idKeys: Set<String> = ["request_id", "trace_id", "correlation_id", "job_id", "batch_id", "session_id", "requestId", "traceId", "correlationId", "jobId", "batchId"]

    public static func summary(of text: String, kind: LogFile.Kind) -> LogEntrySummary {
        let (header, body) = split(text, kind: kind)
        _ = header
        let firstLine = String(body.prefix { $0 != "\n" })

        if kind == .requests {
            return LogEntrySummary(message: requestLine(text))
        }

        if kind != .app {
            let php = phpSource(of: firstLine)
            return LogEntrySummary(message: cut(php.message), sourceFile: php.file, sourceLine: php.line)
        }

        let context = contextRange(in: body)
        var message = context.map { String(body[..<$0.lowerBound]) } ?? body
        message = String(message.prefix { $0 != "\n" }).trimmingCharacters(in: .whitespaces)

        if let marker = firstLine.range(of: #"[object] ("#) {
            let className = String(firstLine[marker.upperBound...].prefix { $0 != "(" })
            // An exception of Laravel often starts in vendor/. The row shows the first line of the
            // app, because that is the line to fix.
            let origin = exceptionSource(in: body)
            let source = origin.flatMap { $0.file.contains("/vendor/") ? firstAppFrame(in: body) ?? $0 : $0 }
            let pairs = context.flatMap { range in parseJSON(String(body[range])) }.map { pairsPreview($0) } ?? []
            return LogEntrySummary(message: cut(message), exceptionClass: className.split(separator: "\\").last.map(String.init), sourceFile: source?.file, sourceLine: source?.line, context: pairs)
        }

        if message.hasPrefix("PHP ") || message.hasPrefix("WordPress database error") {
            let php = phpSource(of: firstLine)
            return LogEntrySummary(message: cut(php.message), sourceFile: php.file, sourceLine: php.line)
        }

        let pairs = context.flatMap { range in parseJSON(String(body[range])) }.map { pairsPreview($0) } ?? []
        return LogEntrySummary(message: cut(message), context: pairs)
    }

    public static func detail(of text: String, kind: LogFile.Kind, isCut: Bool) -> LogEntryDetail {
        var detail = parsedDetail(of: text, kind: kind, isCut: isCut)
        let header = split(text, kind: kind).header

        if let match = header.firstMatch(of: #/^\[([^\]]+)\](?: ([\w-]+)\.[A-Z]+:)?/#) {
            detail.logTime = String(match.output.1)
            detail.channel = match.output.2.map(String.init)
        }

        return detail
    }

    private static func parsedDetail(of text: String, kind: LogFile.Kind, isCut: Bool) -> LogEntryDetail {
        let (_, body) = split(text, kind: kind)

        if kind == .requests {
            return LogEntryDetail(message: text, characters: text.count, isCut: isCut, exceptions: [], context: nil, ids: [])
        }

        if kind != .app || body.hasPrefix("PHP ") || body.hasPrefix("WordPress database error") {
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { kind == .phpErrors ? stripFPMPrefix(String($0)) : String($0) }
            let php = phpSource(of: lines.first ?? "")
            let frames = lines.dropFirst().compactMap(frame)
            let exception = php.file == nil && frames.isEmpty ? [] : [LogException(className: php.level, message: php.message, file: php.file, line: php.line, frames: frames)]
            let message = lines.joined(separator: "\n")
            return LogEntryDetail(message: String(message.prefix(shownCharacters)), characters: message.count, isCut: isCut || message.count > shownCharacters, exceptions: exception, context: nil, ids: [])
        }

        let contextRange = contextRange(in: body)
        let message = (contextRange.map { String(body[..<$0.lowerBound]) } ?? body).trimmingCharacters(in: .whitespacesAndNewlines)
        var exceptions: [LogException] = []
        var context: DumpNode?
        var ids: [LogID] = []

        if let contextRange, let parsed = parseJSON(String(body[contextRange])) {
            var children: [DumpNode] = []

            for node in parsed {
                if node.key == "exception", node.kind == .string, let value = node.value, value.hasPrefix("[object] (") {
                    exceptions = Self.exceptions(in: value)
                    continue
                }

                children.append(node)

                if let key = node.key, idKeys.contains(key), let value = node.value, node.kind == .string || node.kind == .int {
                    ids.append(LogID(key: key, value: value))
                }
            }

            context = children.isEmpty ? nil : DumpNode(kind: .array, count: children.count, children: children)
        }

        return LogEntryDetail(message: String(message.prefix(shownCharacters)), characters: message.count, isCut: isCut || message.count > shownCharacters, exceptions: exceptions, context: context, ids: ids)
    }

    // A path in the project without the folder of the project.
    public static func relative(_ path: String, to project: String) -> String {
        for prefix in LogFolders.prefixes(of: project) where path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }

        return path
    }

    // MARK: Parts

    // The time, the channel and the level at the start of the first line, and the rest.
    static func split(_ text: String, kind: LogFile.Kind) -> (header: String, body: String) {
        switch kind {
        case .app, .phpErrors:
            if kind == .phpErrors, let range = text.range(of: "PHP message: "), text.distance(from: text.startIndex, to: range.lowerBound) < 24 {
                return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
            }

            if let match = text.prefixMatch(of: #/\[[^\]\n]{10,40}\] (?:[\w-]+\.[A-Z]+: )?/#) {
                return (String(match.output), String(text[match.range.upperBound...]))
            }

            return ("", text)
        case .requests, .output:
            return ("", text)
        }
    }

    // GET /checkout HTTP/2.0 of an access line.
    static func requestLine(_ text: String) -> String {
        guard let open = text.firstIndex(of: "\""), let close = text[text.index(after: open)...].firstIndex(of: "\"") else {
            return text
        }

        let request = text[text.index(after: open)..<close]
        let parts = request.split(separator: " ")
        return parts.count >= 2 ? "\(parts[0]) \(parts[1])" : String(request)
    }

    // PHP Warning:  Undefined array key "price" in /path/functions.php on line 212
    static func phpSource(of line: String) -> (level: String, message: String, file: String?, line: Int?) {
        var text = line
        var level = "PHP"

        if let match = text.prefixMatch(of: #/PHP ([A-Za-z ]+?):\s+/#) {
            level = String(match.output.1)
            text = String(text[match.range.upperBound...])
        }

        guard let place = text.firstMatch(of: #/ in (/[^\n]+?)(?: on line |:)(\d+)$/#) else {
            return (level, text, nil, nil)
        }

        return (level, String(text[..<place.range.lowerBound]), String(place.output.1), Int(place.output.2))
    }

    static func stripFPMPrefix(_ line: String) -> String {
        guard let match = line.prefixMatch(of: #/[A-Z]+: (?:PHP message: )?/#) else {
            return line
        }

        return String(line[match.range.upperBound...])
    }

    // The file and the line of the first exception: " at /path/File.php:131)" before the stack
    // trace.
    static func exceptionSource(in body: String) -> (file: String, line: Int)? {
        let head = body.range(of: "\n[stacktrace]").map { body[..<$0.lowerBound] } ?? body[...]

        guard let match = head.firstMatch(of: #/ at (/[^\n]+?):(\d+)\)/#), let line = Int(match.output.2) else {
            return nil
        }

        return (String(match.output.1), line)
    }

    static func firstAppFrame(in body: String) -> (file: String, line: Int)? {
        guard let trace = body.range(of: "\n[stacktrace]\n") else {
            return nil
        }

        for line in body[trace.upperBound...].split(separator: "\n") {
            guard line.hasPrefix("#") else {
                break
            }

            if let frame = frame(String(line)), let file = frame.file, let number = frame.line, !frame.isVendor {
                return (file, number)
            }
        }

        return nil
    }

    // [object] (Class(code: 0): message at /path:12)\n[stacktrace]\n#0 ...\n[previous exception] ...
    static func exceptions(in value: String) -> [LogException] {
        value.components(separatedBy: "\n[previous exception] ").compactMap { part in
            let pieces = part.components(separatedBy: "\n[stacktrace]\n")
            var head = pieces[0]

            guard head.hasPrefix("[object] (") else {
                return nil
            }

            head.removeFirst(10)

            if head.hasSuffix(")") {
                head.removeLast()
            }

            guard let code = head.range(of: "(code: ") else {
                return nil
            }

            let className = String(head[..<code.lowerBound])
            var rest = head[code.upperBound...]

            if let close = rest.range(of: "): ") {
                rest = rest[close.upperBound...]
            }

            var message = String(rest)
            var file: String?
            var line: Int?

            if let place = message.firstMatch(of: #/ at (/[^\n]+?):(\d+)$/#) {
                file = String(place.output.1)
                line = Int(place.output.2)
                message = String(message[..<place.range.lowerBound])
            }

            let frames = pieces.count > 1 ? pieces[1].split(separator: "\n").compactMap { frame(String($0)) } : []
            return LogException(className: className, message: message, file: file, line: line, frames: frames)
        }
    }

    // #0 /path/File.php(131): Class->method() or #1 [internal function]: ... or #2 {main}
    static func frame(_ line: String) -> LogFrame? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        guard let match = trimmed.prefixMatch(of: #/#(\d+) /#) else {
            return nil
        }

        let rest = trimmed[match.range.upperBound...]
        let number = Int(match.output.1)

        if let place = rest.prefixMatch(of: #/(/[^(]+)\((\d+)\): /#) {
            return LogFrame(number: number, file: String(place.output.1), line: Int(place.output.2), call: String(rest[place.range.upperBound...]))
        }

        return LogFrame(number: number, file: nil, line: nil, call: String(rest))
    }

    // The context of Monolog: a JSON object after the message, and maybe a second one (extra). The
    // message can hold JSON too. So the range must end at the end of the entry.
    static func contextRange(in body: String) -> Range<String.Index>? {
        let bytes = Array(body.utf8)
        var candidate = 0

        while candidate + 2 < bytes.count {
            guard bytes[candidate] == UInt8(ascii: " ") || bytes[candidate] == 10, bytes[candidate + 1] == UInt8(ascii: "{"), bytes[candidate + 2] == UInt8(ascii: "\"") else {
                candidate += 1
                continue
            }

            if let end = JSONScanner.end(of: bytes, from: candidate + 1), restIsExtra(bytes, from: end) {
                let start = body.utf8.index(body.startIndex, offsetBy: candidate + 1)
                let stop = body.utf8.index(body.startIndex, offsetBy: bytes.count)
                return start..<stop
            }

            candidate += 1
        }

        return nil
    }

    private static func restIsExtra(_ bytes: [UInt8], from start: Int) -> Bool {
        var index = start

        while index < bytes.count, bytes[index] == 32 || bytes[index] == 10 || bytes[index] == 13 {
            index += 1
        }

        guard index < bytes.count else {
            return true
        }

        guard bytes[index] == UInt8(ascii: "{") || bytes[index] == UInt8(ascii: "["), let end = JSONScanner.end(of: bytes, from: index) else {
            return false
        }

        return bytes[end...].allSatisfy { $0 == 32 || $0 == 10 || $0 == 13 }
    }

    // The nodes of the context and of the extra part, in the order of the log.
    static func parseJSON(_ text: String) -> [DumpNode]? {
        var parser = JSONScanner(bytes: Array(text.utf8))
        var nodes: [DumpNode] = []

        while let value = parser.nextTopValue() {
            if value.kind == .array, let children = value.children {
                nodes += children
            }
        }

        return parser.failed ? nil : nodes
    }

    static func pairsPreview(_ nodes: [DumpNode]) -> [String] {
        nodes.filter { $0.key != "exception" && $0.children == nil && $0.value != nil }
            .prefix(2)
            .map { node in
                let value = node.value ?? ""
                return "\(node.key ?? "") \(value.count > 12 ? "\(value.prefix(12))…" : value)"
            }
    }

    static func cut(_ text: String) -> String {
        text.count > 500 ? String(text.prefix(500)) : text
    }
}

// A small reader of JSON that keeps the order of the keys. Monolog writes a line break in a value
// as a real line break, which plain JSON does not permit. This reader accepts it.
struct JSONScanner {
    let bytes: [UInt8]
    var index = 0
    var failed = false
    private var depth = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    // The index after the end of the object or the array that starts at start.
    static func end(of bytes: [UInt8], from start: Int) -> Int? {
        var depth = 0
        var index = start
        var inString = false

        while index < bytes.count {
            let byte = bytes[index]

            if inString {
                if byte == UInt8(ascii: "\\") {
                    index += 2
                    continue
                }

                if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                depth += 1
            } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                depth -= 1

                if depth == 0 {
                    return index + 1
                }
            }

            index += 1
        }

        return nil
    }

    mutating func nextTopValue() -> DumpNode? {
        skipSpace()

        guard index < bytes.count, !failed else {
            return nil
        }

        return value(key: nil, isIndex: false)
    }

    private mutating func value(key: String?, isIndex: Bool) -> DumpNode? {
        skipSpace()

        guard index < bytes.count, depth < 64 else {
            failed = true
            return nil
        }

        switch bytes[index] {
        case UInt8(ascii: "{"):
            return container(key: key, isIndex: isIndex, close: UInt8(ascii: "}"), keyed: true)
        case UInt8(ascii: "["):
            return container(key: key, isIndex: isIndex, close: UInt8(ascii: "]"), keyed: false)
        case UInt8(ascii: "\""):
            guard let text = string() else {
                return nil
            }

            return DumpNode(kind: .string, key: key, index: isIndex ? true : nil, value: text, length: text.count)
        default:
            let start = index

            while index < bytes.count, !",}] \n\r\t".utf8.contains(bytes[index]) {
                index += 1
            }

            let word = String(decoding: bytes[start..<index], as: UTF8.self)

            switch word {
            case "true", "false": return DumpNode(kind: .bool, key: key, index: isIndex ? true : nil, value: word)
            case "null": return DumpNode(kind: .null, key: key, index: isIndex ? true : nil, value: "null")
            default:
                guard Double(word) != nil else {
                    failed = true
                    return nil
                }

                return DumpNode(kind: word.contains(".") || word.contains("e") ? .float : .int, key: key, index: isIndex ? true : nil, value: word)
            }
        }
    }

    private mutating func container(key: String?, isIndex: Bool, close: UInt8, keyed: Bool) -> DumpNode? {
        index += 1
        depth += 1
        defer { depth -= 1 }
        var children: [DumpNode] = []

        while true {
            skipSpace()

            guard index < bytes.count else {
                failed = true
                return nil
            }

            if bytes[index] == close {
                index += 1
                break
            }

            if !children.isEmpty {
                guard bytes[index] == UInt8(ascii: ",") else {
                    failed = true
                    return nil
                }

                index += 1
                skipSpace()
            }

            var childKey = String(children.count)

            if keyed {
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let name = string() else {
                    failed = true
                    return nil
                }

                skipSpace()

                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                    failed = true
                    return nil
                }

                index += 1
                childKey = name
            }

            guard let child = value(key: childKey, isIndex: !keyed) else {
                return nil
            }

            children.append(child)
        }

        return DumpNode(kind: .array, key: key, index: isIndex ? true : nil, count: children.count, children: children)
    }

    private mutating func string() -> String? {
        index += 1
        var result: [UInt8] = []

        while index < bytes.count {
            let byte = bytes[index]

            if byte == UInt8(ascii: "\"") {
                index += 1
                return String(decoding: result, as: UTF8.self)
            }

            if byte == UInt8(ascii: "\\"), index + 1 < bytes.count {
                let escaped = bytes[index + 1]
                index += 2

                switch escaped {
                case UInt8(ascii: "n"): result.append(10)
                case UInt8(ascii: "t"): result.append(9)
                case UInt8(ascii: "r"): result.append(13)
                case UInt8(ascii: "b"): result.append(8)
                case UInt8(ascii: "f"): result.append(12)
                case UInt8(ascii: "u"):
                    guard index + 4 <= bytes.count, let code = UInt32(String(decoding: bytes[index..<(index + 4)], as: UTF8.self), radix: 16) else {
                        failed = true
                        return nil
                    }

                    index += 4
                    var scalar = code

                    // A high surrogate without a low surrogate after it stays alone and gives a ?.
                    if (0xD800...0xDBFF).contains(code), index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u"), let low = UInt32(String(decoding: bytes[(index + 2)..<(index + 6)], as: UTF8.self), radix: 16), (0xDC00...0xDFFF).contains(low) {
                        scalar = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        index += 6
                    }

                    result.append(contentsOf: Array(String(Unicode.Scalar(scalar).map(Character.init) ?? "?").utf8))
                default:
                    result.append(escaped)
                }

                continue
            }

            result.append(byte)
            index += 1
        }

        failed = true
        return nil
    }

    private mutating func skipSpace() {
        while index < bytes.count, bytes[index] == 32 || bytes[index] == 10 || bytes[index] == 13 || bytes[index] == 9 {
            index += 1
        }
    }
}
