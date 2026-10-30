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
// complete, and a later setup does not take a part for the clone. The part stays out of the
// worktree, because git would see it there (D50). git worktree remove then refuses for as long as
// the clone takes. The part stays on the disk of the target, so a clone stays a clone.
public enum FileClone {
    // prepare gets the path of the part. A later setup keeps a clone with its final name, so what
    // must change in a clone changes before that name.
    public static func clone(_ source: String, to target: String, preparing prepare: (String) throws -> Void = { _ in }) throws {
        let manager = FileManager.default
        let part = try partPath(of: target)
        defer { removeFolder(of: part) }

        guard copyfile(source, part, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)) == 0 else {
            throw FileCloneError.failed(path: source, reason: String(cString: strerror(errno)))
        }

        try prepare(part)
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
        defer { removeFolder(of: part) }

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

    // Each part gets a new temporary folder of macOS on the disk of the target.
    static func partPath(of target: String) throws -> String {
        let manager = FileManager.default
        let folder = URL(filePath: (target as NSString).deletingLastPathComponent, directoryHint: .isDirectory)

        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        return try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
            .appending(path: (target as NSString).lastPathComponent)
            .path(percentEncoded: false)
    }

    private static func removeFolder(of part: String) {
        try? FileManager.default.removeItem(atPath: (part as NSString).deletingLastPathComponent)
    }
}
