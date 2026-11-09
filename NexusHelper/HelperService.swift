import Foundation
import NexusCore
import NexusDNS
import NexusIPC

// Runs as root. It changes only /etc/resolver/<tld> and the Nexus lines in /etc/hosts, and
// SystemDNSFiles checks every value again before it writes.
//
// launchd starts the helper for a request. The helper ends after a time without requests. An
// update replaces its file, and only root can restart it. So the next request after the end
// starts the new code.
final class HelperService: NSObject, NSXPCListenerDelegate, NexusXPCService, @unchecked Sendable {
    static let idleTime: DispatchTimeInterval = .seconds(30)

    private let requirement: String?
    private let files = SystemDNSFiles()
    private let queue = DispatchQueue(label: "nl.roodfruit.nexus.helper.files")
    private var lastRequest = DispatchTime.now()

    override init() {
        requirement = CodeSigning.ownTeamIdentifier().map {
            "identifier \"\(NexusIdentifiers.daemon)\" and anchor apple generic and certificate leaf[subject.OU] = \"\($0)\""
        }
        super.init()
        endWhenIdle()
    }

    // Each request runs on the queue, so the helper never ends in the middle of a request. nexusd
    // tries a request again when the helper does not answer.
    private func endWhenIdle() {
        queue.asyncAfter(deadline: lastRequest + Self.idleTime) { [weak self] in
            guard let self else {
                return
            }

            guard DispatchTime.now() < lastRequest + Self.idleTime else {
                exit(0)
            }

            endWhenIdle()
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
        queue.async { [self, files] in
            defer { lastRequest = .now() }
            let response: HelperResponse

            do {
                let decoded = try NexusMessageCoding.decode(HelperRequest.self, from: request)
                if try Self.perform(decoded, with: files) {
                    Self.flushDNSCaches()
                }
                response = .done
            } catch {
                response = .failure(message: ErrorText.plain(error))
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
