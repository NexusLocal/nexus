import Foundation

// The dumps that nexusd catches from the prepend file of PHP. The name "dump" alone belongs to
// the database dumps.

// One call of dump() or dd(). text is the output of CliDumper without colors for the CLI, the MCP
// tool, the copy button and the search. treeJSON holds the same values for the tree view of the
// app. nexusd keeps it as the text that PHP sent and never decodes it. Only the app decodes the
// tree of the dump that it shows. The PHP side sends no tree when its JSON is larger than 512 KB.
public struct CaughtDump: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case dump
        case dd
    }

    public let requestID: String
    public let seq: Int
    public let time: Date
    public let kind: Kind
    public let file: String?
    public let line: Int?
    public let label: String?
    public let text: String
    public let treeJSON: String?
    public let truncated: Bool

    // The PHP side counts seq from 1 in each request. So the pair is unique in the store.
    public var id: String {
        "\(requestID)-\(seq)"
    }

    enum CodingKeys: String, CodingKey {
        case requestID
        case seq
        case time
        case kind
        case file
        case line
        case label
        case text
        case treeJSON = "tree"
        case truncated
    }

    public init(requestID: String, seq: Int, time: Date, kind: Kind = .dump, file: String? = nil, line: Int? = nil, label: String? = nil, text: String, treeJSON: String? = nil, truncated: Bool = false) {
        self.requestID = requestID
        self.seq = seq
        self.time = time
        self.kind = kind
        self.file = file
        self.line = line
        self.label = label
        self.text = text
        self.treeJSON = treeJSON
        self.truncated = truncated
    }

    // A tree that does not decode gives nil. The app then shows the text.
    public func decodedTree() -> DumpNode? {
        guard let treeJSON else {
            return nil
        }

        return try? JSONDecoder().decode(DumpNode.self, from: Data(treeJSON.utf8))
    }
}

// A web request or a command without the bodies of its dumps. The app loads the dumps of one
// request only when the user selects it. So a change of the list never sends them again. A command
// has no method and its command line as the target.
public struct DumpedRequest: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case http
        case command
    }

    public let id: String
    public let kind: Kind
    public let method: String?
    public let target: String
    public let url: String?
    public let host: String?
    public var site: String?
    public var workspace: String?
    public let started: Date
    // These come with the end of the request. A request that still runs or that PHP ended without
    // its shutdown functions has none.
    public var status: Int?
    public var exitCode: Int?
    public var duration: TimeInterval?
    // nexusd updates these when a dump arrives.
    public var dumpCount: Int
    public var hasDD: Bool

    public init(id: String, kind: Kind, method: String? = nil, target: String, url: String? = nil, host: String? = nil, site: String? = nil, workspace: String? = nil, started: Date, status: Int? = nil, exitCode: Int? = nil, duration: TimeInterval? = nil, dumpCount: Int = 0, hasDD: Bool = false) {
        self.id = id
        self.kind = kind
        self.method = method
        self.target = target
        self.url = url
        self.host = host
        self.site = site
        self.workspace = workspace
        self.started = started
        self.status = status
        self.exitCode = exitCode
        self.duration = duration
        self.dumpCount = dumpCount
        self.hasDD = hasDD
    }

    // So the list shows both kinds in the same columns.
    public var displayMethod: String {
        switch kind {
        case .http: method ?? ""
        case .command: "CLI"
        }
    }
}

// A site whose dumps Nexus cannot catch. With VAR_DUMPER_FORMAT the site keeps its own dump
// handler. A .user.ini with its own prepend file replaces the prepend file of Nexus. The site keeps
// that file (owner, 2026-11-11). file is the .env or the .user.ini that the banner opens. It is nil
// when the key does not come from a file of the site.
public struct DumpBlock: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable {
        case varDumperFormat = "var_dumper_format"
        case userIni = "user_ini"
    }

    public let host: String
    public let reason: Reason
    public let file: String?

    public init(host: String, reason: Reason, file: String? = nil) {
        self.host = host
        self.reason = reason
        self.file = file
    }
}

// One value in the tree of a dump, as the Nexus dumper of the PHP side writes it (wire format
// version 1). A key that the dumper leaves out stays nil. So an encode leaves it out again.
public struct DumpNode: Codable, Sendable, Equatable {
    // label is a constant or another short value that VarDumper shows without quotes. A kind from a
    // newer PHP side becomes a label. So one unknown node does not hide the whole tree.
    public enum Kind: String, Codable, Sendable {
        case null
        case bool
        case int
        case float
        case string
        case label
        case array
        case object
        case resource

        public init(from decoder: any Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .label
        }
    }

    // virtual is a value that a caster adds, also each key of a resource. dynamic is a property that
    // the class does not declare. An access from a newer PHP side becomes virtual.
    public enum Access: String, Codable, Sendable {
        case `public`
        case protected
        case `private`
        case virtual
        case dynamic

        public init(from decoder: any Decoder) throws {
            self = Access(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .virtual
        }
    }

    public let kind: Kind
    public let key: String?
    public let index: Bool?
    public let access: Access?
    public let value: String?
    public let className: String?
    public let ref: Int?
    public let count: Int?
    public let cut: Int?
    public let length: Int?
    // The tree already shows this object. So the node has no children. A loop in the data then
    // cannot make the tree endless.
    public let refersTo: Int?
    public let children: [DumpNode]?

    enum CodingKeys: String, CodingKey {
        case kind
        case key
        case index
        case access
        case value
        case className = "class"
        case ref
        case count
        case cut
        case length
        case refersTo
        case children
    }

    public init(kind: Kind, key: String? = nil, index: Bool? = nil, access: Access? = nil, value: String? = nil, className: String? = nil, ref: Int? = nil, count: Int? = nil, cut: Int? = nil, length: Int? = nil, refersTo: Int? = nil, children: [DumpNode]? = nil) {
        self.kind = kind
        self.key = key
        self.index = index
        self.access = access
        self.value = value
        self.className = className
        self.ref = ref
        self.count = count
        self.cut = cut
        self.length = length
        self.refersTo = refersTo
        self.children = children
    }

    // The key as the tree view shows it. It follows CliDumper. So the tree and the text name a value
    // the same way. A string key of an array gets quotes and an integer key does not. A property
    // gets the marker of its access: + public, # protected and - private. A virtual value has no
    // marker. CliDumper puts quotes around a dynamic property.
    public var displayKey: String? {
        guard let key else {
            return nil
        }

        guard let access else {
            return index == true ? key : "\"\(key)\""
        }

        switch access {
        case .public: return "+\(key)"
        case .protected: return "#\(key)"
        case .private: return "-\(key)"
        case .virtual: return key
        case .dynamic: return "+\"\(key)\""
        }
    }
}
