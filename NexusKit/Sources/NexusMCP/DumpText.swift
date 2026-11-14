import Foundation
import NexusCore
import NexusIPC

// The text of the caught entries for nexus dumps and the MCP tool read_dumps.

// One entry of any kind with its request, as one JSON line. The key stays dump, as in the first
// version. Dates are ISO 8601. tree is the JSON of the tree as one string, as PHP sent it. The
// numbers of the store are values for the app. So the line leaves them out: a number of 0 has no
// key. marks holds the tags of a query and has no key for the other entries.
public struct CaughtDumpLine: Encodable, Sendable {
    public let request: DumpedRequest
    public let dump: CaughtDump
    public let marks: [QueryMark]?

    public init(request: DumpedRequest, dump: CaughtDump, marks: Set<QueryMark> = []) {
        var plainRequest = request
        plainRequest.lastNumber = 0
        plainRequest.firstNumber = 0
        var plainDump = dump
        plainDump.number = 0

        self.request = plainRequest
        self.dump = plainDump
        self.marks = marks.isEmpty ? nil : marks.sorted()
    }
}

// The tags of each query for nexus dumps and read_dumps. The text shows each query on its own line.
// So each query gets the tag of its group as the app shows it: "N+1 · 12×" or "duplicate · 2×". The
// groups come from QueryRow.rows. So a query that is N+1 and duplicate is only in its N+1 group. A
// single query with a copy in an N+1 group gets "duplicate", and a slow query gets "slow", as in the
// app. The groups need all queries of the request.
public struct QueryTags: Sendable {
    private struct Group: Sendable {
        let kind: QueryRowKind
        let count: Int
        let isFirst: Bool
    }

    public let marks: QueryMarks
    private let groups: [String: Group]

    public init(_ entries: some Sequence<CaughtDump>) {
        let queries = entries.filter { entry in entry.kind == .query }
        let marks = QueryMarks(queries)
        var groups: [String: Group] = [:]

        for row in QueryRow.rows(of: queries, marks: marks, query: { query in query }) {
            for (index, query) in row.entries.enumerated() {
                groups[query.id] = Group(kind: row.kind, count: row.entries.count, isFirst: index == 0)
            }
        }

        self.marks = marks
        self.groups = groups
    }

    public func texts(of query: CaughtDump) -> [String] {
        let marks = marks.marks(of: query)
        let group = groups[query.id]
        var texts: [String] = []

        if let group, let tag = DumpEntryText.groupTag(group.kind, count: group.count) {
            texts.append(tag)
        } else if marks.contains(.duplicate) {
            texts.append("duplicate")
        }

        if marks.contains(.slow) {
            texts.append("slow")
        }

        return texts
    }

    // The note of the app follows the first query of each N+1 group. Only Laravel sends a pattern.
    // So a query with a pattern comes from a Laravel site.
    public func note(after query: CaughtDump) -> String? {
        guard let group = groups[query.id], group.kind == .nPlusOne, group.isFirst else {
            return nil
        }

        return DumpEntryText.nPlusOneNote(count: group.count, isLaravel: query.pattern != nil)
    }
}

// The time of a request. A request of an earlier day shows its date too, because the list keeps
// the dumps of earlier runs. The formats are made once.
public struct DumpTimeText: Sendable {
    private let calendar: Calendar
    private let time: Date.VerbatimFormatStyle
    private let dateAndTime: Date.VerbatimFormatStyle

    public init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar

        time = Date.VerbatimFormatStyle(format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)", timeZone: timeZone, calendar: calendar)
        dateAndTime = Date.VerbatimFormatStyle(format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)", timeZone: timeZone, calendar: calendar)
    }

    public func text(_ date: Date, now: Date) -> String {
        calendar.isDate(date, inSameDayAs: now) ? date.formatted(time) : date.formatted(dateAndTime)
    }
}

// The texts of the app come from NexusCore. So the CLI, the MCP tool, the app and the web page name
// a request and its entries the same way. locale is for the tests.
public enum DumpText {
    // A failed job shows its try as its status: "try 3 of 3".
    public static func header(of request: DumpedRequest, now: Date, times: DumpTimeText) -> String {
        var parts = [times.text(request.started, now: now), request.displayMethod, request.title]
        parts += [request.statusText, request.durationText].compactMap { $0 }

        // The URL of a web request names its host already.
        if request.kind != .http, let site = request.site {
            parts.append(request.workspace.map { "workspace \($0) of \(site)" } ?? site)
        }

        return parts.joined(separator: "  ")
    }

    // The lines under the line of a request: the job of a worker, the counts and the queries that
    // PHP did not keep. A request with only dumps gets no counts. So its text stays as before. id
    // starts the counts with the id of the request, for read_dumps.
    public static func details(of request: DumpedRequest, id: Bool = false, locale: Locale = .current) -> [String] {
        var lines = request.job.map(jobLines(of:)) ?? []
        var counts = [Count.text(request.dumpCount, "dump")]

        if request.queryCount > 0 {
            counts.append("\(Count.text(request.queryCount, "query", plural: "queries")) in \(DumpEntryText.milliseconds(request.queryMilliseconds, locale: locale))")
        }

        if request.logCount > 0 {
            counts.append(Count.text(request.logCount, "log line"))
        }

        if request.jobCount > 0 {
            counts.append(Count.text(request.jobCount, "job"))
        }

        if request.marks.contains(.nPlusOne) {
            counts.append("N+1")
        }

        if request.dumpCount == 0 {
            counts.removeFirst()
        }

        if id {
            counts.insert("request \(request.id)", at: 0)
        }

        if id || request.queryCount + request.logCount + request.jobCount > 0 {
            lines.append("  \(counts.joined(separator: " · "))")
        }

        if request.droppedQueries > 0 {
            lines.append("  \(DumpEntryText.droppedQueries(request.droppedQueries))")
        }

        return lines
    }

    // The header shows the try of a failed job. The app shows no try of a job that ended well.
    private static func jobLines(of job: JobRun) -> [String] {
        var lines: [String] = []

        if let queue = DumpEntryText.queue(of: job) {
            lines.append("  Queue   \(queue)")
        }

        if let command = job.command {
            lines.append("  Worker  \(command)")
        }

        if let queuedBy = job.queuedBy {
            lines.append("  From    request \(queuedBy)")
        }

        return lines
    }

    // tags holds the tags of all queries of the request. Each entry starts with its kind.
    public static func lines(of entry: CaughtDump, tags: QueryTags, locale: Locale = .current) -> [String] {
        switch entry.kind {
        case .dump, .dd: dumpLines(of: entry)
        case .query: queryLines(of: entry, tags: tags, locale: locale)
        case .log: logLines(of: entry)
        case .job: jobLines(of: entry, locale: locale)
        }
    }

    private static func dumpLines(of dump: CaughtDump) -> [String] {
        let label = dump.label.map { " \"\($0)\"" } ?? ""
        var lines = ["  \(dump.kind.rawValue)\(label)\(source(of: dump).map { " \($0)" } ?? "")"]
        lines += indented(withoutLastLineBreaks(dump.text))

        if dump.truncated {
            lines.append("    [The text stops here, because the dump is larger than 64 KB.]")
        }

        return lines
    }

    // The line joins the lines of the SQL. The JSON keeps the exact text.
    private static func queryLines(of query: CaughtDump, tags: QueryTags, locale: Locale) -> [String] {
        let sql = query.text.replacing(/\s*\n\s*/, with: " ").trimmingCharacters(in: .whitespaces)
        var parts = ["query"]
        parts += [query.milliseconds.map { milliseconds in DumpEntryText.milliseconds(milliseconds, locale: locale) }].compactMap { $0 }
        parts += tags.texts(of: query)
        parts.append(sql)
        parts += [source(of: query)].compactMap { $0 }

        var lines = ["  \(parts.joined(separator: "  "))"]

        if query.truncated {
            lines.append("    [The SQL stops here, because it is larger than 64 KB.]")
        }

        if let note = tags.note(after: query) {
            lines.append("    \(note)")
        }

        return lines
    }

    // The first line of the message stays on the line of the entry. The other lines and the context
    // follow with an indent.
    private static func logLines(of log: CaughtDump) -> [String] {
        let message = withoutLastLineBreaks(log.text).split(separator: "\n", omittingEmptySubsequences: false)
        let level = (log.label ?? "log") + (log.detail.map { " (\($0))" } ?? "")
        var parts = ["log", level, String(message.first ?? "")]
        parts += [source(of: log)].compactMap { $0 }

        var lines = ["  \(parts.joined(separator: "  "))"]
        lines += indented(message.dropFirst().joined(separator: "\n"))

        if log.truncated {
            lines.append("    [The message stops here, because it is larger than 64 KB.]")
        }

        if let context = log.decodedTree() {
            lines += indented(DumpEntryText.text(of: context))
        }

        return lines
    }

    private static func jobLines(of row: CaughtDump, locale: Locale) -> [String] {
        let time = row.milliseconds.map { milliseconds in DumpEntryText.milliseconds(milliseconds, locale: locale) }
        var parts = ["job", row.label ?? "queued", row.text]
        parts += [time, row.detail, source(of: row)].compactMap { $0 }
        return ["  \(parts.joined(separator: "  "))"]
    }

    private static func source(of entry: CaughtDump) -> String? {
        entry.file.map { file in "at \(file)\(entry.line.map { ":\($0)" } ?? "")" }
    }

    private static func withoutLastLineBreaks(_ text: String) -> Substring {
        var text = Substring(text)

        while text.hasSuffix("\n") {
            text = text.dropLast()
        }

        return text
    }

    private static func indented(_ text: some StringProtocol) -> [String] {
        guard !text.isEmpty else {
            return []
        }

        return text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : "    \($0)" }
    }

    public static func json(request: DumpedRequest, dump: CaughtDump, marks: Set<QueryMark> = []) throws -> String {
        String(decoding: try JSONEncoder.mcp.encode(CaughtDumpLine(request: request, dump: dump, marks: marks)), as: UTF8.self)
    }

    // The blocks of an event list hold all places. place keeps only the blocks of one site or
    // workspace. nil keeps all.
    public static func notes(of state: DumpState, place: DumpPlace?) -> [String] {
        var notes: [String] = []

        if !state.settings.catchDumps {
            notes.append("Catch dumps is off. So Nexus catches no new dumps. Turn it on with: nexus dumps settings --catch-dumps on")
        }

        notes += (state.problem ?? "").split(separator: "\n").map { "Warning: \($0)" }
        notes += state.blocked
            .filter { block in block.isShown(for: state.settings) && place.includes(block.place ?? DumpPlace()) }
            .map { block in "Warning: \(block.title). \(block.message)" }
        return notes
    }

    public static func noRequests(of host: String?) -> String {
        host.map { "Nexus has no requests of \($0)." } ?? "Nexus has no requests."
    }

    public static func lines(of settings: DumpSettings) -> [String] {
        [
            "Catch dumps       \(onOff(settings.catchDumps))",
            "Catch queries     \(onOff(settings.catchQueries))",
            "Catch log lines   \(onOff(settings.catchLogs))",
            "Catch queue jobs  \(onOff(settings.catchJobs))",
            "Page              \(settings.pageMode.rawValue) (\(settings.pageMode.title))",
            "Commands          \(onOff(settings.commands))",
        ]
    }

    private static func onOff(_ value: Bool) -> String {
        value ? "on" : "off"
    }
}
