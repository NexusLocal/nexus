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

    // Nil when an env file cannot help: phpunit.xml sets another value for a key of the plan, or it
    // sets no APP_ENV. Without APP_ENV the tests read .env.
    public static func make(for target: Target, check: TestDatabaseCheck, projectFolder: URL) -> TestDatabasePlan? {
        guard let file = check.testEnvFile, phpunitConflicts(for: target, check: check, projectFolder: projectFolder).isEmpty else {
            return nil
        }

        let fileURL = projectFolder.appending(path: file)
        let exists = FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
        let current = EnvFile.values(of: exists ? fileURL : projectFolder.appending(path: ".env"))
        let changes = wanted(for: target, projectFolder: projectFolder).filter { change in
            check.phpunitDatabaseValues[change.key] == nil && (current[change.key] ?? (change.key == "DB_URL" ? "" : nil)) != change.value
        }

        return TestDatabasePlan(file: file, createsFile: !exists, changes: changes, backupFile: exists ? freeName(for: "\(file).backup", in: projectFolder) : nil)
    }

    // A value of phpunit.xml wins over the env files. A DB_URL there wins over all other keys.
    public static func phpunitConflicts(for target: Target, check: TestDatabaseCheck, projectFolder: URL) -> [String] {
        let phpunit = check.phpunitDatabaseValues
        let url = phpunit["DB_URL"].map { $0.isEmpty ? [] : ["DB_URL"] } ?? []

        return wanted(for: target, projectFolder: projectFolder)
            .filter { $0.key != "DB_URL" && phpunit[$0.key] != nil && phpunit[$0.key] != $0.value }
            .map(\.key) + url
    }

    // A database that Nexus makes or lists is on the server of the development database. So the
    // tests get the server and the account of .env too, also when .env.testing names another
    // server. A DB_URL wins over the other keys, so it must be empty.
    private static func wanted(for target: Target, projectFolder: URL) -> [Change] {
        switch target {
        case .database(let name):
            let development = EnvFile.values(of: projectFolder.appending(path: ".env"))
            let server = ["DB_CONNECTION", "DB_HOST", "DB_PORT", "DB_USERNAME", "DB_PASSWORD"].compactMap { key in
                development[key].map { Change(key: key, value: $0) }
            }

            return server + [Change(key: "DB_DATABASE", value: name), Change(key: "DB_URL", value: "")]
        case .sqliteMemory:
            return [Change(key: "DB_CONNECTION", value: "sqlite"), Change(key: "DB_DATABASE", value: ":memory:"), Change(key: "DB_URL", value: "")]
        }
    }

    // An existing file keeps a backup next to it. The name of the backup is free, so no backup
    // replaces an older one. Returns the name of the backup.
    public var changesNothing: Bool {
        !createsFile && changes.isEmpty
    }

    @discardableResult
    public func apply(projectFolder: URL) throws -> String? {
        guard !changesNothing else {
            return nil
        }

        let fileURL = projectFolder.appending(path: file)
        let source = createsFile ? projectFolder.appending(path: ".env") : fileURL
        let text = try String(contentsOf: source, encoding: .utf8)
        let changed = EnvRewrite.apply(to: text, hosts: [], keys: Dictionary(uniqueKeysWithValues: changes.map { ($0.key, $0.value) }))
        let permissions = (try? FileManager.default.attributesOfItem(atPath: source.path(percentEncoded: false))[.posixPermissions] as? Int) ?? 0o600
        var backup: String?

        if !createsFile {
            let name = Self.freeName(for: "\(file).backup", in: projectFolder)
            try FileManager.default.copyItem(at: fileURL, to: projectFolder.appending(path: name))
            backup = name
        }

        try Data(changed.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: fileURL.path(percentEncoded: false))
        return backup
    }

    public enum GitState: Sendable {
        case ignored
        case tracked
        case shown
    }

    // A copy of .env holds its keys. Git does not ignore .env.testing in a new Laravel project. So
    // the user must know before a commit. Nil when the folder is no git repository.
    public static func gitState(of file: String, in folder: URL) async -> GitState? {
        let path = folder.path(percentEncoded: false)

        guard let git = await GitTool.executable(), let ignored = try? await GitTool.ignores(file, in: path, git: git) else {
            return nil
        }

        if ignored {
            return .ignored
        }

        return (try? await GitTool.tracks(file, in: path, git: git)) == true ? .tracked : .shown
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
