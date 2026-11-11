import Foundation
import NexusCore
import NexusLaravel
import NexusWorkspaces

// The help of the Site screen for tests that use the development database. The user is in charge
// and Nexus only offers help. Nexus writes only the env file that the tests read, never
// phpunit.xml. Laravel reads .env.testing instead of .env in tests, and not both. So a new
// .env.testing is a copy of .env with only the database lines changed.
public struct TestDatabasePlan: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case database(String)
        case sqliteMemory
    }

    public struct Change: Sendable, Equatable {
        public let key: String
        public let value: String
    }

    public let projectFolder: URL
    public let file: String
    public let createsFile: Bool
    public let changes: [Change]
    // The name that the backup of an existing file gets.
    public let backupFile: String?

    // The text does not follow the language of the Mac, because the app is in English. It does not
    // show a password, because the activity log gets it too.
    public var changeText: String {
        let lines = changes.map { $0.key == "DB_PASSWORD" ? "the DB_PASSWORD of .env" : "\($0.key)=\($0.value)" }

        guard let last = lines.last, lines.count > 1 else {
            return lines.joined()
        }

        return "\(lines.dropLast().joined(separator: ", ")) and \(last)"
    }

    // The env files that a plan needs. A sheet reads them once for all its plans.
    public struct Files: Sendable {
        let folder: URL
        let file: String
        let exists: Bool
        let development: [String: String]
        // The values of the env file of the tests, or of .env when that file does not exist yet.
        let current: [String: String]

        // Nil without APP_ENV in phpunit.xml. The tests then read .env itself.
        public static func read(check: TestDatabaseCheck, projectFolder: URL) -> Files? {
            guard let file = check.testEnvFile else {
                return nil
            }

            let fileURL = projectFolder.appending(path: file)
            let exists = FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
            let development = EnvFile.values(of: projectFolder.appending(path: ".env"))
            return Files(folder: projectFolder, file: file, exists: exists, development: development, current: exists ? EnvFile.values(of: fileURL) : development)
        }
    }

    public static func make(for target: Target, check: TestDatabaseCheck, projectFolder: URL) -> TestDatabasePlan? {
        Files.read(check: check, projectFolder: projectFolder).flatMap { make(for: target, check: check, files: $0) }
    }

    // Nil when phpunit.xml sets another value for a key of the plan.
    public static func make(for target: Target, check: TestDatabaseCheck, files: Files) -> TestDatabasePlan? {
        let wanted = wanted(for: target, development: files.development)

        guard phpunitConflicts(in: wanted, check: check).isEmpty else {
            return nil
        }

        let changes = wanted.filter { change in
            check.phpunitDatabaseValues[change.key] == nil && (files.current[change.key] ?? (change.key == "DB_URL" ? "" : nil)) != change.value
        }

        return TestDatabasePlan(projectFolder: files.folder, file: files.file, createsFile: !files.exists, changes: changes, backupFile: files.exists ? freeName(for: "\(files.file).backup", in: files.folder) : nil)
    }

    public static func phpunitConflicts(for target: Target, check: TestDatabaseCheck, projectFolder: URL) -> [String] {
        phpunitConflicts(in: wanted(for: target, development: EnvFile.values(of: projectFolder.appending(path: ".env"))), check: check)
    }

    public static func phpunitConflicts(for target: Target, check: TestDatabaseCheck, files: Files) -> [String] {
        phpunitConflicts(in: wanted(for: target, development: files.development), check: check)
    }

    // A value of phpunit.xml wins over the env files. A DB_URL there wins over all other keys.
    private static func phpunitConflicts(in wanted: [Change], check: TestDatabaseCheck) -> [String] {
        let phpunit = check.phpunitDatabaseValues
        let url = phpunit["DB_URL"].map { $0.isEmpty ? [] : ["DB_URL"] } ?? []

        return wanted
            .filter { $0.key != "DB_URL" && phpunit[$0.key] != nil && phpunit[$0.key] != $0.value }
            .map(\.key) + url
    }

    // A database that Nexus makes or lists is on the server of the development database. So the
    // tests get the server and the account of .env too, also when .env.testing names another
    // server. A DB_URL wins over the other keys, so it must be empty.
    private static func wanted(for target: Target, development: [String: String]) -> [Change] {
        switch target {
        case .database(let name):
            let server = ["DB_CONNECTION", "DB_HOST", "DB_PORT", "DB_USERNAME", "DB_PASSWORD"].compactMap { key in
                development[key].map { Change(key: key, value: $0) }
            }

            return server + [Change(key: "DB_DATABASE", value: name), Change(key: "DB_URL", value: "")]
        case .sqliteMemory:
            return [Change(key: "DB_CONNECTION", value: "sqlite"), Change(key: "DB_DATABASE", value: ":memory:"), Change(key: "DB_URL", value: "")]
        }
    }

    public var changesNothing: Bool {
        !createsFile && changes.isEmpty
    }

    // An existing file keeps a backup next to it. The name of the backup is free. So no backup
    // replaces an older one. The backup holds the text of the file, also when the file is a link.
    // Returns the name of the backup.
    @discardableResult
    public func apply() throws -> String? {
        guard !changesNothing else {
            return nil
        }

        let fileURL = projectFolder.appending(path: file)
        let env = projectFolder.appending(path: ".env").resolvingSymlinksInPath()
        let text = try String(contentsOf: createsFile ? env : fileURL, encoding: .utf8)
        let changed = EnvRewrite.apply(to: text, hosts: [], keys: Dictionary(uniqueKeysWithValues: changes.map { ($0.key, $0.value) }))
        var backup: String?

        if !createsFile {
            let name = Self.freeName(for: "\(file).backup", in: projectFolder)
            try FileManager.default.copyItem(at: fileURL.resolvingSymlinksInPath(), to: projectFolder.appending(path: name))
            backup = name
        }

        // A new copy of .env gets the permissions of .env. So a test run as another user can still
        // read it.
        let envPermissions = (try? FileManager.default.attributesOfItem(atPath: env.path(percentEncoded: false)))?[.posixPermissions] as? Int ?? 0o600
        try FileText.write(changed, to: fileURL, newFilePermissions: envPermissions)
        return backup
    }

    public enum GitState: Sendable {
        case ignored
        case tracked
        case shown
    }

    // A copy of .env holds its keys. Git does not ignore .env.testing in a new Laravel project. So
    // the user must know before a commit. A file is missing from the result when the folder is no
    // git repository.
    public static func gitStates(of files: [String], in folder: URL) async -> [String: GitState] {
        let path = folder.path(percentEncoded: false)

        guard let git = await GitTool.executable() else {
            return [:]
        }

        var states: [String: GitState] = [:]

        for file in files {
            guard let ignored = try? await GitTool.ignores(file, in: path, git: git) else {
                continue
            }

            states[file] = ignored ? .ignored : (try? await GitTool.tracks(file, in: path, git: git)) == true ? .tracked : .shown
        }

        return states
    }

    static func freeName(for name: String, in folder: URL) -> String {
        var candidate = name
        var number = 2

        while FileManager.default.fileExists(atPath: folder.appending(path: candidate).path(percentEncoded: false)) {
            candidate = "\(name)-\(number)"
            number += 1
        }

        return candidate
    }
}
