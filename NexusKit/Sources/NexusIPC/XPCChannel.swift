import Foundation
import Security

// The one XPC method of nexusd and of the helper. Each side encodes its own request and response
// types as JSON, so the XPC interface never changes when a request is added.
@objc public protocol NexusXPCService {
    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

// Sends one message to an XPC Mach service and waits for the answer. Every call uses a new
// connection, because the callers send few messages.
struct XPCChannel: Sendable {
    let serviceName: String
    let privileged: Bool

    func send(_ payload: Data) async throws -> Data {
        let connection = NSXPCConnection(machServiceName: serviceName, options: privileged ? .privileged : [])
        connection.remoteObjectInterface = NSXPCInterface(with: NexusXPCService.self)
        connection.resume()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(throwing: XPCChannelError.unreachable(error.localizedDescription))
            }

            guard let service = proxy as? NexusXPCService else {
                once.resume(throwing: XPCChannelError.unreachable("no proxy for \(serviceName)"))
                return
            }

            service.handle(payload) { reply in
                once.resume(returning: reply)
            }
        }
    }
}

enum XPCChannelError: Error {
    case unreachable(String)
}

public enum CodeSigning {
    // The team that signed the running program. nil for a build without a signature, such as a
    // build in CI.
    public static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else {
            return nil
        }

        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?

    init(_ continuation: CheckedContinuation<Data, any Error>) {
        self.continuation = continuation
    }

    func resume(returning data: Data) {
        take()?.resume(returning: data)
    }

    func resume(throwing error: any Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Data, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let current = continuation
        continuation = nil
        return current
    }
}
