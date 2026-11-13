import Foundation

// A config file that belongs to the user, such as my.cnf or redis.conf. Nexus writes it only when
// it is not there, so a change of the user stays.
public enum UserConfigFile {
    public static func writeIfMissing(_ text: String, to file: URL) throws {
        guard !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            return
        }

        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
}
