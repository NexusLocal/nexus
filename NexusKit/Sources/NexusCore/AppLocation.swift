import Darwin
import Foundation

// A user can open Nexus directly from the disk image. macOS then runs the app from the disk image
// or from a temporary copy in an AppTranslocation folder. Both go away when the disk image closes,
// and the background services stop working.
public enum AppLocation {
    public static let applications = URL(filePath: "/Applications", directoryHint: .isDirectory)

    private static let quarantineAttribute = "com.apple.quarantine"

    public static func isTemporary(_ bundle: URL) -> Bool {
        let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        return isTemporary(path: bundle.path(percentEncoded: false), onReadOnlyVolume: values?.volumeIsReadOnly == true)
    }

    public static func isTranslocated(path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    static func isTemporary(path: String, onReadOnlyVolume: Bool) -> Bool {
        onReadOnlyVolume || isTranslocated(path: path)
    }

    public static func target(of bundle: URL, in folder: URL) -> URL {
        folder.appending(path: bundle.lastPathComponent, directoryHint: .isDirectory)
    }

    // The copy gets a temporary name first. So a failed copy leaves an older Nexus in place. When
    // the last step fails, the older Nexus comes back from the Trash.
    public static func move(_ bundle: URL, to folder: URL, using fileManager: FileManager = .default) throws -> URL {
        let target = target(of: bundle, in: folder)
        let copy = folder.appending(path: ".\(UUID().uuidString)-\(bundle.lastPathComponent)", directoryHint: .isDirectory)
        var trashedCopy: NSURL?

        do {
            try fileManager.copyItem(at: bundle, to: copy)
            try removeQuarantine(from: copy, using: fileManager)

            if fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
                try fileManager.trashItem(at: target, resultingItemURL: &trashedCopy)
            }

            try fileManager.moveItem(at: copy, to: target)
        } catch {
            try? fileManager.removeItem(at: copy)

            if let trashedCopy = trashedCopy as URL? {
                try? fileManager.moveItem(at: trashedCopy, to: target)
            }

            throw error
        }

        return target
    }

    // macOS runs an app with the quarantine mark from a temporary copy again. The user already
    // opened this app, so macOS already checked it. Only the mark on the app itself must go. With
    // that mark, Nexus would ask to move at each start.
    private static func removeQuarantine(from bundle: URL, using fileManager: FileManager) throws {
        let contents = fileManager.enumerator(at: bundle, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []

        for item in contents {
            removexattr(item.path(percentEncoded: false), quarantineAttribute, XATTR_NOFOLLOW)
        }

        if removexattr(bundle.path(percentEncoded: false), quarantineAttribute, XATTR_NOFOLLOW) != 0, errno != ENOATTR {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
