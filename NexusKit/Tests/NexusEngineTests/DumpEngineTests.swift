import Foundation
import NexusConfig
import NexusCore
import NexusIPC
import NexusSupervisor
import Testing
@testable import NexusEngine

extension NexusEngineTests {
    private static let catchingNothing = DumpSettings(catchDumps: false, catchQueries: false, catchLogs: false, catchJobs: false, pageMode: .automatic, commands: true)

    private func fakeDumpLibrary(in root: URL, hash: String) throws -> URL {
        let library = root.appending(path: "Nexus.app/Contents/Resources/php/dumps", directoryHint: .isDirectory)
        let files = [
            "prepend.php": "<?php\n",
            "src/Catcher.php": "<?php\n",
            "vendor/var-dumper/VERSION": "v7.4.22\n",
            "HASH": "\(hash)\n",
        ]

        for (path, text) in files {
            let file = library.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        return library
    }

    private func makeDumpEngine(root: URL, lines: [String] = ["8.5"], state: EngineState = EngineState(), hash: String = "0123456789ab") throws -> NexusEngine {
        try makeSiteEngine(root: root, state: state, runtimes: lines.map { ("php", $0) }, dumpLibrarySource: try fakeDumpLibrary(in: root, hash: hash))
    }

    private func writeConfig(_ engine: NexusEngine, line: String = "8.5") async throws -> Bool {
        try await engine.writePHPConfig(line: line, state: await engine.stateStore.current())
    }

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).sorted()
    }

    private func text(of file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }

    @Test func theLibraryGoesToTheFolderThatItsHashFileNames() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDumpEngine(root: root)
        let paths = await engine.paths

        let installed = try #require(await engine.dumpLibrary())
        let again = await engine.dumpLibrary()

        #expect(installed.lastPathComponent == "0123456789ab")
        #expect(again == installed)
        #expect(names(in: paths.dumpLibrary) == ["0123456789ab"])
        #expect(names(in: installed) == ["HASH", "prepend.php", "src", "vendor"])
    }

    @Test func aLibraryWithoutAValidHashIsNotTriedAgainInThisRun() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDumpEngine(root: root, hash: "../other")
        let paths = await engine.paths

        let first = await engine.dumpLibrary()
        _ = try fakeDumpLibrary(in: root, hash: "0123456789ab")
        let second = await engine.dumpLibrary()

        #expect(first == nil)
        #expect(second == nil)
        #expect(names(in: paths.dumpLibrary).isEmpty)
    }

    @Test func aRemovedLibraryComesBackAtTheNextWrite() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDumpEngine(root: root)
        let paths = await engine.paths

        let installed = try #require(await engine.dumpLibrary())
        try FileManager.default.removeItem(at: paths.dumpLibrary)
        _ = try await writeConfig(engine)

        #expect(exists(installed.appending(path: "prepend.php")))
    }

    @Test func aNewLibraryGetsANewFolderAndTheOldFolderStaysWhileAStubNamesIt() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try makeDumpEngine(root: root)
        let paths = await old.paths
        let stub = paths.phpConfigFolder(line: "8.5").appending(path: PHPConfig.dumpStubName)

        _ = try await writeConfig(old)
        let new = try makeDumpEngine(root: root, hash: "ba9876543210")
        _ = await new.dumpLibrary()
        await new.removeOldDumpLibraries()
        let keptWhileTheStubNamesIt = names(in: paths.dumpLibrary)
        _ = try await writeConfig(new)
        await new.removeOldDumpLibraries()

        #expect(keptWhileTheStubNamesIt == ["0123456789ab", "ba9876543210"])
        #expect(try text(of: stub).contains("/ba9876543210/prepend.php';"))
        #expect(names(in: paths.dumpLibrary) == ["ba9876543210"])
    }

    @Test func atTheStartEachPHPVersionGetsOnlyItsStubAndOnlyANamedOldLibraryStays() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDumpEngine(root: root, lines: ["8.4", "8.5"], hash: "aaaaaaaaaaaa")
        let paths = await engine.paths
        let library = paths.dumpLibrary.path(percentEncoded: false)

        for name in ["0123456789ab", "ba9876543210", ".staging-1"] {
            try FileManager.default.createDirectory(at: paths.dumpLibrary.appending(path: "\(name)/src"), withIntermediateDirectories: true)
        }

        for (line, name) in [("8.5", "0123456789ab"), ("8.1", "ba9876543210")] {
            let folder = paths.phpConfigFolder(line: line)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("<?php\n\nrequire '\(library)\(name)/prepend.php';\n".utf8).write(to: folder.appending(path: PHPConfig.dumpStubName))
        }

        await engine.prepareDumpLibrary()

        #expect(names(in: paths.dumpLibrary) == ["aaaaaaaaaaaa", "ba9876543210"])

        for line in ["8.4", "8.5"] {
            let folder = paths.phpConfigFolder(line: line)

            #expect(try text(of: folder.appending(path: PHPConfig.dumpStubName)).contains("/aaaaaaaaaaaa/prepend.php';"))
            #expect(exists(folder.appending(path: "dumps.d/00-nexus-dumps.ini")))
            #expect(!exists(folder.appending(path: "php-fpm.conf")))
        }
    }

    @Test func whileCatchDumpsIsOnThePoolAndTheCommandsNameTheStub() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDumpEngine(root: root)
        let paths = await engine.paths
        let folder = paths.phpConfigFolder(line: "8.5")
        let stub = folder.appending(path: PHPConfig.dumpStubName)
        let stubPath = stub.path(percentEncoded: false)

        let firstWrite = try await writeConfig(engine)
        let secondWrite = try await writeConfig(engine)
        let library = try #require(await engine.installedDumpLibrary)
        let stubText = try text(of: stub)

        #expect(firstWrite)
        #expect(!secondWrite)
        #expect(try text(of: folder.appending(path: "php-fpm.conf")).hasSuffix("php_value[auto_prepend_file] = \"\(stubPath)\"\n"))
        #expect(try text(of: folder.appending(path: "dumps.d/00-nexus-dumps.ini")).contains("\nauto_prepend_file = \"\(stubPath)\"\n"))
        #expect(!(try text(of: folder.appending(path: "conf.d/00-nexus.ini")).contains("auto_prepend_file")))
        #expect(stubText.contains("'socket' => '\(paths.dumpSocket.path(percentEncoded: false))',"))
        #expect(stubText.contains("'folder' => '\(RealPath.trimmed(paths.dumpFolder.path(percentEncoded: false)))',"))
        #expect(stubText.contains("'page' => 'automatic',"))
        #expect(stubText.contains("    'dumps' => true,\n    'queries' => false,\n    'logs' => true,\n    'jobs' => false,\n"))
        #expect(stubText.contains("'userPrepend' => null,"))
        #expect(stubText.contains("require '\(library.appending(path: "prepend.php").path(percentEncoded: false))';"))
    }

    @Test func withCommandsOffOnlyThePoolNamesTheStub() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var state = EngineState()
        state.dumpSettings.commands = false
        let engine = try makeDumpEngine(root: root, state: state)
        let folder = await engine.paths.phpConfigFolder(line: "8.5")

        _ = try await writeConfig(engine)

        #expect(try text(of: folder.appending(path: "php-fpm.conf")).contains("php_value[auto_prepend_file]"))
        #expect(!exists(folder.appending(path: PHPConfig.dumpsFolderName)))
        #expect(await engine.commandDumpsFolder(line: "8.5") == nil)
    }

    @Test func withOnlyCatchQueriesOnThePoolAndTheCommandsStillNameTheStub() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var state = EngineState()
        state.dumpSettings = Self.catchingNothing
        state.dumpSettings.catchQueries = true
        let engine = try makeDumpEngine(root: root, state: state)
        let folder = await engine.paths.phpConfigFolder(line: "8.5")
        let stubPath = folder.appending(path: PHPConfig.dumpStubName).path(percentEncoded: false)

        _ = try await writeConfig(engine)
        let stubText = try text(of: folder.appending(path: PHPConfig.dumpStubName))

        #expect(try text(of: folder.appending(path: "php-fpm.conf")).hasSuffix("php_value[auto_prepend_file] = \"\(stubPath)\"\n"))
        #expect(try text(of: folder.appending(path: "dumps.d/00-nexus-dumps.ini")).contains("\nauto_prepend_file = \"\(stubPath)\"\n"))
        #expect(await engine.commandDumpsFolder(line: "8.5") != nil)
        #expect(stubText.contains("    'dumps' => false,\n    'queries' => true,\n    'logs' => false,\n    'jobs' => false,\n"))
        #expect(await engine.installedDumpLibrary != nil)
    }

    @Test func eachSwitchReachesTheStubOfEachPHPVersion() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDumpEngine(root: root, lines: ["8.4", "8.5"])
        let paths = await engine.paths
        let settings = DumpSettings(catchDumps: true, catchQueries: true, catchLogs: false, catchJobs: true, pageMode: .automatic, commands: true)

        try await whileRunning(engine) {
            let message = try await engine.serialWeb { try await engine.setDumpSettings(settings) }
            await engine.syncBackgroundProcesses().value

            #expect(message == "The settings of the dump viewer are changed.")
            #expect(await engine.stateStore.current().dumpSettings == settings)

            for line in ["8.4", "8.5"] {
                let stubText = try text(of: paths.phpConfigFolder(line: line).appending(path: PHPConfig.dumpStubName))
                #expect(stubText.contains("    'dumps' => true,\n    'queries' => true,\n    'logs' => false,\n    'jobs' => true,\n"))
            }
        }
    }

    @Test func theStubIncludesThePrependFileOfTheUserButNeverItself() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDumpEngine(root: root)
        let folder = await engine.paths.phpConfigFolder(line: "8.5")
        let stub = folder.appending(path: PHPConfig.dumpStubName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("memory_limit = 1G\nauto_prepend_file = \"/Sites/blog/wordfence-waf.php\"\n".utf8).write(to: folder.appending(path: "php.ini"))

        let link = root.appending(path: "link.php")
        let customLines = [
            "auto_prepend_file = /Sites/custom.php",
            "auto_prepend_file = \(stub.path(percentEncoded: false))",
            "auto_prepend_file = \(link.path(percentEncoded: false))",
            "auto_prepend_file = \(stub.path(percentEncoded: false))/",
            "auto_prepend_file = waf.php",
        ]
        var stubs: [String] = []

        _ = try await writeConfig(engine)
        let fromPHPIni = try text(of: stub)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: stub)

        for customLine in customLines {
            try await engine.stateStore.update { $0.phpCustomSettings["8.5"] = [customLine] }
            _ = try await writeConfig(engine)
            stubs.append(try text(of: stub))
        }

        #expect(fromPHPIni.contains("'userPrepend' => '/Sites/blog/wordfence-waf.php',"))
        #expect(stubs[0].contains("'userPrepend' => '/Sites/custom.php',"))
        #expect(stubs[1].contains("'userPrepend' => null,"))
        #expect(stubs[2].contains("'userPrepend' => null,"))
        #expect(stubs[3].contains("'userPrepend' => null,"))
        #expect(stubs[4].contains("'userPrepend' => 'waf.php',"))
    }

    @Test func anErrorOfTheDumpViewerDoesNotStopPHP() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDumpEngine(root: root)
        let folder = await engine.paths.phpConfigFolder(line: "8.5")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("auto_prepend_file = \"/Sites/a\tb.php\"\n".utf8).write(to: folder.appending(path: "php.ini"))

        let changed = try await writeConfig(engine)

        #expect(changed)
        #expect(!(try text(of: folder.appending(path: "php-fpm.conf")).contains("auto_prepend_file")))
        #expect(exists(folder.appending(path: "conf.d/00-nexus.ini")))
        #expect(!exists(folder.appending(path: PHPConfig.dumpsFolderName)))
    }

    @Test func withAllSwitchesOffAStoppedPHPFPMLosesItsStubAtOnce() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDumpEngine(root: root)
        let folder = await engine.paths.phpConfigFolder(line: "8.5")

        _ = try await writeConfig(engine)
        try await engine.stateStore.update { $0.dumpSettings = Self.catchingNothing }
        let changed = try await writeConfig(engine)

        #expect(changed)
        #expect(!(try text(of: folder.appending(path: "php-fpm.conf")).contains("auto_prepend_file")))
        #expect(!exists(folder.appending(path: PHPConfig.dumpsFolderName)))
        #expect(!exists(folder.appending(path: PHPConfig.dumpStubName)))
    }

    @Test func withAllSwitchesOffARunningPHPFPMKeepsItsStubUntilItsPoolNoLongerNamesIt() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDumpEngine(root: root)
        let paths = await engine.paths
        let stub = paths.phpConfigFolder(line: "8.5").appending(path: PHPConfig.dumpStubName)
        let fakePHPFPM = ServiceDefinition(id: "php-8.5", displayName: "PHP 8.5", executable: URL(filePath: "/bin/sleep"), arguments: ["60"], logFile: paths.log("php-8.5"))

        try await whileRunning(engine) {
            _ = try await writeConfig(engine)
            try await engine.supervisor.start(fakePHPFPM)
            try await engine.stateStore.update { $0.dumpSettings = Self.catchingNothing }
            _ = try await writeConfig(engine)
            let stubWhilePHPFPMUsesIt = exists(stub)
            _ = try await writeConfig(engine)

            #expect(stubWhilePHPFPMUsesIt)
            #expect(!exists(stub))
        }
    }

    @Test func atTheStartOnlyThePHPVersionsWithoutASiteGetOnlyTheirStub() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shop.appending(path: "public"), withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeDumpEngine(root: root, lines: ["8.4", "8.5"], state: state)
        let paths = await engine.paths

        try await whileRunning(engine) {
            await engine.startEnabledServices()
            let sitePool = try text(of: paths.phpConfigFolder(line: "8.5").appending(path: "php-fpm.conf"))

            #expect(sitePool.contains("php_value[auto_prepend_file]"))
            #expect(!exists(paths.phpConfigFolder(line: "8.4").appending(path: "php-fpm.conf")))
            #expect(exists(paths.phpConfigFolder(line: "8.4").appending(path: PHPConfig.dumpStubName)))
            #expect(exists(paths.phpConfigFolder(line: "8.4").appending(path: "dumps.d/00-nexus-dumps.ini")))
            #expect(await engine.phpLinesWrittenAtStart == nil)
        }
    }

    @Test func atTheNextStartAPoolThatNamesAStubThatGoesIsWrittenAgain() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDumpEngine(root: root)
        let paths = await engine.paths
        let folder = paths.phpConfigFolder(line: "8.5")
        var off = EngineState()
        off.dumpSettings = Self.catchingNothing

        _ = try await writeConfig(engine)
        let next = try makeDumpEngine(root: root, state: off)
        await next.prepareDumpLibrary()

        #expect(!(try text(of: folder.appending(path: "php-fpm.conf")).contains("auto_prepend_file")))
        #expect(!exists(folder.appending(path: PHPConfig.dumpStubName)))
        #expect(names(in: paths.dumpLibrary).isEmpty)
    }

    @Test func theSettingsSayWhenNexusCannotCatchDumps() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root, runtimes: [("php", "8.5")])

        try await whileRunning(engine) {
            let on = try await engine.serialWeb { try await engine.setDumpSettings(DumpSettings()) }
            let off = try await engine.serialWeb { try await engine.setDumpSettings(Self.catchingNothing) }
            await engine.syncBackgroundProcesses().value

            #expect(on.contains("\nNexus catches nothing from PHP, because it cannot copy the PHP library of the dump viewer from the app."))
            #expect(off == "The settings of the dump viewer are changed.")
        }
    }

    @Test func anIncompleteOrChangedCopyIsCopiedAgain() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDumpEngine(root: root)

        let installed = try #require(await engine.dumpLibrary())
        try FileManager.default.removeItem(at: installed.appending(path: "src"))
        let afterARemovedFolder = await engine.dumpLibrary()
        let sourceIsBack = exists(installed.appending(path: "src/Catcher.php"))
        try Data("ffffffffffff\n".utf8).write(to: installed.appending(path: "HASH"))
        let afterAChangedHash = await engine.dumpLibrary()

        #expect(afterARemovedFolder == installed)
        #expect(sourceIsBack)
        #expect(afterAChangedHash == installed)
        #expect(try text(of: installed.appending(path: "HASH")) == "0123456789ab\n")
    }

    @Test func withAllSwitchesOffNexusCopiesNoLibrary() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var state = EngineState()
        state.dumpSettings = Self.catchingNothing
        let engine = try makeDumpEngine(root: root, state: state)
        let paths = await engine.paths

        _ = try await writeConfig(engine)

        #expect(names(in: paths.dumpLibrary).isEmpty)
        #expect(!exists(paths.phpConfigFolder(line: "8.5").appending(path: PHPConfig.dumpStubName)))
    }

    @Test func withoutALibraryInTheAppPHPRunsWithoutTheDumpViewer() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root, runtimes: [("php", "8.5")])
        let folder = await engine.paths.phpConfigFolder(line: "8.5")

        _ = try await writeConfig(engine)

        #expect(!(try text(of: folder.appending(path: "php-fpm.conf")).contains("auto_prepend_file")))
        #expect(!exists(folder.appending(path: PHPConfig.dumpsFolderName)))
        #expect(!exists(folder.appending(path: PHPConfig.dumpStubName)))
    }

    @Test func aNewPageModeReachesTheStubOfEachPHPVersion() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDumpEngine(root: root, lines: ["8.4", "8.5"])
        let paths = await engine.paths

        try await whileRunning(engine) {
            let message = try await engine.serialWeb { try await engine.setDumpSettings(DumpSettings(catchDumps: true, pageMode: .always, commands: true)) }
            await engine.syncBackgroundProcesses().value

            #expect(message == "The settings of the dump viewer are changed.")
            #expect(await engine.stateStore.current().dumpSettings.pageMode == .always)

            for line in ["8.4", "8.5"] {
                #expect(try text(of: paths.phpConfigFolder(line: line).appending(path: PHPConfig.dumpStubName)).contains("'page' => 'always',"))
            }
        }
    }

    @Test func onlyPHPOfTheUserAndTheBackgroundProcessesGetTheFolderOfTheDumpViewer() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shop, withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.5"), ("composer", "2")], dumpLibrarySource: try fakeDumpLibrary(in: root, hash: "0123456789ab"))
        let dumps = await engine.paths.phpConfigFolder(line: "8.5").appending(path: "dumps.d").path(percentEncoded: false)

        try await whileRunning(engine) {
            let php = try await toolCommand(engine, .php, in: shop)
            let composer = try await toolCommand(engine, .composer, in: shop)
            let setup = try await engine.toolCommand(.php, folder: shop.path(percentEncoded: false), inSetup: true)
            let backgroundEnvironment = await engine.environment(of: php)
            let setupEnvironment = await engine.environment(of: setup)
            _ = try await engine.setDumpSettings(DumpSettings(catchDumps: true, pageMode: .automatic, commands: false))
            let withoutCommands = try await toolCommand(engine, .php, in: shop)
            await engine.syncBackgroundProcesses().value

            #expect(php.dumpsFolder == dumps)
            #expect(php.environment(for: ["artisan", "queue:work"])["PHP_INI_SCAN_DIR"]?.hasSuffix("/conf.d:\(dumps)") == true)
            #expect(backgroundEnvironment["PHP_INI_SCAN_DIR"]?.hasSuffix("/conf.d:\(dumps)") == true)
            #expect(composer.dumpsFolder == nil)
            #expect(setup.dumpsFolder == nil)
            #expect(setupEnvironment["PHP_INI_SCAN_DIR"]?.contains("dumps.d") == false)
            #expect(withoutCommands.dumpsFolder == nil)
        }
    }
}
