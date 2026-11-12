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
    // The place of the dump in the order of all dumps of the store, as DumpCursor counts it. The
    // order of the numbers is the order in which the dumps arrived. PHP can send a lower seq after
    // a higher one. So a client asks for the dumps of a request after a number and not after a
    // seq. 0 is a dump that the store did not number yet. Its JSON has no number.
    public var number: Int

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
        case number
    }

    public init(requestID: String, seq: Int, time: Date, kind: Kind = .dump, file: String? = nil, line: Int? = nil, label: String? = nil, text: String, treeJSON: String? = nil, truncated: Bool = false, number: Int = 0) {
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
        self.number = number
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        requestID = try container.decode(String.self, forKey: .requestID)
        seq = try container.decode(Int.self, forKey: .seq)
        time = try container.decode(Date.self, forKey: .time)
        kind = try container.decode(Kind.self, forKey: .kind)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        line = try container.decodeIfPresent(Int.self, forKey: .line)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        text = try container.decode(String.self, forKey: .text)
        treeJSON = try container.decodeIfPresent(String.self, forKey: .treeJSON)
        truncated = try container.decode(Bool.self, forKey: .truncated)
        number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(requestID, forKey: .requestID)
        try container.encode(seq, forKey: .seq)
        try container.encode(time, forKey: .time)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(file, forKey: .file)
        try container.encodeIfPresent(line, forKey: .line)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(treeJSON, forKey: .treeJSON)
        try container.encode(truncated, forKey: .truncated)

        if number > 0 {
            try container.encode(number, forKey: .number)
        }
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
    // The document root of a web request or the working folder of a command. nexusd finds the
    // site and the workspace again from the host and this folder when a site changes. A request
    // of an older nexusd has none.
    public let root: String?
    // nexusd sets the place, its first host and its project folder from its map of the sites.
    // placeHost is the host that a block names. The project folder is a real path, for example the
    // folder above public/. A request outside every site and a request of an older nexusd have no
    // placeHost and no projectFolder.
    public var site: String?
    public var workspace: String?
    public var placeHost: String?
    public var projectFolder: String?
    public let started: Date
    // These come with the end of the request. A request that still runs or that PHP ended without
    // its shutdown functions has none.
    public var status: Int?
    public var exitCode: Int?
    public var duration: TimeInterval?
    // nexusd updates these when a dump arrives. lastSeq is the newest seq of the request. It stays
    // when the limits remove old dumps. So a client reads the dumps of a request again only when
    // lastSeq grew. firstSeq is the lowest seq that the store still has. A client removes each dump
    // with a lower seq. lastNumber is the highest number that the store keeps of the request, so the
    // number of its newest dump. A client that has the dumps up to a number asks requestDumps after
    // that number when lastNumber
    // is higher. So a lower seq that arrives later also comes. firstNumber is the lowest number that
    // the store still keeps of the request. A client removes each dump with a lower number. The
    // numbers are values of the store. So the JSON for a script leaves them out.
    public var dumpCount: Int
    public var hasDD: Bool
    public var lastSeq: Int
    public var firstSeq: Int
    public var lastNumber: Int
    public var firstNumber: Int

    public init(id: String, kind: Kind, method: String? = nil, target: String, url: String? = nil, host: String? = nil, root: String? = nil, site: String? = nil, workspace: String? = nil, started: Date, status: Int? = nil, exitCode: Int? = nil, duration: TimeInterval? = nil, dumpCount: Int = 0, hasDD: Bool = false, lastSeq: Int = 0, firstSeq: Int = 0, placeHost: String? = nil, projectFolder: String? = nil, lastNumber: Int = 0, firstNumber: Int = 0) {
        self.id = id
        self.kind = kind
        self.method = method
        self.target = target
        self.url = url
        self.host = host
        self.root = root
        self.site = site
        self.workspace = workspace
        self.started = started
        self.status = status
        self.exitCode = exitCode
        self.duration = duration
        self.dumpCount = dumpCount
        self.hasDD = hasDD
        self.lastSeq = lastSeq
        self.firstSeq = firstSeq
        self.placeHost = placeHost
        self.projectFolder = projectFolder
        self.lastNumber = lastNumber
        self.firstNumber = firstNumber
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case method
        case target
        case url
        case host
        case root
        case site
        case workspace
        case placeHost
        case projectFolder
        case started
        case status
        case exitCode
        case duration
        case dumpCount
        case hasDD
        case lastSeq
        case firstSeq
        case lastNumber
        case firstNumber
    }

    // A request of an older nexusd has no lastSeq, firstSeq, lastNumber, firstNumber, placeHost and
    // projectFolder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        target = try container.decode(String.self, forKey: .target)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        root = try container.decodeIfPresent(String.self, forKey: .root)
        site = try container.decodeIfPresent(String.self, forKey: .site)
        workspace = try container.decodeIfPresent(String.self, forKey: .workspace)
        started = try container.decode(Date.self, forKey: .started)
        status = try container.decodeIfPresent(Int.self, forKey: .status)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        dumpCount = try container.decode(Int.self, forKey: .dumpCount)
        hasDD = try container.decode(Bool.self, forKey: .hasDD)
        lastSeq = try container.decodeIfPresent(Int.self, forKey: .lastSeq) ?? 0
        firstSeq = try container.decodeIfPresent(Int.self, forKey: .firstSeq) ?? 0
        lastNumber = try container.decodeIfPresent(Int.self, forKey: .lastNumber) ?? 0
        firstNumber = try container.decodeIfPresent(Int.self, forKey: .firstNumber) ?? 0
        placeHost = try container.decodeIfPresent(String.self, forKey: .placeHost)
        projectFolder = try container.decodeIfPresent(String.self, forKey: .projectFolder)
    }

    // A number of 0 is no number. So a header without numbers has none in its JSON.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(method, forKey: .method)
        try container.encode(target, forKey: .target)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(host, forKey: .host)
        try container.encodeIfPresent(root, forKey: .root)
        try container.encodeIfPresent(site, forKey: .site)
        try container.encodeIfPresent(workspace, forKey: .workspace)
        try container.encodeIfPresent(placeHost, forKey: .placeHost)
        try container.encodeIfPresent(projectFolder, forKey: .projectFolder)
        try container.encode(started, forKey: .started)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(exitCode, forKey: .exitCode)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encode(dumpCount, forKey: .dumpCount)
        try container.encode(hasDD, forKey: .hasDD)
        try container.encode(lastSeq, forKey: .lastSeq)
        try container.encode(firstSeq, forKey: .firstSeq)

        if lastNumber > 0 {
            try container.encode(lastNumber, forKey: .lastNumber)
        }

        if firstNumber > 0 {
            try container.encode(firstNumber, forKey: .firstNumber)
        }
    }

    // So the list shows both kinds in the same columns.
    public var displayMethod: String {
        switch kind {
        case .http: method ?? ""
        case .command: "CLI"
        }
    }

    public var place: DumpPlace {
        DumpPlace(site: site, workspace: workspace)
    }

    // The link to the page of a GET request. The browser sends a GET without a body. So the page of
    // another method would not be the same, or it would change data again.
    public var pageURL: URL? {
        guard kind == .http, method == "GET", let url, let link = URL(string: url) else {
            return nil
        }

        guard link.scheme == "http" || link.scheme == "https" else {
            return nil
        }

        return link
    }

    public var location: DumpLocation {
        get {
            DumpLocation(place: place, host: placeHost, projectFolder: projectFolder)
        }
        set {
            site = newValue.place.site
            workspace = newValue.place.workspace
            placeHost = newValue.host
            projectFolder = newValue.projectFolder
        }
    }

    // "200" for a web request and "exit 0" for a command. A request that still runs, or that PHP
    // ended without its shutdown functions, has none. The Dumps screen and nexus dumps show the
    // same text.
    public var statusText: String? {
        switch kind {
        case .http: status.map(String.init)
        case .command: exitCode.map { "exit \($0)" }
        }
    }

    public var durationText: String? {
        duration.map { Self.durationText($0) }
    }

    // "184 ms", "1.3 s" or "1 min 5 s". Each unit gets the rounded value. So 0.9996 s is "1.0 s"
    // and 59.97 s is "1 min 0 s".
    public static func durationText(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        let milliseconds = Int((seconds * 1000).rounded())

        if milliseconds < 1000 {
            return "\(milliseconds) ms"
        }

        let tenths = (seconds * 10).rounded() / 10

        if tenths < 60 {
            return "\(tenths.formatted(.number.precision(.fractionLength(1)).locale(locale))) s"
        }

        let whole = Int(seconds.rounded())
        return "\(whole / 60) min \(whole % 60) s"
    }
}

// A place in the order of all dumps of the store. number counts up for each dump. epoch names the
// store: it changes when the store starts without its file and after a clear of all dumps. A cursor
// of another epoch tells a client to start again with the newest requests.
public struct DumpCursor: Codable, Sendable, Hashable {
    public let epoch: String
    public let number: Int

    public init(epoch: String, number: Int) {
        self.epoch = epoch
        self.number = number
    }
}

// Dumps with the headers of their requests, in the order in which the dumps arrived. cursor is the
// newest dump of the store at the time of the read. A client gives it back in newDumps and then
// gets only the dumps that came later. olderCounts comes with lastDumps: for each request of the
// batch, the number of its older dumps that the batch leaves out.
public struct DumpBatch: Codable, Sendable, Equatable {
    public let dumps: [CaughtDump]
    public let requests: [DumpedRequest]
    public let cursor: DumpCursor
    public let olderCounts: [String: Int]

    public init(dumps: [CaughtDump], requests: [DumpedRequest], cursor: DumpCursor, olderCounts: [String: Int] = [:]) {
        self.dumps = dumps
        self.requests = requests
        self.cursor = cursor
        self.olderCounts = olderCounts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        dumps = try container.decode([CaughtDump].self, forKey: .dumps)
        requests = try container.decode([DumpedRequest].self, forKey: .requests)
        cursor = try container.decode(DumpCursor.self, forKey: .cursor)
        olderCounts = try container.decodeIfPresent([String: Int].self, forKey: .olderCounts) ?? [:]
    }
}

// The site or the workspace of a request. nexusd finds it from the host and the root. site is the
// host of the site and workspace is the name of the workspace. A filter with a place gives only the
// requests with the same site and the same workspace. So a site does not give the requests of its
// workspaces. DumpPlace() is the place of the requests without a site.
public struct DumpPlace: Codable, Sendable, Hashable {
    public var site: String?
    public var workspace: String?

    public init(site: String? = nil, workspace: String? = nil) {
        self.site = site
        self.workspace = workspace
    }
}

// A filter of the list. nil means all places.
extension DumpPlace? {
    public func includes(_ place: DumpPlace) -> Bool {
        guard let self else {
            return true
        }

        return self == place
    }
}

// The changes of the dump list since the last change, at most four times each second. It never
// holds the dumps themselves. The app applies a change in this order:
// 1. cleared: remove all requests.
// 2. removed: remove each request with one of these ids. An unknown id does nothing.
// 3. changed: replace each request with the same id in its place. Put each other request at the
//    top, in the order of the array. So the last new request is the newest.
// removedDumps holds the store numbers of single dumps that a user removed. A client removes them
// from the dumps that it shows. The request of such a dump is in changed, or in removed without
// dumps.
public struct DumpChange: Codable, Sendable, Equatable {
    public var changed: [DumpedRequest]
    public var removed: [String]
    public var cleared: Bool
    public var removedDumps: [Int]

    public init(changed: [DumpedRequest] = [], removed: [String] = [], cleared: Bool = false, removedDumps: [Int] = []) {
        self.changed = changed
        self.removed = removed
        self.cleared = cleared
        self.removedDumps = removedDumps
    }

    // A change of an older nexusd has no removedDumps.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        changed = try container.decode([DumpedRequest].self, forKey: .changed)
        removed = try container.decode([String].self, forKey: .removed)
        cleared = try container.decode(Bool.self, forKey: .cleared)
        removedDumps = try container.decodeIfPresent([Int].self, forKey: .removedDumps) ?? []
    }

    public var isEmpty: Bool {
        changed.isEmpty && removed.isEmpty && !cleared && removedDumps.isEmpty
    }

    // The list has the newest request first, as the store and DumpList have it. So the list gets
    // the same order as the list of the store.
    public func apply(to requests: inout [DumpedRequest]) {
        if cleared {
            requests.removeAll()
        }

        let gone = Set(removed)
        requests.removeAll { request in gone.contains(request.id) }

        for request in changed {
            if let index = requests.firstIndex(where: { $0.id == request.id }) {
                requests[index] = request
                continue
            }

            requests.insert(request, at: 0)
        }
    }
}

// Where a request belongs: its place, the first host of the place and the project folder of its
// site or workspace. nexusd finds it in its map of the sites.
public struct DumpLocation: Sendable, Equatable {
    public var place: DumpPlace
    public var host: String?
    public var projectFolder: String?

    public init(place: DumpPlace = DumpPlace(), host: String? = nil, projectFolder: String? = nil) {
        self.place = place
        self.host = host
        self.projectFolder = projectFolder
    }
}

// A site whose dumps Nexus cannot catch. With VAR_DUMPER_FORMAT the site keeps its own dump
// handler. A .user.ini with its own prepend file replaces the prepend file of Nexus. The site keeps
// that file (owner, 2026-11-11). file is the .env or the .user.ini that the banner opens. It is nil
// when the key does not come from a file of the site.
public struct DumpBlock: Codable, Sendable, Hashable {
    public enum Reason: String, Codable, Sendable {
        case varDumperFormat = "var_dumper_format"
        case userIni = "user_ini"
    }

    // host is the first host of the place. A block of an older nexusd has no place.
    public let host: String
    public let reason: Reason
    public let file: String?
    public let place: DumpPlace?

    public init(host: String, reason: Reason, file: String? = nil, place: DumpPlace? = nil) {
        self.host = host
        self.reason = reason
        self.file = file
        self.place = place
    }
}

// One value in the tree of a dump, as the Nexus dumper of the PHP side writes it (wire format
// version 1). A key that the dumper leaves out stays nil. So an encode leaves it out again.
public struct DumpNode: Codable, Sendable, Equatable {
    // The top node of a dump starts open in the app and on the web page, unless it has more
    // children than this.
    public static let openChildrenLimit = 100

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
