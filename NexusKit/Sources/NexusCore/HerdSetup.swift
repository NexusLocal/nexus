import Foundation

// What Laravel Herd has on this Mac (group 9, docs/group9-herd.md). Nexus reads only files and
// needs no Herd process. The CLI of Herd is a fork of Laravel Valet 4, so the layout is the
// layout of Valet: config.json, Sites, Nginx and Certificates.
public struct HerdSetup: Sendable, Equatable {
    // A linked site. Each symlink in Sites is one name. More names for one folder are aliases.
    public struct Link: Sendable, Equatable {
        public let names: [String]
        public let folder: URL

        public init(names: [String], folder: URL) {
            self.names = names
            self.folder = folder
        }
    }

    // The nginx file of one site. Herd writes it only for a site with HTTPS, its own PHP version
    // or a proxy.
    public struct SiteFile: Sendable, Equatable {
        public let host: String
        public var php: String?
        public var proxy: String?
        public var secured: Bool
        public var ownLines: [String]

        public init(host: String, php: String? = nil, proxy: String? = nil, secured: Bool = false, ownLines: [String] = []) {
            self.host = host
            self.php = php
            self.proxy = proxy
            self.secured = secured
            self.ownLines = ownLines
        }
    }

    public struct Workspace: Sendable, Equatable {
        public let kind: String
        public let folder: URL
        public let site: String

        public init(kind: String, folder: URL, site: String) {
            self.kind = kind
            self.folder = folder
            self.site = site
        }
    }

    public var tld: String
    public var parkedFolders: [URL]
    public var links: [Link]
    public var siteFiles: [SiteFile]
    public var defaultPHP: String?
    public var phpIniLines: [String: [String]]
    public var workspaces: [Workspace]

    public init(tld: String = "test", parkedFolders: [URL] = [], links: [Link] = [], siteFiles: [SiteFile] = [], defaultPHP: String? = nil, phpIniLines: [String: [String]] = [:], workspaces: [Workspace] = []) {
        self.tld = tld
        self.parkedFolders = parkedFolders
        self.links = links
        self.siteFiles = siteFiles
        self.defaultPHP = defaultPHP
        self.phpIniLines = phpIniLines
        self.workspaces = workspaces
    }

    public func siteFile(of host: String) -> SiteFile? {
        siteFiles.first { $0.host == host }
    }

    public var hasSites: Bool {
        !parkedFolders.isEmpty || !links.isEmpty || !siteFiles.isEmpty
    }
}

public enum HerdReader {
    public static let bundleIdentifier = "de.beyondco.herd"
    public static let app = URL(filePath: "/Applications/Herd.app", directoryHint: .isDirectory)

    public static func folder(home: URL) -> URL {
        home.appending(path: "Library/Application Support/Herd", directoryHint: .isDirectory)
    }

    // nil when Herd has no configuration on this Mac. The stubs of the Herd app let Nexus find
    // the lines that the user added to a site file. Without them, a site file has no own lines.
    public static func read(herd: URL, stubs: URL? = app.appending(path: "Contents/Resources/valet/cli/stubs")) -> HerdSetup? {
        let valet = herd.appending(path: "config/valet", directoryHint: .isDirectory)

        guard let data = try? Data(contentsOf: valet.appending(path: "config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let sitesFolder = valet.appending(path: "Sites", directoryHint: .isDirectory)
        let templates = stubs.map(StubTemplates.init(folder:))

        return HerdSetup(
            tld: config["tld"] as? String ?? "test",
            parkedFolders: parkedFolders(config["paths"] as? [String] ?? [], without: sitesFolder),
            links: links(in: sitesFolder),
            siteFiles: siteFiles(in: valet.appending(path: "Nginx", directoryHint: .isDirectory), templates: templates),
            defaultPHP: defaultPHP(bin: herd.appending(path: "bin", directoryHint: .isDirectory)),
            phpIniLines: phpIniLines(in: herd.appending(path: "config/php", directoryHint: .isDirectory), herd: herd),
            workspaces: workspaces(in: valet.appending(path: "workspaces.json"))
        )
    }

    // The Sites folder of Herd is always in the list, because a link adds it. It is not a folder
    // of the user. Herd skips a folder that no longer exists, so Nexus does too.
    static func parkedFolders(_ paths: [String], without sitesFolder: URL) -> [URL] {
        paths
            .map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL }
            .filter { $0.path(percentEncoded: false) != sitesFolder.standardizedFileURL.path(percentEncoded: false) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    static func links(in sitesFolder: URL) -> [HerdSetup.Link] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: sitesFolder.path(percentEncoded: false))) ?? []).sorted()
        var folders: [(folder: URL, names: [String])] = []

        for name in names {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: sitesFolder.appending(path: name).path(percentEncoded: false)) else {
                continue
            }

            let folder = URL(filePath: target, directoryHint: .isDirectory, relativeTo: sitesFolder).standardizedFileURL

            if let index = folders.firstIndex(where: { $0.folder == folder }) {
                folders[index].names.append(name)
            } else {
                folders.append((folder, [name]))
            }
        }

        return folders.map { HerdSetup.Link(names: $0.names, folder: $0.folder) }
    }

    static func siteFiles(in nginx: URL, templates: StubTemplates?) -> [HerdSetup.SiteFile] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: nginx.path(percentEncoded: false))) ?? []).sorted()

        return names.compactMap { name in
            guard !name.hasPrefix("."), let text = try? String(contentsOf: nginx.appending(path: name), encoding: .utf8) else {
                return nil
            }

            return siteFile(host: name, text: text, templates: templates)
        }
    }

    static func siteFile(host: String, text: String, templates: StubTemplates?) -> HerdSetup.SiteFile {
        let lines = text.components(separatedBy: "\n")
        let php = lines.first { $0.hasPrefix("# ISOLATED_PHP_VERSION=") }.map { phpVersion(String($0.dropFirst("# ISOLATED_PHP_VERSION=".count))) }
        let proxy = lines.lazy.compactMap { $0.firstMatch(of: #/^\s*proxy_pass\s+([^;\s]+);/#).map { String($0.1) } }.first
        let secured = lines.contains { $0.contains("listen") && $0.contains(":443 ssl") }

        return HerdSetup.SiteFile(host: host, php: php, proxy: proxy, secured: secured, ownLines: templates?.ownLines(in: lines) ?? [])
    }

    // Herd writes 8.3, Valet writes php@8.3.
    static func phpVersion(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.replacingOccurrences(of: "php@", with: "").replacingOccurrences(of: "php", with: "")
    }

    // bin/php is a symlink to bin/php85 for the default PHP 8.5.
    static func defaultPHP(bin: URL) -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: bin.appending(path: "php").path(percentEncoded: false)),
              let match = (target as NSString).lastPathComponent.firstMatch(of: #/^php(\d)(\d+)$/#) else {
            return nil
        }

        return "\(match.1).\(match.2)"
    }

    // The lines of the user in the php.ini of each version, with the last value of each key. A line
    // with a path of Herd, for example its CA file or its dump loader, has no use in Nexus.
    static func phpIniLines(in phpFolder: URL, herd: URL) -> [String: [String]] {
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: phpFolder.path(percentEncoded: false))) ?? []).filter { $0.allSatisfy(\.isNumber) && $0.count >= 2 }
        var result: [String: [String]] = [:]

        for folder in versions {
            guard let text = try? String(contentsOf: phpFolder.appending(path: "\(folder)/php.ini"), encoding: .utf8) else {
                continue
            }

            let lines = userIniLines(text, herd: herd)

            if !lines.isEmpty {
                result["\(folder.prefix(1)).\(folder.dropFirst())"] = lines
            }
        }

        return result
    }

    static let herdIniKeys: Set<String> = ["curl.cainfo", "openssl.cafile", "pcre.jit", "output_buffering", "auto_prepend_file"]

    static func userIniLines(_ text: String, herd: URL) -> [String] {
        var values: [(key: String, line: String)] = []
        let herdPath = herd.path(percentEncoded: false)

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)

            guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("["), let equals = line.firstIndex(of: "=") else {
                continue
            }

            let key = line[..<equals].trimmingCharacters(in: .whitespaces)

            guard !herdIniKeys.contains(key), !line.contains("/Applications/Herd.app"), !line.contains(herdPath) else {
                continue
            }

            if key == "extension" || key == "zend_extension" {
                values.append((line, line))
                continue
            }

            values.removeAll { $0.key == key }
            values.append((key, line))
        }

        return values.map(\.line)
    }

    static func workspaces(in file: URL) -> [HerdSetup.Workspace] {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["workspaces"] as? [[String: Any]] else {
            return []
        }

        return list.compactMap { entry in
            guard let kind = entry["kind"] as? String, let path = entry["path"] as? String else {
                return nil
            }

            return HerdSetup.Workspace(kind: kind, folder: URL(filePath: path, directoryHint: .isDirectory), site: entry["parent_site"] as? String ?? entry["site"] as? String ?? "")
        }
    }
}

// The nginx templates of Herd. A line of a site file that matches no template line is a line of
// the user. A placeholder such as VALET_SITE or HERD_HOME_PATH matches any text, and so does a
// number, because Herd writes the upload size of its settings into each file.
struct StubTemplates {
    let patterns: [Regex<Substring>]

    init(folder: URL) {
        let files = ["site.valet.conf", "secure.valet.conf", "proxy.valet.conf", "secure.proxy.valet.conf"]
        let lines = files.flatMap { name in
            ((try? String(contentsOf: folder.appending(path: name), encoding: .utf8)) ?? "").components(separatedBy: "\n")
        }

        patterns = Set(lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }).compactMap(Self.pattern)
    }

    init(templateLines: [String]) {
        patterns = templateLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.compactMap(Self.pattern)
    }

    static func pattern(_ line: String) -> Regex<Substring>? {
        var escaped = NSRegularExpression.escapedPattern(for: line)
        escaped = escaped.replacingOccurrences(of: #"(VALET|HERD)_[A-Z_]+"#, with: ".*", options: .regularExpression)
        escaped = escaped.replacingOccurrences(of: #"\d+"#, with: #"\\d+"#, options: .regularExpression)
        escaped = escaped.replacingOccurrences(of: #"\$herd_sock"#, with: #"\$herd_sock\w*"#)
        escaped = escaped.replacingOccurrences(of: #"valet\.sock"#, with: #"valet\d*\.sock"#)
        return try? Regex("^" + escaped + "$")
    }

    func ownLines(in lines: [String]) -> [String] {
        lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && $0 != "}" && $0 != "{" }
            .filter { line in !patterns.contains { line.wholeMatch(of: $0) != nil } }
    }
}
