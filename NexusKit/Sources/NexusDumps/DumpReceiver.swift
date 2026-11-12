import Darwin
import Dispatch
import Foundation
import NexusCore
import Synchronization

// The Unix socket of nexusd that the prepend file of PHP sends its dumps to. Each connection runs
// on its own thread with blocking reads, as in SMTPReceiver. That thread also calls receive. A PHP
// process keeps its connection for its whole life, also a queue worker that waits for hours. So a
// read has no timeout. A closed connection makes PHP stop sending for 10 seconds.
public final class DumpReceiver: Sendable {
    // The PHP side keeps each line at 1,000,000 bytes or less.
    public static let maxLineBytes = 1 << 20

    private struct Listening: @unchecked Sendable {
        let source: any DispatchSourceRead
        let closed: DispatchSemaphore
    }

    private let socket: URL
    private let folder: URL
    private let receive: @Sendable (DumpEvent) -> Void
    private let listening = Mutex<Listening?>(nil)
    private let connections = Mutex<Set<Int32>>([])
    private let readers = DispatchGroup()

    // folder holds the files that PHP touches (NexusPaths.dumpFolder).
    public init(socket: URL, folder: URL, receive: @escaping @Sendable (DumpEvent) -> Void) {
        self.socket = socket
        self.folder = folder
        self.receive = receive
    }

    public var pauseFile: URL {
        folder.appending(path: "paused", directoryHint: .notDirectory)
    }

    public var isListening: Bool {
        listening.withLock { current in current != nil }
    }

    var openConnections: Int {
        connections.withLock { open in open.count }
    }

    // A second start while the receiver listens does nothing.
    public func start() throws {
        if isListening {
            return
        }

        try SocketError.checkPath(socket)

        let path = socket.path(percentEncoded: false)
        let manager = FileManager.default
        try manager.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)

        guard descriptor >= 0 else {
            throw SocketError.system("socket", errno)
        }

        // The socket of an earlier nexusd stays as a file and blocks the bind.
        unlink(path)
        var address = Self.address(of: path)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bound == 0 else {
            throw Self.failure("bind", closing: descriptor, socketFile: nil)
        }

        let socketFile = SocketFile(path: path)

        guard chmod(path, 0o600) == 0 else {
            throw Self.failure("chmod", closing: descriptor, socketFile: socketFile)
        }

        guard listen(descriptor, 64) == 0 else {
            throw Self.failure("listen", closing: descriptor, socketFile: socketFile)
        }

        // PHP waits 10 seconds after a failed send. A receiver that listens can take the dumps at
        // once.
        try? manager.removeItem(at: pauseFile)

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "nl.roodfruit.nexus.dumps"))
        source.setEventHandler { [weak self] in
            self?.acceptConnection(on: descriptor)
        }
        let closed = DispatchSemaphore(value: 0)
        source.setCancelHandler {
            socketFile?.remove()
            close(descriptor)
            closed.signal()
        }
        listening.withLock { current in current = Listening(source: source, closed: closed) }
        source.resume()
    }

    // Each open connection ends too. PHP then sends nothing for 10 seconds and connects again. stop
    // waits for the reader threads. So no event reaches receive after stop returns. receive must
    // not call stop, because stop would then wait for itself.
    public func stop() {
        let current = listening.withLock { listening in
            defer { listening = nil }
            return listening
        }

        guard let current else {
            return
        }

        current.source.cancel()
        current.closed.wait()

        connections.withLock { open in
            for descriptor in open {
                shutdown(descriptor, SHUT_RDWR)
            }

            open.removeAll()
        }

        readers.wait()
    }

    private func acceptConnection(on descriptor: Int32) {
        let client = accept(descriptor, nil, nil)

        guard client >= 0 else {
            return
        }

        connections.withLock { open in _ = open.insert(client) }
        readers.enter()

        Thread.detachNewThread { [self] in
            serve(client)
        }
    }

    // The last line of a connection that closes without its new line is cut. So it is dropped.
    private func serve(_ descriptor: Int32) {
        defer {
            connections.withLock { open in _ = open.remove(descriptor) }
            close(descriptor)
            readers.leave()
        }

        var splitter = DumpLineSplitter(maxLength: Self.maxLineBytes)
        var chunk = [UInt8](repeating: 0, count: 65_536)

        while true {
            let count = read(descriptor, &chunk, chunk.count)

            if count < 0, errno == EINTR {
                continue
            }

            guard count > 0 else {
                return
            }

            for line in splitter.append(chunk[0..<count]) {
                deliver(line)
            }
        }
    }

    // A line that does not decode is dropped. The next line of the connection still counts.
    private func deliver(_ line: Data) {
        guard let event = try? DumpLine.decode(line) else {
            return
        }

        receive(event)
    }

    private static func failure(_ call: String, closing descriptor: Int32, socketFile: SocketFile?) -> SocketError {
        let code = errno
        close(descriptor)
        socketFile?.remove()
        return .system(call, code)
    }

    package static func address(of path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8.prefix(buffer.count - 1))
        }

        return address
    }
}

// The socket file that one receiver made. A newer receiver can make a new file at the same path,
// for example a second nexusd. The device and the inode tell the two files apart.
struct SocketFile: Sendable, Equatable {
    let path: String
    let device: dev_t
    let inode: ino_t

    init?(path: String) {
        var info = stat()

        guard stat(path, &info) == 0 else {
            return nil
        }

        self.path = path
        device = info.st_dev
        inode = info.st_ino
    }

    // Removes the file only while it is still this file.
    func remove() {
        guard SocketFile(path: path) == self else {
            return
        }

        unlink(path)
    }
}

// Splits the bytes of one connection into lines that end in a new line. A line above the limit is
// dropped up to its new line. So the connection goes on with the next line.
struct DumpLineSplitter {
    let maxLength: Int
    // The start of a line that the next read ends.
    private var buffer = Data()
    private var skipping = false

    init(maxLength: Int) {
        self.maxLength = maxLength
    }

    mutating func append(_ bytes: ArraySlice<UInt8>) -> [Data] {
        var lines: [Data] = []
        var rest = bytes

        while let newline = rest.firstIndex(of: UInt8(ascii: "\n")) {
            if let line = finishLine(with: rest[rest.startIndex..<newline]) {
                lines.append(line)
            }

            rest = rest[rest.index(after: newline)...]
        }

        if skipping {
            return lines
        }

        if buffer.count + rest.count > maxLength {
            buffer = Data()
            skipping = true
            return lines
        }

        buffer.append(contentsOf: rest)
        return lines
    }

    // nil for a line above the limit. The line takes the buffer with it. So a large line does not
    // keep its memory in the connection.
    private mutating func finishLine(with end: ArraySlice<UInt8>) -> Data? {
        if skipping {
            skipping = false
            return nil
        }

        if buffer.count + end.count > maxLength {
            buffer = Data()
            return nil
        }

        if buffer.isEmpty {
            return Data(end)
        }

        buffer.append(contentsOf: end)
        let line = buffer
        buffer = Data()
        return line
    }
}
