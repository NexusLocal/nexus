import Foundation
import NexusConfig

// The cert of cloudflared tunnel login (research 6, section 2): one PEM block ARGO TUNNEL TOKEN
// with JSON. nexusd keeps the whole file in the Keychain and reads it at each use.
struct CloudflareCert: Decodable, Sendable, Equatable {
    let zoneID: String
    let accountID: String
    let apiToken: String

    static func parse(_ pem: Data) -> CloudflareCert? {
        let text = String(decoding: pem, as: UTF8.self)

        guard let begin = text.range(of: "-----BEGIN ARGO TUNNEL TOKEN-----"), let end = text.range(of: "-----END ARGO TUNNEL TOKEN-----", range: begin.upperBound..<text.endIndex) else {
            return nil
        }

        let body = String(text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace })

        guard let json = Data(base64Encoded: body), let cert = try? JSONDecoder().decode(CloudflareCert.self, from: json) else {
            return nil
        }

        guard !cert.zoneID.isEmpty, !cert.accountID.isEmpty, !cert.apiToken.isEmpty else {
            return nil
        }

        return cert
    }
}

struct CloudflareDNSRecord: Decodable, Sendable, Equatable {
    let id: String
    let type: String
    let name: String
    let content: String

    // A CNAME to the tunnel of Nexus is a record of Nexus. Each other record belongs to the user
    // (decisions.md).
    func points(to tunnelTarget: String) -> Bool {
        type == "CNAME" && content == tunnelTarget
    }
}

// An answer of the API that is not a success. refused is 401 or 403: the key does not work now.
// conflict is 409: the account has a tunnel with that name. The description goes into the log of
// the own domain and into activity.log. It never holds the token.
enum CloudflareAPIError: Error, Equatable, CustomStringConvertible {
    case refused
    case notFound
    case conflict
    case failed(status: Int, message: String)
    case noAnswer

    var description: String {
        switch self {
        case .refused:
            "Cloudflare refused the key of Nexus."
        case .notFound:
            "Cloudflare does not know the tunnel or the record."
        case .conflict:
            "Cloudflare has a tunnel with this name already."
        case .failed(let status, let message):
            message.isEmpty ? "Cloudflare gave the status \(status)." : "Cloudflare gave the status \(status): \(message)"
        case .noAnswer:
            "Nexus did not reach Cloudflare."
        }
    }
}

// The calls of the API of Cloudflare for the own domain (group 4, 4h). token is the apiToken of
// the cert. A test gives its own answers. So no unit test connects to Cloudflare. Way R makes the
// tunnel and the DNS records through the API, as check E did (decisions.md, 2026-11-20). So the cert
// is never a file after the login.
struct CloudflareAPI: Sendable {
    var zoneName: @Sendable (_ zone: String, _ token: String) async throws -> String
    var records: @Sendable (_ zone: String, _ name: String, _ token: String) async throws -> [CloudflareDNSRecord]
    var addRecord: @Sendable (_ zone: String, _ name: String, _ target: String, _ token: String) async throws -> Void
    var deleteRecord: @Sendable (_ zone: String, _ id: String, _ token: String) async throws -> Void
    var createTunnel: @Sendable (_ account: String, _ name: String, _ token: String) async throws -> String
    var putRules: @Sendable (_ account: String, _ tunnel: String, _ rules: [String: Int], _ token: String) async throws -> Int
    var tunnelToken: @Sendable (_ account: String, _ tunnel: String, _ token: String) async throws -> Data
    var deleteTunnel: @Sendable (_ account: String, _ tunnel: String, _ token: String) async throws -> Void

    static let base = URL(string: "https://api.cloudflare.com/client/v4/")!
    static let timeout: TimeInterval = 15

    private struct Named: Decodable {
        let name: String
    }

    private struct Identified: Decodable {
        let id: String
    }

    static let live = CloudflareAPI(
        zoneName: { zone, token in
            try await call(request("GET", "zones/\(zone)", token: token), as: Named.self).name
        },
        records: { zone, name, token in
            try await call(request("GET", "zones/\(zone)/dns_records", query: [URLQueryItem(name: "name", value: name)], token: token), as: [CloudflareDNSRecord].self)
        },
        addRecord: { zone, name, target, token in
            let body = try JSONSerialization.data(withJSONObject: ["type": "CNAME", "name": name, "content": target, "proxied": true] as [String: Any])
            _ = try await call(request("POST", "zones/\(zone)/dns_records", token: token, body: body), as: Identified.self)
        },
        deleteRecord: { zone, id, token in
            try await call(request("DELETE", "zones/\(zone)/dns_records/\(id)", token: token))
        },
        createTunnel: { account, name, token in
            let body = try JSONEncoder().encode(["name": name, "config_src": "cloudflare"])
            return try await call(request("POST", "accounts/\(account)/cfd_tunnel", token: token, body: body), as: Identified.self).id
        },
        putRules: { account, tunnel, rules, token in
            let body = try JSONEncoder().encode(["config": ["ingress": CloudflaredConfig.ingress(rules)]])
            return try await call(request("PUT", "accounts/\(account)/cfd_tunnel/\(tunnel)/configurations", token: token, body: body), as: Versioned.self).version
        },
        tunnelToken: { account, tunnel, token in
            let value = try await call(request("GET", "accounts/\(account)/cfd_tunnel/\(tunnel)/token", token: token), as: String.self)
            return Data(value.utf8)
        },
        deleteTunnel: { account, tunnel, token in
            do {
                try await call(request("DELETE", "accounts/\(account)/cfd_tunnel/\(tunnel)/connections", token: token))
            } catch CloudflareAPIError.notFound {}

            try await call(request("DELETE", "accounts/\(account)/cfd_tunnel/\(tunnel)", token: token))
        }
    )

    // The request with the header Authorization: Bearer <token>, for the tests.
    static func request(_ method: String, _ path: String, query: [URLQueryItem] = [], token: String, body: Data? = nil) -> URLRequest {
        var url = base.appending(path: path)

        if !query.isEmpty {
            url.append(queryItems: query)
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        return request
    }

    private struct Message: Decodable {
        let message: String
    }

    private struct Envelope: Decodable {
        let success: Bool
        let errors: [Message]?
    }

    private struct Answer<Result: Decodable>: Decodable {
        let result: Result
    }

    // An answer with "success": true is a success. The status decides the error.
    static func check(_ data: Data, status: Int) throws {
        switch status {
        case 401, 403:
            throw CloudflareAPIError.refused
        case 404:
            throw CloudflareAPIError.notFound
        case 409:
            throw CloudflareAPIError.conflict
        default:
            break
        }

        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)

        guard (200..<300).contains(status), envelope?.success == true else {
            throw CloudflareAPIError.failed(status: status, message: (envelope?.errors ?? []).map(\.message).joined(separator: " "))
        }
    }

    static func result<Result: Decodable>(_ type: Result.Type, from data: Data, status: Int) throws -> Result {
        try check(data, status: status)

        guard let answer = try? JSONDecoder().decode(Answer<Result>.self, from: data) else {
            throw CloudflareAPIError.failed(status: status, message: "The answer has no result.")
        }

        return answer.result
    }

    private static let session = DirectSession.make(timeout: timeout)

    private static func call<Result: Decodable>(_ request: URLRequest, as type: Result.Type) async throws -> Result {
        let (data, status) = try await send(request)
        return try result(type, from: data, status: status)
    }

    private static func call(_ request: URLRequest) async throws {
        let (data, status) = try await send(request)
        try check(data, status: status)
    }

    // A network error gives noAnswer. A cancel stays a cancel.
    private static func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            try Task.checkCancellation()
            throw CloudflareAPIError.noAnswer
        }
    }
}
