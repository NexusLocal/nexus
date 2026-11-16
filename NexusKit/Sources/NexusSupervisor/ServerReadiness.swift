import Darwin
import Foundation
import NexusCore

// The moment of a hand-over (plan item 3e). MySQL and MariaDB send their
// greeting after both listeners exist. MariaDB 11.8 does not stop on SIGTERM before its greeting.
// PostgreSQL answers "the database system is starting up" until line 8 of postmaster.pid says
// "ready".
public enum ServerReadiness {
    // A connection to the Unix socket of the server gets the first byte of its greeting. The probe
    // does not go to the TCP port, so the gate of that port never gets it.
    public static func greets(socket path: String, timeout: TimeInterval = 1) -> Bool {
        guard var address = try? UnixSocket.address(of: path) else {
            return false
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)

        guard descriptor >= 0 else {
            return false
        }

        defer { close(descriptor) }

        var on: Int32 = 1
        var interval = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }

        guard connected == 0 else {
            return false
        }

        var byte: UInt8 = 0
        return recv(descriptor, &byte, 1, 0) == 1
    }

    // The same probe for async code. A probe can wait for the whole timeout. So it runs on its own
    // thread and does not block a thread of the cooperative pool of Swift.
    public static func receivesGreeting(socket path: String, timeout: TimeInterval = 1) async -> Bool {
        await withCheckedContinuation { result in
            Thread.detachNewThread {
                result.resume(returning: greets(socket: path, timeout: timeout))
            }
        }
    }

    // A postgres that got SIGKILL leaves its postmaster.pid with "ready". So the process of line 1
    // must be a postgres that runs.
    public static func isReady(postgreSQLData folder: URL, isPostgres: (Int32) -> Bool = ServerReadiness.runsPostgres) -> Bool {
        guard let text = try? String(contentsOf: folder.appending(path: "postmaster.pid", directoryHint: .notDirectory), encoding: .utf8) else {
            return false
        }

        let lines = text.components(separatedBy: "\n")

        guard lines.count >= 8, lines[7].trimmingCharacters(in: .whitespaces) == "ready", let pid = Int32(lines[0].trimmingCharacters(in: .whitespaces)), pid > 0 else {
            return false
        }

        return isPostgres(pid)
    }

    public static func runsPostgres(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 && PortInspector.executablePath(of: pid)?.hasSuffix("/postgres") == true
    }
}
