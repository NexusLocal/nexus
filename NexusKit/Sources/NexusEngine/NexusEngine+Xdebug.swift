import Foundation
import NexusConfig
import NexusCore
import NexusRuntime
import NexusSupervisor

// The PHP-FPM with Xdebug of each PHP version (owner, 2026-11-14). It runs while the PHP-FPM of
// its version runs and the Xdebug switch of that version is on. nginx and Apache send it only a
// request that starts a debug session.
extension NexusEngine {
    static func loadsXdebug(line: String, available: Set<String>, state: EngineState) -> Bool {
        PHPConfig.extensionsToLoad(enabled: state.phpExtensions[line] ?? PHPConfig.defaultExtensions, available: available).contains("xdebug")
    }

    func xdebugLines(_ state: EngineState, installed: [InstalledRuntime]) -> Set<String> {
        Set(installed.filter { $0.name == "php" && Self.loadsXdebug(line: $0.line, available: toggleNames(of: $0), state: state) }.map(\.line))
    }

    func syncXdebugServices() async {
        for runtime in await installer.installedRuntimes() where runtime.name == "php" {
            await syncXdebug(line: runtime.line, installed: runtime)
        }
    }

    // One PHP version only. "Stop all services" stops the versions at the same time. Each stop then
    // changes only the PHP-FPM with Xdebug of its own version. A PHP-FPM with Xdebug that starts
    // here reads the new configuration. So it gets no reload. A reload signal before php-fpm has
    // its signal handler stops php-fpm.
    func syncXdebug(line: String, installed: InstalledRuntime? = nil) async {
        let id = ServiceID.xdebug(line: line)
        let running = await supervisor.state(of: id)?.isActive == true
        let phpRuns = await supervisor.state(of: ServiceCatalog.phpID(line: line))?.isActive == true

        guard phpRuns || running else {
            return
        }

        let state = await stateStore.current()
        let runtime = if let installed { installed } else { await runtime(named: "php", line: line) }
        let switchIsOn = runtime.map { Self.loadsXdebug(line: line, available: toggleNames(of: $0), state: state) } == true

        if phpRuns, switchIsOn {
            if !running, let runtime {
                try? await supervisor.start(catalog.xdebugDefinition(for: runtime))
            }

            return
        }

        if running {
            try? await supervisor.stop(id, cause: phpRuns ? "the Xdebug switch of PHP \(line) is off" : "PHP \(line) does not run")
        }
    }

    // A change of the configuration reaches both PHP-FPM processes of a version. The PHP-FPM with
    // Xdebug reads the configuration of its PHP version. So it reloads with it.
    func signalPHP(line: String, _ signal: Int32) async {
        await supervisor.signal(ServiceCatalog.phpID(line: line), signal)
        await supervisor.signal(ServiceID.xdebug(line: line), signal)
    }

    // nexus debug works with each PHP version that has xdebug.so, also while the switch is off.
    func xdebugFolder(of php: InstalledRuntime) async throws -> String {
        guard toggleNames(of: php).contains("xdebug") else {
            throw RuntimeError.unsupported("PHP \(php.line) has no Xdebug. So nexus debug does not work with this PHP version.")
        }

        if !hasXdebugIni(line: php.line) {
            _ = try await serialWeb { try await self.writePHPConfig(line: php.line, state: await self.stateStore.current()) }
        }

        return paths.xdebugFolder(line: php.line).path(percentEncoded: false)
    }

    func hasXdebugIni(line: String) -> Bool {
        let ini = paths.xdebugFolder(line: line).appending(path: PHPConfig.xdebugIniName)
        return FileManager.default.fileExists(atPath: ini.path(percentEncoded: false))
    }

    // The PHP screen shows a PHP-FPM with Xdebug that failed (owner, 2026-11-14). Without this, the
    // reason is only in the log of the PHP version.
    func xdebugProblem(of runtime: InstalledRuntime, phpRuns: Bool) async -> String? {
        guard runtime.name == "php", phpRuns, case .failed(let reason) = await supervisor.state(of: ServiceID.xdebug(line: runtime.line)) else {
            return nil
        }

        return "The PHP-FPM with Xdebug does not run. A request that starts a debug session gets no answer. \(reason)"
    }
}
