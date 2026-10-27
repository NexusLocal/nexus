#if DEBUG
import Foundation

// Writes a sample of the app to the temporary folder when the main thread is busy for more than
// one second. The sample shows the cause of a slow click afterwards.
nonisolated final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()

    private let lock = NSLock()
    private var lastAnswer = Date.now
    private var sampling = false

    var folder: URL {
        FileManager.default.temporaryDirectory.appending(path: "NexusHangs")
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                DispatchQueue.main.async { [self] in
                    lock.withLock { lastAnswer = .now }
                }

                Thread.sleep(forTimeInterval: 0.25)

                let busy = lock.withLock { Date.now.timeIntervalSince(lastAnswer) > 1 && !sampling }
                if busy {
                    sample()
                }
            }
        }
    }

    private func sample() {
        lock.withLock { sampling = true }
        defer { lock.withLock { sampling = false } }

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "hang-\(Int(Date.now.timeIntervalSince1970)).txt")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sample")
        process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "3", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        print("Nexus was busy for more than one second. Sample: \(file.path)")
    }
}
#endif
