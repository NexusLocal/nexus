import Foundation
import NexusCore

// The request object of the wire format. Each event carries it in full. So the store can join the
// events of a request in any order. root is the document root of a web request and the working
// folder of a command. Part 7 maps the host and the root to a site or a workspace. A job of a
// worker has the kind job and its job.
public struct DumpEnvelope: Decodable, Sendable, Equatable {
    public let id: String
    public let kind: DumpedRequest.Kind
    public let method: String?
    public let url: String?
    public let host: String?
    public let command: String?
    public let cwd: String?
    public let root: String?
    public let started: Date
    public let pid: Int?
    public let job: JobRun?

    public init(id: String, kind: DumpedRequest.Kind, method: String? = nil, url: String? = nil, host: String? = nil, command: String? = nil, cwd: String? = nil, root: String? = nil, started: Date, pid: Int? = nil, job: JobRun? = nil) {
        self.id = id
        self.kind = kind
        self.method = method
        self.url = url
        self.host = host
        self.command = command
        self.cwd = cwd
        self.root = root
        self.started = started
        self.pid = pid
        self.job = job
    }

    // The header of the list starts without a place, an end and entries. The target of a job is its
    // name. So its job keeps the command line of the worker.
    public var header: DumpedRequest {
        DumpedRequest(id: id, kind: kind, method: method, target: target, url: url, host: host, root: root, started: started, job: headerJob)
    }

    private var headerJob: JobRun? {
        guard kind == .job, var job else {
            return job
        }

        job.command = job.command ?? command
        return job
    }

    // The list shows the path and the query of a web request. It shows the command line of a
    // command and the name of a job. The command line of a job is the command of the worker.
    var target: String {
        if kind == .job, let job {
            return job.name
        }

        guard kind == .http else {
            return command ?? ""
        }

        guard let url, let components = URLComponents(string: url) else {
            return url ?? "/"
        }

        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath

        guard let query = components.percentEncodedQuery else {
            return path
        }

        return "\(path)?\(query)"
    }
}

// entries holds queries, log lines and job rows, in one line for each group that PHP sends. The
// end of a job of a worker has its outcome. droppedQueries counts the queries after the first 500
// of a request.
public enum DumpEvent: Sendable, Equatable {
    case dump(request: DumpEnvelope, dump: CaughtDump)
    case entries(request: DumpEnvelope, entries: [CaughtDump])
    case end(request: DumpEnvelope, status: Int?, exitCode: Int?, duration: TimeInterval?, outcome: JobRun.Outcome? = nil, droppedQueries: Int? = nil)
    case blocked(request: DumpEnvelope, reason: DumpBlock.Reason, detail: String?)

    public var request: DumpEnvelope {
        switch self {
        case .dump(let request, _): request
        case .entries(let request, _): request
        case .end(let request, _, _, _, _, _): request
        case .blocked(let request, _, _): request
        }
    }
}

public enum DumpLineError: Error, Equatable, CustomStringConvertible {
    case unknownVersion(Int)
    case unknownType(String)
    case missingRequestID

    public var description: String {
        switch self {
        case .unknownVersion(let version): "The line has the unknown wire version \(version)."
        case .unknownType(let type): "The line has the unknown event type \(type)."
        case .missingRequestID: "The request of the line has no id."
        }
    }
}

// One line of the prepend file of PHP (wire format version 1, see Part 3 of
// docs/dump-viewer-build.md and "Exact wire format" in docs/dump-viewer-part2.md). The tree stays
// the JSON text that PHP sent. Only the app decodes it.
public enum DumpLine {
    public static let version = 1

    public static func decode(_ line: Data) throws -> DumpEvent {
        try DumpCoding.decoder.decode(WireEvent.self, from: line).event
    }
}

// Dates are seconds since 1970, on the wire and in logs/dumps.jsonl. The keys of the file are
// sorted. So a record gets the same bytes each time.
enum DumpCoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

private struct WireEvent: Decodable {
    let event: DumpEvent

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case type
        case request
        case dump
        case entries
        case status
        case exit
        case duration
        case outcome
        case droppedQueries
        case reason
        case detail
    }

    enum RequestKeys: String, CodingKey {
        case id
    }

    // The version comes first. A newer PHP side can change every other key.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)

        guard version == DumpLine.version else {
            throw DumpLineError.unknownVersion(version)
        }

        let type = try container.decode(String.self, forKey: .type)
        let requestKeys = try container.nestedContainer(keyedBy: RequestKeys.self, forKey: .request)
        let id = try requestKeys.decodeIfPresent(String.self, forKey: .id) ?? ""

        guard !id.isEmpty else {
            throw DumpLineError.missingRequestID
        }

        let request = try container.decode(DumpEnvelope.self, forKey: .request)

        switch type {
        case "dump":
            let dump = try container.decode(WireDump.self, forKey: .dump)
            event = .dump(request: request, dump: dump.caughtDump(requestID: request.id))
        case "entries":
            let entries = try container.decode([SkippableEntry].self, forKey: .entries)
            event = .entries(request: request, entries: entries.compactMap { skippable in skippable.entry?.caughtDump(requestID: request.id) })
        case "end":
            // An unknown outcome does not cost the end of the request.
            event = .end(
                request: request,
                status: try container.decodeIfPresent(Int.self, forKey: .status),
                exitCode: try container.decodeIfPresent(Int.self, forKey: .exit),
                duration: try container.decodeIfPresent(Double.self, forKey: .duration),
                outcome: (try? container.decodeIfPresent(JobRun.Outcome.self, forKey: .outcome)) ?? nil,
                droppedQueries: try container.decodeIfPresent(Int.self, forKey: .droppedQueries)
            )
        case "blocked":
            event = .blocked(
                request: request,
                reason: try container.decode(DumpBlock.Reason.self, forKey: .reason),
                detail: try container.decodeIfPresent(String.self, forKey: .detail)
            )
        default:
            throw DumpLineError.unknownType(type)
        }
    }
}

// One entry of an entries line. An entry that does not decode is nil, for example a kind of a newer
// PHP side or a time that is not a number. So one bad entry does not cost the other entries of
// its line.
private struct SkippableEntry: Decodable {
    let entry: WireDump?

    init(from decoder: any Decoder) throws {
        entry = try? WireDump(from: decoder)
    }
}

// A dump, or an entry of an entries line with the same keys and the keys of the other kinds.
private struct WireDump: Decodable {
    let seq: Int
    let time: Date
    let kind: CaughtDump.Kind
    let file: String?
    let line: Int?
    let label: String?
    let text: String
    let tree: String?
    let ms: Double?
    let pattern: String?
    let detail: String?
    let ref: String?
    let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case seq
        case time
        case kind
        case file
        case line
        case label
        case text
        case tree
        case ms
        case pattern
        case detail
        case ref
        case truncated
    }

    // ref is the id of an action of Action Scheduler or the uuid of a Laravel job. So it can come
    // as a number.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        seq = try container.decode(Int.self, forKey: .seq)
        time = try container.decode(Date.self, forKey: .time)
        kind = try container.decode(CaughtDump.Kind.self, forKey: .kind)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        line = try container.decodeIfPresent(Int.self, forKey: .line)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        text = try container.decode(String.self, forKey: .text)
        tree = try container.decodeIfPresent(String.self, forKey: .tree)
        ms = try container.decodeIfPresent(Double.self, forKey: .ms)
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        ref = try container.decodeTextIfPresent(forKey: .ref)
        truncated = try container.decode(Bool.self, forKey: .truncated)
    }

    func caughtDump(requestID: String) -> CaughtDump {
        CaughtDump(requestID: requestID, seq: seq, time: time, kind: kind, file: file, line: line, label: label, text: text, treeJSON: tree, milliseconds: ms, pattern: pattern, detail: detail, ref: ref, truncated: truncated)
    }
}
