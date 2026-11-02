import CoreServices
import Foundation

// Watches folders and everything in them with FSEvents. FSEvents names each folder whose content
// changed, with its real path and a / at the end. The watch root flag also reports a watched
// folder that moves or goes away.
final class FolderWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nl.roodfruit.nexus.folder-watcher")
    private let onChange: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?

    // FSEvents waits for the latency before it reports a change. reportsFirstChangeAtOnce reports the
    // first change after a quiet time without that wait, for a program that reacts to the same change.
    init?(folders: [URL], latency: TimeInterval = 0.3, reportsFirstChangeAtOnce: Bool = false, onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange

        guard !folders.isEmpty else {
            return nil
        }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else {
                return
            }

            let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray as? [String] ?? []
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange(changed)
        }
        let noDefer = reportsFirstChangeAtOnce ? kFSEventStreamCreateFlagNoDefer : 0
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot | noDefer)
        let paths = folders.map { $0.path(percentEncoded: false) } as CFArray

        guard let stream = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            return nil
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    // The queue of the stream runs the callback. A stop on that queue waits for a running
    // callback, so no callback runs after the stop.
    func stop() {
        queue.sync {
            guard let stream else {
                return
            }

            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit {
        stop()
    }
}
