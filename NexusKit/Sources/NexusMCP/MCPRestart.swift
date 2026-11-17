import Foundation
import NexusCore
import Synchronization

// What a new build of nexus mcp needs to go on with the session of the old process. That is the
// name of a legacy client from its initialize and the input that the old process read but did not
// handle. That input starts with the requests that the old process held. A modern client sends its
// name with each request. The old process ends each running request before the new build starts.
public struct MCPResume: Codable, Equatable, Sendable {
    public static let environmentKey = "NEXUS_MCP_RESUME"

    public let agent: String?
    public let input: Data

    public init(agent: String?, input: Data) {
        self.agent = agent
        self.input = input
    }

    public var environmentValue: String? {
        (try? JSONEncoder().encode(self))?.base64EncodedString()
    }

    public init?(environmentValue: String) {
        guard let data = Data(base64Encoded: environmentValue), let resume = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }

        self = resume
    }
}

// An update of Nexus replaces the file of nexus mcp while an agent uses it. nexusd then refuses
// each request of the old process. So before each request, the server checks its file. When a new
// file is there, start runs it in the place of this process. start returns only when that fails. A
// file that failed gets no second try. An update can move the old app away before it puts the new
// one in place. So the check waits a short time for a missing file. A file that stays missing is
// no new build.
public final class MCPRestart: Sendable {
    private let file: ExecutableFile
    private let missingWait: Duration
    private let start: @Sendable (String, MCPResume) -> Void
    private let failedFile = Mutex<ExecutableFile?>(nil)

    public init(file: ExecutableFile, missingWait: Duration = ExecutableFile.missingWait, start: @escaping @Sendable (_ path: String, _ resume: MCPResume) -> Void) {
        self.file = file
        self.missingWait = missingWait
        self.start = start
    }

    func isNeeded() async -> Bool {
        let deadline = ContinuousClock.now + missingWait

        while file.change == .removed, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard file.change == .updated, let current = ExecutableFile(path: file.path) else {
            return false
        }

        return failedFile.withLock { $0 != current }
    }

    func run(_ resume: MCPResume) {
        let current = ExecutableFile(path: file.path)
        start(file.path, resume)
        failedFile.withLock { $0 = current }
    }

    public var startFailed: Bool {
        guard let current = ExecutableFile(path: file.path) else {
            return false
        }

        return failedFile.withLock { $0 == current }
    }
}
