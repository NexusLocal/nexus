import Foundation
import NexusConfig
import NexusCore
import NexusRuntime

// The PHP library of the dump viewer and the files that load it (Parts 5 and 6 of
// docs/dump-viewer-build.md). The app holds the library. nexusd copies it to php/dumps/<hash>/.
// So the path stays the same when the app moves. An update of the app also does not change a file
// that PHP uses. Each PHP version gets a stub with the settings and a require of that copy.
extension NexusEngine {
    static let dumpLibraryHashFile = "HASH"

    // Runs inside serialWeb after applyWeb, which wrote the full configuration of the PHP versions
    // of the sites. A PHP version whose pool names its stub gets its full configuration too. So the
    // pool never names a stub that is gone. Each other PHP version gets only its stub and dumps.d,
    // for nexus php. No PHP-FPM of an earlier run is left at the start. So an old library that no
    // stub names can go.
    func prepareDumpLibrary() async {
        let written = phpLinesWrittenAtStart ?? []
        let state = await stateStore.current()
        phpLinesWrittenAtStart = nil

        for runtime in await installer.installedRuntimes() where runtime.name == "php" {
            if written.contains(runtime.line) {
                continue
            }

            guard poolNamesDumpStub(line: runtime.line) else {
                _ = writeDumpFiles(line: runtime.line, state: state, keepingStub: false)
                continue
            }

            do {
                _ = try await writePHPConfig(line: runtime.line, state: state)
            } catch {
                activity?.write("dumps", "PHP \(runtime.line) keeps its old configuration. \(ErrorText.plain(error))")
            }
        }

        removeOldDumpLibraries()
    }

    // A new setting reaches each PHP version at once. PHP-FPM reloads when its pool or its stub
    // changed. A background process starts again when its environment changed. The request runs
    // this inside serialWeb, as each other request that changes the PHP configuration. The watchers
    // then get the dump list with the new settings.
    func setDumpSettings(_ settings: DumpSettings) async throws -> String {
        try await stateStore.update { $0.dumpSettings = settings }

        let problems = await rewritePHPConfigs().map { "PHP \($0.line) keeps the old settings of the dump viewer. \(ErrorText.plain($0.error))" }
        _ = syncBackgroundProcesses()
        await publishDumpList()

        return (["The settings of the dump viewer are changed."] + problems + [dumpLibraryProblem(settings)].compactMap { $0 }).joined(separator: "\n")
    }

    // The dump list shows this text too. So it only reads and never copies the library. Before the
    // first copy nexusd knows of no problem.
    func dumpLibraryProblem(_ settings: DumpSettings) -> String? {
        guard settings.catchesAnything else {
            return nil
        }

        guard dumpLibraryIsMissing else {
            return nil
        }

        return "Nexus catches nothing from PHP, because it cannot copy the PHP library of the dump viewer from the app. The activity log has the reason."
    }

    private var dumpLibraryIsMissing: Bool {
        if dumpLibraryFailed {
            return true
        }

        guard let installedDumpLibrary else {
            return false
        }

        return !Self.hasDumpLibrary(in: installedDumpLibrary)
    }

    // A copy that someone removed or changed comes back.
    func dumpLibrary() -> URL? {
        if let installedDumpLibrary, Self.hasDumpLibrary(in: installedDumpLibrary) {
            return installedDumpLibrary
        }

        if dumpLibraryFailed {
            return nil
        }

        return installDumpLibrary()
    }

    // Config/php-files.sh names the copy with a hash of the files. So a new version gets a new
    // folder. The old folder stays for the PHP processes that still use it. The copy goes to a
    // staging folder first and gets its name in one rename. So PHP never reads half a library.
    private func installDumpLibrary() -> URL? {
        installedDumpLibrary = nil

        do {
            guard let source = dumpLibrarySource else {
                throw RuntimeError.unsupported("The app has no PHP library of the dump viewer.")
            }

            let folder = paths.dumpLibrary.appending(path: try Self.dumpLibraryHash(in: source), directoryHint: .isDirectory)

            if !Self.hasDumpLibrary(in: folder) {
                try copyDumpLibrary(from: source, to: folder)
            }

            guard Self.hasDumpLibrary(in: folder) else {
                throw RuntimeError.unsupported("The PHP library of the dump viewer in the app is not complete.")
            }

            installedDumpLibrary = folder
            return folder
        } catch {
            activity?.write("dumps", "nexusd cannot copy the PHP library of the dump viewer. \(ErrorText.plain(error))")
            dumpLibraryFailed = true
            return nil
        }
    }

    static func dumpLibraryHash(in source: URL) throws -> String {
        let hash = try String(contentsOf: source.appending(path: dumpLibraryHashFile), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard hash.wholeMatch(of: /[0-9a-f]+/) != nil else {
            throw RuntimeError.unsupported("The file \(dumpLibraryHashFile) of the PHP library in the app holds no hash.")
        }

        return hash
    }

    // The folder has the name of the hash in its HASH file.
    private static func hasDumpLibrary(in folder: URL) -> Bool {
        let parts = [PHPConfig.dumpLibraryEntry, "src", "vendor/var-dumper"]

        guard parts.allSatisfy({ FileManager.default.fileExists(atPath: folder.appending(path: $0).path(percentEncoded: false)) }) else {
            return false
        }

        return (try? dumpLibraryHash(in: folder)) == folder.lastPathComponent
    }

    private func copyDumpLibrary(from source: URL, to folder: URL) throws {
        let staging = paths.dumpLibrary.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }

        try Self.copyFolder(source, to: staging, skipping: [])

        // An incomplete folder with this name can already stop each PHP script.
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: staging, to: folder)
    }

    // A copy stays while a stub names it, for example the stub of a PHP version that nexusd could
    // not write. The staging folder of a copy that did not end goes too.
    func removeOldDumpLibraries() {
        let lines = (try? FileManager.default.contentsOfDirectory(atPath: paths.phpConfigRoot.path(percentEncoded: false))) ?? []
        let stubs = lines.compactMap { try? String(contentsOf: dumpStub(line: $0), encoding: .utf8) }
        let folders = (try? FileManager.default.contentsOfDirectory(at: paths.dumpLibrary, includingPropertiesForKeys: nil)) ?? []

        for folder in folders {
            let name = folder.lastPathComponent

            if name == installedDumpLibrary?.lastPathComponent {
                continue
            }

            if stubs.contains(where: { $0.contains("/\(name)/\(PHPConfig.dumpLibraryEntry)'") }) {
                continue
            }

            try? FileManager.default.removeItem(at: folder)
        }
    }

    func dumpStub(line: String) -> URL {
        paths.phpConfigFolder(line: line).appending(path: PHPConfig.dumpStubName)
    }

    func poolNamesDumpStub(line: String) -> Bool {
        let pool = (try? String(contentsOf: paths.phpConfigFolder(line: line).appending(path: "php-fpm.conf"), encoding: .utf8)) ?? ""
        return pool.contains(dumpStub(line: line).path(percentEncoded: false))
    }

    // A running PHP-FPM reads the stub until it reloads with a pool that does not name it. For a
    // PHP-FPM that does not run, the pool on disk does not matter.
    func poolUsesDumpStub(line: String) async -> Bool {
        guard await supervisor.state(of: ServiceCatalog.phpID(line: line))?.isActive == true else {
            return false
        }

        return poolNamesDumpStub(line: line)
    }

    // The stub needs one of the four switches (dumps, queries, log lines, queue jobs) and the
    // library. dumps.d also needs "Commands and queue workers". The result names the stub for the
    // pool of PHP-FPM. An error of the dump viewer never stops PHP. PHP then runs without the dump
    // viewer.
    func writeDumpFiles(line: String, state: EngineState, keepingStub: Bool) -> (stub: URL?, stubChanged: Bool) {
        let folder = paths.phpConfigFolder(line: line)
        let stub = dumpStub(line: line)
        let library = state.dumpSettings.catchesAnything ? dumpLibrary() : nil

        guard let library else {
            try? Self.writeScanFolder(named: PHPConfig.dumpsFolderName, iniName: PHPConfig.dumpsIniName, ini: nil, in: folder)

            if !keepingStub {
                try? FileManager.default.removeItem(at: stub)
            }

            return (nil, false)
        }

        do {
            let text = try PHPConfig.dumpStub(
                settings: state.dumpSettings,
                socket: paths.dumpSocket,
                folder: paths.dumpFolder,
                library: library,
                userPrepend: userPrepend(line: line, state: state)
            )

            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stubChanged = try Self.writeIfChanged(text, to: stub)
            let ini = try state.dumpSettings.commands ? PHPConfig.dumpsIni(stub: stub) : nil
            try Self.writeScanFolder(named: PHPConfig.dumpsFolderName, iniName: PHPConfig.dumpsIniName, ini: ini, in: folder)
            return (stub, stubChanged)
        } catch {
            activity?.write("dumps", "PHP \(line) runs without the dump viewer. \(ErrorText.plain(error))")
            try? Self.writeScanFolder(named: PHPConfig.dumpsFolderName, iniName: PHPConfig.dumpsIniName, ini: nil, in: folder)
            return (nil, false)
        }
    }

    // The stub never includes itself, also not through a symbolic link. PHP finds a relative path
    // through include_path (prepend.php).
    private func userPrepend(line: String, state: EngineState) -> String? {
        let phpIni = (try? String(contentsOf: paths.phpConfigFolder(line: line).appending(path: "php.ini"), encoding: .utf8)) ?? ""

        guard let file = PHPConfig.userPrepend(phpIni: phpIni, customLines: state.phpCustomSettings[line] ?? []) else {
            return nil
        }

        return RealPath.of(URL(filePath: RealPath.trimmed(file))) == RealPath.of(dumpStub(line: line)) ? nil : file
    }

    // writeDumpFiles writes dumps.d only while one of the four switches and "Commands and queue
    // workers" are on and the library is installed.
    func commandDumpsFolder(line: String) -> String? {
        let folder = paths.phpConfigFolder(line: line).appending(path: PHPConfig.dumpsFolderName)

        guard FileManager.default.fileExists(atPath: folder.appending(path: PHPConfig.dumpsIniName).path(percentEncoded: false)) else {
            return nil
        }

        return folder.path(percentEncoded: false)
    }
}
