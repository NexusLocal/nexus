import Foundation

// A tag of a query (Herd item 8 in docs/dump-viewer-part2.md).
public enum QueryMark: String, Codable, Sendable, CaseIterable, Comparable {
    case nPlusOne = "n_plus_one"
    case duplicate
    case slow

    public static func < (lhs: QueryMark, rhs: QueryMark) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }
}

// The marks of the queries of one request. The store keeps the marks of each request in its
// header. The app, the web page, the CLI and the MCP tool use the marks of each entry. So all show
// the same tags.
// - slow: the query took 100 ms or more.
// - duplicate: the request ran the same text two times or more.
// - N+1: one line of code ran the same pattern 5 times or more, with other texts.
public struct QueryMarks: Sendable, Equatable {
    public static let slowMilliseconds = 100.0
    public static let duplicateCount = 2
    public static let nPlusOneCount = 5

    // By the id of the entry. An entry without marks has no key.
    public let entries: [String: Set<QueryMark>]

    // Give the entries of one request. Each entry that is not a query has no marks.
    public init(_ entries: some Sequence<CaughtDump>) {
        let queries = entries
            .filter { entry in entry.kind == .query }
            .map { query in (query: query, source: QuerySource(query, pattern: Self.pattern(of: query))) }
        var textCounts: [String: Int] = [:]
        var sources: [QuerySource: (count: Int, texts: Set<String>)] = [:]

        for (query, source) in queries {
            textCounts[query.text, default: 0] += 1
            sources[source, default: (0, [])].count += 1
            sources[source, default: (0, [])].texts.insert(query.text)
        }

        var marked: [String: Set<QueryMark>] = [:]

        for (query, source) in queries {
            var marks: Set<QueryMark> = []

            if query.milliseconds ?? 0 >= Self.slowMilliseconds {
                marks.insert(.slow)
            }

            if textCounts[query.text] ?? 0 >= Self.duplicateCount {
                marks.insert(.duplicate)
            }

            if Self.reads(query.text), let group = sources[source], group.count >= Self.nPlusOneCount, group.texts.count > 1 {
                marks.insert(.nPlusOne)
            }

            if !marks.isEmpty {
                marked[query.id] = marks
            }
        }

        self.entries = marked
    }

    // The marks of all queries together.
    public var request: Set<QueryMark> {
        entries.values.reduce(into: []) { all, marks in all.formUnion(marks) }
    }

    public func marks(of entry: CaughtDump) -> Set<QueryMark> {
        entries[entry.id] ?? []
    }

    // N+1 is about rows that a loop reads one by one. A loop that writes rows one by one is a
    // different problem. So only a select can be N+1.
    public static func reads(_ sql: String) -> Bool {
        sql.drop { character in character.isWhitespace || character == "(" }.prefix(6).lowercased() == "select"
    }

    // Laravel sends the pattern. WordPress does not.
    public static func pattern(of query: CaughtDump) -> String {
        query.pattern ?? pattern(of: query.text)
    }

    // The SQL with a ? for each string and number literal. A string has single or double quotes. A
    // quote in a string has a backslash before it or is doubled. A name in backticks stays as it
    // is. So the table wp_2_posts of a WordPress network keeps its number.
    public static func pattern(of sql: String) -> String {
        let bytes = Array(sql.utf8)
        var result: [UInt8] = []
        var index = 0
        result.reserveCapacity(bytes.count)

        while index < bytes.count {
            let byte = bytes[index]

            if byte == .singleQuote || byte == .doubleQuote {
                index = end(of: byte, in: bytes, after: index)
                result.append(.questionMark)
                continue
            }

            if byte == .backtick {
                let end = end(of: byte, in: bytes, after: index)
                result.append(contentsOf: bytes[index..<end])
                index = end
                continue
            }

            guard byte.isDigit, index == 0 || !bytes[index - 1].isWordByte else {
                result.append(byte)
                index += 1
                continue
            }

            let end = endOfNumber(in: bytes, at: index)

            // A digit at the start of a name, as in 2fa_codes.
            if end < bytes.count, bytes[end].isWordByte {
                result.append(contentsOf: bytes[index..<end])
                index = end
                continue
            }

            result.append(.questionMark)
            index = end
        }

        return String(decoding: result, as: UTF8.self)
    }

    // The index after the closing quote. A text without its closing quote ends at the end.
    private static func end(of quote: UInt8, in bytes: [UInt8], after start: Int) -> Int {
        var index = start + 1

        while index < bytes.count {
            if bytes[index] == .backslash, quote != .backtick {
                index += 2
                continue
            }

            guard bytes[index] == quote else {
                index += 1
                continue
            }

            if index + 1 < bytes.count, bytes[index + 1] == quote {
                index += 2
                continue
            }

            return index + 1
        }

        return bytes.count
    }

    // Digits, with one decimal point between digits.
    private static func endOfNumber(in bytes: [UInt8], at start: Int) -> Int {
        var index = start

        while index < bytes.count, bytes[index].isDigit {
            index += 1
        }

        guard index + 1 < bytes.count, bytes[index] == .period, bytes[index + 1].isDigit else {
            return index
        }

        index += 1

        while index < bytes.count, bytes[index].isDigit {
            index += 1
        }

        return index
    }
}

// The queries of one line of code with one pattern. N+1 counts them.
struct QuerySource: Hashable, Sendable {
    let pattern: String
    let file: String?
    let line: Int?

    init(_ query: CaughtDump, pattern: String) {
        self.pattern = pattern
        file = query.file
        line = query.line
    }
}

// The marks and the time of the queries of one request, kept up to date one query at a time. The
// store adds each new query and removes each query that goes. So an event does not make the marks
// of all queries of the request again. The marks are the same as QueryMarks(queries).request.
public struct QueryTally: Sendable, Equatable {
    private struct SourceTally: Sendable, Equatable {
        var count = 0
        var reads = 0
        var texts: [String: Int] = [:]

        // QueryMarks marks a query of the group as N+1 when its text is a select.
        var isNPlusOne: Bool {
            count >= QueryMarks.nPlusOneCount && texts.count > 1 && reads > 0
        }
    }

    // The longest time that counts for one query: one day. So the sum of many queries cannot go
    // past the largest Int.
    private static let longestMilliseconds = 86_400_000.0

    private var textCounts: [String: Int] = [:]
    private var sources: [QuerySource: SourceTally] = [:]
    private var duplicateTexts = 0
    private var nPlusOneSources = 0
    private var slowQueries = 0
    // Whole nanoseconds. So the sum after a removal is the sum of the queries that stay, without a
    // rounding error.
    private var nanoseconds = 0

    public init() {}

    public var marks: Set<QueryMark> {
        var marks: Set<QueryMark> = []

        if nPlusOneSources > 0 {
            marks.insert(.nPlusOne)
        }

        if duplicateTexts > 0 {
            marks.insert(.duplicate)
        }

        if slowQueries > 0 {
            marks.insert(.slow)
        }

        return marks
    }

    public var milliseconds: Double {
        Double(nanoseconds) / 1_000_000
    }

    // pattern is QueryMarks.pattern(of: query). The caller makes it once for each query.
    public mutating func add(_ query: CaughtDump, pattern: String) {
        change(query, pattern: pattern, by: 1)
    }

    public mutating func remove(_ query: CaughtDump, pattern: String) {
        change(query, pattern: pattern, by: -1)
    }

    private mutating func change(_ query: CaughtDump, pattern: String, by change: Int) {
        let milliseconds = min(max(query.milliseconds ?? 0, 0), Self.longestMilliseconds)
        nanoseconds += change * Int((milliseconds * 1_000_000).rounded())

        if milliseconds >= QueryMarks.slowMilliseconds {
            slowQueries += change
        }

        let textsBefore = textCounts[query.text] ?? 0
        let textsAfter = textsBefore + change
        textCounts[query.text] = textsAfter > 0 ? textsAfter : nil
        duplicateTexts += Self.flag(textsAfter >= QueryMarks.duplicateCount) - Self.flag(textsBefore >= QueryMarks.duplicateCount)

        let source = QuerySource(query, pattern: pattern)
        var tally = sources[source] ?? SourceTally()
        let wasNPlusOne = tally.isNPlusOne
        let sameTexts = (tally.texts[query.text] ?? 0) + change

        tally.count += change
        tally.texts[query.text] = sameTexts > 0 ? sameTexts : nil

        if QueryMarks.reads(query.text) {
            tally.reads += change
        }

        nPlusOneSources += Self.flag(tally.isNPlusOne) - Self.flag(wasNPlusOne)
        sources[source] = tally.count > 0 ? tally : nil
    }

    private static func flag(_ value: Bool) -> Int {
        value ? 1 : 0
    }
}

private extension UInt8 {
    static let singleQuote = UInt8(ascii: "'")
    static let doubleQuote = UInt8(ascii: "\"")
    static let backtick = UInt8(ascii: "`")
    static let backslash = UInt8(ascii: "\\")
    static let questionMark = UInt8(ascii: "?")
    static let period = UInt8(ascii: ".")

    var isDigit: Bool {
        self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9")
    }

    // A byte of a name. A byte of a character outside ASCII counts too.
    var isWordByte: Bool {
        if isDigit || self == UInt8(ascii: "_") || self == UInt8(ascii: "$") || self >= 0x80 {
            return true
        }

        let lower = self | 0x20
        return lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "z")
    }
}
