import Foundation
import NexusCore

public enum SystemDNSFilesError: Error, Equatable, CustomStringConvertible {
    case invalidPort(Int)
    case foreignResolver(String)
    case unreadableHosts(String)
    case brokenHostsBlock(String)
    case tooManyHosts(Int)
    case linkedHosts(String)

    public var description: String {
        switch self {
        case .invalidPort(let port):
            "\(port) is not a valid port for the DNS server. Use a port from 1024 to 65535."
        case .foreignResolver(let path):
            "\(path) belongs to another app, so Nexus does not change it. Remove that file, or choose another dev TLD."
        case .unreadableHosts(let path):
            "Nexus cannot read \(path) as text, so it does not change it."
        case .brokenHostsBlock(let path):
            "\(path) has a \"\(SystemDNSFiles.hostsBegin)\" line without a \"\(SystemDNSFiles.hostsEnd)\" line. Nexus does not change the file until you fix this."
        case .tooManyHosts(let count):
            "Nexus writes at most \(SystemDNSFiles.maximumHosts) hosts to /etc/hosts, not \(count)."
        case .linkedHosts(let path):
            "\(path) is a link that another app manages, so Nexus does not change it."
        }
    }
}

// The two system files that Nexus changes: /etc/resolver/<tld> and the Nexus lines in
// /etc/hosts. Both belong to root, so only the privileged helper uses this. Every other line of
// /etc/hosts stays as it is, because MAMP PRO and the user write lines there too.
public struct SystemDNSFiles: Sendable {
    public static let resolverMarker = "# Written by Nexus. Nexus removes this file when you remove Nexus."
    public static let hostsBegin = "# Nexus begin"
    public static let hostsEnd = "# Nexus end"
    public static let maximumHosts = 10_000

    public let resolverFolder: URL
    public let hostsFile: URL

    public init(
        resolverFolder: URL = URL(filePath: "/etc/resolver", directoryHint: .isDirectory),
        hostsFile: URL = URL(filePath: "/etc/hosts", directoryHint: .notDirectory)
    ) {
        self.resolverFolder = resolverFolder
        self.hostsFile = hostsFile
    }

    // Both files are readable by every user, so nexusd can check them without the helper.
    public func hasNexusResolver(tld: String) -> Bool {
        let resolver = try? String(contentsOf: resolverFile(for: tld.lowercased()), encoding: .utf8)
        return resolver?.hasPrefix(Self.resolverMarker) == true
    }

    public var hasNexusHosts: Bool {
        let hosts = try? String(contentsOf: hostsFile, encoding: .utf8)
        return hosts?.components(separatedBy: "\n").contains(Self.hostsBegin) == true
    }

    // The dev TLDs that have a resolver file of Nexus. After a change of the dev TLD, the file of
    // the old one stays until the helper removes it.
    public var nexusResolvers: [String] {
        HostName.devTLDs.sorted().filter { hasNexusResolver(tld: $0) }
    }

    public static func resolverContents(port: Int) -> String {
        "\(resolverMarker)\nnameserver 127.0.0.1\nport \(port)\n"
    }

    // Returns true when the file changed, so the helper knows when to flush the DNS cache.
    @discardableResult
    public func setResolver(tld: String, port: Int) throws -> Bool {
        let tld = try HostName.validatedTLD(tld)

        guard (1024...65535).contains(port) else {
            throw SystemDNSFilesError.invalidPort(port)
        }

        let file = resolverFile(for: tld)
        let contents = Self.resolverContents(port: port)
        let exists = FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
        let current = try? String(contentsOf: file, encoding: .utf8)

        if current == contents {
            return false
        }

        if exists, current?.hasPrefix(Self.resolverMarker) != true {
            throw SystemDNSFilesError.foreignResolver(file.path(percentEncoded: false))
        }

        try FileManager.default.createDirectory(at: resolverFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try write(contents, to: file)
        return true
    }

    // Removes the resolver file only when Nexus wrote it.
    @discardableResult
    public func removeResolver(tld: String) throws -> Bool {
        let file = resolverFile(for: try HostName.validatedTLD(tld))

        guard let current = try? String(contentsOf: file, encoding: .utf8), current.hasPrefix(Self.resolverMarker) else {
            return false
        }

        try FileManager.default.removeItem(at: file)
        return true
    }

    @discardableResult
    public func setHosts(_ hosts: [String]) throws -> Bool {
        guard hosts.count <= Self.maximumHosts else {
            throw SystemDNSFilesError.tooManyHosts(hosts.count)
        }

        let hosts = Set(try hosts.map(HostName.validated)).sorted()
        let path = hostsFile.path(percentEncoded: false)

        if (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw SystemDNSFilesError.linkedHosts(path)
        }

        guard let data = FileManager.default.contents(atPath: path), let current = String(data: data, encoding: .utf8) else {
            throw SystemDNSFilesError.unreadableHosts(path)
        }

        let updated = try Self.replacingHostsBlock(in: current, with: hosts, path: path)
        if updated == current {
            return false
        }

        try write(updated, to: hostsFile)
        return true
    }

    static func replacingHostsBlock(in contents: String, with hosts: [String], path: String) throws -> String {
        var lines = contents.components(separatedBy: "\n")
        let endsWithNewline = lines.last == ""
        if endsWithNewline {
            lines.removeLast()
        }

        if let begin = lines.firstIndex(of: hostsBegin) {
            guard let end = lines[begin...].firstIndex(of: hostsEnd) else {
                throw SystemDNSFilesError.brokenHostsBlock(path)
            }

            lines.removeSubrange(begin...end)
        }

        if !hosts.isEmpty {
            lines.append(hostsBegin)
            for host in hosts {
                lines.append("127.0.0.1 \(host)")
                lines.append("::1 \(host)")
            }
            lines.append(hostsEnd)
        }

        let joined = lines.joined(separator: "\n")
        return endsWithNewline || !hosts.isEmpty ? joined + "\n" : joined
    }

    private func resolverFile(for tld: String) -> URL {
        resolverFolder.appending(path: tld, directoryHint: .notDirectory)
    }

    private func write(_ contents: String, to file: URL) throws {
        try Data(contents.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path(percentEncoded: false))
    }
}
