import Darwin

// A new file at the same path has another device or another inode, also when it has the same
// content.
public struct FileIdentity: Sendable, Equatable {
    public let device: dev_t
    public let inode: ino_t

    public init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
    }

    public init?(path: String) {
        var status = stat()

        guard stat(path, &status) == 0 else {
            return nil
        }

        self.init(status)
    }
}
