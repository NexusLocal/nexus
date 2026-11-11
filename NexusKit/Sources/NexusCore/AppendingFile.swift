import Darwin
import Foundation

// A log that only grows at its end. With O_APPEND each write goes to the end of the file, also
// when another process writes to it. mode applies only to a new file. O_CLOEXEC keeps the
// descriptor out of the child processes of nexusd. A child that gets the file as its output gets a
// copy without this flag.
package enum AppendingFile {
    // A missing folder is made first.
    package static func open(_ file: URL, mode: mode_t) throws -> Int32 {
        let path = file.path(percentEncoded: false)
        let flags = O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC
        var descriptor = Darwin.open(path, flags, mode)

        if descriptor < 0, errno == ENOENT {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            descriptor = Darwin.open(path, flags, mode)
        }

        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        return descriptor
    }
}
