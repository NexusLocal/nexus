import Foundation

// The texts of a request and its entries on the Dumps screen (docs/dump-viewer-part2.md). The web
// page, nexus dumps and the MCP tool can use the same texts. So all name a request, a query, a log
// line and a job the same way.
public enum DumpEntryText {
    // "3 dumps · 24 queries · 200 · 184 ms". At most two counts that are not zero show, the dumps
    // first, then the queries, then the log lines. So the status and the time fit in the row of the
    // list. The tabs of the request show the other counts. A job of a worker starts with its
    // outcome: "done · 4 queries · 220 ms". A failed job names its try there, because its tag says
    // that it failed.
    public static func summary(of request: DumpedRequest, locale: Locale = .current) -> String {
        let counts = [
            (request.dumpCount, "dump", "dumps"),
            (request.queryCount, "query", "queries"),
            (request.logCount, "log line", "log lines"),
        ]
        .filter { count in count.0 > 0 }
        .prefix(2)
        .map { count in Count.text(count.0, count.1, plural: count.2) }

        let duration = request.duration.map { seconds in DumpedRequest.durationText(seconds, locale: locale) }

        guard request.kind == .job else {
            return (counts + [request.statusText, duration].compactMap { $0 }).joined(separator: " · ")
        }

        return ([outcome(of: request)].compactMap { $0 } + counts + [duration].compactMap { $0 }).joined(separator: " · ")
    }

    // "done", "released" or "try 3 of 3" for a failed job. A failed job without its try has none,
    // because its tag says that it failed.
    private static func outcome(of request: DumpedRequest) -> String? {
        guard let job = request.job, job.outcome == .failed else {
            return request.job?.outcomeText
        }

        return job.tryText
    }

    // The method column of the list. DumpedRequest.displayMethod gives it now. This stays until its
    // callers use that.
    public static func method(of request: DumpedRequest) -> String {
        request.displayMethod
    }

    // The Queue line of a job: "default · redis". A WP-Cron event has none.
    public static func queue(of job: JobRun) -> String? {
        let parts = [job.queue, job.connection].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // The Status line of a job: "Done · 220 ms", "Failed on try 3 of 3 · 1.4 s" or "Released". A
    // job that still runs has none.
    public static func jobStatus(of request: DumpedRequest, locale: Locale = .current) -> String? {
        guard let job = request.job, let outcome = job.outcome else {
            return nil
        }

        let status = switch outcome {
        case .done: "Done"
        case .released: "Released"
        case .failed: "Failed\(job.tryText.map { tryText in " on \(tryText)" } ?? "")"
        }

        let duration = request.duration.map { seconds in DumpedRequest.durationText(seconds, locale: locale) }
        return ([status] + [duration].compactMap { $0 }).joined(separator: " · ")
    }

    // The link of a job row to the job of the worker: "Ran at 14:32:10 · done". time is the start of
    // that job as the caller shows a time.
    public static func run(of job: DumpedRequest, time: String) -> String {
        (["Ran at \(time)"] + [job.statusText].compactMap { $0 }).joined(separator: " · ")
    }

    // The From line of a job: "GET /checkout at 14:32:08".
    public static func origin(_ request: DumpedRequest, time: String) -> String {
        "\(method(of: request)) \(request.target) at \(time)"
    }

    // "0.84 ms", "9.6 ms", "142 ms" or "1.4 s". A short time gets more digits after the point.
    public static func milliseconds(_ value: Double, locale: Locale = .current) -> String {
        if value.rounded() >= 1000 {
            return DumpedRequest.durationText(value / 1000, locale: locale)
        }

        let digits = value < 1 ? 2 : value < 100 ? 1 : 0
        return "\(value.formatted(.number.precision(.fractionLength(0...digits)).grouping(.never).locale(locale))) ms"
    }

    // The summary of the Queries tab: "38.4 ms in total".
    public static func queryTotal(of request: DumpedRequest, locale: Locale = .current) -> String {
        "\(milliseconds(request.queryMilliseconds, locale: locale)) in total"
    }

    // The tag of a group of queries: "N+1 · 12×" or "duplicate · 2×".
    public static func groupTag(_ kind: QueryRowKind, count: Int) -> String? {
        switch kind {
        case .single: nil
        case .nPlusOne: "N+1 · \(count)×"
        case .duplicate: "duplicate · \(count)×"
        }
    }

    // The note under an N+1 group. Only Laravel sends a pattern with each query. So a pattern means
    // a Laravel site.
    public static func nPlusOneNote(count: Int, isLaravel: Bool) -> String {
        let note = "This line runs the same query \(count) times with other values. One query for all values is faster."
        return isLaravel ? "\(note) In Laravel, load the relation with with()." : note
    }

    // The last line of the Queries tab when PHP kept only the first 500 queries.
    public static func droppedQueries(_ count: Int) -> String {
        "Nexus did not keep \(Count.text(count, "more query", plural: "more queries"))."
    }

    // The tag of a log line or a job row. Red for error and higher and for a sync job that failed,
    // orange for a warning, the accent for a queued job and gray for the rest.
    public static func tone(of entry: CaughtDump) -> DumpTagTone {
        switch entry.kind {
        case .log:
            if entry.isError {
                return .error
            }

            return entry.label?.lowercased() == "warning" ? .warning : .neutral
        case .job:
            switch entry.label {
            case "queued": return .accent
            case "failed": return .error
            default: return .neutral
            }
        default:
            return .neutral
        }
    }

    // The copy button of a log line gives the message and the context as text.
    public static func copyText(message: String, context: DumpNode?) -> String {
        guard let context else {
            return message
        }

        return "\(message)\n\(text(of: context))"
    }

    // A tree as text, in the way of CliDumper: "array:2 [", a line for each item with two spaces
    // more, and "]".
    public static func text(of node: DumpNode) -> String {
        var lines: [String] = []
        append(node, depth: 0, to: &lines)
        return lines.joined(separator: "\n")
    }

    private static func append(_ node: DumpNode, depth: Int, to lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        let key = node.displayKey.map { key in node.access == nil ? "\(key) => " : "\(key): " } ?? ""
        let children = node.refersTo == nil ? node.children ?? [] : []
        let cut = node.cut.flatMap { cut in cut == 0 ? nil : cut }
        let leftOut = cut.map { cut in cut < 0 ? "…" : "…\(cut)" }

        switch node.kind {
        case .null, .bool, .int, .float:
            lines.append("\(indent)\(key)\(node.value ?? node.kind.rawValue)")
        case .label:
            lines.append("\(indent)\(key)\(node.value ?? "")")
        case .string:
            lines.append("\(indent)\(key)\"\(node.value ?? "")\"\(leftOut ?? "")")
        case .array, .object, .resource:
            let (head, open, close) = container(node)

            guard !children.isEmpty else {
                let inside = leftOut.map { text in " \(text)" } ?? ""
                lines.append(open == "[" && (node.count ?? 0) == 0 ? "\(indent)\(key)[]" : "\(indent)\(key)\(head) \(open)\(inside)\(close)")
                return
            }

            lines.append("\(indent)\(key)\(head) \(open)")

            for child in children {
                append(child, depth: depth + 1, to: &lines)
            }

            if let leftOut {
                lines.append("\(indent)  \(leftOut)")
            }

            lines.append("\(indent)\(close)")
        }
    }

    private static func container(_ node: DumpNode) -> (head: String, open: String, close: String) {
        switch node.kind {
        case .object:
            return (node.className ?? "object", node.ref.map { ref in "{#\(ref)" } ?? "{", "}")
        case .resource:
            return ("\(node.className ?? "unknown") resource\(node.ref.map { ref in " @\(ref)" } ?? "")", "{", "}")
        default:
            return ("array:\(node.count ?? node.children?.count ?? 0)", "[", "]")
        }
    }
}

// The color of a tag of an entry.
public enum DumpTagTone: Sendable, Equatable {
    case accent
    case warning
    case error
    case neutral
}

// A tab of the request view: one for each kind of entry. A dump and a dd() share the tab of the
// dumps.
public enum DumpEntryTab: String, CaseIterable, Sendable {
    case dumps
    case queries
    case logs
    case jobs

    public init(_ kind: CaughtDump.Kind) {
        switch kind {
        case .dump, .dd: self = .dumps
        case .query: self = .queries
        case .log: self = .logs
        case .job: self = .jobs
        }
    }

    // The tabs of the kinds that the request has, in the order of the design. The request view has
    // no tabs when the request has only dumps. So this is empty then.
    public static func tabs(of request: DumpedRequest) -> [DumpEntryTab] {
        let tabs = allCases.filter { tab in tab.count(in: request) > 0 }
        return tabs.contains { tab in tab != .dumps } ? tabs : []
    }

    public func count(in request: DumpedRequest) -> Int {
        switch self {
        case .dumps: request.dumpCount
        case .queries: request.queryCount
        case .logs: request.logCount
        case .jobs: request.jobCount
        }
    }

    // "Dumps (3)", "Queries (24)", "Log lines (1)" or "Jobs (2)".
    public func title(in request: DumpedRequest) -> String {
        let name = switch self {
        case .dumps: "Dumps"
        case .queries: "Queries"
        case .logs: "Log lines"
        case .jobs: "Jobs"
        }

        return "\(name) (\(count(in: request)))"
    }
}

public enum QueryRowKind: Sendable, Equatable {
    case single
    case nPlusOne
    case duplicate
}

// A row of the Queries tab. The queries of an N+1 or a duplicate show as one group, at the place of
// the first query of the group. A query that is both goes into the group of the N+1. A duplicate
// whose other copy is in an N+1 group then stays a single row. Entry is the type of the caller for a
// query, for example the shown dump of the app.
public struct QueryRow<Entry> {
    public let kind: QueryRowKind
    public let entries: [Entry]
    // The time of all queries of the row together.
    public let milliseconds: Double

    // An N+1 group is the source that QueryMarks counts. So the group and the mark use one key.
    private enum GroupKey: Hashable {
        case nPlusOne(QuerySource)
        case duplicate(text: String)

        var kind: QueryRowKind {
            switch self {
            case .nPlusOne: .nPlusOne
            case .duplicate: .duplicate
            }
        }
    }

    // Each entry that is not a query is left out.
    public static func rows(of entries: [Entry], marks: QueryMarks, query: (Entry) -> CaughtDump) -> [QueryRow] {
        var rows: [(kind: QueryRowKind, entries: [Entry], milliseconds: Double)] = []
        var groups: [GroupKey: Int] = [:]

        for entry in entries {
            let caught = query(entry)

            guard caught.kind == .query else {
                continue
            }

            let time = caught.milliseconds ?? 0

            guard let key = groupKey(of: caught, marks: marks.marks(of: caught)) else {
                rows.append((.single, [entry], time))
                continue
            }

            if let index = groups[key] {
                rows[index].entries.append(entry)
                rows[index].milliseconds += time
                continue
            }

            groups[key] = rows.count
            rows.append((key.kind, [entry], time))
        }

        return rows.map { row in
            QueryRow(kind: row.entries.count > 1 ? row.kind : .single, entries: row.entries, milliseconds: row.milliseconds)
        }
    }

    private static func groupKey(of query: CaughtDump, marks: Set<QueryMark>) -> GroupKey? {
        if marks.contains(.nPlusOne) {
            return .nPlusOne(QuerySource(query, pattern: QueryMarks.pattern(of: query)))
        }

        if marks.contains(.duplicate) {
            return .duplicate(text: query.text)
        }

        return nil
    }
}
