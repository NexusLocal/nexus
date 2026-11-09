import Foundation

// Another program can prepare a new worktree at the same time as Nexus. A script that runs after
// git worktree add can copy vendor or run composer install there. A probe or an install of Nexus
// that reads a part of such a folder fails. So Nexus waits until these folders stop changing.
//
// A copy or an install gives new files and folders up to three levels deep all the time, also in a
// large package. So a recent change there means that a program still writes. Deeper files do not
// count, because node_modules can hold 100000 files. A clone of Nexus keeps the times of the main
// checkout, so a clone of Nexus alone gives no wait.
public enum FolderActivity {
    static let depth = 3

    // The time of the newest change in the folders, up to three levels deep.
    public static func lastChange(in folders: [String]) -> Date? {
        let key = URLResourceKey.contentModificationDateKey
        var newest: Date?

        func add(_ url: URL) {
            guard let date = (try? url.resourceValues(forKeys: [key]))?.contentModificationDate else {
                return
            }

            newest = max(newest ?? date, date)
        }

        for folder in folders where FileManager.default.fileExists(atPath: folder) {
            let url = URL(filePath: folder, directoryHint: .isDirectory)
            add(url)

            guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [key], options: [], errorHandler: { _, _ in true }) else {
                continue
            }

            for case let item as URL in items {
                if items.level >= depth {
                    items.skipDescendants()
                }

                add(item)
            }
        }

        return newest
    }

    // Waits while the newest change is less than quiet ago, at most for limit.
    public static func waitUntilQuiet(
        _ folders: [String],
        quiet: Duration = .seconds(6),
        interval: Duration = .seconds(1),
        limit: Duration = .seconds(180)
    ) async {
        let clock = ContinuousClock()
        let start = clock.now
        let quietSeconds = Double(quiet.components.seconds) + Double(quiet.components.attoseconds) / 1e18

        while clock.now - start < limit, !Task.isCancelled {
            let last = await Task.detached { lastChange(in: folders) }.value

            guard let last, Date().timeIntervalSince(last) < quietSeconds else {
                return
            }

            try? await Task.sleep(for: interval)
        }
    }
}
