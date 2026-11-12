import Foundation
import NexusCore

// A browser for the tests of the web page of the dumps: one request on its own connection.
public enum PageClient {
    public struct Answer: Sendable {
        public let status: Int
        public let headers: [String: String]
        public let body: String
    }

    public static func get(_ path: String, port: Int, host: String? = nil) throws -> Answer {
        try exchange("GET \(path) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\n\r\n", port: port)
    }

    public static func post(_ path: String, json: String, port: Int, token: String, origin: String? = nil) throws -> Answer {
        var head = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nX-Nexus-Token: \(token)\r\n"
        head += "Origin: \(origin ?? "http://127.0.0.1:\(port)")\r\nContent-Length: \(Data(json.utf8).count)\r\n\r\n"
        return try exchange(head + json, port: port)
    }

    // An open connection to /api/events. readLine gives the lines of the events.
    package static func events(port: Int) throws -> LineSocket {
        let socket = try LineSocket.connect(port: port, timeout: 5)
        try socket.write(Data("GET /api/events HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8))
        return socket
    }

    private static func exchange(_ request: String, port: Int) throws -> Answer {
        let socket = try LineSocket.connect(port: port, timeout: 5)
        defer { socket.close() }
        try socket.write(Data(request.utf8))

        let statusLine = String(decoding: try socket.readLine() ?? Data(), as: UTF8.self)
        var headers: [String: String] = [:]

        while let line = try socket.readLine(), !line.isEmpty {
            let text = String(decoding: line, as: UTF8.self)

            if let colon = text.firstIndex(of: ":") {
                headers[text[..<colon].lowercased()] = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = try socket.read(count: length) ?? Data()
        let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
        return Answer(status: status, headers: headers, body: String(decoding: body, as: UTF8.self))
    }
}
