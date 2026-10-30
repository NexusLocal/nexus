import Foundation
import NexusCore

public enum LaravelProject {
    // A site folder can be the public folder of the application. So the search goes up.
    public static func root(containing folder: URL) -> URL? {
        var current = URL(filePath: RealPath.of(folder), directoryHint: .isDirectory)

        while true {
            if isApplication(current) {
                return current
            }

            let parent = current.deletingLastPathComponent()

            guard parent.path(percentEncoded: false) != current.path(percentEncoded: false) else {
                return nil
            }

            current = parent
        }
    }

    // Laravel 11 and newer merge the config files of the framework into the configuration. So
    // the keys of those files count too.
    static func envKeys(of root: URL) -> [String] {
        let folders = [root.appending(path: "config"), root.appending(path: "vendor/laravel/framework/config")]
        let files = folders.flatMap(phpFiles)
        let keys = files.flatMap { file in
            envKeys(in: String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self))
        }

        return Set(keys).sorted()
    }

    static func envKeys(in source: String) -> [String] {
        source.matches(of: #/(?:\benv|\bgetenv|Env::get(?:OrFail)?)\(\s*['"]([A-Za-z_][A-Za-z0-9_.]*)['"]/#).map { String($0.output.1) }
    }

    private static func isApplication(_ folder: URL) -> Bool {
        ["artisan", "bootstrap/app.php"].allSatisfy { file in
            FileManager.default.fileExists(atPath: folder.appending(path: file).path(percentEncoded: false))
        }
    }

    private static func phpFiles(in folder: URL) -> [URL] {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }

        return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "php" }
    }
}
