import Foundation

// The configuration of one PHP version. php.ini belongs to the user: Nexus writes it one time and
// then leaves it alone. conf.d/00-nexus.ini belongs to Nexus and holds the extension toggles
// (D27). PHP reads the conf.d folder after php.ini through PHP_INI_SCAN_DIR.
public enum PHPConfig {
    public static let zendExtensions: Set<String> = ["opcache", "xdebug"]

    // An extension that needs another one loads after it.
    public static let dependencies: [String: [String]] = ["redis": ["igbinary"]]

    public static let defaultExtensions: Set<String> = ["opcache", "apcu", "igbinary", "redis", "imagick", "pgsql", "pdo_pgsql", "yaml"]

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
        var loaded = enabled.intersection(available)

        for (name, required) in dependencies where loaded.contains(name) {
            guard required.allSatisfy(available.contains) else {
                loaded.remove(name)
                continue
            }
            loaded.formUnion(required)
        }

        let first = Set(dependencies.values.flatMap { $0 })
        return loaded.sorted { left, right in
            (first.contains(left) ? 0 : 1, left) < (first.contains(right) ? 0 : 1, right)
        }
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
