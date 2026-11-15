import Foundation
import NexusCore
import NexusDNS
import NexusIPC
import NexusRuntime
import NexusSupervisor
import NexusTestSupport
import NexusTLS
import Testing
@testable import NexusEngine

extension NexusEngineTests {
    private func addXdebug(to engine: NexusEngine, line: String) async throws {
        let extensions = await engine.paths.runtime("php", line: line).appending(path: "lib/php/extensions/no-debug-non-zts-20250925", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        try Data().write(to: extensions.appending(path: "xdebug.so"))
    }

    @Test func theXdebugSwitchWritesThePoolWithXdebugAndConfDNeverLoadsIt() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root, runtimes: [("php", "8.5"), ("php", "8.4")])
        try await addXdebug(to: engine, line: "8.5")
        let config = await engine.paths.phpConfigFolder(line: "8.5")
        let socket = await engine.paths.xdebugSocket(line: "8.5").path(percentEncoded: false)

        let response = await engine.handle(.setExtension(php: "8.5", name: "xdebug", enabled: true))

        let nexusIni = try String(contentsOf: config.appending(path: "conf.d/00-nexus.ini"), encoding: .utf8)
        let xdebugIni = try String(contentsOf: config.appending(path: "xdebug.d/00-nexus-xdebug.ini"), encoding: .utf8)
        let pool = try String(contentsOf: config.appending(path: "php-fpm-xdebug.conf"), encoding: .utf8)
        #expect(response == .done(message: "xdebug on for PHP 8.5. Other PHP versions do not change."))
        #expect(!nexusIni.contains("zend_extension = xdebug"))
        #expect(nexusIni.contains("xdebug.start_with_request = trigger"))
        #expect(xdebugIni.contains("zend_extension = xdebug"))
        #expect(pool.contains("listen = \"\(socket)\""))
        #expect(pool.contains("pm = ondemand"))
        #expect(await engine.supervisor.state(of: "xdebug-8.5") == nil)
    }

    @Test func aPHPIniThatLoadsXdebugKeepsItsOwnXdebugSettings() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root, runtimes: [("php", "8.5")])
        try await addXdebug(to: engine, line: "8.5")
        let config = await engine.paths.phpConfigFolder(line: "8.5")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data("zend_extension = xdebug\nxdebug.mode = profile\n".utf8).write(to: config.appending(path: "php.ini"))

        _ = await engine.handle(.setExtension(php: "8.5", name: "xdebug", enabled: true))

        let nexusIni = try String(contentsOf: config.appending(path: "conf.d/00-nexus.ini"), encoding: .utf8)
        let xdebugIni = try String(contentsOf: config.appending(path: "xdebug.d/00-nexus-xdebug.ini"), encoding: .utf8)
        #expect(!nexusIni.contains("xdebug.mode"))
        #expect(!xdebugIni.contains("zend_extension = xdebug"))
    }

    @Test func nexusDebugGivesTheFolderOfXdebugAndRefusesAPHPWithoutIt() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shop = root.appending(path: "shop", directoryHint: .isDirectory)
        let blog = root.appending(path: "blog", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shop, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blog, withIntermediateDirectories: true)
        var state = EngineState()
        state.sites = [Site(host: "shop.test", folder: shop, php: "8.5"), Site(host: "blog.test", folder: blog, php: "8.4")]
        let engine = try makeSiteEngine(root: root, state: state, runtimes: [("php", "8.5"), ("php", "8.4")])
        try await addXdebug(to: engine, line: "8.5")
        let xdebugFolder = await engine.paths.phpConfigFolder(line: "8.5").appending(path: "xdebug.d").path(percentEncoded: false)

        let debug = await engine.handle(.tool(.php, folder: shop.path(percentEncoded: false), argumentFolder: nil, debug: true))
        let plain = try await toolCommand(engine, .php, in: shop)
        let withoutXdebug = await engine.handle(.tool(.php, folder: blog.path(percentEncoded: false), argumentFolder: nil, debug: true))
        let node = await engine.handle(.tool(.node, folder: shop.path(percentEncoded: false), argumentFolder: nil, debug: true))

        guard case .tool(let command) = debug else {
            Issue.record("No command: \(debug)")
            return
        }
        #expect(command.xdebugFolder == xdebugFolder)
        #expect(exists(URL(filePath: xdebugFolder).appending(path: "00-nexus-xdebug.ini")))
        #expect(plain.xdebugFolder == nil)
        #expect(withoutXdebug == .failure(message: "PHP 8.4 has no Xdebug. So nexus debug does not work with this PHP version."))
        #expect(node == .failure(message: "nexus debug runs PHP only. Xdebug cannot debug node."))
    }

    @Test func aFailedPHPFPMWithXdebugIsAProblemWhileItsPHPRuns() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeSiteEngine(root: root, runtimes: [("php", "8.5")])
        let runtime = InstalledRuntime(name: "php", line: "8.5", version: "8.5.0", revision: 1, sha256: "", installedAt: .now, folder: await engine.paths.runtime("php", line: "8.5"))

        let whileStopped = await engine.xdebugProblem(of: runtime, phpRuns: true)
        try? await engine.supervisor.start(ServiceDefinition(id: "xdebug-8.5", displayName: "PHP 8.5.0 with Xdebug", executable: root.appending(path: "missing/php-fpm"), logFile: root.appending(path: "php-8.5.log")))
        let failed = await engine.xdebugProblem(of: runtime, phpRuns: true)
        let phpStopped = await engine.xdebugProblem(of: runtime, phpRuns: false)

        #expect(whileStopped == nil)
        #expect(failed?.hasPrefix("The PHP-FPM with Xdebug does not run. A request that starts a debug session gets no answer. ") == true)
        #expect(phpStopped == nil)
    }
}

extension NexusEngineTests {
    @Test(.enabled(if: realRuntimes != nil), .timeLimit(.minutes(2)))
    func aRealDebugRequestUsesXdebugAndEveryOtherRequestAndCommandDoesNot() async throws {
        let root = shortTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NexusPaths(root: root.appending(path: "Application Support/Nexus", directoryHint: .isDirectory))
        try paths.createFolders()
        try linkRealRuntimes(in: paths, ["nginx/1.30", "httpd/2.4", "php/8.5"])

        let httpsPort = freePort()
        var state = EngineState()
        state.ports[ServiceCatalog.httpPortKey] = freePort()
        state.ports[ServiceCatalog.httpsPortKey] = httpsPort
        state.ports[ServiceCatalog.apacheID] = freePort()
        state.ports[NexusEngine.dnsServiceID] = freeUDPPort()
        try JSONEncoder().encode(state).write(to: paths.config.appending(path: "state.json"))

        let projects = root.appending(path: "projects", directoryHint: .isDirectory)
        for name in ["shop", "blog"] {
            let folder = projects.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("<?php echo extension_loaded('xdebug') ? 'with-xdebug' : 'without-xdebug';".utf8).write(to: folder.appending(path: "index.php"))
        }

        let engine = NexusEngine(
            paths: paths,
            helper: helper,
            certificateAuthority: CertificateAuthority(paths: paths, store: keyStore),
            systemFiles: SystemDNSFiles(
                resolverFolder: root.appending(path: "etc/resolver", directoryHint: .isDirectory),
                hostsFile: root.appending(path: "etc/hosts", directoryHint: .notDirectory)
            )
        )
        let hosts = ["shop.test", "blog.test"]
        var plain: [String: String] = [:]
        var cookie: [String: String] = [:]
        var query: [String: String] = [:]
        var afterSwitchOff: [String: String] = [:]
        var debugRuns, debugRunsAfterStop, debugRunsAfterStart, debugRunsAfterSwitchOff: Bool?
        var debugCommand, plainCommand: String?

        try await whileRunning(engine) {
            _ = await engine.handle(.addSite(folder: projects.appending(path: "shop").path(percentEncoded: false), host: "shop.test", aliases: [], php: "8.5", server: .nginx))
            _ = await engine.handle(.addSite(folder: projects.appending(path: "blog").path(percentEncoded: false), host: "blog.test", aliases: [], php: "8.5", server: .apache))
            _ = await engine.handle(.setCustomSettings(php: "8.5", lines: ["xdebug.client_port = \(freePort())"]))
            _ = await engine.handle(.setExtension(php: "8.5", name: "xdebug", enabled: true))

            for host in hosts {
                plain[host] = await debugPage(host, port: httpsPort, containing: "without-xdebug")
                cookie[host] = await debugPage(host, port: httpsPort, arguments: ["-b", "XDEBUG_SESSION=1"], containing: "with-xdebug")
                query[host] = await debugPage(host, port: httpsPort, path: "/?XDEBUG_TRIGGER=1", containing: "with-xdebug")
            }

            debugRuns = await engine.supervisor.state(of: "xdebug-8.5")?.isActive
            debugCommand = try await phpOutput(engine, in: projects.appending(path: "shop"), debug: true)
            plainCommand = try await phpOutput(engine, in: projects.appending(path: "shop"), debug: false)

            _ = await engine.handle(.stop(service: "php-8.5"))
            debugRunsAfterStop = await engine.supervisor.state(of: "xdebug-8.5")?.isActive
            _ = await engine.handle(.start(service: "php-8.5"))
            debugRunsAfterStart = await engine.supervisor.state(of: "xdebug-8.5")?.isActive

            _ = await engine.handle(.setExtension(php: "8.5", name: "xdebug", enabled: false))
            debugRunsAfterSwitchOff = await engine.supervisor.state(of: "xdebug-8.5")?.isActive

            for host in hosts {
                afterSwitchOff[host] = await debugPage(host, port: httpsPort, arguments: ["-b", "XDEBUG_SESSION=1"], containing: "without-xdebug")
            }

            _ = await engine.handle(.stopAll)
        }

        for host in hosts {
            #expect(plain[host]?.contains("without-xdebug") == true, "\(host): \(plain[host] ?? "no page")")
            #expect(cookie[host]?.contains("with-xdebug") == true, "\(host): \(cookie[host] ?? "no page")")
            #expect(query[host]?.contains("with-xdebug") == true, "\(host): \(query[host] ?? "no page")")
            #expect(afterSwitchOff[host]?.contains("without-xdebug") == true, "\(host): \(afterSwitchOff[host] ?? "no page")")
        }
        #expect(debugRuns == true)
        #expect(debugCommand?.contains("with-xdebug") == true, "\(debugCommand ?? "no output")")
        #expect(plainCommand?.contains("without-xdebug") == true, "\(plainCommand ?? "no output")")
        #expect(debugRunsAfterStop == false)
        #expect(debugRunsAfterStart == true)
        #expect(debugRunsAfterSwitchOff == false)
    }

    private func phpOutput(_ engine: NexusEngine, in folder: URL, debug: Bool) async throws -> String {
        let response = await engine.handle(.tool(.php, folder: folder.path(percentEncoded: false), argumentFolder: nil, debug: debug ? true : nil))

        guard case .tool(let command) = response else {
            Issue.record("No command: \(response)")
            throw CancellationError()
        }

        let arguments = ["-r", "echo extension_loaded('xdebug') ? 'with-xdebug' : 'without-xdebug';"]
        let php = Process()
        php.executableURL = URL(filePath: command.executable)
        php.arguments = command.arguments + arguments
        php.environment = ProcessInfo.processInfo.environment.merging(command.environment(for: arguments)) { _, new in new }
        php.currentDirectoryURL = folder
        let output = Pipe()
        php.standardOutput = output
        php.standardError = FileHandle.nullDevice
        try php.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        php.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func debugPage(_ host: String, port: Int, path: String = "/", arguments: [String] = [], containing marker: String) async -> String {
        let deadline = ContinuousClock.now + .seconds(15)
        var body = ""

        while !body.contains(marker), ContinuousClock.now < deadline {
            body = await curl(arguments + ["https://\(host):\(port)\(path)"], host: host, port: port, seconds: 5)

            if !body.contains(marker) {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        return body
    }
}
