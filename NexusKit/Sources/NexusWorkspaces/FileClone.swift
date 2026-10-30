import Darwin
import Foundation
import NexusSupervisor

public enum FileCloneError: Error, Equatable, CustomStringConvertible {
    case failed(path: String, reason: String)

    public var description: String {
        switch self {
        case .failed(let path, let reason):
            "Nexus cannot clone \(path): \(reason)"
        }
    }
}

// An APFS clone (D46, D49). A clone takes almost no time and uses no extra disk until a file
// changes. On a disk without APFS, copyfile makes a normal copy. A normal copy that fails or that
// a stop of nexusd ends leaves a part of the file. So the target gets its name only when it is
// complete, and a later setup does not take a part for the clone. The name of the part ends as
// the name of the target, so a pattern such as *.sqlite in .gitignore also applies to the part.
public enum FileClone {
    public static func clone(_ source: String, to target: String) throws {
        let manager = FileManager.default
        let part = try partPath(of: target)
        defer { try? manager.removeItem(atPath: part) }

        guard copyfile(source, part, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)) == 0 else {
            throw FileCloneError.failed(path: source, reason: String(cString: strerror(errno)))
        }

        try manager.moveItem(atPath: part, toPath: target)
    }

    // Two clones of a SQLite file and its write-ahead file are not one moment while the main site
    // writes. The backup command of sqlite3 reads one moment, and it gives one complete file. A
    // normal connection that closes last moves the write-ahead file into the main file. With
    // -readonly, sqlite3 changes nothing in the database of the main site. A file with a rollback
    // journal needs a normal connection. It waits for a write that runs, and it rolls back a write
    // that a crash ended, as the next connection of the application does.
    public static func backUpSQLiteFile(_ source: String, to target: String, readOnly: Bool) async throws {
        let manager = FileManager.default
        let part = try partPath(of: target)
        defer { try? manager.removeItem(atPath: part) }

        let quoted = part.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
        let arguments = ["-batch", "-init", "/dev/null"] + (readOnly ? ["-readonly"] : []) + ["-cmd", ".timeout 5000", source, ".backup \"\(quoted)\""]

        do {
            try await CommandRunner.run(Command(executable: URL(filePath: "/usr/bin/sqlite3"), arguments: arguments))
        } catch {
            throw FileCloneError.failed(path: source, reason: String(describing: error))
        }

        let permissions = try manager.attributesOfItem(atPath: source)[.posixPermissions]
        try manager.setAttributes([.posixPermissions: permissions ?? 0o600], ofItemAtPath: part)
        try manager.moveItem(atPath: part, toPath: target)
    }

    private static func partPath(of target: String) throws -> String {
        let manager = FileManager.default
        let folder = (target as NSString).deletingLastPathComponent
        let part = "\(folder)/.nexus-part-\((target as NSString).lastPathComponent)"

        try manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? manager.removeItem(atPath: part)
        return part
    }
}
