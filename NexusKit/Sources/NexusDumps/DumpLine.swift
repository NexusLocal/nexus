import Foundation
import NexusCore

// The request object of the wire format. Each event carries it in full. So the store can join the
// events of a request in any order. root is the document root of a web request and the working
// folder of a command. Part 7 maps the host and the root to a site or a workspace.
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

    public init(id: String, kind: DumpedRequest.Kind, method: String? = nil, url: String? = nil, host: String? = nil, command: String? = nil, cwd: String? = nil, root: String? = nil, started: Date, pid: Int? = nil) {
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
    }

    // The header of the list starts without a place, an end and dumps.
    public var header: DumpedRequest {
        DumpedRequest(id: id, kind: kind, method: method, target: target, url: url, host: host, root: root, started: started)
    }

    // The list shows the path and the query of a web request. It shows the command line of a
    // command.
    var target: String {
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

public enum DumpEvent: Sendable, Equatable {
    case dump(request: DumpEnvelope, dump: CaughtDump)
    case end(request: DumpEnvelope, status: Int?, exitCode: Int?, duration: TimeInterval?)
    case blocked(request: DumpEnvelope, reason: DumpBlock.Reason, detail: String?)

    public var request: DumpEnvelope {
        switch self {
        case .dump(let request, _): request
        case .end(let request, _, _, _): request
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
// docs/dump-viewer-build.md). The tree stays the JSON text that PHP sent. Only the app decodes it.
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
        case status
        case exit
        case duration
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
        case "end":
            event = .end(
                request: request,
                status: try container.decodeIfPresent(Int.self, forKey: .status),
                exitCode: try container.decodeIfPresent(Int.self, forKey: .exit),
                duration: try container.decodeIfPresent(Double.self, forKey: .duration)
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

private struct WireDump: Decodable {
    let seq: Int
    let time: Date
    let kind: CaughtDump.Kind
    let file: String?
    let line: Int?
    let label: String?
    let text: String
    let tree: String?
    let truncated: Bool

    func caughtDump(requestID: String) -> CaughtDump {
        CaughtDump(requestID: requestID, seq: seq, time: time, kind: kind, file: file, line: line, label: label, text: text, treeJSON: tree, truncated: truncated)
    }
}
