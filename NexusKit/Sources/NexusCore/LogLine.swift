import Foundation

// The four groups of the level filter on the Logs screen (group 7). Each level of Monolog, PHP and
// the status of a request belongs to one group.
public enum LogLevelGroup: String, Codable, Sendable, CaseIterable {
    case error
    case warning
    case info
    case debug

    public var title: String {
        switch self {
        case .error: "Error"
        case .warning: "Warning"
        case .info: "Info"
        case .debug: "Debug"
        }
    }

    public static func of(level: String) -> LogLevelGroup {
        switch level {
        case "emergency", "alert", "critical", "error": .error
        case "warning": .warning
        case "debug": .debug
        default:
            if let status = Int(level) {
                status >= 500 ? .error : status >= 400 ? .warning : .info
            } else {
                .info
            }
        }
    }
}

// The first line of an entry. messageStart is the byte where the message starts in the line.
struct LogLineStart {
    let date: Double?
    let level: String
    let channel: String?
    let messageStart: Int
    let messageEnd: Int
}

// Reads the first line of an entry in each format that the Logs screen knows. It works on bytes,
// because it reads each line of a large file.
struct LogLineParser {
    let kind: LogFile.Kind
    let zone: TimeZone
    private var offsets: [Int: Int] = [:]
    private var zones: [String: TimeZone] = [:]

    init(kind: LogFile.Kind, zone: TimeZone) {
        self.kind = kind
        self.zone = zone
    }

    mutating func start(of line: UnsafeBufferPointer<UInt8>) -> LogLineStart? {
        switch kind {
        case .app:
            laravel(line) ?? php(line)
        case .phpErrors:
            fpm(line) ?? php(line)
        case .requests:
            access(line)
        case .output:
            nil
        }
    }

    // [2026-11-23 14:18:31] local.ERROR: The message {"key":"value"} or the format of Monolog
    // with a T, parts of a second and a zone: [2026-11-23T14:18:31.123456+01:00].
    private mutating func laravel(_ line: UnsafeBufferPointer<UInt8>) -> LogLineStart? {
        guard line.count > 25, line[0] == ascii("["), let year = number(line, 1, 4), line[5] == ascii("-"), let month = number(line, 6, 2), line[8] == ascii("-"), let day = number(line, 9, 2), line[11] == ascii(" ") || line[11] == ascii("T"), let hour = number(line, 12, 2), line[14] == ascii(":"), let minute = number(line, 15, 2), line[17] == ascii(":"), let second = number(line, 18, 2) else {
            return nil
        }

        var index = 20
        var fraction = 0.0
        var explicitOffset: Int?

        if index < line.count, line[index] == ascii(".") {
            var scale = 0.1
            index += 1

            while index < line.count, let digit = digit(line[index]) {
                fraction += Double(digit) * scale
                scale /= 10
                index += 1
            }
        }

        if index + 5 < line.count, line[index] == ascii("+") || line[index] == ascii("-"), let hours = number(line, index + 1, 2), line[index + 3] == ascii(":"), let minutes = number(line, index + 4, 2) {
            explicitOffset = (hours * 3600 + minutes * 60) * (line[index] == ascii("-") ? -1 : 1)
            index += 6
        } else if index < line.count, line[index] == ascii("Z") {
            explicitOffset = 0
            index += 1
        }

        guard index + 1 < line.count, line[index] == ascii("]"), line[index + 1] == ascii(" ") else {
            return nil
        }

        let channelStart = index + 2
        var dot = channelStart

        while dot < line.count, isNameByte(line[dot]) {
            dot += 1
        }

        guard dot > channelStart, dot < line.count, line[dot] == ascii(".") else {
            return nil
        }

        var colon = dot + 1

        while colon < line.count, line[colon] >= ascii("A"), line[colon] <= ascii("Z") {
            colon += 1
        }

        guard colon > dot + 1, colon < line.count, line[colon] == ascii(":") else {
            return nil
        }

        let local = Self.seconds(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        let date = local - Double(explicitOffset ?? offset(of: zone, local: local)) + fraction
        let channel = string(line, channelStart, dot)
        let level = string(line, dot + 1, colon).lowercased()
        let messageStart = min(colon + 2, line.count)

        return LogLineStart(date: date, level: level, channel: channel, messageStart: messageStart, messageEnd: Self.contextStart(line, from: messageStart) ?? Self.trimmedEnd(line))
    }

    // [23-Nov-2026 14:18:31 UTC] PHP Warning:  Undefined array key "price" in /path on line 212.
    // The zone is a name, an abbreviation or missing. Without it PHP wrote the local time.
    private mutating func php(_ line: UnsafeBufferPointer<UInt8>) -> LogLineStart? {
        guard line.count > 22, line[0] == ascii("["), let day = number(line, 1, 2), line[3] == ascii("-"), let month = Self.month(line, 4), line[7] == ascii("-"), let year = number(line, 8, 4), line[12] == ascii(" "), let hour = number(line, 13, 2), line[15] == ascii(":"), let minute = number(line, 16, 2), line[18] == ascii(":"), let second = number(line, 19, 2) else {
            return nil
        }

        var close = 21
        var lineZone = TimeZone.current

        if line[close] == ascii(" ") {
            let zoneStart = close + 1

            while close < line.count, line[close] != ascii("]") {
                close += 1
            }

            let name = string(line, zoneStart, close)
            lineZone = zoneNamed(name) ?? .current
        }

        guard close < line.count, line[close] == ascii("]") else {
            return nil
        }

        var messageStart = close + 1

        while messageStart < line.count, line[messageStart] == ascii(" ") {
            messageStart += 1
        }

        let local = Self.seconds(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        let date = local - Double(offset(of: lineZone, local: local))

        return LogLineStart(date: date, level: Self.phpLevel(line, from: messageStart) ?? "info", channel: nil, messageStart: messageStart, messageEnd: Self.trimmedEnd(line))
    }

    // The PHP-FPM log of Nexus: NOTICE: PHP message: PHP Warning:  ... PHP-FPM writes no time for
    // the messages of a worker. A line of a message with more lines has no "PHP " after the prefix.
    private func fpm(_ line: UnsafeBufferPointer<UInt8>) -> LogLineStart? {
        guard let prefix = Self.find("PHP message: ", in: line, before: 24) else {
            return nil
        }

        let messageStart = prefix + 13

        guard let level = Self.phpLevel(line, from: messageStart) else {
            return nil
        }

        return LogLineStart(date: nil, level: level, channel: nil, messageStart: messageStart, messageEnd: Self.trimmedEnd(line))
    }

    // The access log of nginx: ::1 - - [08/Nov/2026:21:40:50 +0100] "GET / HTTP/2.0" 302 362 ...
    // The level is the status.
    private func access(_ line: UnsafeBufferPointer<UInt8>) -> LogLineStart? {
        guard let open = Self.find("[", in: line, before: 64), open + 28 < line.count, let day = number(line, open + 1, 2), line[open + 3] == ascii("/"), let month = Self.month(line, open + 4), line[open + 7] == ascii("/"), let year = number(line, open + 8, 4), let hour = number(line, open + 13, 2), let minute = number(line, open + 16, 2), let second = number(line, open + 19, 2), let hours = number(line, open + 23, 2), let minutes = number(line, open + 25, 2) else {
            return nil
        }

        let sign = line[open + 22] == ascii("-") ? -1 : 1
        let local = Self.seconds(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        let date = local - Double(sign * (hours * 3600 + minutes * 60))
        let messageStart = min(open + 29, line.count)
        var quote = messageStart + 1

        while quote < line.count, line[quote] != ascii("\"") {
            quote += 1
        }

        let status = quote + 4 < line.count ? string(line, quote + 2, quote + 5) : ""

        return LogLineStart(date: date, level: Int(status) == nil ? "info" : status, channel: nil, messageStart: messageStart, messageEnd: min(quote + 5, line.count))
    }

    // The context of Monolog starts with  {" at the end of the first line, or the line has an
    // exception with more lines after it.
    static func contextStart(_ line: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        var index = start

        while index + 2 < line.count {
            if line[index] == UInt8(ascii: " "), line[index + 1] == UInt8(ascii: "{"), line[index + 2] == UInt8(ascii: "\"") {
                return index
            }

            index += 1
        }

        return nil
    }

    static func trimmedEnd(_ line: UnsafeBufferPointer<UInt8>) -> Int {
        var end = line.count

        while end > 0, line[end - 1] == UInt8(ascii: " ") || line[end - 1] == UInt8(ascii: "\r") {
            end -= 1
        }

        return end
    }

    // PHP Fatal error, PHP Warning and the others. WordPress writes "WordPress database error".
    static func phpLevel(_ line: UnsafeBufferPointer<UInt8>, from start: Int) -> String? {
        let levels: [(String, String)] = [
            ("PHP Fatal error", "error"), ("PHP Parse error", "error"), ("PHP Recoverable fatal error", "error"),
            ("PHP Warning", "warning"), ("PHP Notice", "notice"), ("PHP Deprecated", "deprecated"),
            ("PHP Strict Standards", "notice"), ("WordPress database error", "error"),
        ]

        for (text, level) in levels where has(text, in: line, at: start) {
            return level
        }

        return nil
    }

    static func has(_ text: String, in line: UnsafeBufferPointer<UInt8>, at start: Int) -> Bool {
        let bytes = Array(text.utf8)

        guard start + bytes.count <= line.count else {
            return false
        }

        for (offset, byte) in bytes.enumerated() where line[start + offset] != byte {
            return false
        }

        return true
    }

    static func find(_ text: String, in line: UnsafeBufferPointer<UInt8>, before limit: Int) -> Int? {
        let last = min(limit, line.count - text.utf8.count)

        guard last >= 0 else {
            return nil
        }

        for start in 0...last where has(text, in: line, at: start) {
            return start
        }

        return nil
    }

    static func month(_ line: UnsafeBufferPointer<UInt8>, _ start: Int) -> Int? {
        guard start + 3 <= line.count else {
            return nil
        }

        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return names.firstIndex { has($0, in: line, at: start) }.map { $0 + 1 }
    }

    // The seconds since 1970 of a date and time in UTC (days from civil, by Howard Hinnant).
    static func seconds(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Double {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return Double(days * 86_400 + hour * 3600 + minute * 60 + second)
    }

    // The offset of a zone for each hour. The time of a log line is local, so the offset of the
    // same time as UTC is close enough, except in the hour of a change of the clock.
    private mutating func offset(of zone: TimeZone, local: Double) -> Int {
        let hour = Int(local / 3600)

        guard zone == self.zone else {
            return zone.secondsFromGMT(for: Date(timeIntervalSince1970: local))
        }

        if let known = offsets[hour] {
            return known
        }

        let found = zone.secondsFromGMT(for: Date(timeIntervalSince1970: local))
        offsets[hour] = found
        return found
    }

    private mutating func zoneNamed(_ name: String) -> TimeZone? {
        if let known = zones[name] {
            return known
        }

        let zone = TimeZone(identifier: name) ?? TimeZone(abbreviation: name)
        zones[name] = zone
        return zone
    }

    private func number(_ line: UnsafeBufferPointer<UInt8>, _ start: Int, _ length: Int) -> Int? {
        guard start + length <= line.count else {
            return nil
        }

        var value = 0

        for index in start..<(start + length) {
            guard let digit = digit(line[index]) else {
                return nil
            }

            value = value * 10 + digit
        }

        return value
    }

    private func digit(_ byte: UInt8) -> Int? {
        byte >= ascii("0") && byte <= ascii("9") ? Int(byte - ascii("0")) : nil
    }

    private func isNameByte(_ byte: UInt8) -> Bool {
        (byte >= ascii("a") && byte <= ascii("z")) || (byte >= ascii("A") && byte <= ascii("Z")) || (byte >= ascii("0") && byte <= ascii("9")) || byte == ascii("_") || byte == ascii("-")
    }

    private func string(_ line: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> String {
        guard start < end, end <= line.count else {
            return ""
        }

        return String(decoding: UnsafeBufferPointer(rebasing: line[start..<end]), as: UTF8.self)
    }

    private func ascii(_ character: Unicode.Scalar) -> UInt8 {
        UInt8(ascii: character)
    }
}
