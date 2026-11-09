import Foundation
import NexusConfig
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor
import Synchronization

// What nexusd knows of a backup after it read it. The import uses it again, so the backup is read
// one time.
struct SiteBackupPlan: Sendable {
    enum Kind: Sendable {
        case archive
        case wpress
        case folder
    }

    let source: URL
    let kind: Kind
    let layout: BackupLayout
    // The paths of the archive as tar lists them, for a path in the layout.
    let archivePaths: [String: String]
    let wpressEntries: [WpressArchive.Entry]
    // nil when the dump has no options table. Then the wp-config.php of the backup keeps its prefix.
    let prefix: String?
    // .wpress writes SERVMASK_PREFIX_ in place of the table prefix (3f).
    let replacesPrefix: Bool
    let siteURL: String?
    let wordPressVersion: String?
    let dumpBytes: Int64
    // The dump of .wpress has no theme and no active plugins. Its package.json has them, and the
    // importer of the plugin sets them again (3f).
    var theme: (template: String, stylesheet: String)?
    var plugins: [String] = []

    var reader: BackupFileReader {
        BackupFileReader(source: source, kind: kind, archivePaths: archivePaths, wpressEntries: wpressEntries)
    }
}

// The size and the date of a backup file. For a folder also those of its dumps, because a new dump
// does not change the date of the folder.
struct BackupStamp: Sendable, Equatable {
    let dates: [Date?]
    let sizes: [Int64?]

    init(_ source: URL, kind: SiteBackupPlan.Kind, dumps: [String]) {
        let files = kind == .folder ? [source] + dumps.map { source.appending(path: $0) } : [source]
        let attributes = files.map { try? FileManager.default.attributesOfItem(atPath: $0.path(percentEncoded: false)) }

        dates = attributes.map { $0?[.modificationDate] as? Date }
        sizes = attributes.map { ($0?[.size] as? NSNumber)?.int64Value }
    }
}

// The last backup that nexusd read. The sheet reads a backup, and the import then uses this plan.
struct BackupRead: Sendable {
    let path: String
    let stamp: BackupStamp
    let info: BackupInfo
    let plan: SiteBackupPlan
}

final class NewSiteNotes: Sendable {
    private let lines = Mutex<[String]>([])

    func add(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    var text: String {
        lines.withLock { $0.joined(separator: " ") }
    }
}

// An existing WordPress site from a backup (Phase 4, 3f). The import is a new WordPress site whose
// files and database come from the backup. So it has the steps, the log, Stop and "Move to trash"
// of a new site. The URLs change at the end with the code of "Change the URLs" (3d).
extension NexusEngine {
    func inspectBackup(path: String) async throws -> BackupInfo {
        try await readBackup(at: path).info
    }

    func importSite(_ request: SiteImport) async throws -> CreatedSite {
        let (info, plan) = try await readBackup(at: request.backup)

        guard let plan else {
            throw RuntimeError.unsupported(info.problem ?? BackupLayout.problem)
        }

        let site = NewSite(template: .wordpress, name: request.name, parent: request.parent, git: request.git, database: request.database)
        return try await createSite(site, importing: plan)
    }

    func readBackup(at path: String) async throws -> (info: BackupInfo, plan: SiteBackupPlan?) {
        let source = URL(filePath: path).standardizedFileURL
        let sourcePath = source.path(percentEncoded: false)

        if let last = lastBackupRead, last.path == sourcePath, last.stamp == BackupStamp(source, kind: last.plan.kind, dumps: last.plan.layout.dumps) {
            return (last.info, last.plan)
        }

        let (info, plan) = try await readBackupAgain(at: path)

        if let plan {
            lastBackupRead = BackupRead(path: sourcePath, stamp: BackupStamp(source, kind: plan.kind, dumps: plan.layout.dumps), info: info, plan: plan)
        }

        return (info, plan)
    }

    private func readBackupAgain(at path: String) async throws -> (info: BackupInfo, plan: SiteBackupPlan?) {
        let source = URL(filePath: path).standardizedFileURL
        let name = BackupName.suggested(for: path)
        var isFolder: ObjCBool = false

        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false), isDirectory: &isFolder) else {
            throw RuntimeError.unsupported("\(path) does not exist.")
        }

        let lower = source.lastPathComponent.lowercased()
        let kind: SiteBackupPlan.Kind

        if isFolder.boolValue {
            kind = .folder
        } else if lower.hasSuffix(".wpress") {
            kind = .wpress
        } else if [".zip", ".tar", ".tar.gz", ".tgz"].contains(where: lower.hasSuffix) {
            kind = .archive
        } else if BackupLayout.isDump(lower) {
            return (BackupInfo(path: path, format: nil, suggestedName: name, problem: "A dump has no files of the site. Choose the folder with wp-content and the dump, or a zip of both."), nil)
        } else {
            return (BackupInfo(path: path, format: nil, suggestedName: name, problem: "Nexus cannot read this file. Choose a .zip, .tar.gz or .wpress file, or a folder."), nil)
        }

        let entries: [BackupEntry]
        var archivePaths: [String: String] = [:]
        var wpressEntries: [WpressArchive.Entry] = []

        switch kind {
        case .archive:
            let listed = try await Self.archiveEntries(source)
            entries = listed.map(\.entry)
            archivePaths = Dictionary(listed.map { (BackupLayout.normalized($0.entry.path), $0.original) }) { first, _ in first }
        case .wpress:
            wpressEntries = try await Self.detached { try WpressArchive.entries(source) }
            entries = wpressEntries.map { BackupEntry(path: $0.header.path, size: $0.header.size, date: $0.header.date) }
        case .folder:
            entries = try await Self.detached { Self.folderEntries(source) }
        }

        let layout = kind == .wpress ? Self.wpressLayout(entries) : BackupLayout.detect(entries)

        guard let layout else {
            return (BackupInfo(path: path, format: nil, suggestedName: name, problem: BackupLayout.problem), nil)
        }

        let reader = BackupFileReader(source: source, kind: kind, archivePaths: archivePaths, wpressEntries: wpressEntries)
        let dumpBytes = layout.dumps.reduce(Int64(0)) { sum, dump in sum + (entries.first { BackupLayout.normalized($0.path) == dump }?.size ?? 0) }
        let dumpDate = entries.first { BackupLayout.normalized($0.path) == layout.dumps.first }?.date
        let dumpText = layout.dumps.count == 1 ? layout.dumps[0] : "\((layout.dumps[0] as NSString).deletingLastPathComponent)/, \(layout.dumps.count) files"
        var prefix: String?
        var siteURL: String?
        var version: String?
        var replacesPrefix = false
        var theme: (template: String, stylesheet: String)?
        var plugins: [String] = []

        if layout.hasCore {
            let file = layout.siteRoot.isEmpty ? "wp-includes/version.php" : "\(layout.siteRoot)/wp-includes/version.php"
            version = (try? await reader.text(of: file)).flatMap(Self.wordPressVersion(in:))
        }

        if kind == .wpress {
            let package = try await reader.json(of: "package.json")
            let database = package?["Database"] as? [String: Any]
            let wordPress = package?["WordPress"] as? [String: Any]

            if (package?["Encrypted"] as? Bool) == true {
                return (BackupInfo(path: path, format: .wpress, suggestedName: name, problem: "This backup has a password. Nexus cannot read it. Export the site again without \"Encrypt this backup with a password\"."), nil)
            }

            if ((package?["Compression"] as? [String: Any])?["Enabled"] as? Bool) == true {
                return (BackupInfo(path: path, format: .wpress, suggestedName: name, problem: "This backup is compressed by an extension of All-in-One WP Migration. Nexus cannot read it. Export the site again without compression."), nil)
            }

            prefix = (database?["Prefix"] as? String).flatMap(Self.safePrefix) ?? "wp_"
            siteURL = (package?["HomeURL"] as? String) ?? (package?["SiteURL"] as? String)
            version = version ?? (wordPress?["Version"] as? String)
            replacesPrefix = true
            plugins = (package?["Plugins"] as? [String]) ?? []

            if let template = package?["Template"] as? String, let stylesheet = package?["Stylesheet"] as? String, !template.isEmpty {
                theme = (template, stylesheet.isEmpty ? template : stylesheet)
            }
        } else {
            let scanned = try await scanDump(layout: layout, reader: reader)
            prefix = scanned.prefix.flatMap(Self.safePrefix)
            siteURL = scanned.url
        }

        if version == nil, let meta = layout.metaFile, meta.hasSuffix("meta.json") {
            version = try? await reader.json(of: meta)?["wordpressVersion"] as? String
        }

        if siteURL == nil, let meta = layout.metaFile, meta.hasSuffix("meta.json") {
            siteURL = try? await reader.json(of: meta)?["siteUrl"] as? String
        }

        // Without a wp-config.php in the backup, Nexus writes one with the prefix wp_.
        let tablePrefix = prefix ?? (layout.hasConfig ? nil : "wp_")
        let info = BackupInfo(path: path, format: layout.format, wordPressVersion: version, hasCore: layout.hasCore, dump: dumpText, dumpBytes: dumpBytes, dumpDate: dumpDate, tablePrefix: tablePrefix, siteURL: siteURL, suggestedName: name)
        let plan = SiteBackupPlan(source: source, kind: kind, layout: layout, archivePaths: archivePaths, wpressEntries: wpressEntries, prefix: tablePrefix, replacesPrefix: replacesPrefix, siteURL: siteURL, wordPressVersion: version, dumpBytes: dumpBytes, theme: theme, plugins: plugins)

        return (info, plan)
    }

    // The URLs change after the site is added, because "Change the URLs" (3d) works on a site of
    // Nexus. That code also changes each site of a network and WP_HOME of the configuration.
    func importSteps(_ context: NewSiteContext, plan: SiteBackupPlan) async throws -> [NewSiteStep] {
        let wpCLI = try await wpCLITool(php: context.php?.line ?? "")
        let other = context.work.appending(path: ".backup", directoryHint: .isDirectory)
        let project = context.project.path(percentEncoded: false)
        var steps = [NewSiteStep(title: "Unpack the backup") {
            try await self.unpackBackup(plan, context: context, other: other)
        }]

        if !plan.layout.hasCore {
            steps.append(NewSiteStep(title: "WordPress download") {
                let version = plan.wordPressVersion.map { ["--version=\($0)"] } ?? []
                try await self.runWP(["core", "download", "--skip-content", "--path=\(project)"] + version, wpCLI: wpCLI, context: context)
            })
        }

        steps += databaseSteps(context)

        if let database = context.database {
            steps.append(NewSiteStep(title: "Dump into \(database.name)") {
                try await self.importDump(plan, into: database, context: context, other: other)
            })
        }

        steps.append(NewSiteStep(title: "wp-config.php") {
            try await self.writeImportedConfig(plan, wpCLI: wpCLI, context: context)

            if plan.kind == .wpress {
                try await self.activateBackupTheme(plan, wpCLI: wpCLI, context: context)
            }
        })

        if context.site.git {
            steps.append(NewSiteStep(title: "Git repository with a first commit") {
                try await self.makeRepository(context)
            })
        }

        steps.append(NewSiteStep(title: "Site on \(context.url)") {
            try await self.addNewSite(context)
        })
        steps.append(NewSiteStep(title: plan.siteURL.map { "URLs: \($0) to \(context.url)" } ?? "URLs of the site") {
            try await self.changeImportedURLs(context)
        })

        return steps
    }

    // The site goes to the folder of the tool. The dumps and the files of the backup tool stay in
    // other, outside the site.
    private func unpackBackup(_ plan: SiteBackupPlan, context: NewSiteContext, other: URL) async throws {
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let project = context.project
        let root = plan.layout.siteRoot

        switch plan.kind {
        case .archive:
            let command = Command(executable: URL(filePath: "/usr/bin/tar"), arguments: ["-xf", plan.source.path(percentEncoded: false), "-C", other.path(percentEncoded: false)], name: "tar")
            try await runLogged(command, display: "tar -xf \(plan.source.lastPathComponent)", context: context)

            if root.isEmpty {
                let kept = Set(plan.layout.dumps.compactMap { $0.split(separator: "/").first.map(String.init) } + ["meta.json", "studio.json", "local-site.json"])
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

                for item in try FileManager.default.contentsOfDirectory(at: other, includingPropertiesForKeys: nil) where !kept.contains(item.lastPathComponent) {
                    try FileManager.default.moveItem(at: item, to: project.appending(path: item.lastPathComponent))
                }
            } else {
                try FileManager.default.moveItem(at: other.appending(path: root), to: project)
            }
        case .wpress:
            Self.appendToLog("Nexus unpacks \(plan.source.lastPathComponent) into wp-content.\n", context.log)
            try await Self.detached {
                try WpressArchive.extract(plan.source, entries: plan.wpressEntries, wpContent: project.appending(path: "wp-content", directoryHint: .isDirectory), other: other)
            }
        case .folder:
            let source = root.isEmpty ? plan.source : plan.source.appending(path: root)
            let skipped = Self.backupFilesInSite(plan.layout)
            Self.appendToLog("Nexus copies \(Self.shortPath(source)) without \(Self.skippedFolders.sorted().joined(separator: ", ")) and the dump.\n", context.log)
            try await Self.detached {
                try Self.copyFolder(source, to: project, skipping: skipped)
            }
        }
    }

    // The dumps and the files of the backup tool at the root of the site. Their first folder stays
    // out of the site, for example sql/ of Jetpack.
    static func backupFilesInSite(_ layout: BackupLayout) -> Set<String> {
        Set(layout.dumps.compactMap { pathInSite($0, root: layout.siteRoot)?.split(separator: "/").first.map(String.init) } + ["meta.json", "studio.json", "local-site.json"])
    }

    // The site gets a repository of its own. A repository inside it would go into that repository
    // as a link without its files. node_modules is only for a build.
    static let skippedFolders: Set<String> = [".git", "node_modules"]

    // File by file, so a stop reaches the copy at its next file. skipped holds paths at the root.
    static func copyFolder(_ source: URL, to target: URL, skipping skipped: Set<String>) throws {
        guard let enumerator = FileManager.default.enumerator(atPath: source.path(percentEncoded: false)) else {
            throw RuntimeError.unsupported("Nexus cannot read \(shortPath(source)).")
        }

        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        while let relative = enumerator.nextObject() as? String {
            try Task.checkCancellation()

            let isFolder = enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory
            let isSkippedFolder = isFolder && skippedFolders.contains((relative as NSString).lastPathComponent)

            if skipped.contains(relative) || isSkippedFolder {
                if isFolder {
                    enumerator.skipDescendants()
                }

                continue
            }

            let destination = target.appending(path: relative)

            if isFolder {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try FileManager.default.copyItem(at: source.appending(path: relative), to: destination)
            }
        }
    }

    // A dump in the folder of a zipped site moved with the site. A folder is read where it is.
    static func dumpFile(_ dump: String, plan: SiteBackupPlan, project: URL, other: URL) -> URL {
        switch plan.kind {
        case .folder:
            return plan.source.appending(path: dump)
        case .wpress:
            return other.appending(path: dump)
        case .archive:
            if !plan.layout.siteRoot.isEmpty, let inSite = pathInSite(dump, root: plan.layout.siteRoot) {
                return project.appending(path: inSite)
            }

            return other.appending(path: dump)
        }
    }

    static func pathInSite(_ dump: String, root: String) -> String? {
        if root.isEmpty {
            return dump
        }

        return dump.hasPrefix(root + "/") ? String(dump.dropFirst(root.count + 1)) : nil
    }

    private func importDump(_ plan: SiteBackupPlan, into database: NewSiteDatabase, context: NewSiteContext, other: URL) async throws {
        let files = plan.layout.dumps.map { Self.dumpFile($0, plan: plan, project: context.project, other: other).path(percentEncoded: false) }

        // A dump in the folder of the site is a copy. A web server must not serve it.
        defer {
            for dump in plan.layout.dumps {
                if let inSite = Self.pathInSite(dump, root: plan.layout.siteRoot) {
                    try? FileManager.default.removeItem(at: context.project.appending(path: inSite))
                }
            }
        }

        let (tools, client, work) = try await runningClient(database.instance.id)
        defer { try? FileManager.default.removeItem(at: work) }

        let reader = Command(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", #"for f in "$@"; do case "$f" in *.gz|*.GZ) /usr/bin/gzip -dc "$f" || exit 1;; *) /bin/cat "$f" || exit 1;; esac; done"#, "reader"] + files,
            name: "the dump"
        )
        let restore = Command(
            executable: URL(filePath: "/bin/bash"),
            arguments: ["-c", #"set -o pipefail; LC_ALL=C /usr/bin/sed -E "$1" | "$2" "${@:3}""#, "restore", Self.importFilter(prefix: plan.replacesPrefix ? plan.prefix ?? "wp_" : nil, toMySQL: tools.kind == .mysql), tools.client.path(percentEncoded: false), "--defaults-file=\(client.options.path(percentEncoded: false))", "--default-character-set=utf8mb4", "--init-command=\(Self.importSession)", database.name],
            name: tools.client.lastPathComponent
        )

        let total = files.contains { $0.lowercased().hasSuffix(".gz") } ? nil : plan.dumpBytes
        let progress = context.progress
        let counted = Mutex<Int64>(0)

        Self.appendToLog("$ \(tools.client.lastPathComponent) \(database.name) < \(plan.layout.dumps.joined(separator: " "))\n", context.log)
        try await CommandRunner.pipe(reader, into: restore) { data in
            let done = counted.withLock { value in
                value += Int64(data.count)
                return value
            }

            let text = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
            progress.update { $0.stepDetail = total.map { "\(text) of \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? text }
        }
    }

    // mysqldump writes these settings at the start of its dump. The dump of All-in-One WP Migration
    // has none, and its zero dates such as '0000-00-00 00:00:00' then fail in the strict mode of
    // MySQL 8.
    static let importSession = "SET SESSION sql_mode='NO_AUTO_VALUE_ON_ZERO', FOREIGN_KEY_CHECKS=0, UNIQUE_CHECKS=0"

    // A dump can switch to its own database with USE, or make or drop one. That would write into
    // another database of the instance, so these lines go, in each case and also in the versioned
    // comment of mysqldump --add-drop-database. The prefix of .wpress goes back, and a dump of
    // MariaDB gets the changes for MySQL as in a copy.
    static func importFilter(prefix: String?, toMySQL: Bool) -> String {
        var filter = #"/^[[:space:]]*use([[:space:]]+|`)[^;]*;[[:space:]]*$/Id; /^[[:space:]]*(\/\*![0-9]+[[:space:]]*)?(create|drop)[[:space:]]+(database|schema)([[:space:]]|`)/Id; "#

        if let prefix {
            filter += "s/SERVMASK_PREFIX_/\(prefix)/g; "
        }

        return toMySQL ? filter + DatabaseConfig.mariadbToMySQLFilter : filter
    }

    // A wp-config.php of the backup keeps its salts and settings. Only the database values change.
    private func writeImportedConfig(_ plan: SiteBackupPlan, wpCLI: ToolCommand, context: NewSiteContext) async throws {
        guard let database = context.database else {
            throw RuntimeError.unsupported("WordPress needs a MySQL or MariaDB of Nexus.")
        }

        let path = "--path=\(context.project.path(percentEncoded: false))"
        let host = "127.0.0.1:\(database.instance.port)"

        guard FileManager.default.fileExists(atPath: context.project.appending(path: "wp-config.php").path(percentEncoded: false)) else {
            let shared = ["config", "create", path, "--dbname=\(database.name)", "--dbuser=\(database.account.user)", "--dbhost=\(host)", "--dbprefix=\(plan.prefix ?? "wp_")", "--skip-check"]
            try await runWP(shared + ["--dbpass=\(database.account.password)"], wpCLI: wpCLI, context: context, display: "wp \((shared + ["--dbpass=…"]).joined(separator: " "))")
            try await runWP(["config", "set", "WP_ENVIRONMENT_TYPE", "local", "--type=constant", path], wpCLI: wpCLI, context: context)
            return
        }

        for (key, value) in [("DB_NAME", database.name), ("DB_USER", database.account.user), ("DB_HOST", host), ("WP_ENVIRONMENT_TYPE", "local")] {
            try await runWP(["config", "set", key, value, "--type=constant", path], wpCLI: wpCLI, context: context)
        }

        // WP-CLI prints the new value after a change. --quiet keeps the password out of the log.
        try await runWP(["config", "set", "DB_PASSWORD", database.account.password, "--type=constant", "--quiet", path], wpCLI: wpCLI, context: context, display: "wp config set DB_PASSWORD … --type=constant --quiet")

        guard let prefix = plan.prefix else {
            Self.appendToLog("The dump has no options table. So table_prefix of wp-config.php stays.\n", context.log)
            return
        }

        try await runWP(["config", "set", "table_prefix", prefix, "--type=variable", path], wpCLI: wpCLI, context: context)
    }

    // The theme and the plugins of package.json, as the importer of All-in-One WP Migration sets them.
    private func activateBackupTheme(_ plan: SiteBackupPlan, wpCLI: ToolCommand, context: NewSiteContext) async throws {
        let path = "--path=\(context.project.path(percentEncoded: false))"
        let quiet = ["--skip-plugins", "--skip-themes", path]

        if let theme = plan.theme {
            try await runWP(["option", "update", "template", theme.template] + quiet, wpCLI: wpCLI, context: context)
            try await runWP(["option", "update", "stylesheet", theme.stylesheet] + quiet, wpCLI: wpCLI, context: context)
        }

        let plugins = String(decoding: try JSONSerialization.data(withJSONObject: plan.plugins), as: UTF8.self)
        try await runWP(["option", "update", "active_plugins", plugins, "--format=json"] + quiet, wpCLI: wpCLI, context: context)
    }

    // Without a plan the URLs are right only when Nexus could read the home option.
    private func changeImportedURLs(_ context: NewSiteContext) async throws {
        let info = try await wordPressSite(host: context.host)

        if let problem = info.problem {
            throw RuntimeError.unsupported("Nexus cannot check the URLs of the site. \(problem)")
        }

        guard info.databaseExists == true else {
            throw RuntimeError.unsupported("Nexus does not find the database \(info.database ?? "") of wp-config.php on \(info.instance ?? "an instance of Nexus"). So it cannot change the URLs.")
        }

        guard info.home != nil else {
            throw RuntimeError.unsupported("Nexus cannot read the home option in the database \(info.database ?? ""). Is table_prefix in wp-config.php the prefix of the tables in the dump?")
        }

        guard let plan = info.urlPlan else {
            context.notes.add("The URLs of the backup were the URLs of Nexus already.")
            return
        }

        let message = try await changeWordPressURLs(host: context.host, plan: plan)
        Self.appendToLog("\(message)\n", context.log)
        context.notes.add(message)
    }

    // Large files are listed and copied outside the actor, so nexusd answers other requests
    // meanwhile. A stop reaches the copy at its next file.
    static func detached<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(operation: work)

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func wpressLayout(_ entries: [BackupEntry]) -> BackupLayout? {
        let paths = Set(entries.map(\.path))

        guard paths.contains("package.json"), paths.contains("database.sql") else {
            return nil
        }

        return BackupLayout(format: .wpress, siteRoot: "", dumps: ["database.sql"], hasCore: false, hasConfig: false, metaFile: "package.json")
    }

    static func wordPressVersion(in text: String) -> String? {
        text.firstMatch(of: /\$wp_version\s*=\s*'([^']+)'/).map { String($0.output.1) }
    }

    static func safePrefix(_ prefix: String) -> String? {
        guard !prefix.isEmpty, prefix.count <= 40, prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            return nil
        }

        return prefix
    }

    private func scanDump(layout: BackupLayout, reader: BackupFileReader) async throws -> DumpScanner {
        var scanner = DumpScanner()

        try await reader.streamText(layout.optionsDump, maximumBytes: 2_000_000_000) { text in
            scanner.scan(text)
            return !scanner.isComplete
        }

        return scanner
    }

    // tar of macOS reads zip files too. The size is the fifth column and the name starts at the
    // ninth one.
    static func archiveEntries(_ archive: URL) async throws -> [(entry: BackupEntry, original: String)] {
        let output: CommandOutput

        do {
            output = try await CommandRunner.run(Command(executable: URL(filePath: "/usr/bin/tar"), arguments: ["-tvf", archive.path(percentEncoded: false)], name: "tar"))
        } catch {
            throw RuntimeError.unsupported("Nexus cannot read \(archive.lastPathComponent). Is it a whole zip or tar file? \(ErrorText.plain(error))")
        }

        return output.standardOutput.split(separator: "\n").compactMap { line in
            let columns = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)

            guard columns.count == 9 else {
                return nil
            }

            let original = String(columns[8])
            let isFolder = columns[0].hasPrefix("d")
            let path = isFolder && !original.hasSuffix("/") ? original + "/" : original
            return (BackupEntry(path: path, size: Int64(columns[4]) ?? 0), original)
        }
    }

    // A folder can be a whole site with a large wp-content. The layout needs only the top levels and
    // the dumps.
    static func folderEntries(_ folder: URL) -> [BackupEntry] {
        var entries: [BackupEntry] = []

        // The enumerator of a path gives relative paths. A URL can come back as /private/tmp for
        // /tmp, and then a path relative to the folder is wrong.
        guard let enumerator = FileManager.default.enumerator(atPath: folder.path(percentEncoded: false)) else {
            return []
        }

        while let relative = enumerator.nextObject() as? String {
            let attributes = enumerator.fileAttributes
            let depth = relative.split(separator: "/").count

            if attributes?[.type] as? FileAttributeType == .typeDirectory {
                entries.append(BackupEntry(path: relative + "/"))

                let name = (relative as NSString).lastPathComponent

                if depth >= 3 || name == "wp-content" || name == "node_modules" || name == ".git" {
                    enumerator.skipDescendants()
                }
            } else {
                entries.append(BackupEntry(path: relative, size: (attributes?[.size] as? NSNumber)?.int64Value ?? 0, date: attributes?[.modificationDate] as? Date))
            }
        }

        return entries
    }
}

// Reads one file of a backup: a zip or tar file through tar, a .wpress archive from its offset, or a
// file of a folder.
struct BackupFileReader: Sendable {
    let source: URL
    let kind: SiteBackupPlan.Kind
    let archivePaths: [String: String]
    let wpressEntries: [WpressArchive.Entry]

    func text(of path: String) async throws -> String {
        var data = Data()

        try await streamData(path, maximumBytes: 4_000_000) { chunk in
            data.append(chunk)
            return true
        }

        return String(decoding: data, as: UTF8.self)
    }

    func json(of path: String) async throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: Data(try await text(of: path).utf8)) as? [String: Any]
    }

    func streamText(_ path: String, maximumBytes: Int64, _ handle: (String) -> Bool) async throws {
        try await streamData(path, maximumBytes: maximumBytes) { data in
            handle(String(decoding: data, as: UTF8.self))
        }
    }

    // A dump with .gz goes through gzip. handle returns false when it has what it needs.
    func streamData(_ path: String, maximumBytes: Int64, _ handle: (Data) -> Bool) async throws {
        let compressed = path.lowercased().hasSuffix(".gz")

        switch kind {
        case .wpress:
            guard let entry = wpressEntries.first(where: { $0.header.path == path }) else {
                throw RuntimeError.unsupported("The backup has no \(path).")
            }

            let file = try FileHandle(forReadingFrom: source)
            defer { try? file.close() }
            try file.seek(toOffset: entry.offset)
            var left = min(entry.header.size, maximumBytes)

            while left > 0 {
                let chunk = try file.read(upToCount: Int(min(left, 1 << 20))) ?? Data()

                guard !chunk.isEmpty, handle(chunk) else {
                    return
                }

                left -= Int64(chunk.count)
            }
        case .archive:
            let original = archivePaths[path] ?? path
            var commands = [Command(executable: URL(filePath: "/usr/bin/tar"), arguments: ["-xOf", source.path(percentEncoded: false), original], name: "tar")]

            if compressed {
                commands.append(Command(executable: URL(filePath: "/usr/bin/gzip"), arguments: ["-dc"], name: "gzip"))
            }

            try await ProcessStream.read(commands, maximumBytes: maximumBytes, handle)
        case .folder:
            let file = source.appending(path: path)

            if compressed {
                try await ProcessStream.read([Command(executable: URL(filePath: "/usr/bin/gzip"), arguments: ["-dc", file.path(percentEncoded: false)], name: "gzip")], maximumBytes: maximumBytes, handle)
                return
            }

            let reader = try FileHandle(forReadingFrom: file)
            defer { try? reader.close() }
            var total: Int64 = 0

            while total < maximumBytes, let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                total += Int64(chunk.count)

                guard handle(chunk) else {
                    return
                }
            }
        }
    }
}

// The files of a .wpress archive with the offset of their content.
enum WpressArchive {
    struct Entry: Sendable {
        let header: WpressHeader
        let offset: UInt64
    }

    static func entries(_ archive: URL) throws -> [Entry] {
        let file = try FileHandle(forReadingFrom: archive)
        defer { try? file.close() }

        let size = try file.seekToEnd()
        var offset: UInt64 = 0
        var entries: [Entry] = []

        while offset + UInt64(WpressHeader.length) <= size {
            try file.seek(toOffset: offset)

            guard let data = try file.read(upToCount: WpressHeader.length), let header = WpressHeader.parse(data) else {
                break
            }

            let content = offset + UInt64(WpressHeader.length)

            guard header.size >= 0, content + UInt64(header.size) <= size else {
                throw RuntimeError.unsupported("\(archive.lastPathComponent) ends in the middle of \(header.path). The download is not complete.")
            }

            entries.append(Entry(header: header, offset: content))
            offset = content + UInt64(header.size)
        }

        return entries
    }

    // Each file goes to its place below the folder. package.json and database.sql go to other.
    static func extract(_ archive: URL, entries: [Entry], wpContent: URL, other: URL) throws {
        let file = try FileHandle(forReadingFrom: archive)
        defer { try? file.close() }

        for entry in entries {
            let path = entry.header.path

            guard BackupLayout.isSafe(path) else {
                throw RuntimeError.unsupported("The backup has a file outside its folder: \(path)")
            }

            let target = ["package.json", "database.sql", "multisite.json"].contains(path) ? other.appending(path: path) : wpContent.appending(path: path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

            guard FileManager.default.createFile(atPath: target.path(percentEncoded: false), contents: nil) else {
                throw RuntimeError.unsupported("Nexus cannot write \(target.path(percentEncoded: false)).")
            }

            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            try file.seek(toOffset: entry.offset)
            var left = entry.header.size

            while left > 0 {
                try Task.checkCancellation()
                let chunk = try file.read(upToCount: Int(min(left, 1 << 20))) ?? Data()

                guard !chunk.isEmpty else {
                    break
                }

                try output.write(contentsOf: chunk)
                left -= Int64(chunk.count)
            }
        }
    }
}

// Reads the output of one program, or of two programs in a pipe, part by part. When the reader has
// what it needs, the programs stop. So a scan of a large dump ends at the options table.
enum ProcessStream {
    static func read(_ commands: [Command], maximumBytes: Int64, _ handle: (Data) -> Bool) async throws {
        var processes: [Process] = []
        var input: Pipe?

        for command in commands {
            let process = Process()
            process.executableURL = command.executable
            process.arguments = command.arguments
            process.environment = ChildEnvironment.base().merging(command.environment) { _, own in own }
            process.standardInput = input ?? FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            processes.append(process)
            input = output
        }

        defer {
            for process in processes where process.isRunning {
                process.terminate()
            }
        }

        guard let reader = input?.fileHandleForReading else {
            return
        }

        var total: Int64 = 0

        while total < maximumBytes {
            try Task.checkCancellation()
            let chunk = try await Task.detached { try reader.read(upToCount: 1 << 20) }.value ?? Data()

            guard !chunk.isEmpty else {
                break
            }

            total += Int64(chunk.count)

            guard handle(chunk) else {
                break
            }
        }
    }
}
