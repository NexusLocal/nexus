import Foundation

// The configuration of one PHP version. php.ini belongs to the user: Nexus writes it one time and
// then leaves it alone. conf.d/00-nexus.ini belongs to Nexus and holds the extension toggles
// (D27). conf.d/99-custom.ini holds the custom lines of the app (D60). PHP reads the conf.d
// folder after php.ini through PHP_INI_SCAN_DIR, in the order of the file names.
public enum PHPConfig {
    public static let zendExtensions: Set<String> = ["opcache", "xdebug"]

    public static let dependencies = ToggleDependencies(["redis": ["igbinary"]])

    public static let defaultExtensions: Set<String> = ["opcache", "apcu", "igbinary", "redis", "imagick", "pgsql", "pdo_pgsql", "yaml"]

    public static let nexusIniName = "00-nexus.ini"
    public static let customIniName = "99-custom.ini"

    // The first line of the custom file is a comment. So line 1 of the custom lines is line 2
    // of the file.
    public static let customIniHeaderLines = 1

    public static func fpmConfig(socket: URL, pidFile: URL) throws -> String {
        """
        ; Nexus writes this file. Changes are lost at the next start of this PHP version.
        [global]
        pid = \(try ConfigText.quoted(pidFile))
        error_log = /dev/stderr
        daemonize = no

        [nexus]
        listen = \(try ConfigText.socket(socket))
        listen.mode = 0600
        pm = dynamic
        pm.max_children = 10
        pm.start_servers = 2
        pm.min_spare_servers = 1
        pm.max_spare_servers = 3
        catch_workers_output = yes
        decorate_workers_output = no
        clear_env = no

        """
    }

    // The extensions that load in a valid order. They come from the toggles and the .so files.
    public static func extensionsToLoad(enabled: Set<String>, available: Set<String>) -> [String] {
        dependencies.loadOrder(enabled, available: available)
    }

    public static func customIni(lines: [String]) -> String {
        (["; Nexus writes this file from the custom settings of each PHP version. Change them in the Nexus app."] + lines)
            .joined(separator: "\n") + "\n"
    }

    // The messages in the start output of PHP that the baseline output does not have. A message
    // that shows twice in the output and once in the baseline counts once.
    public static func newStartupMessages(in output: String, baseline: String) -> [PHPStartupMessage] {
        var known = baseline.split(whereSeparator: \.isNewline).reduce(into: [String: Int]()) { counts, line in
            counts[line.trimmingCharacters(in: .whitespaces), default: 0] += 1
        }
        var messages: [PHPStartupMessage] = []

        for line in output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if let count = known[line], count > 0 {
                known[line] = count - 1
                continue
            }

            messages.append(PHPStartupMessage(line))
        }

        return messages
    }

    public static func nexusIni(extensionDirectory: URL, extensions: [String]) throws -> String {
        var lines = [
            "; Nexus writes this file for the extension toggles. Change the php.ini in the folder above.",
            "extension_dir = \(try ConfigText.quoted(extensionDirectory))",
        ]

        for name in extensions {
            lines.append(zendExtensions.contains(name) ? "zend_extension = \(name)" : "extension = \(name)")
        }

        if extensions.contains("xdebug") {
            lines += [
                "xdebug.mode = debug,develop",
                "xdebug.start_with_request = trigger",
                "xdebug.client_port = 9003",
            ]
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // The first php.ini of a PHP version: the development template of PHP with settings that suit
    // local Laravel work.
    public static func initialIni(template: String, timezone: String) -> String {
        template + """

            ; Settings of Nexus. Change them here: Nexus does not write this file again.
            memory_limit = 1024M
            upload_max_filesize = 1024M
            post_max_size = 1024M
            max_execution_time = 300
            date.timezone = \(timezone)
            opcache.enable = 1
            opcache.enable_cli = 0
            opcache.validate_timestamps = 1
            opcache.revalidate_freq = 0

            """
    }
}

// One line that PHP writes when it reads its settings at the start, for example:
// PHP:  syntax error, unexpected '=' in /path/conf.d/99-custom.ini on line 3
// Warning: Invalid "memory_limit" setting. Invalid quantity "abc" ... in Unknown on line 0
// The text has no prefix and no place. A message without a file or a line names "Unknown" and 0.
public struct PHPStartupMessage: Sendable, Equatable {
    public let text: String
    public let file: String?
    public let line: Int?

    public init(text: String, file: String?, line: Int?) {
        self.text = text
        self.file = file
        self.line = line
    }

    public init(_ output: String) {
        var text = output.trimmingCharacters(in: .whitespaces)
        var file: String?
        var line: Int?

        if let place = text.firstMatch(of: /\s+in (.+) on line (\d+)$/) {
            let name = String(place.1)
            file = name == "Unknown" ? nil : name
            line = Int(place.2).flatMap { $0 > 0 ? $0 : nil }
            text = String(text[..<place.range.lowerBound])
        }

        for prefix in [/^PHP:\s+/, /^(?:PHP )?(?:Fatal error|Parse error|Warning|Notice|Deprecated|Error):\s+/, /^PHP Startup:\s+/] {
            if let match = text.prefixMatch(of: prefix) {
                text = String(text[match.range.upperBound...])
            }
        }

        // A library that does not load names every path that PHP tried. These paths are long and
        // do not help.
        if let tried = text.range(of: " (tried: ") {
            text = String(text[..<tried.lowerBound])
        }

        while text.hasSuffix(".") {
            text.removeLast()
        }

        self.init(text: text, file: file, line: line)
    }
}
