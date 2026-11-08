import Foundation

// nexus wp gives WP-CLI the core folder of WordPress (Phase 4, 3c). WP-CLI looks for WordPress
// itself from the current folder up to /. It stops at a folder with wp-load.php or at an
// index.php that loads WordPress from a subfolder. The nearest wp-cli.local.yml or wp-cli.yml can
// give a path too, as in Bedrock. A site that holds WordPress one folder down is not on that way.
// nexusd then gives the nexus command that folder. The root is the folder of the site or the same
// folder in a worktree. So a worktree gets its own core.
public enum WordPressCore {
    static let configFiles = ["wp-cli.local.yml", "wp-cli.yml"]

    // WP-CLI 2.12 has code that PHP 8.5 marks as deprecated. PHP then prints notices before the
    // output of each command. The folder of this file is in PHP_INI_SCAN_DIR of nexus wp. So a PHP
    // process that WP-CLI starts itself reads it too. When WordPress loads, WP-CLI sets the error
    // level from WP_DEBUG. So the notices of WordPress, a plugin or a theme still show.
    public static let phpSettingsFileName = "nexus-wp-cli.ini"
    public static let phpSettings = "error_reporting = E_ALL & ~E_DEPRECATED\n"

    // The pattern of extract_subdir_path in WP-CLI 2.12.
    nonisolated(unsafe) static let loadsWordPress = /^\s*require\s*\(?\s*(.+?)\/wp-blog-header\.php['"]/.anchorsMatchLineEndings()

    public static func coreFolder(for folder: URL, in root: URL) -> String? {
        let rootPath = RealPath.of(root)
        let start = RealPath.of(folder)

        guard RealPath.contains(rootPath, start) else {
            return nil
        }

        let folders = upward(from: start)

        if folders.contains(where: wpCLIFindsWordPress) {
            return nil
        }

        if let config = nearestConfigFile(in: folders), setsPath(config) {
            return nil
        }

        return coreFolder(below: rootPath)
    }

    // The --path of Nexus comes first. So WP_CLI_STRICT_ARGS_MODE reads it as a global option.
    // WP-CLI reads an alias such as @prod only as the first argument. So a command with an alias
    // gets no --path. A --path, --ssh or --http of the user wins. wp core download works in the
    // current folder. A path in the global config of WP-CLI wins too.
    public static func arguments(_ arguments: [String], core: String?, environment: [String: String], home: URL) -> [String] {
        guard let core, !userChoosesWordPress(arguments), !globalConfigSetsPath(environment: environment, home: home) else {
            return arguments
        }

        return ["--path=\(core)"] + arguments
    }

    static func userChoosesWordPress(_ arguments: [String]) -> Bool {
        if arguments.first?.hasPrefix("@") == true {
            return true
        }

        let options = ["--path", "--ssh", "--http"]

        if arguments.contains(where: { argument in options.contains { argument == $0 || argument.hasPrefix("\($0)=") } }) {
            return true
        }

        return arguments.filter { !$0.hasPrefix("-") }.starts(with: ["core", "download"])
    }

    static func globalConfigSetsPath(environment: [String: String], home: URL) -> Bool {
        let file = environment["WP_CLI_CONFIG_PATH"] ?? home.appending(path: ".wp-cli/config.yml").path(percentEncoded: false)
        return setsPath(file)
    }

    // Two folders with WordPress give no core folder. WP-CLI then says that it finds no WordPress.
    // The user chooses one with --path.
    static func coreFolder(below root: String) -> String? {
        PHPProject.wordPressFolder(in: URL(filePath: root, directoryHint: .isDirectory)).map { RealPath.trimmed($0.path(percentEncoded: false)) }
    }

    static func wpCLIFindsWordPress(in folder: String) -> Bool {
        if PHPProject.hasWordPress(URL(filePath: folder, directoryHint: .isDirectory)) {
            return true
        }

        return text(of: (folder as NSString).appendingPathComponent("index.php"))?.contains(loadsWordPress) == true
    }

    // WP-CLI reads only the first config file that it finds. In one folder wp-cli.local.yml wins.
    static func nearestConfigFile(in folders: [String]) -> String? {
        for folder in folders {
            for name in configFiles {
                let file = (folder as NSString).appendingPathComponent(name)

                if FileManager.default.fileExists(atPath: file) {
                    return file
                }
            }
        }

        return nil
    }

    static func setsPath(_ file: String) -> Bool {
        text(of: file)?.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("path:") } == true
    }

    static func upward(from path: String) -> [String] {
        var folders = [path]

        while let last = folders.last, last != "/" {
            folders.append((last as NSString).deletingLastPathComponent)
        }

        return folders
    }

    // PHP reads the bytes of the file. A file with Latin-1 text must not hide its require line.
    private static func text(of file: String) -> String? {
        FileManager.default.contents(atPath: file).map { String(decoding: $0, as: UTF8.self) }
    }
}
