import Darwin
import Foundation
import NexusConfig
import NexusCore
import NexusIPC
import NexusRuntime
import NexusSupervisor

// What the app shows for a web service next to its state.
struct WebDetails {
    var toggles: [Toggle] = []
    var customSettings: [String]?
    var usedBy: [String] = []
    var note: String?
}

// The custom php.ini lines of each PHP version (D60), and the details of the web services.
extension NexusEngine {
    func customSettings(line: String) async throws -> [String] {
        guard await runtime(named: "php", line: line) != nil else {
            throw RuntimeError.unsupported("PHP \(line) is not installed.")
        }

        return await stateStore.current().phpCustomSettings[line] ?? []
    }

    // PHP checks the new lines before nexusd keeps them. When PHP refuses a line, the old lines
    // stay in the state and in conf.d. So a running PHP keeps its settings. A running PHP reads
    // the new lines at once.
    func setCustomSettings(line: String, lines: [String]) async throws -> String {
        guard let runtime = await runtime(named: "php", line: line) else {
            throw RuntimeError.unsupported("PHP \(line) is not installed. Run: nexus install php \(line)")
        }

        let oldFilesChanged = try await writePHPConfig(line: line, state: await stateStore.current())

        if let error = try await checkCustomSettings(lines, of: runtime) {
            throw error
        }

        try await stateStore.update { $0.phpCustomSettings[line] = lines }

        let id = ServiceCatalog.phpID(line: line)
        let running = await supervisor.state(of: id)?.isActive == true
        let newFilesChanged = try await writePHPConfig(line: line, state: await stateStore.current())

        if oldFilesChanged || newFilesChanged, running {
            await supervisor.signal(id, SIGUSR2)
        }

        return running
            ? "PHP \(line) runs with the new custom settings."
            : "PHP \(line) uses the new custom settings at its next start."
    }

    // PHP reads its settings at the start and writes a message for each wrong line. A message
    // that also shows without the new lines is not caused by them. So it does not count. A
    // message without a line number gets the first line that makes this same message show. A
    // later line can hide the message of an earlier line, for example a second memory_limit.
    func checkCustomSettings(_ lines: [String], of runtime: InstalledRuntime) async throws -> PHPSettingsError? {
        let confD = paths.phpConfigFolder(line: runtime.line).appending(path: "conf.d", directoryHint: .isDirectory)
        let check = paths.run.appending(path: "php-\(runtime.line)-check", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: check)
        try FileManager.default.createDirectory(at: check, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: check) }

        let others = (try? FileManager.default.contentsOfDirectory(at: confD, includingPropertiesForKeys: nil)) ?? []
        for file in others where file.pathExtension == "ini" && file.lastPathComponent != PHPConfig.customIniName {
            try FileManager.default.copyItem(at: file, to: check.appending(path: file.lastPathComponent))
        }

        let customFile = check.appending(path: PHPConfig.customIniName)
        let baseline = try await startOutput(of: runtime, scanFolder: check)

        func messages(with custom: ArraySlice<String>) async throws -> [PHPStartupMessage] {
            try Data(PHPConfig.customIni(lines: Array(custom)).utf8).write(to: customFile)
            return PHPConfig.newStartupMessages(in: try await startOutput(of: runtime, scanFolder: check), baseline: baseline)
        }

        guard let first = try await messages(with: lines[...]).first else {
            return nil
        }

        // A string without its closing quote gets the line after the last line.
        if first.file?.hasSuffix("/\(PHPConfig.customIniName)") == true, let fileLine = first.line {
            let line = min(max(fileLine - PHPConfig.customIniHeaderLines, 1), max(lines.count, 1))
            return PHPSettingsError(php: runtime.line, line: line, message: first.text)
        }

        for index in lines.indices where Self.isSetting(lines[index]) {
            if try await messages(with: lines[...index]).contains(first) {
                return PHPSettingsError(php: runtime.line, line: index + 1, message: first.text)
            }
        }

        return PHPSettingsError(php: runtime.line, line: nil, message: first.text)
    }

    // The start of the command line PHP with the settings of this version. PHP shows each start
    // message, also when the custom lines turn the messages off. It runs no file before or after
    // the empty script. Xdebug does not connect to the editor for the empty script. A listening
    // editor could otherwise stop the check, and every change after it would wait.
    private func startOutput(of runtime: InstalledRuntime, scanFolder: URL) async throws -> String {
        let settings = [
            "display_startup_errors=1", "display_errors=stderr", "html_errors=0", "log_errors=0",
            "error_reporting=-1", "auto_prepend_file=", "auto_append_file=", "xdebug.start_with_request=no",
        ]
        let command = Command(
            executable: runtime.folder.appending(path: "bin/php"),
            arguments: ["-c", paths.phpConfigFolder(line: runtime.line).appending(path: "php.ini").path(percentEncoded: false)]
                + settings.flatMap { ["-d", $0] }
                + ["-r", ""],
            environment: ServiceCatalog.phpEnvironment.merging(["PHP_INI_SCAN_DIR": scanFolder.path(percentEncoded: false)]) { _, new in new }
        )

        // CommandRunner keeps only the end of a long output and starts it with "...". The first
        // line is then only a part of a message. The baseline does not have this part.
        do {
            let output = try await CommandRunner.run(command)
            return "\(output.standardOutput)\n\(output.standardError)"
        } catch CommandError.failed(_, _, let output) {
            return output.hasPrefix("...") ? String(output.drop { !$0.isNewline }) : output
        }
    }

    private static func isSetting(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.hasPrefix(";")
    }

    func webDetails(of runtime: InstalledRuntime, state: EngineState, sites: [Site]) -> WebDetails {
        let available = toggleNames(of: runtime)

        switch runtime.name {
        case "php":
            return WebDetails(
                toggles: Self.extensionToggles(line: runtime.line, available: available, state: state),
                customSettings: state.phpCustomSettings[runtime.line] ?? [],
                usedBy: sites.filter { $0.php == runtime.line }.map(\.host).sorted()
            )
        case "nginx":
            return WebDetails(toggles: Self.moduleToggles(.nginx, available: available, state: state))
        case "httpd":
            let users = sites.filter { $0.server == .apache }.map(\.host).sorted()
            return WebDetails(
                toggles: Self.moduleToggles(.apache, available: available, state: state),
                usedBy: users,
                note: users.isEmpty ? "Apache runs only when a site uses it. No site uses Apache now." : nil
            )
        default:
            return WebDetails()
        }
    }
}
