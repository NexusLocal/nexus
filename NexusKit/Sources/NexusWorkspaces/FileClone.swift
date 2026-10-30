import Darwin
import Foundation

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
        let folder = (target as NSString).deletingLastPathComponent
        let part = "\(folder)/.nexus-part-\((target as NSString).lastPathComponent)"

        try manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? manager.removeItem(atPath: part)
        defer { try? manager.removeItem(atPath: part) }

        guard copyfile(source, part, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)) == 0 else {
            throw FileCloneError.failed(path: source, reason: String(cString: strerror(errno)))
        }

        try manager.moveItem(atPath: part, toPath: target)
    }
}
