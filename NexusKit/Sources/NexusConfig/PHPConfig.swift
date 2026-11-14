import Foundation
import NexusCore

// The configuration of one PHP version. php.ini belongs to the user: Nexus writes it one time and
// then leaves it alone. conf.d/00-nexus.ini belongs to Nexus and holds the extension toggles
// (D27). conf.d/99-custom.ini holds the custom lines of the app (D60). PHP reads the conf.d
// folder after php.ini through PHP_INI_SCAN_DIR, in the order of the file names.
public enum PHPConfig {
    public static let zendExtensions: Set<String> = ["opcache", "xdebug"]

    public static let dependencies = ToggleDependencies(["redis": ["igbinary"]])

    public static let defaultExtensions: Set<String> = ["opcache", "apcu", "igbinary", "redis", "imagick", "pgsql", "pdo_pgsql", "yaml", "mailparse", "pcov"]

    public static let nexusIniName = "00-nexus.ini"
    public static let customIniName = "99-custom.ini"

    // PCOV with pcov.enabled = 1 runs every line of PHP through its own code, also without a test.
    // A page then took about 70% more time in PHP, and a loop on the command line 3 times more
    // (measured on 2026-11-09). So PCOV loads with pcov.enabled = 0 (owner, 2026-11-09). The nexus
    // command adds this folder after conf.d for a command with --coverage, --tia or --mutate, for
    // example pest --tia. A PHP that the command starts gets the folder too, because it is in the
    // environment. A custom setting pcov.enabled = 1 turns it on for each command and each page.
    public static let coverageFolderName = "coverage.d"
    public static let coverageIniName = "00-nexus-coverage.ini"

    public static let coverageIni = """
        ; Nexus writes this file. The nexus command reads it only for a command with --coverage, --tia or --mutate.
        pcov.enabled = 1

        """

    // The first line of the custom file is a comment. So line 1 of the custom lines is line 2
    // of the file.
    public static let customIniHeaderLines = 1

    // The dump viewer. conf.d is shared by PHP-FPM and the command line. So the prepend file is not
    // there. The pool of PHP-FPM names the stub of the PHP version. The nexus command adds dumps.d
    // after conf.d only while the setting "Commands and queue workers" is on (see "Stub contract"
    // in docs/dump-viewer-build.md).
    public static let dumpsFolderName = "dumps.d"
    public static let dumpsIniName = "00-nexus-dumps.ini"
    public static let dumpStubName = "nexus-prepend.php"
    public static let dumpStubVersion = 1
    public static let dumpLibraryEntry = "prepend.php"

    // php_value and not php_admin_value: the .user.ini of a site with its own prepend file still
    // wins, for example the firewall of Wordfence (owner answer 3).
    public static func fpmConfig(socket: URL, pidFile: URL, prepend: URL? = nil) throws -> String {
        let config = try poolConfig(socket: socket, pidFile: pidFile)

        guard let prepend else {
            return config
        }

        return config + "php_value[auto_prepend_file] = \(try ConfigText.quoted(prepend))\n"
    }

    private static func poolConfig(socket: URL, pidFile: URL) throws -> String {
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

    public static func dumpsIni(stub: URL) throws -> String {
        """
        ; Nexus writes this file. The nexus command and the background processes read it.
        auto_prepend_file = \(try ConfigText.quoted(stub))

        """
    }

    // The stub holds the settings of the dump viewer and one require of the library. The four
    // switches say which kinds PHP sends. An older stub has no switches. PHP then sends only dumps.
    public static func dumpStub(settings: DumpSettings, socket: URL, folder: URL, library: URL, userPrepend: String?) throws -> String {
        let prepend = try userPrepend.map(phpString) ?? "null"

        return """
            <?php

            // Nexus writes this file. Nexus writes it again when the settings of the dump viewer change.

            namespace Nexus\\Dumps;

            const SETTINGS = [
                'version' => \(dumpStubVersion),
                'socket' => \(try phpString(socket)),
                'folder' => \(try phpString(folder)),
                'page' => \(try phpString(settings.pageMode.rawValue)),
                'dumps' => \(phpBool(settings.catchDumps)),
                'queries' => \(phpBool(settings.catchQueries)),
                'logs' => \(phpBool(settings.catchLogs)),
                'jobs' => \(phpBool(settings.catchJobs)),
                'userPrepend' => \(prepend),
            ];

            require \(try phpString(library.appending(path: dumpLibraryEntry)));

            """
    }

    // The pool and dumps.d replace the prepend file of php.ini and of the custom lines. So the stub
    // includes that file first. The custom lines come after php.ini. The last line wins, as in PHP.
    // An empty value or a word such as none turns the prepend file off.
    public static func userPrepend(phpIni: String, customLines: [String]) -> String? {
        let lines = phpIni.split(whereSeparator: \.isNewline) + customLines.map { Substring($0) }
        let value = lines.compactMap { iniValue(of: "auto_prepend_file", in: $0) }.last

        guard let value else {
            return nil
        }

        return value.isEmpty ? nil : value
    }

    // A .user.ini wins over the pool of PHP-FPM. Each value of the key replaces the stub of Nexus,
    // also an empty value. So Nexus then catches no dumps of the site.
    public static func setsPrependFile(userIni: String) -> Bool {
        userIni.split(whereSeparator: \.isNewline).contains { line in iniValue(of: "auto_prepend_file", in: line) != nil }
    }

    // PHP reads the value without its quotes. A value without quotes ends at a comment. A word such
    // as off gives an empty value.
    private static func iniValue(of key: String, in line: Substring) -> String? {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)

        guard parts.count == 2 else {
            return nil
        }

        guard parts[0].trimmingCharacters(in: .whitespaces) == key else {
            return nil
        }

        let value = parts[1].trimmingCharacters(in: .whitespaces)

        if let quote = value.first, "\"'".contains(quote) {
            return String(value.dropFirst().prefix { $0 != quote })
        }

        let plain = value.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
        return ["none", "null", "off", "no", "false"].contains(plain.lowercased()) ? "" : plain
    }

    private static func phpString(_ url: URL) throws -> String {
        try phpString(RealPath.trimmed(url.path(percentEncoded: false)))
    }

    // A line break or another control character is refused, as in mailLines.
    private static func phpString(_ text: String) throws -> String {
        guard text.rangeOfCharacter(from: CharacterSet.controlCharacters.union(.newlines)) == nil else {
            throw ConfigError.unsafePath(text)
        }

        return PHPString.quoted(text)
    }

    private static func phpBool(_ value: Bool) -> String {
        value ? "true" : "false"
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

    // mail() of PHP gives each mail to the mail service of Nexus, never to the sendmail of macOS
    // (Phase 3, 3b). PHP runs sendmail_path with /bin/sh, so the path of the command is in single
    // quotes for the space in Application Support. Symfony Mailer with native://default refuses a
    // sendmail_path without -t, so the flags of the old default stay. The X header names the
    // script that sent the mail.
    public static func mailLines(command: URL, smtpPort: Int) throws -> [String] {
        let path = command.path(percentEncoded: false)

        guard path.rangeOfCharacter(from: CharacterSet(charactersIn: "'\"\\$").union(.controlCharacters).union(.newlines)) == nil else {
            throw ConfigError.unsafePath(path)
        }

        return [
            "sendmail_path = \"'\(path)' sendmail -S 127.0.0.1:\(smtpPort) -t -i\"",
            "mail.add_x_header = On",
        ]
    }

    public static func nexusIni(extensionDirectory: URL, extensions: [String], mailLines: [String] = []) throws -> String {
        var lines = [
            "; Nexus writes this file for the extension toggles and the mail service. Change the php.ini in the folder above.",
            "extension_dir = \(try ConfigText.quoted(extensionDirectory))",
        ] + mailLines

        for name in extensions {
            lines.append(zendExtensions.contains(name) ? "zend_extension = \(name)" : "extension = \(name)")
        }

        if extensions.contains("pcov") {
            lines.append("pcov.enabled = 0")
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
