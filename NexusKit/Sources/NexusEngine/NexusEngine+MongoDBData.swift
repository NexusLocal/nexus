import Foundation
import NexusConfig
import NexusCore
import NexusIPC
import NexusLaravel
import NexusMongoDB
import NexusRuntime
import NexusSupervisor
import Synchronization

// mongodump and mongorestore of the package mongodb-tools. A password goes in a config file in a
// private folder, so it does not show in the process list. The caller removes that folder.
struct MongoDBTransfer {
    let tools: DatabaseTools
    let work: URL

    // A URL of a server without a password, and the password that goes with it. An empty password
    // adds no config file.
    struct Endpoint: Equatable {
        let url: String
        let password: String

        // The user and the settings of the URL, for the own client of Nexus.
        var user: String? {
            URLComponents(string: url)?.user
        }

        var authenticationDatabase: String {
            URLComponents(string: url)?.queryItems?.first { $0.name.lowercased() == "authsource" }?.value ?? "admin"
        }
    }

    // The URL of another server, also with mongodb+srv or a list of servers. A password in the URL
    // would show in the process list, so it goes into the config file. mongodump refuses a database
    // in the URL next to its option --db. The URL spec of MongoDB logs in to that database when the
    // URL has a user and no authSource. So the database then moves into authSource.
    static func source(url value: String, password typed: String) -> Endpoint {
        guard let schemeEnd = value.range(of: "://") else {
            return Endpoint(url: value, password: typed)
        }

        let scheme = value[..<schemeEnd.upperBound]
        let rest = value[schemeEnd.upperBound...]
        let authority = rest.prefix { $0 != "/" && $0 != "?" }
        let afterAuthority = rest.dropFirst(authority.count)
        let database = afterAuthority.dropFirst().prefix { $0 != "?" }
        var query = afterAuthority.firstIndex(of: "?").map { String(afterAuthority[afterAuthority.index(after: $0)...]) } ?? ""

        var servers = authority
        var password = typed

        if let at = authority.lastIndex(of: "@") {
            let userInfo = authority[..<at]
            let user = userInfo.prefix { $0 != ":" }

            if userInfo.count > user.count {
                password = String(userInfo.dropFirst(user.count + 1)).removingPercentEncoding ?? typed
            }

            servers = "\(user)@\(authority[authority.index(after: at)...])"
        }

        // The Go driver of mongodump refuses authSource in a URL without a user.
        if !database.isEmpty, authority.contains("@"), !query.lowercased().contains("authsource=") {
            query += query.isEmpty ? "authSource=\(database)" : "&authSource=\(database)"
        }

        return Endpoint(url: "\(scheme)\(servers)/\(query.isEmpty ? "" : "?\(query)")", password: password)
    }

    // A local server of Nexus. Its user is in the database admin.
    static func local(port: Int, account: DatabaseAccount) -> Endpoint {
        guard !account.password.isEmpty else {
            return Endpoint(url: "mongodb://127.0.0.1:\(port)/", password: "")
        }

        return Endpoint(url: "mongodb://\(encodedUser(account.user))@127.0.0.1:\(port)/?authSource=admin", password: account.password)
    }

    static func encodedUser(_ user: String) -> String {
        user.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? user
    }

    // A name of a database for --nsInclude, --nsFrom and --nsTo. These read * as a wildcard and \ as
    // an escape.
    static func namespacePattern(_ database: String) -> String {
        "\(database.replacing("\\", with: "\\\\").replacing("*", with: "\\*")).*"
    }

    // YAML reads a backslash and a double quote in a quoted value as special. DatabaseUser refuses a
    // control character in a password.
    static func yamlString(_ value: String) -> String {
        "\"\(value.replacing("\\", with: "\\\\").replacing("\"", with: "\\\""))\""
    }

    private func connection(_ endpoint: Endpoint, file: String) throws -> [String] {
        guard !endpoint.password.isEmpty else {
            return ["--uri=\(endpoint.url)"]
        }

        let config = work.appending(path: "\(file).yaml")
        try NexusEngine.writePrivate("password: \(Self.yamlString(endpoint.password))\n", to: config)

        return ["--uri=\(endpoint.url)", "--config=\(config.path(percentEncoded: false))"]
    }

    // Writes an archive of one database to its standard output.
    func dumpCommand(_ endpoint: Endpoint, database: String) throws -> Command {
        Command(
            executable: tools.dump,
            arguments: try connection(endpoint, file: "source") + ["--db=\(database)", "--archive", "--quiet"],
            name: "mongodump"
        )
    }

    // Reads an archive from its standard input. Only the database source goes in, with the name of
    // the target. drop replaces each collection of the archive that exists already.
    func restoreCommand(_ endpoint: Endpoint, from source: String, as name: String, drop: Bool) throws -> Command {
        var arguments = try connection(endpoint, file: "target") + [
            "--archive",
            "--nsInclude=\(Self.namespacePattern(source))",
            "--nsFrom=\(Self.namespacePattern(source))",
            "--nsTo=\(Self.namespacePattern(name))",
            "--stopOnError",
            "--quiet",
        ]

        if drop {
            arguments.append("--drop")
        }

        return Command(executable: tools.client, arguments: arguments, name: "mongorestore")
    }
}

extension NexusEngine {
    // Each install of a MongoDB installs the tools when they are not there. All versions of MongoDB
    // share them. An install that failed comes again at the first import, copy or dump. A second
    // call during an install waits for that install.
    func ensureMongoDBTools() async throws {
        let mongodump = paths.runtime(MongoDBToolsPackage.name, line: MongoDBToolsPackage.line).appending(path: "bin/mongodump")

        if FileManager.default.isExecutableFile(atPath: mongodump.path(percentEncoded: false)) {
            return
        }

        if let running = mongoDBToolsInstall {
            try await running.value
            return
        }

        let install = Task {
            guard let package = try await self.manifest().package(named: MongoDBToolsPackage.name, line: MongoDBToolsPackage.line) else {
                throw RuntimeError.unsupported("Nexus needs mongodump and mongorestore of the package \(MongoDBToolsPackage.name), but the manifest has no such package yet.")
            }

            _ = try await self.install(package)
        }

        mongoDBToolsInstall = install
        defer { mongoDBToolsInstall = nil }

        try await install.value
    }

    // A failure leaves the server in place, because it runs without the tools.
    func installToolsOfMongoDB() async -> String {
        do {
            try await ensureMongoDBTools()
            return ""
        } catch {
            return " The MongoDB tools did not install, so imports and dumps do not work yet. Nexus tries again at the first import. \(ErrorText.plain(error))"
        }
    }

    func mongoDBEndpoint(_ tools: DatabaseTools) async throws -> MongoDBTransfer.Endpoint {
        MongoDBTransfer.local(port: try await connectionPort(of: tools), account: try await account(of: tools))
    }

    func mongoDBWork() throws -> URL {
        let work = paths.run.appending(path: ".mongodb-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return work
    }

    // The start of the archive without gzip. The list of the collections is at the start, and 4 MB
    // holds the list of thousands of collections.
    func mongoDBArchiveCollections(of file: URL, container: DumpContainer) async throws -> [MongoDBArchive.Collection] {
        let work = try mongoDBWork()
        defer { try? FileManager.default.removeItem(at: work) }

        let start = work.appending(path: "start")
        let script = "( \(container.readerScript(dump: nil)) ) 2>/dev/null | /usr/bin/head -c 4194304 > \"$2\"; exit 0"
        _ = try await CommandRunner.run(Command(executable: URL(filePath: "/bin/bash"), arguments: ["-c", script, "reader", file.path(percentEncoded: false), start.path(percentEncoded: false)]))

        do {
            return try MongoDBArchive.collections(in: try Data(contentsOf: start))
        } catch {
            throw RuntimeError.unsupported("Nexus cannot read the list of the collections in \(file.lastPathComponent). Make the file again with mongodump --archive.")
        }
    }

    // The databases of the archive are the dumps that the sheet offers. A file with one database
    // needs no choice.
    func inspectMongoDBDump(_ inspection: DumpInspection, file: URL, container: DumpContainer, info: DumpInfo) async throws -> DumpInfo {
        var info = info
        info.format = .mongodb

        guard !container.isArchive else {
            info.problem = "Nexus reads an archive of mongodump only as a file of its own, not in a .zip or .tar file."
            return info
        }

        let collections = try await mongoDBArchiveCollections(of: file, container: container)
        let databases = MongoDBArchive.databases(of: collections)

        info.dumps = databases
        info.dump = inspection.dump.flatMap { databases.contains($0) ? $0 : nil } ?? (databases.count == 1 ? databases[0] : nil)

        guard let database = info.dump else {
            info.problem = databases.isEmpty ? "\(file.lastPathComponent) has no collections." : nil
            return info
        }

        info.tables = collections.filter { $0.database == database }.map(\.name)

        if let target = inspection.target, let name = inspection.name.flatMap({ try? DatabaseName.validated($0) }), let address = try? await mongoDBAddress(target) {
            let existing = try? await withMongoDB(at: address) { try await $0.collections(of: name) }
            info.existingTables = existing?.isEmpty == false ? existing : nil
        }

        return info
    }

    // nexus db import and the sheet with a file of mongodump --archive, with or without --gzip.
    // Replace the tables drops only the collections of the archive. A new database that fails is
    // dropped. An old database goes into the trash before each change. A workspace has the names of
    // the main site on a server of its own. So its trash copy and its reservation get the name of
    // the workspace too.
    func importMongoDBDump(_ request: DumpImport, tools: DatabaseTools, file: URL, container: DumpContainer) async throws -> NexusResponse {
        let instance = request.target.instanceID
        let server = request.target.serverName

        guard !container.isArchive else {
            throw RuntimeError.unsupported("Nexus reads an archive of mongodump only as a file of its own, not in a .zip or .tar file.")
        }

        let fileName = file.lastPathComponent
        let name = try DatabaseName.validated(request.name)
        let collections = try await mongoDBArchiveCollections(of: file, container: container)
        let databases = MongoDBArchive.databases(of: collections)

        let source: String

        if let wanted = request.dump {
            guard databases.contains(wanted) else {
                throw RuntimeError.unsupported("\(fileName) has no database \(wanted). It has: \(databases.joined(separator: ", ")).")
            }

            source = wanted
        } else if databases.count == 1 {
            source = databases[0]
        } else {
            throw RuntimeError.unsupported(databases.isEmpty ? "\(fileName) has no collections." : "\(fileName) has \(databases.count) databases: \(databases.joined(separator: ", ")). Choose one with --dump.")
        }

        try await ensureMongoDBTools()

        let address = try await mongoDBAddress(request.target)
        let ownName: String

        if case .workspace(_, let workspace, _) = request.target {
            ownName = Workspace.databaseName(name, workspace: workspace)
        } else {
            ownName = name
        }

        let reserved = try reserveCopyTarget(ownName, on: instance, for: "import")
        defer { copyTargets.remove(reserved) }

        let exists = try await !withMongoDB(at: address) { try await $0.collections(of: name) }.isEmpty

        if exists, request.existing == nil {
            throw DatabaseTargetExists(description: "\(name) exists on \(server) already. Add --replace-tables or --replace-database, or load the dump into another database with --into.")
        }

        let trashCopy = exists ? try await writeMongoDBDump(of: name, as: ownName, at: address, instance: instance) : nil
        let keptCopy = trashCopy.map { " Nexus put a copy of the old \(name) in the trash: \($0.lastPathComponent)." } ?? ""

        if exists, request.existing == .replaceDatabase {
            try await dropMongoDBDatabase(name, at: address)
        }

        let work = try mongoDBWork()
        defer { try? FileManager.default.removeItem(at: work) }

        let transfer = MongoDBTransfer(tools: tools, work: work)
        let restore = try transfer.restoreCommand(MongoDBTransfer.local(port: address.port, account: address.account), from: source, as: name, drop: request.existing == .replaceTables)
        let reader = Self.reader(of: file, container: container, dump: nil)
        let progress = TaskProgress()
        let shownName = "\(fileName) (\(source))"
        let total = await Self.sqlSize(of: file, container: container)
        progress.update { $0.total = total }

        do {
            try await runTask(.importDump(file: fileName, instance: instance, name: name), progress: progress, stopped: {
                exists ? "The import of \(shownName) stopped. \(name) can be incomplete.\(keptCopy)" : "The import of \(shownName) stopped. \(server) has no database \(name)."
            }) { progress in
                try await CommandRunner.pipe(reader, into: restore) { data in
                    progress.update { $0.completed += Int64(data.count) }
                }
            }
        } catch {
            guard exists else {
                await Task { try? await self.dropMongoDBDatabase(name, at: address) }.value
                throw error
            }

            throw RuntimeError.unsupported("The dump did not load completely. \(ErrorText.plain(error))\(keptCopy)")
        }

        switch request.existing {
        case nil:
            return .done(message: "\(shownName) is loaded into the new database \(name) on \(server).")
        case .replaceTables:
            return .done(message: "\(shownName) is loaded into \(name) on \(server). The collections of the dump replaced their old collections. The other collections stay as they were.\(keptCopy)")
        case .replaceDatabase:
            return .done(message: "\(shownName) replaced the database \(name) on \(server).\(keptCopy)")
        }
    }

    // nexus db restore with a dump of writeMongoDBDump. Such a dump has one database. A restore that
    // fails leaves no part of the database.
    func restoreMongoDBDump(_ dump: URL, as name: String, at address: MongoDBAddress) async throws {
        guard try await withMongoDB(at: address, { try await $0.collections(of: name) }).isEmpty else {
            throw RuntimeError.unsupported("\(address.name) has a database \(name) already. Give the restore another name with --as.")
        }

        try await ensureMongoDBTools()

        guard let source = MongoDBArchive.databases(of: try await mongoDBArchiveCollections(of: dump, container: .gzip)).first else {
            throw RuntimeError.unsupported("\(dump.lastPathComponent) has no collections.")
        }

        let work = try mongoDBWork()
        defer { try? FileManager.default.removeItem(at: work) }

        let restore = try MongoDBTransfer(tools: address.tools, work: work).restoreCommand(MongoDBTransfer.local(port: address.port, account: address.account), from: source, as: name, drop: false)

        do {
            try await CommandRunner.pipe(Self.reader(of: dump, container: .gzip, dump: nil), into: restore)
        } catch {
            await Task { try? await self.dropMongoDBDatabase(name, at: address) }.value
            throw error
        }
    }

    func dropMongoDBDatabase(_ name: String, tools: DatabaseTools) async throws {
        try await dropMongoDBDatabase(name, at: try await mongoDBAddress(of: tools))
    }

    func dropMongoDBDatabase(_ name: String, at address: MongoDBAddress) async throws {
        try await withMongoDB(at: address) { try await $0.dropDatabase(name) }
    }

    // An archive with gzip, as mongodump --archive --gzip writes it. The file gets its name only when
    // it is complete. A dump of a workspace has the name of the workspace in fileName.
    func writeMongoDBDump(of name: String, as fileName: String, at address: MongoDBAddress, instance: String, workspace: String? = nil) async throws -> URL {
        try await ensureMongoDBTools()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"

        let file = Self.freeFile(named: "\(formatter.string(from: .now))-\(instance)-\(fileName)", extension: DatabaseKind.mongodb.dumpExtension, in: paths.trash)
        let partial = file.deletingLastPathComponent().appending(path: "\(file.lastPathComponent).partial")
        let work = try mongoDBWork()
        defer {
            try? FileManager.default.removeItem(at: work)
            try? FileManager.default.removeItem(at: partial)
        }

        try FileManager.default.createDirectory(at: paths.trash, withIntermediateDirectories: true)

        guard FileManager.default.createFile(atPath: partial.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RuntimeError.unsupported("Nexus cannot write \(partial.path(percentEncoded: false)).")
        }

        let dump = try MongoDBTransfer(tools: address.tools, work: work).dumpCommand(MongoDBTransfer.local(port: address.port, account: address.account), database: name)

        try await runTask(.dumpDatabase(name: name, instance: instance, workspace: workspace), stopped: { "The dump of \(name) stopped. \(address.name) keeps the database." }) { progress in
            try await CommandRunner.pipe(dump, into: Command(executable: URL(filePath: "/usr/bin/gzip")), writingTo: partial) { data in
                progress.update { $0.completed += Int64(data.count) }
            }
        }

        try FileManager.default.moveItem(at: partial, to: file)
        return file
    }

    // D37 for MongoDB: mongodump reads the other server, for example MongoDB Atlas or a server in
    // Docker, and mongorestore writes into the instance. The other server does not change.
    func copyMongoDB(_ request: DatabaseCopy, tools: DatabaseTools) async throws -> String {
        let database = try DatabaseName.validated(request.database)
        let name = try DatabaseName.validated(request.name ?? request.database)
        let port = try await connectionPort(of: tools)
        let source = Self.mongoDBSource(request.source)

        if let url = MongoDBURL(source.url), url.isLocal, url.port == port, database == name {
            throw RuntimeError.unsupported("\(database) cannot be copied onto itself. Give the copy another name with --as.")
        }

        try await ensureMongoDBTools()

        let copyTarget = try reserveCopyTarget(name, on: request.instance, for: "copy")
        defer { copyTargets.remove(copyTarget) }

        if await supervisor.state(of: request.instance)?.isActive != true {
            _ = try await serialWeb { try await self.start(request.instance) }
        }

        let replaces = try await !withMongoDB(tools) { try await $0.collections(of: name) }.isEmpty

        if replaces, !request.replace {
            throw DatabaseTargetExists(description: "\(request.instance) has a database \(name) already. Add --replace to drop it and copy it again, or give the copy another name with --as.")
        }

        let work = try mongoDBWork()
        defer { try? FileManager.default.removeItem(at: work) }

        let transfer = MongoDBTransfer(tools: tools, work: work)
        let dump = try transfer.dumpCommand(source, database: database)
        let restore = try transfer.restoreCommand(try await mongoDBEndpoint(tools), from: database, as: name, drop: false)
        let archive = work.appending(path: "source.archive.gz")

        guard FileManager.default.createFile(atPath: archive.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RuntimeError.unsupported("Nexus cannot write \(archive.path(percentEncoded: false)).")
        }

        let dropped = Mutex(false)
        let dumped = Mutex<Int64>(0)
        let task = TaskWork.copyDatabase(database: database, instance: request.instance, name: name)
        let stopped = { @Sendable in
            dropped.withLock { $0 }
                ? "The copy of \(database) stopped. \(request.instance) has no database \(name) now, because the copy dropped the old one first."
                : "The copy of \(database) stopped. \(request.instance) did not change."
        }

        // The dump of the other server comes first. A wrong name or a server that does not answer then
        // costs no old copy. mongodump writes an empty archive for a database that does not exist.
        do {
            try await runTask(task, stopped: stopped) { progress in
                try await CommandRunner.pipe(dump, into: Command(executable: URL(filePath: "/usr/bin/gzip")), writingTo: archive) { data in
                    dumped.withLock { $0 += Int64(data.count) }
                    progress.update { $0.completed += Int64(data.count) }
                }

                guard try await self.mongoDBArchiveCollections(of: archive, container: .gzip).contains(where: { $0.database == database }) else {
                    throw RuntimeError.unsupported("The other server has no database \(database), or \(database) has no collections. \(request.instance) did not change.")
                }

                if replaces {
                    try await self.dropMongoDBDatabase(name, tools: tools)
                    dropped.withLock { $0 = true }
                }

                let size = dumped.withLock { $0 }
                progress.update { values in
                    values.completed = 0
                    values.total = size
                }

                try await CommandRunner.pipe(Self.reader(of: archive, container: .gzip, dump: nil), into: restore) { data in
                    progress.update { $0.completed = min($0.completed + Int64(data.count), size) }
                }
            }
        } catch {
            // Before the drop, the old database stays as it was.
            if !replaces || dropped.withLock({ $0 }) {
                await Task { try? await self.dropMongoDBDatabase(name, tools: tools) }.value
            }

            throw error
        }

        let copied = try await withMongoDB(tools) { try await $0.collections(of: name) }

        let account = try await account(of: tools)
        let login = account.password.isEmpty ? "No login is needed." : "Log in with the user \(account.user) and the password \(account.password)."

        return """
            \(database) is copied to \(request.instance) as \(name), with \(Count.text(copied.count, "collection")).
            Connect to port \(port) on 127.0.0.1. \(login)
            """
    }

    // The sheet gives the server as a URL, the command line can give a host and a port. A password in
    // the URL wins over the typed one.
    static func mongoDBSource(_ server: DatabaseServer) -> MongoDBTransfer.Endpoint {
        guard let url = server.url, !url.isEmpty else {
            let user = server.account.password.isEmpty ? "" : "\(MongoDBTransfer.encodedUser(server.account.user))@"
            return MongoDBTransfer.Endpoint(url: "mongodb://\(user)\(server.host):\(server.port ?? DatabaseKind.mongodb.standardPort)/", password: server.account.password)
        }

        return MongoDBTransfer.source(url: url, password: server.account.password)
    }

    // Only a server on this Mac without TLS answers the own client of Nexus. For another server, the
    // user types the name of the database.
    func mongoDBSourceDatabases(_ server: DatabaseServer) async throws -> [DatabaseSize] {
        let source = Self.mongoDBSource(server)

        guard let url = MongoDBURL(source.url), url.isLocal, URLComponents(string: source.url)?.queryItems?.contains(where: { ["tls", "ssl"].contains($0.name.lowercased()) && $0.value == "true" }) != true else {
            throw RuntimeError.unsupported("Nexus can list the databases only of a MongoDB on this Mac. Type the name of the database.")
        }

        let account = source.password.isEmpty ? nil : DatabaseAccount(user: source.user ?? server.account.user, password: source.password)

        do {
            let mongo = MongoDBServer(try await MongoDBConnection.connect(port: url.port, account: account, authenticationDatabase: source.authenticationDatabase))
            let databases = try await mongo.databases()
            await mongo.connection.disconnect()
            return databases.map { DatabaseSize(name: $0.name, bytes: $0.bytes) }
        } catch let error as MongoDBError {
            throw RuntimeError.unsupported("Nexus cannot read the databases on \(url.host):\(url.port). \(error.description)")
        }
    }
}
