import Foundation
import NexusCore

// One env file of a Node.js app. name is its path in the folder of the app.
public struct NodeEnvFile: Sendable, Equatable {
    public let name: String
    public let text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }

    // The files that the frameworks read in development (D67). Next.js, Vite, Nuxt and Astro all
    // read .env. Next.js and Vite also read the .local files and the files of the mode. A key can be
    // in more than one file. Nexus changes it in each file, so the order of the files does not matter.
    public static let names = [".env", ".env.local", ".env.development", ".env.development.local"]
}

// A Node.js app has no configuration that Nexus can ask, so its env files are the plan (D67). A key
// that leads to a Nexus instance gets the server or the Redis index of the workspace. A key that
// Nexus cannot change gives Not isolated (D48). A server that is no Nexus instance gives a warning,
// because Nexus cannot copy it. The workspace then runs with the server of the main site.
extension WorkspaceEnvPlan {
    public init(nodeFiles: [NodeEnvFile], usesDatabaseClient: Bool, request: WorkspaceEnvRequest) {
        self.init()

        let files = nodeFiles.map { EnvFile.values(in: $0.text) }
        let merged = files.reduce(into: [String: String]()) { all, file in
            all.merge(file) { _, later in later }
        }

        for hostKey in merged.keys.filter(Self.isHostKey).sorted() {
            add(hostKey: hostKey, values: merged, request: request)
        }

        let urlKeys = Set(files.flatMap { file in file.filter { ConnectionURL($0.value) != nil }.keys })

        for key in urlKeys.sorted(by: Self.databaseURLFirst) {
            for value in files.compactMap({ $0[key] }) {
                if let url = ConnectionURL(value) {
                    add(url, value: value, key: key, values: merged, request: request)
                }
            }
        }

        if usesDatabaseClient, serverPorts.isEmpty, redisKeys.isEmpty, problems.isEmpty, warnings.isEmpty {
            warnings.append("Nexus found no database key in the env files of the app. When the app reaches a Nexus database in another way, this workspace uses the database of the main site.")
        }

        redisKeys.sort()

        if let port = request.smtpPort {
            let mail = NodeMail.nexusKeys(merged, user: Self.hostPlaceholder, nexusPort: port)
            mailKeys = mail.keys
            warnings += mail.warnings
        }
    }

    private static func databaseURLFirst(_ first: String, _ second: String) -> Bool {
        (first == "DATABASE_URL" ? 0 : 1, first) < (second == "DATABASE_URL" ? 0 : 1, second)
    }

    private static func isHostKey(_ key: String) -> Bool {
        key == "PGHOST" || key.hasSuffix("_HOST")
    }

    private mutating func add(_ url: ConnectionURL, value: String, key: String, values: [String: String], request: WorkspaceEnvRequest) {
        let expanded = url.usesVariables ? ConnectionURL(Self.expanding(value, with: values)) : url

        guard let expanded, expanded.isReadable else {
            Self.note(&problems, "Nexus cannot read the URL in \(key), so it cannot change that URL.")
            return
        }

        guard expanded.isLocal else {
            Self.note(&warnings, "\(key) names a server on another computer, so this workspace shares that server with the main site.")
            return
        }

        guard let kind = kind(ofPort: expanded.port, request), kind == expanded.kind else {
            Self.note(&warnings, "\(key) names port \(expanded.port), and no Nexus instance of that kind has that port. So this workspace shares that server with the main site.")
            return
        }

        guard !expanded.namesSocket else {
            Self.note(&problems, "\(key) names a socket in its URL, and a socket ignores the port.")
            return
        }

        // A URL with variables follows the keys of its host and its port.
        if url.usesVariables {
            if !Self.portComesFromKey(value, keys: serverPortKeys[expanded.port] ?? []) || kind == .redis {
                Self.note(&problems, "\(key) builds its URL from other keys, so Nexus cannot change it.")
            }

            return
        }

        switch kind {
        case .redis:
            redisPorts.insert(expanded.port)
            mainRedisIndexes.insert(expanded.redisIndex)
            redisURLKeys.insert(key)

            if !redisKeys.contains(key) {
                redisKeys.append(key)
            }
        case .mysql, .postgresql:
            serverURLKeys.insert(key)
            urlPorts.insert(expanded.port)
            addDatabase(expanded.path, port: expanded.port)
        }
    }

    // A host key and a port key with the same prefix, such as DB_HOST and DB_PORT, PGHOST and
    // PGPORT, or REDIS_HOST and REDIS_PORT. Other keys end in _HOST too, for example MAIL_HOST.
    // So only a port of a Nexus instance counts.
    private mutating func add(hostKey: String, values: [String: String], request: WorkspaceEnvRequest) {
        let prefix = String(hostKey.dropLast(4))
        let portKey = "\(prefix)PORT"

        guard let value = values[hostKey] else {
            return
        }

        let (host, portInHost) = Self.split(host: value)

        guard ConnectionURL.isLocal(host) else {
            return
        }

        // WordPress and Bedrock keep the port in DB_HOST, as in 127.0.0.1:13306.
        if let portInHost {
            if kind(ofPort: portInHost, request) != nil {
                Self.note(&problems, "\(hostKey) has the port of a Nexus instance in it, so Nexus cannot change it. Use \(portKey) for the port.")
            }

            return
        }

        guard let portText = values[portKey] else {
            addHostWithoutPort(hostKey, prefix: prefix, portKey: portKey, request: request)
            return
        }

        guard let port = Int(portText), let kind = kind(ofPort: port, request) else {
            return
        }

        if kind == .redis {
            addRedis(prefix: prefix, hostKey: hostKey, port: port, values: values)
            return
        }

        if host != Self.serverHost {
            keys[hostKey] = Self.serverHost
        }

        if values["\(prefix)SOCKET"]?.isEmpty == false {
            keys["\(prefix)SOCKET"] = ""
        }

        if serverPortKeys[port]?.contains(portKey) != true {
            serverPortKeys[port, default: []].append(portKey)
        }

        let nameKeys = (prefix == "PG" ? ["PGDATABASE"] : []) + ["\(prefix)NAME", "\(prefix)DATABASE", "\(prefix)DB"]
        addDatabase(nameKeys.compactMap { values[$0] }.first ?? "", port: port)
    }

    // A client without a port uses the standard port of its kind. DB_HOST and DATABASE_HOST name no
    // kind, so both standard ports count for them. Other keys end in _HOST too, such as APP_HOST, and
    // they stay out.
    private mutating func addHostWithoutPort(_ hostKey: String, prefix: String, portKey: String, request: WorkspaceEnvRequest) {
        let kinds: [ConnectionURL.Kind] = Self.kind(ofPrefix: prefix).map { [$0] } ?? (Self.namesDatabase(prefix) ? [.mysql, .postgresql] : [])

        guard !kinds.isEmpty else {
            return
        }

        if kinds.contains(where: { ports(of: $0, request).contains($0.standardPort) }) {
            Self.note(&problems, "\(hostKey) names a Nexus instance without \(portKey), so Nexus cannot give this workspace its own server.")
        } else {
            Self.note(&warnings, "\(hostKey) names a local server without \(portKey), and no Nexus instance has the standard port. So this workspace shares that server with the main site.")
        }
    }

    private static func namesDatabase(_ prefix: String) -> Bool {
        ["DB_", "DATABASE_"].contains(prefix.uppercased())
    }

    // A host with a port, as in 127.0.0.1:13306 or [::1]:13306. An IPv6 address without brackets has
    // no port.
    static func split(host value: String) -> (host: String, port: Int?) {
        if value.hasPrefix("["), let end = value.firstIndex(of: "]") {
            let host = String(value[...end])
            let rest = value[value.index(after: end)...]
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil)
        }

        let parts = value.split(separator: ":", omittingEmptySubsequences: false)

        guard parts.count == 2, let port = Int(parts[1]) else {
            return (parts.count == 2 ? String(parts[0]) : value, nil)
        }

        return (String(parts[0]), port)
    }

    private mutating func addRedis(prefix: String, hostKey: String, port: Int, values: [String: String]) {
        guard let indexKey = ["\(prefix)DB", "\(prefix)DATABASE", "\(prefix)INDEX"].first(where: { values[$0] != nil }) else {
            Self.note(&problems, "\(hostKey) names a Nexus Redis instance, but no key holds the index, so this workspace would use the index of the main site. Add \(prefix)DB, or use a URL with the index.")
            return
        }

        redisPorts.insert(port)
        mainRedisIndexes.insert(values[indexKey].flatMap { Int($0) } ?? 0)

        if !redisKeys.contains(indexKey) {
            redisKeys.append(indexKey)
        }
    }

    private mutating func addDatabase(_ name: String, port: Int) {
        guard !name.isEmpty else {
            return
        }

        let isDefault = databases.isEmpty

        if isDefault {
            database = name
        }

        if !databases.contains(where: { $0.name == name && $0.port == port }) {
            databases.append(WorkspaceDatabase(name: name, port: port, isDefault: isDefault))
        }
    }

    private func kind(ofPort port: Int, _ request: WorkspaceEnvRequest) -> ConnectionURL.Kind? {
        if request.mysqlPorts.contains(port) {
            return .mysql
        }

        if request.postgresqlPorts.contains(port) {
            return .postgresql
        }

        return request.redisPorts.contains(port) ? .redis : nil
    }

    private func ports(of kind: ConnectionURL.Kind, _ request: WorkspaceEnvRequest) -> Set<Int> {
        switch kind {
        case .mysql: request.mysqlPorts
        case .postgresql: request.postgresqlPorts
        case .redis: request.redisPorts
        }
    }

    private static func kind(ofPrefix prefix: String) -> ConnectionURL.Kind? {
        let name = prefix.uppercased()

        if name.hasPrefix("PG") || name.contains("POSTGRES") {
            return .postgresql
        }

        if name.contains("MYSQL") || name.contains("MARIADB") {
            return .mysql
        }

        return name.contains("REDIS") ? .redis : nil
    }

    // dotenv-expand, which Next.js and Vite use, reads ${NAME} and $NAME.
    static func expanding(_ value: String, with values: [String: String]) -> String {
        value.replacing(#/\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/#) { match in
            let name = match.output.1 ?? match.output.2 ?? ""
            return values[String(name)] ?? ""
        }
    }

    // The port of the URL is one variable, and the plan gives that key the port of the workspace.
    private static func portComesFromKey(_ value: String, keys: [String]) -> Bool {
        guard let authority = value.split(separator: "://", maxSplits: 1).last?.split(separator: "/", maxSplits: 1).first,
              let port = authority.split(separator: "@").last?.split(separator: ":").last else {
            return false
        }

        return keys.contains { port == "${\($0)}" || port == "$\($0)" }
    }

    private static func note(_ list: inout [String], _ text: String) {
        if !list.contains(text) {
            list.append(text)
        }
    }
}
