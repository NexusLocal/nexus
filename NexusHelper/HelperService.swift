import Foundation
import NexusCore
import NexusDNS
import NexusIPC

// Runs as root. It changes only /etc/resolver/<tld> and the Nexus lines in /etc/hosts, and
// SystemDNSFiles checks every value again before it writes.
final class HelperService: NSObject, NSXPCListenerDelegate, NexusXPCService, @unchecked Sendable {
    private let requirement: String?
    private let files = SystemDNSFiles()
    private let queue = DispatchQueue(label: "nl.roodfruit.nexus.helper.files")

    override init() {
        requirement = CodeSigning.ownTeamIdentifier().map {
            "identifier \"\(NexusIdentifiers.daemon)\" and anchor apple generic and certificate leaf[subject.OU] = \"\($0)\""
        }
    }

    // Only nexusd, signed by the same team, may connect. A build without a signature accepts
    // nobody, because nothing else can prove who the caller is.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement else {
            return false
        }

        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: NexusXPCService.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        queue.async { [files] in
            let response: HelperResponse

            do {
                let decoded = try NexusMessageCoding.decode(HelperRequest.self, from: request)
                if try Self.perform(decoded, with: files) {
                    Self.flushDNSCaches()
                }
                response = .done
            } catch {
                response = .failure(message: String(describing: error))
            }

            reply((try? NexusMessageCoding.encode(response)) ?? Data())
        }
    }

    private static func perform(_ request: HelperRequest, with files: SystemDNSFiles) throws -> Bool {
        switch request {
        case .setResolver(let tld, let port):
            try files.setResolver(tld: tld, port: port)
        case .removeResolver(let tld):
            try files.removeResolver(tld: tld)
        case .setHosts(let hosts):
            try files.setHosts(hosts)
        }
    }

    private static func flushDNSCaches() {
        run("/usr/bin/dscacheutil", ["-flushcache"])
        run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    private static func run(_ program: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(filePath: program)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }
}
