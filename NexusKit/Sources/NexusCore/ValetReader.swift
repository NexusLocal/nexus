import Foundation

// What Laravel Valet has on this Mac (group 9, "Move from Valet"). Valet keeps the files of Herd in
// ~/.config/valet. Its PHP is the PHP of Homebrew, so the default PHP and the php.ini lines come
// from Homebrew.
public enum ValetReader {
    public static let homebrewFolders = ["/opt/homebrew", "/usr/local"].map { URL(filePath: $0, directoryHint: .isDirectory) }

    public static func folder(home: URL) -> URL {
        home.appending(path: ".config/valet", directoryHint: .isDirectory)
    }

    public static func certificate(home: URL) -> URL {
        folder(home: home).appending(path: "CA/LaravelValetCASelfSigned.pem")
    }

    // Composer 2 keeps its global packages in ~/.composer or in ~/.config/composer.
    public static func stubs(home: URL) -> URL? {
        [".composer", ".config/composer"]
            .map { home.appending(path: "\($0)/vendor/laravel/valet/cli/stubs", directoryHint: .isDirectory) }
            .first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    public static func homebrew() -> URL? {
        homebrewFolders.first { FileManager.default.fileExists(atPath: $0.appending(path: "bin/brew").path(percentEncoded: false)) }
    }

    public static func read(home: URL) -> HerdSetup? {
        read(valet: folder(home: home), stubs: stubs(home: home), homebrew: homebrew())
    }

    // nil when Valet has no configuration on this Mac.
    public static func read(valet: URL, stubs: URL?, homebrew: URL?) -> HerdSetup? {
        guard let data = try? Data(contentsOf: valet.appending(path: "config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let sitesFolder = valet.appending(path: "Sites", directoryHint: .isDirectory)

        return HerdSetup(
            tld: config["tld"] as? String ?? "test",
            parkedFolders: HerdReader.parkedFolders(config["paths"] as? [String] ?? [], without: sitesFolder),
            links: HerdReader.links(in: sitesFolder),
            siteFiles: HerdReader.siteFiles(in: valet.appending(path: "Nginx", directoryHint: .isDirectory), templates: stubs.map(StubTemplates.init(folder:))),
            defaultPHP: homebrew.flatMap(defaultPHP(homebrew:)),
            phpIniLines: homebrew.map { phpIniLines(homebrew: $0, valet: valet) } ?? [:]
        )
    }

    // bin/php points to the linked formula, for example ../Cellar/php@8.5/8.5.13/bin/php.
    static func defaultPHP(homebrew: URL) -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: homebrew.appending(path: "bin/php").path(percentEncoded: false)),
              let match = target.firstMatch(of: #/Cellar/php(?:@[\d.]+)?/(\d+)\.(\d+)[^/]*/bin/php$/#) else {
            return nil
        }

        return "\(match.1).\(match.2)"
    }

    // The lines that differ from the php.ini of the Homebrew bottle, and the memory limits that
    // Valet writes. The other files in conf.d load extensions of Homebrew or name the log of Valet.
    static func phpIniLines(homebrew: URL, valet: URL) -> [String: [String]] {
        let etc = homebrew.appending(path: "etc/php", directoryHint: .isDirectory)
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: etc.path(percentEncoded: false))) ?? []).filter { $0.wholeMatch(of: #/\d+\.\d+/#) != nil }
        var result: [String: [String]] = [:]

        for version in versions {
            let folder = etc.appending(path: version, directoryHint: .isDirectory)
            let current = iniValues(text(folder.appending(path: "php.ini")))
            let original = originalIni(version: version, homebrew: homebrew).map(iniValues)
            var values = original.map { original in current.filter { line in original.last { $0.key == line.key }?.value != line.value } } ?? []
            values += iniValues(text(folder.appending(path: "conf.d/php-memory-limits.ini")))

            let paths = [valet, homebrew].map { $0.path(percentEncoded: false) }
            var lines: [(key: String, line: String)] = []

            for value in values where !paths.contains(where: { value.value.contains($0) }) {
                lines.removeAll { $0.key == value.key }
                lines.append((value.key, "\(value.key)=\(value.value)"))
            }

            if !lines.isEmpty {
                result[version] = lines.map(\.line)
            }
        }

        return result
    }

    static func originalIni(version: String, homebrew: URL) -> String? {
        ["php@\(version)", "php"]
            .map { homebrew.appending(path: "opt/\($0)/.bottle/etc/php/\(version)/php.ini") }
            .lazy
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .first
    }

    static func text(_ file: URL) -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    // The last value of each key, in the order of the file. An extension of Homebrew does not load
    // in the PHP of Nexus, so extension lines stay out.
    static func iniValues(_ text: String) -> [(key: String, value: String)] {
        var values: [(key: String, value: String)] = []

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)

            guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("["), let equals = line.firstIndex(of: "=") else {
                continue
            }

            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)

            guard key != "extension", key != "zend_extension" else {
                continue
            }

            values.removeAll { $0.key == key }
            values.append((key, value))
        }

        return values
    }
}
