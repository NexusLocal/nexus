import Foundation

// Reads a dump of MySQL or MariaDB as a stream and changes the links of the live URLs in the rows
// of the tables with the prefix of WordPress (owner, 2026-11-09, docs/dump-url-rewrite.md). It
// reads every byte, because a string can hold a line break. Its state stays between the blocks of
// the stream. A string is in memory only while the filter reads it. A value without a link goes
// through byte for byte. The column guid of the posts tables does not change, as with
// --skip-columns=guid of WP-CLI.
public final class SQLDumpFilter {
    public struct Plan: Codable, Sendable, Equatable {
        public var prefix: String
        public var rules: [LiveURLRule]
        // The order of the columns of a table that has no CREATE TABLE in the dump.
        public var columns: [String: [String]]

        public init(prefix: String, rules: [LiveURLRule] = [], columns: [String: [String]] = [:]) {
            self.prefix = prefix
            self.rules = rules
            self.columns = columns
        }
    }

    // What the filter found. uncertainTables are the tables with a live link that the filter did
    // not change. WP-CLI changes them after the load.
    public struct Report: Codable, Sendable, Equatable {
        public var tables: [String] = []
        public var home: String?
        public var siteURL: String?
        public var networkDomain: String?
        public var changedValues = 0
        public var links = 0
        public var uncertainTables: [String] = []
        public var uncertainLinks = 0
        public var bytes: Int64 = 0

        public init() {}

        public func hasTable(_ name: String) -> Bool {
            tables.contains { $0.lowercased() == name.lowercased() }
        }
    }

    // A larger string goes through unchanged, and its table comes on the list for WP-CLI.
    public static let largestValue = 256 * 1024 * 1024

    private enum Lexical {
        case code
        case string(UInt8)
        case name
        case word
        case hexString
        case lineComment
        case blockComment
        case delimiterLine
    }

    private enum Phase {
        case start
        case head
        case values
        case createBody
        case other
    }

    private enum HeadToken {
        case word(String)
        case name(String)
        case symbol(UInt8)

        var keyword: String? {
            if case .word(let text) = self {
                return text.uppercased()
            }

            return nil
        }

        var identifier: String? {
            switch self {
            case .word(let text), .name(let text): text
            case .symbol: nil
            }
        }

        func isSymbol(_ byte: UInt8) -> Bool {
            if case .symbol(let symbol) = self {
                return symbol == byte
            }

            return false
        }
    }

    private struct Table {
        let name: String
        let hasPrefix: Bool
        let isPosts: Bool
        let columns: [String]?
        let skippedIndex: Int?
        let optionNameIndex: Int?
        let optionValueIndex: Int?
        let siteDomainIndex: Int?
    }

    private enum ValueUse {
        case ignore
        case rewrite
        case check
    }

    private struct Pending {
        let start: Int
        let rewrites: Bool
        let checks: Bool
        let captures: Bool
    }

    private let plan: Plan
    private let prefix: String
    private let rewriter: LiveURLRewriter?
    public private(set) var report = Report()

    private var buffer: [UInt8] = []
    private var position = 0
    private var flushed = 0
    private var tokenStart: Int?
    private var pending: Pending?
    private var lexical = Lexical.code
    private var phase = Phase.start
    private var delimiter: [UInt8] = [UInt8(ascii: ";")]
    private var head: [HeadToken] = []
    private var headDepth = 0
    private var table: Table?
    private var depth = 0
    private var valueIndex = 0
    private var itemStarts = false
    private var createColumns: [String] = []
    private var createdTables: [String: [String]] = [:]
    private var rowOptionName: String?
    private var uncertain: Set<String> = []
    private var seenTables: Set<String> = []

    public init(plan: Plan) {
        self.plan = plan
        prefix = plan.prefix.lowercased()
        rewriter = LiveURLRewriter(rules: plan.rules)
    }

    public func feed(_ chunk: UnsafeRawBufferPointer, write: (UnsafeRawBufferPointer) -> Void) {
        report.bytes += Int64(chunk.count)
        buffer.append(contentsOf: chunk)
        run(final: false, write: write)
    }

    public func finish(write: (UnsafeRawBufferPointer) -> Void) {
        run(final: true, write: write)

        if flushed < buffer.count {
            buffer[flushed...].withUnsafeBytes(write)
            flushed = buffer.count
        }

        report.uncertainTables = uncertain.sorted()
    }

    private func run(final: Bool, write: (UnsafeRawBufferPointer) -> Void) {
        buffer.withUnsafeBufferPointer { bytes in
            step(bytes, final: final, write: write)
        }

        let limit = pending?.start ?? position

        if limit > flushed {
            buffer[flushed..<limit].withUnsafeBytes(write)
            flushed = limit
        }

        let keep = min(flushed, tokenStart ?? position, position)

        if keep > 0, keep >= 1 << 20 || keep * 2 >= buffer.count {
            buffer.removeSubrange(0..<keep)
            position -= keep
            flushed -= keep
            tokenStart = tokenStart.map { $0 - keep }

            if let current = pending {
                pending = Pending(start: current.start - keep, rewrites: current.rewrites, checks: current.checks, captures: current.captures)
            }
        }
    }

    // The main loop. A token that needs more bytes than the buffer has waits for the next block.
    private func step(_ bytes: UnsafeBufferPointer<UInt8>, final: Bool, write: (UnsafeRawBufferPointer) -> Void) {
        var index = position
        let count = bytes.count

        defer { position = index }

        while index < count {
            switch lexical {
            case .string(let quote):
                while index < count {
                    let byte = bytes[index]

                    if byte == quote {
                        guard index + 1 < count || final else {
                            return
                        }

                        if index + 1 < count, bytes[index + 1] == quote {
                            index += 2
                            continue
                        }

                        finishString(bytes, end: index, quote: quote, write: write)
                        lexical = .code
                        index += 1
                        break
                    }

                    if byte == Byte.backslash {
                        guard index + 1 < count || final else {
                            return
                        }

                        index += 2
                        continue
                    }

                    index += 1
                }

                giveUpOnLargeValue(at: index)
            case .name:
                while index < count, bytes[index] != Character.backtick {
                    index += 1
                }

                guard index + 1 < count || (final && index < count) else {
                    if final {
                        index = count
                    }

                    return
                }

                if index + 1 < count, bytes[index + 1] == Character.backtick {
                    index += 2
                    continue
                }

                let start = tokenStart ?? index
                let name = String(decoding: UnsafeBufferPointer(rebasing: bytes[(start + 1)..<index]), as: UTF8.self).replacingOccurrences(of: "``", with: "`")
                index += 1
                tokenStart = nil
                lexical = .code
                token(.name(name))
            case .word:
                while index < count, Character.isWordByte(bytes[index]) {
                    index += 1
                }

                guard index < count || final else {
                    return
                }

                let start = tokenStart ?? index
                tokenStart = nil
                lexical = .code
                finishWord(bytes, start: start, end: index, write: write)
            case .hexString:
                while index < count, bytes[index] != Character.quote {
                    index += 1
                }

                guard index < count else {
                    if final {
                        tokenStart = nil
                        pending = nil
                    }

                    return
                }

                let start = tokenStart ?? index
                tokenStart = nil
                lexical = .code
                finishHex(bytes, contentStart: start + 2, end: index, write: write)
                index += 1
            case .lineComment:
                while index < count, bytes[index] != Character.newline {
                    index += 1
                }

                if index < count {
                    lexical = .code
                    index += 1
                }
            case .blockComment:
                while index < count {
                    if bytes[index] == Character.star {
                        guard index + 1 < count || final else {
                            return
                        }

                        if index + 1 < count, bytes[index + 1] == Byte.slash {
                            index += 2
                            lexical = .code
                            break
                        }
                    }

                    index += 1
                }
            case .delimiterLine:
                while index < count, bytes[index] != Character.newline {
                    index += 1
                }

                guard index < count || final else {
                    return
                }

                let start = tokenStart ?? index
                let line = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                tokenStart = nil
                lexical = .code
                phase = .start
                head = []

                if !line.isEmpty {
                    delimiter = Array(line.utf8)
                }
            case .code:
                let byte = bytes[index]

                if byte == delimiter[0] {
                    guard index + delimiter.count <= count || final else {
                        return
                    }

                    if index + delimiter.count <= count, bytes[index..<(index + delimiter.count)].elementsEqual(delimiter) {
                        endStatement()
                        index += delimiter.count
                        continue
                    }
                }

                switch byte {
                case Character.quote, Character.doubleQuote:
                    startString(at: index)
                    lexical = .string(byte)
                    index += 1
                case Character.backtick:
                    tokenStart = index
                    lexical = .name
                    index += 1
                case Character.hash:
                    lexical = .lineComment
                    index += 1
                case Byte.hyphen:
                    guard index + 2 < count || final else {
                        return
                    }

                    if index + 1 < count, bytes[index + 1] == Byte.hyphen, index + 2 >= count || Character.isSpace(bytes[index + 2]) {
                        lexical = .lineComment
                        index += 2
                    } else {
                        index += 1
                    }
                case Byte.slash:
                    guard index + 2 < count || final else {
                        return
                    }

                    guard index + 1 < count, bytes[index + 1] == Character.star else {
                        index += 1
                        continue
                    }

                    // The inside of /*!40101 ... */ is SQL, because mysqldump puts statements there.
                    if index + 2 < count, bytes[index + 2] == Character.exclamation || bytes[index + 2] == Byte.plus {
                        var end = index + 3

                        while end < count, Byte.isDigit(bytes[end]) {
                            end += 1
                        }

                        guard end < count || final else {
                            return
                        }

                        index = end
                    } else {
                        lexical = .blockComment
                        index += 2
                    }
                case Character.star:
                    guard index + 1 < count || final else {
                        return
                    }

                    index += index + 1 < count && bytes[index + 1] == Byte.slash ? 2 : 1
                case Character.openParenthesis, Character.closeParenthesis, Character.comma, Byte.dot:
                    symbol(byte)
                    index += 1
                default:
                    guard Character.isWordByte(byte) else {
                        index += 1
                        continue
                    }

                    if byte == UInt8(ascii: "x") || byte == UInt8(ascii: "X") {
                        guard index + 1 < count || final else {
                            return
                        }

                        if index + 1 < count, bytes[index + 1] == Character.quote {
                            startHexString(at: index)
                            lexical = .hexString
                            index += 2
                            continue
                        }
                    }

                    startWord(at: index)
                    lexical = .word
                    index += 1
                }
            }
        }
    }

    // MARK: Statements

    private func endStatement() {
        phase = .start
        head = []
        headDepth = 0
        table = nil
        depth = 0
        rowOptionName = nil
    }

    private func token(_ token: HeadToken) {
        switch phase {
        case .start:
            if token.keyword == "DELIMITER" {
                tokenStart = position
                lexical = .delimiterLine
                return
            }

            phase = .head
            head = [token]
            headDepth = 0
            classifyHead()
        case .head:
            head.append(token)
            classifyHead()
        case .createBody:
            createBodyToken(token)
        case .values:
            if depth == 0, token.keyword != nil {
                phase = .other
            }
        case .other:
            break
        }
    }

    private func symbol(_ byte: UInt8) {
        switch phase {
        case .head:
            if byte == Character.openParenthesis {
                headDepth += 1
            } else if byte == Character.closeParenthesis {
                headDepth -= 1
            }

            head.append(.symbol(byte))
            classifyHead()
        case .values:
            if byte == Character.openParenthesis {
                depth += 1

                if depth == 1 {
                    valueIndex = 0
                    rowOptionName = nil
                }
            } else if byte == Character.closeParenthesis {
                depth -= 1
            } else if byte == Character.comma, depth == 1 {
                valueIndex += 1
            }
        case .createBody:
            if byte == Character.openParenthesis {
                depth += 1
            } else if byte == Character.closeParenthesis {
                depth -= 1

                if depth == 0, let created = table {
                    createdTables[created.name.lowercased()] = createColumns
                    phase = .other
                    table = nil
                }
            } else if byte == Character.comma, depth == 1 {
                itemStarts = true
            }
        case .start, .other:
            break
        }
    }

    private func classifyHead() {
        guard let first = head.first?.keyword else {
            phase = .other
            return
        }

        guard head.count < 512 else {
            phase = .other
            return
        }

        switch first {
        case "INSERT", "REPLACE":
            guard let last = head.last else {
                return
            }

            if last.keyword == "SELECT" || (headDepth == 0 && last.keyword == "SET") {
                startOther(insertTable())
            } else if headDepth == 0, last.keyword == "VALUES" || last.keyword == "VALUE" {
                startValues()
            }
        case "CREATE":
            if head.count == 2, head[1].keyword != "TABLE", head[1].keyword != "TEMPORARY" {
                phase = .other
            } else if head.last?.isSymbol(Character.openParenthesis) == true, headDepth == 1 {
                startCreateBody()
            }
        default:
            phase = .other
        }
    }

    // INSERT [LOW_PRIORITY | DELAYED | HIGH_PRIORITY] [IGNORE] [INTO] name [PARTITION (...)] [(columns)]
    private func insertTable() -> (name: String, columns: [String]?)? {
        var index = 1
        let modifiers: Set<String> = ["LOW_PRIORITY", "DELAYED", "HIGH_PRIORITY", "IGNORE", "INTO"]

        while index < head.count, let keyword = head[index].keyword, modifiers.contains(keyword) {
            index += 1
        }

        guard index < head.count, var name = head[index].identifier else {
            return nil
        }

        index += 1

        if index + 1 < head.count, head[index].isSymbol(Byte.dot), let second = head[index + 1].identifier {
            name = second
            index += 2
        }

        if index < head.count, head[index].keyword == "PARTITION" {
            var level = 0
            index += 1

            while index < head.count {
                if head[index].isSymbol(Character.openParenthesis) {
                    level += 1
                } else if head[index].isSymbol(Character.closeParenthesis) {
                    level -= 1

                    if level == 0 {
                        index += 1
                        break
                    }
                }

                index += 1
            }
        }

        guard index < head.count, head[index].isSymbol(Character.openParenthesis) else {
            return (name, nil)
        }

        var columns: [String] = []
        index += 1

        while index < head.count, !head[index].isSymbol(Character.closeParenthesis) {
            if let column = head[index].identifier {
                columns.append(column)
            }

            index += 1
        }

        return (name, columns)
    }

    private func startValues() {
        guard let found = insertTable() else {
            phase = .other
            return
        }

        table = describe(found.name, columns: found.columns)
        phase = .values
        depth = 0
        valueIndex = 0
    }

    private func startOther(_ found: (name: String, columns: [String]?)?) {
        phase = .other
        table = found.map { describe($0.name, columns: nil) }
    }

    private func startCreateBody() {
        let keywords: Set<String> = ["CREATE", "TEMPORARY", "TABLE", "IF", "NOT", "EXISTS"]
        let names = head.dropLast().filter { token in token.keyword.map { !keywords.contains($0) } ?? !token.isSymbol(Byte.dot) }
        let name = names.last?.identifier

        guard let name, name.lowercased().hasPrefix(prefix) else {
            phase = .other
            return
        }

        table = describe(name, columns: nil)
        createColumns = []
        phase = .createBody
        depth = 1
        itemStarts = true
    }

    private func createBodyToken(_ token: HeadToken) {
        guard depth == 1, itemStarts else {
            return
        }

        itemStarts = false
        let notColumns: Set<String> = ["PRIMARY", "KEY", "UNIQUE", "INDEX", "CONSTRAINT", "FULLTEXT", "SPATIAL", "CHECK", "FOREIGN", "PERIOD"]

        if case .name(let name) = token {
            createColumns.append(name)
        } else if let keyword = token.keyword, !notColumns.contains(keyword), let name = token.identifier {
            createColumns.append(name)
        }
    }

    private func describe(_ name: String, columns listed: [String]?) -> Table {
        let lowered = name.lowercased()
        let hasPrefix = lowered.hasPrefix(prefix)

        if hasPrefix, !seenTables.contains(lowered) {
            seenTables.insert(lowered)
            report.tables.append(name)
        }

        let isPosts = hasPrefix && Self.isPostsTable(String(lowered.dropFirst(prefix.count)))
        let planned = { [plan] (table: String) in plan.columns.first { $0.key.lowercased() == table }?.value }

        // The posts tables of the sites of a network have the columns of the posts table.
        let columns = listed ?? createdTables[lowered] ?? planned(lowered) ?? (isPosts ? createdTables[prefix + "posts"] ?? planned(prefix + "posts") : nil)
        let isOptions = lowered == prefix + "options"
        let isSite = lowered == prefix + "site"
        let index = { (column: String) in columns?.firstIndex { $0.lowercased() == column } }

        return Table(
            name: name,
            hasPrefix: hasPrefix,
            isPosts: isPosts,
            columns: columns,
            skippedIndex: isPosts ? index("guid") : nil,
            optionNameIndex: isOptions ? (columns == nil ? 1 : index("option_name")) : nil,
            optionValueIndex: isOptions ? (columns == nil ? 2 : index("option_value")) : nil,
            siteDomainIndex: isSite ? (columns == nil ? 1 : index("domain")) : nil
        )
    }

    // posts, and 2_posts of a site in a network.
    static func isPostsTable(_ rest: String) -> Bool {
        if rest == "posts" {
            return true
        }

        guard rest.hasSuffix("_posts") else {
            return false
        }

        let number = rest.dropLast(6)
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }

    // MARK: Values

    private func use(of table: Table) -> ValueUse {
        guard phase == .values || phase == .other, table.hasPrefix, rewriter != nil else {
            return .ignore
        }

        guard phase == .values, depth >= 1 else {
            return .check
        }

        if table.isPosts {
            guard let skipped = table.skippedIndex else {
                return .check
            }

            return valueIndex == skipped ? .ignore : .rewrite
        }

        return .rewrite
    }

    private func captures(_ table: Table) -> Bool {
        guard phase == .values, depth == 1 else {
            return false
        }

        return valueIndex == table.optionNameIndex || valueIndex == table.optionValueIndex || (valueIndex == table.siteDomainIndex && report.networkDomain == nil)
    }

    private func startString(at index: Int) {
        guard let table else {
            pending = nil
            return
        }

        let use = use(of: table)
        let captures = captures(table)

        guard use != .ignore || captures else {
            pending = nil
            return
        }

        pending = Pending(start: index, rewrites: use == .rewrite, checks: use == .check, captures: captures)
    }

    private func startHexString(at index: Int) {
        tokenStart = index
        startString(at: index)
    }

    private func startWord(at index: Int) {
        tokenStart = index

        if phase == .values, depth >= 1, let table, use(of: table) != .ignore {
            pending = Pending(start: index, rewrites: use(of: table) == .rewrite, checks: use(of: table) == .check, captures: false)
        } else {
            pending = nil
        }
    }

    private func giveUpOnLargeValue(at index: Int) {
        guard let current = pending, index - current.start > Self.largestValue else {
            return
        }

        if let table, current.rewrites || current.checks {
            markUncertain(table, value: nil)
        }

        pending = nil
    }

    // The links of a value that the filter did not change. WP-CLI changes them after the load.
    private func markUncertain(_ table: Table, value: [UInt8]?) {
        uncertain.insert(table.name)
        report.uncertainLinks += value.flatMap { rewriter?.rewrite($0)?.links } ?? 1
    }

    private func finishWord(_ bytes: UnsafeBufferPointer<UInt8>, start: Int, end: Int, write: (UnsafeRawBufferPointer) -> Void) {
        let isHex = end - start > 2 && bytes[start] == UInt8(ascii: "0") && (bytes[start + 1] == UInt8(ascii: "x") || bytes[start + 1] == UInt8(ascii: "X"))

        if isHex, pending != nil {
            finishHex(bytes, contentStart: start + 2, end: end, write: write)
            return
        }

        pending = nil

        // A number or NULL in a row is no token of the statement.
        guard phase != .other, phase != .values || depth == 0 else {
            return
        }

        let word = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
        position = end
        token(.word(word))
    }

    private func finishString(_ bytes: UnsafeBufferPointer<UInt8>, end: Int, quote: UInt8, write: (UnsafeRawBufferPointer) -> Void) {
        guard let current = pending, let table else {
            pending = nil
            return
        }

        pending = nil
        let content = UnsafeBufferPointer(rebasing: bytes[(current.start + 1)..<end])

        if current.captures {
            capture(Self.decode(content, quote: quote), of: table)
        }

        guard let rewriter, current.rewrites || current.checks, rewriter.mayContain(content) else {
            return
        }

        let decoded = Self.decode(content, quote: quote)

        guard current.rewrites else {
            markUncertain(table, value: decoded)
            return
        }

        switch SerializedPHP.rewrite(decoded, with: rewriter) {
        case .unchanged:
            break
        case .unsafe:
            markUncertain(table, value: decoded)
        case .changed(let value, let links):
            report.changedValues += 1
            report.links += links
            replace(bytes, from: current.start + 1, to: end, with: Self.encode(value, quote: quote), write: write)
        }
    }

    private func finishHex(_ bytes: UnsafeBufferPointer<UInt8>, contentStart: Int, end: Int, write: (UnsafeRawBufferPointer) -> Void) {
        guard let current = pending, let table, let rewriter else {
            pending = nil
            return
        }

        pending = nil
        let hex = UnsafeBufferPointer(rebasing: bytes[contentStart..<end])

        guard current.rewrites || current.checks, hex.count / 2 >= 4, let value = Self.decodeHex(hex), rewriter.mayContain(value) else {
            return
        }

        guard current.rewrites else {
            markUncertain(table, value: value)
            return
        }

        switch SerializedPHP.rewrite(value, with: rewriter) {
        case .unchanged:
            break
        case .unsafe:
            markUncertain(table, value: value)
        case .changed(let changed, let links):
            report.changedValues += 1
            report.links += links
            let lowercase = hex.contains { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f") }
            replace(bytes, from: contentStart, to: end, with: Self.encodeHex(changed, lowercase: lowercase), write: write)
        }
    }

    private func replace(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int, with value: [UInt8], write: (UnsafeRawBufferPointer) -> Void) {
        if start > flushed {
            write(UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(bytes)[flushed..<start]))
        }

        value.withUnsafeBytes(write)
        flushed = end
    }

    private func capture(_ value: [UInt8], of table: Table) {
        let text = String(decoding: value, as: UTF8.self)

        if valueIndex == table.optionNameIndex {
            rowOptionName = text
        }

        if valueIndex == table.siteDomainIndex, report.networkDomain == nil {
            report.networkDomain = text
        }

        guard valueIndex == table.optionValueIndex, value.count <= 4096 else {
            return
        }

        if rowOptionName == "home", report.home == nil {
            report.home = text
        } else if rowOptionName == "siteurl", report.siteURL == nil {
            report.siteURL = text
        }
    }

    // MARK: SQL strings

    static func decode(_ content: UnsafeBufferPointer<UInt8>, quote: UInt8) -> [UInt8] {
        var value: [UInt8] = []
        value.reserveCapacity(content.count)
        var index = 0

        while index < content.count {
            let byte = content[index]

            if byte == Byte.backslash, index + 1 < content.count {
                let next = content[index + 1]

                switch next {
                case UInt8(ascii: "0"): value.append(0)
                case UInt8(ascii: "b"): value.append(8)
                case UInt8(ascii: "n"): value.append(10)
                case UInt8(ascii: "r"): value.append(13)
                case UInt8(ascii: "t"): value.append(9)
                case UInt8(ascii: "Z"): value.append(26)
                case Byte.percent, Byte.underscore: value += [Byte.backslash, next]
                default: value.append(next)
                }

                index += 2
            } else if byte == quote, index + 1 < content.count, content[index + 1] == quote {
                value.append(quote)
                index += 2
            } else {
                value.append(byte)
                index += 1
            }
        }

        return value
    }

    static func encode(_ value: [UInt8], quote: UInt8) -> [UInt8] {
        var content: [UInt8] = []
        content.reserveCapacity(value.count + 16)

        for byte in value {
            let escaped: UInt8

            switch byte {
            case 0: escaped = UInt8(ascii: "0")
            case 10: escaped = UInt8(ascii: "n")
            case 13: escaped = UInt8(ascii: "r")
            case 26: escaped = UInt8(ascii: "Z")
            case Byte.backslash, Character.quote, Character.doubleQuote: escaped = byte
            default:
                content.append(byte)
                continue
            }

            content.append(Byte.backslash)
            content.append(escaped)
        }

        return content
    }

    static func decodeHex(_ hex: UnsafeBufferPointer<UInt8>) -> [UInt8]? {
        guard hex.count.isMultiple(of: 2) else {
            return nil
        }

        var value: [UInt8] = []
        value.reserveCapacity(hex.count / 2)
        var index = 0

        while index < hex.count {
            guard let high = nibble(hex[index]), let low = nibble(hex[index + 1]) else {
                return nil
            }

            value.append(high << 4 | low)
            index += 2
        }

        return value
    }

    static func encodeHex(_ value: [UInt8], lowercase: Bool) -> [UInt8] {
        let digits = Array((lowercase ? "0123456789abcdef" : "0123456789ABCDEF").utf8)
        var hex: [UInt8] = []
        hex.reserveCapacity(value.count * 2)

        for byte in value {
            hex.append(digits[Int(byte >> 4)])
            hex.append(digits[Int(byte & 0x0F)])
        }

        return hex
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    private enum Character {
        static let quote = UInt8(ascii: "'")
        static let doubleQuote = UInt8(ascii: "\"")
        static let backtick = UInt8(ascii: "`")
        static let hash = UInt8(ascii: "#")
        static let star = UInt8(ascii: "*")
        static let exclamation = UInt8(ascii: "!")
        static let newline = UInt8(ascii: "\n")
        static let openParenthesis = UInt8(ascii: "(")
        static let closeParenthesis = UInt8(ascii: ")")
        static let comma = UInt8(ascii: ",")

        @inline(__always) static func isWordByte(_ byte: UInt8) -> Bool {
            Byte.isAlphanumeric(byte) || byte == Byte.underscore || byte == UInt8(ascii: "$")
        }

        @inline(__always) static func isSpace(_ byte: UInt8) -> Bool {
            byte == 32 || byte == 9 || byte == 10 || byte == 13
        }
    }
}
