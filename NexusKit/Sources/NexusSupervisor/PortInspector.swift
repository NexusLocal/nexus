import Darwin
import Foundation

public struct PortOwner: Codable, Sendable, Equatable {
    public let pid: Int32
    public let command: String
    public let executable: String?

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
        if executable.hasPrefix("/opt/homebrew/") || executable.hasPrefix("/usr/local/Cellar/") {
            return "Homebrew"
        }
        if let bundle = executable.components(separatedBy: "/").last(where: { $0.hasSuffix(".app") }) {
            return String(bundle.dropLast(4))
        }

        return command
    }

    public var description: String {
        "\(application) (\(command), process \(pid))"
    }
}

public enum PortInspector {
    // Binds the port on all addresses, the same as the services do. A failed bind means that
    // another process listens on the port, also when lsof cannot see that process because it
    // belongs to another user.
    public static func isFree(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: INADDR_ANY)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }

        return result == 0
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

        return PortOwner(pid: pid, command: command, executable: executablePath(of: pid))
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
