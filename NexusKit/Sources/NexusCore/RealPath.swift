import Foundation

// The path of a folder without symbolic links and without the / at the end. /tmp is /private/tmp,
// for example. FSEvents and getcwd name folders this way.
public enum RealPath {
    public static func of(_ folder: URL) -> String {
        let path = folder.path(percentEncoded: false)

        guard let resolved = realpath(path, nil) else {
            return trimmed(path)
        }

        defer { free(resolved) }
        return trimmed(String(cString: resolved))
    }

    public static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // True when path is folder or a path in it. Both paths come from of(_:).
    public static func contains(_ folder: String, _ path: String) -> Bool {
        folder == "/" || path == folder || path.hasPrefix(folder + "/")
    }
}
