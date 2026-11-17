import Darwin
import Foundation
import Synchronization

// The input of nexus mcp, one message on each line. The reader keeps each byte until the server
// handled it: the bytes after the last line, the line that the server works on and the requests that
// it holds for a new build. So a new build that starts in the place of this process gets each byte.
// The agent then loses no message (bug 2026-11-17).
public final class MCPInput: Sendable {
    private enum Next {
        case line(String?)
        case again
    }

    private struct Buffer {
        var bytes: [UInt8]
        var ended = false
        var waiter: CheckedContinuation<Next, Never>?
        var open: String?
        var held: [String] = []

        mutating func takeLine() -> String? {
            guard let end = bytes.firstIndex(of: 0x0A) else {
                return nil
            }

            let line = String(decoding: bytes[..<end], as: UTF8.self)
            bytes.removeSubrange(...end)
            return line
        }

        mutating func takeRest() -> String? {
            defer { bytes = [] }
            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
    }

    private let buffer: Mutex<Buffer>

    // unread holds the bytes that an earlier process read but did not handle.
    public init(unread: Data = Data()) {
        buffer = Mutex(Buffer(bytes: Array(unread)))
    }

    // A thread reads the standard input, because a read waits until the agent writes.
    public static func standardInput(unread: Data = Data()) -> MCPInput {
        let input = MCPInput(unread: unread)
        let thread = Thread { input.read(from: STDIN_FILENO) }
        thread.start()
        return input
    }

    // The next line without its line end. nil at the end of the input. A last line without a line
    // end counts too. The line stays open until release or hold.
    public func nextLine() async -> String? {
        while true {
            let next = await withCheckedContinuation { (continuation: CheckedContinuation<Next, Never>) in
                buffer.withLock { buffer in
                    if let line = buffer.takeLine() ?? (buffer.ended ? buffer.takeRest() : nil) {
                        buffer.open = line
                        continuation.resume(returning: .line(line))
                    } else if buffer.ended {
                        continuation.resume(returning: .line(nil))
                    } else {
                        buffer.waiter = continuation
                    }
                }
            }

            if case .line(let line) = next {
                return line
            }
        }
    }

    func release() {
        buffer.withLock { $0.open = nil }
    }

    func hold() {
        buffer.withLock { buffer in
            buffer.held += buffer.open.map { [$0] } ?? []
            buffer.open = nil
        }
    }

    func dropHeld(where matches: (String) -> Bool) -> Bool {
        buffer.withLock { buffer in
            let count = buffer.held.count
            buffer.held.removeAll(where: matches)
            return buffer.held.count < count
        }
    }

    func takeHeld() -> [String] {
        buffer.withLock { buffer in
            defer { buffer.held = [] }
            return buffer.held
        }
    }

    // The body gets each byte that the server did not handle: the held lines, the open line and the
    // bytes after it. No new bytes arrive while the body runs. So a new build that the body starts
    // gets each byte.
    public func withUnread<Result>(_ body: (Data) -> Result) -> Result {
        buffer.withLock { buffer in
            let lines = (buffer.held + (buffer.open.map { [$0] } ?? [])).map { Array($0.utf8) + [0x0A] }
            return body(Data(lines.joined() + buffer.bytes))
        }
    }

    // An empty array is the end of the input.
    func add(_ bytes: [UInt8]) {
        buffer.withLock { buffer in
            add(bytes, to: &buffer)
        }
    }

    private func add(_ bytes: [UInt8], to buffer: inout Buffer) {
        if bytes.isEmpty {
            buffer.ended = true
        } else {
            buffer.bytes += bytes
        }

        buffer.waiter?.resume(returning: .again)
        buffer.waiter = nil
    }

    // The read and the add happen in one lock, after poll says that bytes wait. So withUnread never
    // runs between a read and its add.
    private func read(from descriptor: Int32) {
        let size = 65_536
        var chunk = [UInt8](repeating: 0, count: size)

        while true {
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)

            if poll(&waiting, 1, -1) < 0 {
                guard errno == EINTR else {
                    add([])
                    return
                }

                continue
            }

            let ended = buffer.withLock { buffer in
                let count = Darwin.read(descriptor, &chunk, size)

                if count > 0 {
                    add(Array(chunk[..<count]), to: &buffer)
                    return false
                }

                if count < 0, errno == EINTR || errno == EAGAIN {
                    return false
                }

                add([], to: &buffer)
                return true
            }

            if ended {
                return
            }
        }
    }
}
