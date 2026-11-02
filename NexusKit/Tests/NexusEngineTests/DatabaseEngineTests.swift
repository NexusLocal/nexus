import Darwin
import Foundation
import NexusCore
import NexusDNS
import NexusIPC
import NexusRuntime
import NexusSupervisor
import NexusTestSupport
import NexusTLS
import Testing
@testable import NexusEngine

// The database tests are part of NexusEngineTests, so they run one at a time with the other
// engine tests and do not take the same free port.
extension NexusEngineTests {
    private static let initialization = "mkdir -p \"$datadir/mysql\" && cp \"$init_file\" \"$datadir/init.sql\" && exit 0"

    // A socket path may have 103 bytes, and the temporary folder of the tests is longer. So
    // these tests use a short folder in /tmp, with the space of "Application Support".
    private func databaseRoot() -> URL {
        URL(filePath: "/tmp/nx-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    }

    private func databasePaths(_ root: URL) -> NexusPaths {
        NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
    }

    // A mysqld that makes a data folder with --init-file, and else listens on its port.
    private func makeFakeMySQL(in root: URL, initialization: String = Self.initialization) throws -> ManifestPackage {
        let source = root.appending(path: "source/mysql-1.0.0/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let server = source.appending(path: "mysqld")
        let script = """
            #!/bin/sh
            for argument in "$@"; do
                case "$argument" in
                    --datadir=*) datadir="${argument#--datadir=}" ;;
                    --port=*) port="${argument#--port=}" ;;
                    --init-file=*) init_file="${argument#--init-file=}" ;;
                esac
            done
            if [ -n "$init_file" ]; then
                \(initialization)
            fi
            exec /usr/bin/nc -lk 127.0.0.1 "$port"

            """
        try Data(script.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path(percentEncoded: false))

        let archive = root.appending(path: "mysql-1.0.0.tar.xz")
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path(percentEncoded: false), "-C", root.appending(path: "source").path(percentEncoded: false), "mysql-1.0.0"]
        try tar.run()
        tar.waitUntilExit()

        return ManifestPackage(name: "mysql", version: "1.0.0", line: "1.0", revision: 1, url: archive,
                               sha256: try FileChecksum.sha256(of: archive), format: .tarXZ)
    }

    private func makeDatabaseEngine(root: URL, package: ManifestPackage, port: Int) async throws -> NexusEngine {
        let paths = databasePaths(root)
        try paths.createFolders()
        var state = EngineState()
        state.ports["mysql-1.0"] = port
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        let engine = NexusEngine(
            paths: paths,
            helper: helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: keyStore),
            downloader: CopyDownloader(),
            manifestSource: FixedManifest(manifest: Manifest(schema: 1, generated: .now, repository: "test", packages: [package])),
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            ),
            helperRetryDelay: .milliseconds(50)
        )
        _ = await engine.handle(.install(name: "mysql", line: "1.0"))
        return engine
    }

    private func hiddenFiles(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).filter { $0.hasPrefix(".") }
    }

    @Test func aNewInstanceGetsItsDataFolderOnceAndKeepsIt() async throws {
        let root = databaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = freePort()
        let engine = try await makeDatabaseEngine(root: root, package: try makeFakeMySQL(in: root), port: port)
        let paths = databasePaths(root)
        let data = paths.dataFolder(service: "mysql", line: "1.0")

        let started = await engine.handle(.start(service: "mysql-1.0"))
        _ = await engine.handle(.stop(service: "mysql-1.0"))
        let marker = data.appending(path: "mysql/kept")
        try Data().write(to: marker)
        let restarted = await engine.handle(.start(service: "mysql-1.0"))
        _ = await engine.handle(.stop(service: "mysql-1.0"))

        #expect(started == .done(message: "MySQL 1.0.0 runs on port \(port)."))
        #expect(restarted == started)
        #expect(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
        #expect(try String(contentsOf: data.appending(path: "init.sql"), encoding: .utf8).contains("IDENTIFIED BY ''"))
        #expect(await engine.stateStore.current().databaseAccounts["mysql-1.0"] == .newInstance)
        #expect(FileManager.default.fileExists(atPath: paths.databaseConfig(.mysql, line: "1.0").path(percentEncoded: false)))
        #expect(hiddenFiles(in: paths.run).isEmpty)
        #expect(hiddenFiles(in: paths.data).isEmpty)
    }

    @Test func aFailedInitializationLeavesNoDataFolder() async throws {
        let root = databaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let failing = "mkdir -p \"$datadir/partial\"; echo 'the disk is full' >&2; exit 1"
        let engine = try await makeDatabaseEngine(root: root, package: try makeFakeMySQL(in: root, initialization: failing), port: freePort())
        let paths = databasePaths(root)

        let response = await engine.handle(.start(service: "mysql-1.0"))

        guard case .failure(let message) = response else {
            Issue.record("the start did not fail: \(response)")
            return
        }
        #expect(message.contains("the disk is full"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.data.path(percentEncoded: false)).isEmpty)
        #expect(hiddenFiles(in: paths.run).isEmpty)
    }

    @Test func aDataFolderWithOtherFilesIsNeverReplaced() async throws {
        let root = databaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try await makeDatabaseEngine(root: root, package: try makeFakeMySQL(in: root), port: freePort())
        let data = databasePaths(root).dataFolder(service: "mysql", line: "1.0")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let notes = data.appending(path: "notes.txt")
        try Data("mine".utf8).write(to: notes)

        let response = await engine.handle(.start(service: "mysql-1.0"))

        guard case .failure(let message) = response else {
            Issue.record("the start did not fail: \(response)")
            return
        }
        #expect(message.contains("has files, but no MySQL data"))
        #expect(try String(contentsOf: notes, encoding: .utf8) == "mine")
    }

    @Test func theDatabaseListGivesThePortAndTheAccount() async throws {
        let root = databaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = freePort()
        let engine = try await makeDatabaseEngine(root: root, package: try makeFakeMySQL(in: root), port: port)

        let response = await engine.handle(.databases)

        guard case .databases(let instances) = response, let instance = instances.first else {
            Issue.record("no database list: \(response)")
            return
        }
        #expect(instances.count == 1)
        #expect(instance.id == "mysql-1.0")
        #expect(instance.port == port)
        #expect(instance.account == .newInstance)
        #expect(!instance.running)
        #expect(instance.url(database: "shop")?.absoluteString == "mysql://root@127.0.0.1:\(port)/shop")
        #expect(instance.url()?.absoluteString == "mysql://root@127.0.0.1:\(port)")
    }

    @Test func anInstanceThatNexusMadeBeforeTheAccountsKeepsRootWithThePasswordRoot() async throws {
        let root = databaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try await makeDatabaseEngine(root: root, package: try makeFakeMySQL(in: root), port: freePort())
        let data = databasePaths(root).dataFolder(service: "mysql", line: "1.0")
        try FileManager.default.createDirectory(at: data.appending(path: "mysql"), withIntermediateDirectories: true)

        let response = await engine.handle(.databases)

        guard case .databases(let instances) = response else {
            Issue.record("no database list: \(response)")
            return
        }
        #expect(instances.first?.account == .standard)
        #expect(await engine.stateStore.current().databaseAccounts["mysql-1.0"] == .standard)
    }

    @Test func anAccountWithALineBreakOrAnOddUserNameIsRefused() async throws {
        let root = databaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try await makeDatabaseEngine(root: root, package: try makeFakeMySQL(in: root), port: freePort())

        let oddUser = await engine.handle(.setAccount(instance: "mysql-1.0", account: DatabaseAccount(user: "root'@'%", password: "")))
        let lineBreak = await engine.handle(.setAccount(instance: "mysql-1.0", account: DatabaseAccount(user: "root", password: "a\nb")))
        let stopped = await engine.handle(.setAccount(instance: "mysql-1.0", account: DatabaseAccount(user: "root", password: "secret")))

        #expect(oddUser == .failure(message: "root'@'% is not a user name that Nexus can use. Use 1 to 32 characters: letters, digits, _, - and dots."))
        #expect(lineBreak == .failure(message: "A password cannot have a line break or another control character."))
        #expect(stopped == .failure(message: "Start mysql-1.0 first."))
    }

    @Test func aPasswordOnPostgreSQLChangesOnlyTheHostLinesOfPgHba() throws {
        let root = databaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = """
            # TYPE  DATABASE        USER            ADDRESS                 METHOD
            local   all             all                                     trust
            host    all             all             127.0.0.1/32            trust
            host    all             all             ::1/128                 trust

            """
        try Data(original.utf8).write(to: root.appending(path: "pg_hba.conf"))

        try PostgreSQLAccess.setHostMethod("scram-sha-256", in: root)
        let lines = try String(contentsOf: root.appending(path: "pg_hba.conf"), encoding: .utf8).components(separatedBy: "\n")

        #expect(lines[0] == "# TYPE  DATABASE        USER            ADDRESS                 METHOD")
        #expect(lines[1] == "local   all             all                                     trust")
        #expect(lines[2].hasSuffix("scram-sha-256"))
        #expect(lines[3].hasSuffix("scram-sha-256"))
        #expect(lines[2].hasPrefix("host"))
    }

    @Test func postgreSQLOpensThePostgresDatabaseWhenNoDatabaseIsGiven() {
        let instance = DatabaseInstance(id: "postgresql-17", kind: .postgresql, version: "17.11", port: 15432, account: .standard, running: true, dataFolder: "/Nexus/data/postgresql-17")

        #expect(instance.url()?.absoluteString == "postgresql://root:root@127.0.0.1:15432/postgres")
        #expect(instance.url(database: "shop")?.absoluteString == "postgresql://root:root@127.0.0.1:15432/shop")
    }

    @Test func aCopyThatCannotWorkIsRefusedBeforeAnythingStarts() async throws {
        let root = databaseRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = freePort()
        let engine = try await makeDatabaseEngine(root: root, package: try makeFakeMySQL(in: root), port: port)

        let ontoItself = await engine.handle(.copyDatabase(DatabaseCopy(source: DatabaseServer(port: port), database: "shop", instance: "mysql-1.0")))
        let invalidName = await engine.handle(.copyDatabase(DatabaseCopy(source: DatabaseServer(), database: "shop; drop", instance: "mysql-1.0")))
        let unknownInstance = await engine.handle(.copyDatabase(DatabaseCopy(source: DatabaseServer(), database: "shop", instance: "mysql-9.9")))

        #expect(ontoItself == .failure(message: "shop cannot be copied onto itself. Give the copy another name with --as."))
        #expect(invalidName == .failure(message: DatabaseNameError.invalid("shop; drop").description))
        #expect(unknownInstance == .failure(message: "Nexus has no database instance mysql-9.9. See: nexus db list"))
        #expect(await engine.handle(.databases) == .databases([
            DatabaseInstance(id: "mysql-1.0", kind: .mysql, version: "1.0.0", port: port, account: .newInstance, running: false,
                             dataFolder: databasePaths(root).dataFolder(service: "mysql", line: "1.0").path(percentEncoded: false)),
        ]))
    }

    @Test func eachDatabaseListensOnlyOnLoopbackWithItsOwnFiles() {
        let catalog = ServiceCatalog(paths: NexusPaths(root: URL(filePath: "/Nexus", directoryHint: .isDirectory)))
        func runtime(_ name: String, _ line: String) -> InstalledRuntime {
            InstalledRuntime(name: name, line: line, version: "\(line).1", revision: 1, sha256: "", installedAt: .now,
                             folder: URL(filePath: "/Nexus/runtimes/\(name)/\(line)", directoryHint: .isDirectory))
        }

        let mysql = catalog.definition(for: runtime("mysql", "8.4"), ports: ["mysql-8.4": 13307])
        let mariadb = catalog.definition(for: runtime("mariadb", "11.4"), ports: ["mariadb-11.4": 13308])
        let postgresql = catalog.definition(for: runtime("postgresql", "17"), ports: ["postgresql-17": 15432])

        #expect(mysql?.arguments.first == "--defaults-file=/Nexus/config/mysql/8.4/my.cnf")
        #expect(mysql?.arguments.contains("--bind-address=127.0.0.1") == true)
        #expect(mysql?.arguments.contains("--datadir=/Nexus/data/mysql-8.4/") == true)
        #expect(mysql?.arguments.contains("--socket=/Nexus/run/mysql-8.4.sock") == true)
        #expect(mysql?.arguments.contains("--mysqlx=OFF") == true)
        #expect(mariadb?.executable.path(percentEncoded: false) == "/Nexus/runtimes/mariadb/11.4/bin/mariadbd")
        #expect(mariadb?.arguments.contains("--mysqlx=OFF") == false)
        #expect(postgresql?.arguments.contains("listen_addresses=127.0.0.1") == true)
        #expect(postgresql?.stopSignal == SIGINT)
        #expect(postgresql?.ports == [15432])
        #expect(catalog.portRequirements(for: runtime("postgresql", "17")) == [PortRequirement(key: "postgresql-17", standard: 5432)])
        #expect(catalog.portRequirements(for: runtime("mariadb", "11.4")) == [PortRequirement(key: "mariadb-11.4", standard: 3306)])
    }

    @Test func aDumpWatcherCountsTheBytesAndNamesTheTablesAlsoAcrossParts() {
        let progress = TaskProgress()
        let watcher = DumpWatcher(progress: progress, namesTables: true)
        let dump = "-- MySQL dump\n--\n-- Table structure for table `users`\n--\nCREATE TABLE ...;\n--\n-- Table structure for table `audit_logs`\n--\nINSERT ...;\n"
        let bytes = Data(dump.utf8)
        let cut = bytes.count - 40

        watcher.read(bytes.prefix(cut))
        let first = progress.current
        watcher.read(bytes.suffix(from: cut))
        let second = progress.current

        #expect(first.table == "users")
        #expect(first.tableNumber == 1)
        #expect(second.table == "audit_logs")
        #expect(second.tableNumber == 2)
        #expect(second.completed == Int64(bytes.count))
    }

    @Test func aDumpWatcherOfPostgreSQLOnlyCountsTheBytes() {
        let progress = TaskProgress()
        let watcher = DumpWatcher(progress: progress, namesTables: false)

        watcher.read(Data("\n-- Table structure for table `users`".utf8))

        #expect(progress.current == TaskProgress.Values(completed: 37))
    }
}
