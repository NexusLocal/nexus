import Darwin
import Foundation
import NexusCore

public struct PortOwner: Codable, Sendable, Equatable {
    public let pid: Int32
    public let command: String
    public let executable: String?
    // The child processes of a server share its port, and lsof shows only the processes of this
    // user. So pid can be a child. A stop of a child frees nothing, because the main process
    // starts a new child.
    public var mainPID: Int32?
    public var mainProcessIsOwn: Bool?
    // A stop goes to the main process. Its path can differ from the path of pid. Only the path of
    // that same number shows that the number still belongs to the program.
    public var mainExecutable: String?

    public init(pid: Int32, command: String, executable: String?, mainPID: Int32? = nil, mainProcessIsOwn: Bool? = nil, mainExecutable: String? = nil) {
        self.pid = pid
        self.command = command
        self.executable = executable
        self.mainPID = mainPID
        self.mainProcessIsOwn = mainProcessIsOwn
        self.mainExecutable = mainExecutable
    }

    // These apps start their servers again. So only the app itself can stop them.
    public var managerBundleIdentifier: String? {
        OtherWebServers.managerBundleIdentifier(of: application)
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

    public var mainProcess: Int32 {
        mainPID ?? pid
    }

    // An owner of an older nexusd has no path of its main process.
    public var mainProcessPath: String? {
        mainProcess == pid ? executable : mainExecutable
    }

    public var description: String {
        "\(application) (\(command), process \(mainProcess))"
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
        !isInUse(port, address: INADDR_ANY) && !isInUse(port, address: IPv4Socket.loopback)
    }

    // A listener that just closed can keep its port for some milliseconds, for example when a
    // connection still waited in its queue. A start right after a stop waits for that.
    public static func becomesFree(_ port: Int, within timeout: Duration = .seconds(1)) async -> Bool {
        await waitUntil(within: timeout) { isFree(port) }
    }

    // The same wait for one address, for a server that binds only that address.
    public static func becomesFree(_ port: Int, on address: in_addr_t, within timeout: Duration = .seconds(1)) async -> Bool {
        await waitUntil(within: timeout) { !isInUse(port, address: address) }
    }

    private static func waitUntil(within timeout: Duration, _ portIsFree: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout

        while !portIsFree() {
            guard ContinuousClock.now < deadline else {
                return false
            }

            try? await Task.sleep(for: .milliseconds(20))
        }

        return true
    }

    public static func acceptsConnections(_ port: Int) -> Bool {
        connects(to: IPv4Socket.address(IPv4Socket.loopback, port: port), family: AF_INET)
    }

    // The dev server of Vite listens only on [::1]. Another server can listen only on 127.0.0.1.
    public static func acceptsLoopbackConnections(_ port: Int) -> Bool {
        if acceptsConnections(port) {
            return true
        }

        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(UInt16(port).bigEndian)
        address.sin6_addr = in6addr_loopback

        return connects(to: address, family: AF_INET6)
    }

    // Address is sockaddr_in, sockaddr_in6 or sockaddr_un. So its size is the size that connect needs.
    private static func connects<Address>(to address: Address, family: Int32) -> Bool {
        let descriptor = socket(family, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }

        var address = address

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<Address>.size)) }
        }

        return result == 0
    }

    // The ports of the list with an open TCP connection. nil when lsof fails. lsof ends with exit
    // status 1 when it finds no connection, and that gives an empty set.
    public static func portsWithOpenConnections(_ ports: Set<Int>) async -> Set<Int>? {
        guard !ports.isEmpty else {
            return []
        }

        let list = ports.sorted().map(String.init).joined(separator: ",")
        let command = Command(executable: URL(filePath: "/usr/sbin/lsof"), arguments: ["-nP", "-iTCP:\(list)", "-sTCP:ESTABLISHED", "-Fn"])

        do {
            let output = try await CommandRunner.run(command)
            return connectedPorts(inLsofOutput: output.standardOutput, among: ports)
        } catch CommandError.failed(_, 1, _) {
            return []
        } catch {
            return nil
        }
    }

    // Each line n<local>-><remote> of lsof -Fn gives two ports.
    static func connectedPorts(inLsofOutput output: String, among ports: Set<Int>) -> Set<Int> {
        var found: Set<Int> = []

        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            for end in line.dropFirst().split(separator: "->") {
                guard let colon = end.lastIndex(of: ":"), let port = Int(end[end.index(after: colon)...]), ports.contains(port) else {
                    continue
                }

                found.insert(port)
            }
        }

        return found
    }

    // A Unix socket of a server on this Mac, for example the MySQL of MAMP PRO. A path that is too
    // long for a socket accepts no connection.
    public static func acceptsConnections(socket path: String) -> Bool {
        guard let address = try? UnixSocket.address(of: path) else {
            return false
        }

        return connects(to: address, family: AF_UNIX)
    }

    static func isInUse(_ port: Int, address bindAddress: in_addr_t) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = IPv4Socket.address(bindAddress, port: port)

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
            mainProcessIsOwn: main.map { $0.user == getuid() },
            mainExecutable: main.flatMap { executablePath(of: $0.pid) }
        )
    }

    public static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))

        guard length > 0 else {
            return nil
        }

        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public enum ProgramCheck: Sendable, Equatable {
        case same
        case ended
        case other
    }

    // A program can end after a list or a sheet read its number. Another program can then get
    // that number. So a signal goes only to a number that still has the path of before.
    public static func program(at pid: Int32, recordedPath: String?) -> ProgramCheck {
        guard let path = executablePath(of: pid) else {
            return .ended
        }

        return path == recordedPath ? .same : .other
    }

    public static func runs(_ pid: Int32, path: String) -> Bool {
        program(at: pid, recordedPath: path) == .same
    }
}
