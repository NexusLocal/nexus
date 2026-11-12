import Foundation
import NexusCore
import Synchronization

// The web page of the dumps: nexusd serves it on 127.0.0.1, as Mailpit serves its inbox. The
// server answers / with the page itself and handle answers each request of /api.
// /api/events stays open and gets each event of send, as server-sent events. Each other
// connection gets one answer and closes.
//
// The dumps can hold secrets of a site. So the Host of each request must name this server: a
// website that points its own host name at 127.0.0.1 then reads nothing. A request that changes
// something must also come from the page itself, with the token of this run of nexusd. Another
// website cannot read that token.
public final class DumpPageServer: Sendable {
    public typealias Handler = @Sendable (PageRequest) async -> PageResponse

    // An open page that gets the events. Each page writes on its own queue. So a page that stopped
    // reading holds up only its own events. Only the thread of the page closes the socket, after
    // the last write of the queue. So no thread uses the descriptor after the close, also when
    // macOS gives its number to a new connection.
    private final class EventPage: @unchecked Sendable {
        let socket: LineSocket
        private let writes = DispatchQueue(label: "nl.roodfruit.nexus.dumps.page.writes")
        private let lock = NSLock()
        private var closing = false
        private var closed = false

        init(socket: LineSocket) {
            self.socket = socket
        }

        // A failed write ends the page. Its thread then stops reading and closes the socket.
        func send(_ data: Data) {
            writes.async { [self] in
                guard !lock.withLock({ closing }) else {
                    return
                }

                if (try? socket.write(data)) == nil {
                    end()
                }
            }
        }

        // Ends a read or a write that waits, from any thread.
        func end() {
            lock.withLock {
                if !closed {
                    socket.shutdown()
                }
            }
        }

        // The thread of the page calls this once, after the page left the list. A write that
        // started before the end finishes first. A later write sees closing and does nothing.
        func close() {
            lock.withLock {
                closing = true
                socket.shutdown()
            }

            writes.sync {}

            lock.withLock {
                closed = true
                socket.close()
            }
        }
    }

    // A ping after each quiet time shows a page that is gone.
    static let pingInterval: TimeInterval = 30
    // Each open page holds a thread of the listener.
    static let pageLimit = 32

    public let token: String
    private let handle: Handler
    private let pageOpened: @Sendable () -> Void
    private let pages = Mutex<[UUID: EventPage]>([:])
    private let events = DispatchQueue(label: "nl.roodfruit.nexus.dumps.page.events")
    private let listener = Mutex<LoopbackListener?>(nil)
    private let requestedPort: Int

    // Port 0 takes a free port, for the tests. pageOpened runs when a page starts to get events.
    public init(port: Int, token: String = DumpPageServer.newToken(), pageOpened: @escaping @Sendable () -> Void = {}, handle: @escaping Handler) {
        requestedPort = port
        self.token = token
        self.pageOpened = pageOpened
        self.handle = handle
    }

    public static func newToken() -> String {
        (0..<2).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined().lowercased()
    }

    public var port: Int {
        listener.withLock { $0?.port ?? 0 }
    }

    public var url: String {
        "http://127.0.0.1:\(port)/"
    }

    public var hasPages: Bool {
        pages.withLock { !$0.isEmpty }
    }

    // The listener is in place before it accepts a connection. So the Host check of the first
    // connection knows the port.
    public func start() throws {
        let started = LoopbackListener(port: requestedPort, label: "nl.roodfruit.nexus.dumps.page", idleTimeout: Self.pingInterval) { [weak self] socket in
            guard let self else {
                socket.close()
                return
            }

            serve(socket)
        }

        listener.withLock { $0 = started }

        do {
            try started.start()
        } catch {
            listener.withLock { $0 = nil }
            throw error
        }
    }

    // The open pages end too. Their browsers then try again until nexusd runs again.
    public func stop() {
        listener.withLock { current in
            defer { current = nil }
            current?.stop()
        }

        for page in pages.withLock({ Array($0.values) }) {
            page.end()
        }
    }

    // The JSON is made once, on the queue of the events, not on the thread of the caller. It has
    // no line breaks, so it fits on one data line.
    public func send(event: String, value: some Encodable & Sendable) {
        events.async { [self] in
            guard let json = PageResponse.encodedJSON(value) else {
                return
            }

            let message = Data("event: \(event)\ndata: ".utf8) + json + Data("\n\n".utf8)

            for page in pages.withLock({ $0.values }) {
                page.send(message)
            }
        }
    }

    private func serve(_ socket: LineSocket) {
        guard let request = try? PageRequest.read(from: socket) else {
            answer(.message("Nexus did not understand this request.", status: 400), on: socket)
            return
        }

        if let refusal = PageGuard(port: port, token: token).refusal(of: request) {
            answer(refusal, on: socket)
            return
        }

        if request.method == "GET", request.path == "/" {
            answer(DumpPage.response(token: token), on: socket)
            return
        }

        if request.method == "GET", request.path == "/api/events" {
            keepOpen(socket)
            return
        }

        answer(Self.wait(for: request, handle), on: socket)
    }

    private func answer(_ response: PageResponse, on socket: LineSocket) {
        try? socket.write(response.encoded())
        socket.close()
    }

    // The listener gives each connection its own thread. So the thread can wait for the engine.
    private static func wait(for request: PageRequest, _ handle: @escaping Handler) -> PageResponse {
        let result = Mutex<PageResponse?>(nil)
        let done = DispatchSemaphore(value: 0)

        Task {
            let response = await handle(request)
            result.withLock { $0 = response }
            done.signal()
        }

        done.wait()
        return result.withLock { $0 } ?? .message("nexusd gave no answer.", status: 500)
    }

    // The thread reads until the browser closes the page or the page ends. A quiet time gives a
    // ping. The head goes out and the page joins the list in one step. So no event comes before
    // the head, and each event after it reaches the page.
    private func keepOpen(_ socket: LineSocket) {
        let id = UUID()
        let page = EventPage(socket: socket)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\nretry: 2000\n\n"

        let joined: Bool? = pages.withLock { open in
            guard open.count < Self.pageLimit else {
                return nil
            }

            guard (try? socket.write(Data(head.utf8))) != nil else {
                return false
            }

            open[id] = page
            return true
        }

        guard let joined else {
            answer(.message("Nexus has too many open pages of the dumps. Close one and load this page again.", status: 503), on: socket)
            return
        }

        guard joined else {
            socket.close()
            return
        }

        pageOpened()

        while true {
            do {
                guard try socket.readLine() != nil else {
                    break
                }
            } catch SocketError.system(_, let code) where code == EAGAIN || code == EWOULDBLOCK {
                page.send(Data(": ping\n\n".utf8))
            } catch {
                break
            }
        }

        pages.withLock { $0[id] = nil }
        page.close()
    }
}

// One request of the page. The names of the headers are in lower case.
public struct PageRequest: Sendable, Equatable {
    static let maxHeaderLines = 100
    static let maxLineLength = 8192
    static let maxBody = 64 * 1024

    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    // nil for a request that is not HTTP/1.x, that has a body without a length, or that is larger
    // than the limits.
    static func read(from socket: LineSocket) throws -> PageRequest? {
        guard let first = try socket.readLine(maxLength: maxLineLength) else {
            return nil
        }

        var lines: [String] = []

        while let line = try socket.readLine(maxLength: maxLineLength), !line.isEmpty {
            lines.append(String(decoding: line, as: UTF8.self))

            guard lines.count <= maxHeaderLines else {
                return nil
            }
        }

        guard let head = parse(requestLine: String(decoding: first, as: UTF8.self), headerLines: lines) else {
            return nil
        }

        guard head.headers["transfer-encoding"] == nil else {
            return nil
        }

        guard let length = Int(head.headers["content-length"] ?? "0"), (0...maxBody).contains(length) else {
            return nil
        }

        guard let body = try socket.read(count: length) else {
            return nil
        }

        return PageRequest(method: head.method, path: head.path, query: head.query, headers: head.headers, body: body)
    }

    static func parse(requestLine: String, headerLines: [String]) -> PageRequest? {
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)

        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/") else {
            return nil
        }

        guard let components = URLComponents(string: String(parts[1])) else {
            return nil
        }

        var headers: [String: String] = [:]

        for line in headerLines {
            guard let colon = line.firstIndex(of: ":") else {
                return nil
            }

            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        var query: [String: String] = [:]

        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }

        return PageRequest(method: String(parts[0]), path: components.path, query: query, headers: headers)
    }
}

// What a request may do. Each request names this server in its Host. A POST changes something. So
// it also needs the Origin of the page, the token and a JSON body. A form of another website can
// send none of these.
struct PageGuard {
    let port: Int
    let token: String

    private var hosts: Set<String> {
        ["127.0.0.1:\(port)", "localhost:\(port)"]
    }

    func refusal(of request: PageRequest) -> PageResponse? {
        guard hosts.contains(request.headers["host"]?.lowercased() ?? "") else {
            return .message("Open the dumps on http://127.0.0.1:\(port)/.", status: 403)
        }

        switch request.method {
        case "GET":
            return nil
        case "POST":
            break
        default:
            return .message("The page of the dumps takes only GET and POST.", status: 405)
        }

        guard let origin = request.headers["origin"]?.lowercased(), hosts.contains(where: { origin == "http://\($0)" }) else {
            return .message("Only the page of the dumps can change the dumps.", status: 403)
        }

        guard request.headers["x-nexus-token"] == token else {
            return .message("Load the page of the dumps again. Its token is from an earlier start of Nexus.", status: 403)
        }

        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            return .message("Send JSON.", status: 415)
        }

        return nil
    }
}

// An answer of the page. Each answer has the headers that keep the page in its own window: no
// frames, no cache and no referrer.
public struct PageResponse: Sendable, Equatable {
    public let status: Int
    public let contentType: String
    public let body: Data
    public let headers: [String: String]

    public init(status: Int, contentType: String, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.headers = headers
    }

    static let pageCoding: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    // Dates are milliseconds since 1970, as JavaScript counts them.
    public static func json(_ value: some Encodable, status: Int = 200) -> PageResponse {
        guard let body = encodedJSON(value) else {
            return message("nexusd cannot write this answer.", status: 500)
        }

        return PageResponse(status: status, contentType: "application/json", body: body)
    }

    public static func message(_ text: String, status: Int) -> PageResponse {
        json(["message": text], status: status)
    }

    static func encodedJSON(_ value: some Encodable) -> Data? {
        try? pageCoding.encode(value)
    }

    func encoded() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "X-Frame-Options: DENY\r\n"
        head += "Referrer-Policy: no-referrer\r\n"

        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }

        head += "Connection: close\r\n\r\n"

        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 415: "Unsupported Media Type"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}
