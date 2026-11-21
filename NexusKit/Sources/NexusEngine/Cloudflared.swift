import Foundation

// The metrics server of one cloudflared on 127.0.0.1 (group 4, 4b). /quicktunnel gives the public
// host. /ready gives 200 with a connection to Cloudflare and 503 without one. A read has a short
// time limit, because cloudflared can hang during a sleep. nil is no answer.
enum CloudflaredMetrics {
    static let timeout: TimeInterval = 2

    private static let session = DirectSession.make(timeout: timeout)

    private struct QuickTunnel: Decodable {
        let hostname: String
    }

    // The host from /quicktunnel. An empty hostname gives nil.
    static func quickTunnelHost(port: Int) async -> String? {
        guard let (data, status) = await read("quicktunnel", port: port), status == 200 else {
            return nil
        }

        guard let host = try? JSONDecoder().decode(QuickTunnel.self, from: data).hostname, !host.isEmpty else {
            return nil
        }

        return host
    }

    // true for 200 and false for 503 from /ready.
    static func isReady(port: Int) async -> Bool? {
        switch await read("ready", port: port)?.status {
        case 200: true
        case 503: false
        default: nil
        }
    }

    // The version of the rules that a remotely managed tunnel uses now, from /config (group 4,
    // 4h). cloudflared gives -1 before the first rules from Cloudflare.
    static func configVersion(port: Int) async -> Int? {
        guard let (data, status) = await read("config", port: port), status == 200 else {
            return nil
        }

        return try? JSONDecoder().decode(Versioned.self, from: data).version
    }

    private static func read(_ path: String, port: Int) async -> (data: Data, status: Int)? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(path)") else {
            return nil
        }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)

        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
            return nil
        }

        return (data, http.statusCode)
    }
}

// The lines of cloudflared that nexusd reads (research 6, check A).
enum CloudflaredOutput {
    // The first line that starts with https://dash.cloudflare.com/.
    static func loginPage(in log: String) -> String? {
        log.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("https://dash.cloudflare.com/") }
    }

    // cloudflared asks Cloudflare 10 times for the cert and then stops with this error, after
    // about 8 to 10 minutes (token/transfer.go, pollAttempts). That is before the time limit of
    // nexusd. A failure of Cloudflare gives another error.
    static func loginWaitEnded(in log: String) -> Bool {
        log.contains("Failed to fetch resource")
    }
}

// The version of the rules of a tunnel, in an answer of Cloudflare and of cloudflared (4h).
struct Versioned: Decodable {
    let version: Int
}

// No proxy of the system and no cache come between nexusd and cloudflared or Cloudflare.
enum DirectSession {
    static func make(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}
