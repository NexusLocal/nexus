import Darwin
import Foundation

public struct PortOwner: Codable, Sendable, Equatable {
    public let pid: Int32
    public let command: String
    public let executable: String?
    // The child processes of a server share its port, and lsof shows only the processes of this
    // user. So pid can be a child. A stop of a child frees nothing, because the main process
    // starts a new child.
    public var mainPID: Int32?
    public var mainProcessIsOwn: Bool?

    // These apps start their servers again. So only the app itself can stop them.
    public var managerBundleIdentifier: String? {
        switch application {
        case "MAMP PRO": "de.appsolute.mamppro"
        case "Herd": "de.beyondco.herd"
        default: nil
        }
    }

    public var canStop: Bool {
        mainProcessIsOwn == true && managerBundleIdentifier == nil
    }

    // The app that a listening process belongs to, so a message can say "MAMP PRO" and not only
    // "httpd".
    public var application: String {
        guard let executable else {
            return command
        }

        if executable.contains("/Applications/MAMP") {
            return "MAMP PRO"
        }
        if executable.contains("/Herd.app/") || executable.contains("/Application Support/Herd/") {
            return "Herd"
        }
        if executable.contains("/Application Support/Nexus/") {
            return "Nexus"
        }
        if executable.contains("/Application Support/Nexus Dev/") {
            return "Nexus Dev"
        }
        if executable.hasPrefix("/opt/homebrew/") || executable.hasPrefix("/usr/local/Cellar/") {
            return "Homebrew"
        }
        if let bundle = executable.components(separatedBy: "/").last(where: { $0.hasSuffix(".app") }) {
            return String(bundle.dropLast(4))
        }

        return command
    }

    public var description: String {
        "\(application) (\(command), process \(mainPID ?? pid))"
    }
}

struct ProcessEntry: Equatable {
    let parent: Int32
    let user: uid_t
    let command: String
}

enum ProcessTable {
    // sysctl also answers for a process of root. proc_pidinfo does not.
    static func entry(of pid: Int32) -> ProcessEntry? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        let command = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }

        return ProcessEntry(parent: info.kp_eproc.e_ppid, user: info.kp_eproc.e_ucred.cr_uid, command: command)
    }

    // A parent with the name of an interpreter can be another program, such as the pm2 daemon of
    // Node apps. So a stop of that parent could stop more than the program on the port.
    private static let interpreters: Set<String> = ["node", "php", "ruby", "java", "bun", "deno"]

    private static func isInterpreter(_ command: String) -> Bool {
        let name = command.lowercased()
        return interpreters.contains(name) || name.hasPrefix("python")
    }

    // The highest parent that is the same program.
    static func mainProcess(of pid: Int32, lookup: (Int32) -> ProcessEntry? = entry(of:)) -> (pid: Int32, user: uid_t)? {
        guard var current = lookup(pid) else {
            return nil
        }

        var currentPID = pid

        if isInterpreter(current.command) {
            return (currentPID, current.user)
        }

        while current.parent > 1, let parent = lookup(current.parent), parent.command == current.command {
            currentPID = current.parent
            current = parent
        }

        return (currentPID, current.user)
    }
}

public enum PortInspector {
    // Binds the port on all addresses and on 127.0.0.1, the two ways the services bind it. Only
    // "address in use" counts. So another process that listens on the port is found, also when
    // lsof cannot see it because it belongs to another user. macOS refuses 127.0.0.1 below port
    // 1024 to a normal user, and that refusal does not count. SO_REUSEADDR is set as the servers
    // set it. So closed connections that wait on the port after a restart do not count either.
    public static func isFree(_ port: Int) -> Bool {
        !isInUse(port, address: INADDR_ANY) && !isInUse(port, address: inet_addr("127.0.0.1"))
    }

    // A listener that just closed can keep its port for some milliseconds, for example when a
    // connection still waited in its queue. A start right after a stop waits for that.
    public static func becomesFree(_ port: Int, within timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now + timeout

        while !isFree(port) {
            guard ContinuousClock.now < deadline else {
                return false
            }

            try? await Task.sleep(for: .milliseconds(20))
        }

        return true
    }

    public static func acceptsConnections(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }

        return result == 0
    }

    private static func isInUse(_ port: Int, address bindAddress: in_addr_t) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: bindAddress)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }

        return result != 0 && errno == EADDRINUSE
    }

    public static func owner(of port: Int) -> PortOwner? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var pid: Int32?
        var command: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("p"), pid == nil {
                pid = Int32(line.dropFirst())
            }
            if line.hasPrefix("c"), command == nil {
                command = String(line.dropFirst())
            }
        }

        guard let pid, let command else {
            return nil
        }

        let main = ProcessTable.mainProcess(of: pid)

        return PortOwner(
            pid: pid,
            command: command,
            executable: executablePath(of: pid),
            mainPID: main?.pid,
            mainProcessIsOwn: main.map { $0.user == getuid() }
        )
    }

    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))

        guard length > 0 else {
            return nil
        }

        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
