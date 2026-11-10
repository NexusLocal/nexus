import Foundation

// A change to a file of the user. A symbolic link, for example into a folder of dotfiles, stays a
// link: the change goes into the file that it points to. The file keeps its permissions. A new
// file gets 0600 by default, because such files often hold keys or passwords.
public enum FileText {
    public static func write(_ text: String, to file: URL, newFilePermissions: Int = 0o600) throws {
        let target = file.resolvingSymlinksInPath()
        let path = target.path(percentEncoded: false)
        let permissions = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int ?? newFilePermissions

        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
    }
}
