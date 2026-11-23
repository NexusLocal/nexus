import ArgumentParser
import Foundation
import NexusCore
import NexusMCP

// nexus logs (group 7): the log files of the app of a site, as the Logs screen shows them.
struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Shows the newest entries of the log files of the app of the site or the workspace of the current folder, the newest last, for example: nexus logs --level error --follow",
        discussion: "An entry shows its time, its level, its message, its exception with the first line of the app, and a short context. Laravel writes storage/logs, WordPress writes debug.log when WP_DEBUG_LOG is on. --file \"PHP errors\" shows the PHP errors of the site. The Logs screen of Nexus shows the same entries."
    )

    @Argument(help: "A host or a folder. The default is the site or the workspace of the current folder.") var site: String?
    @Option(help: "Only this file, such as laravel.log, cronjobs/import.log or \"PHP errors\".") var file: String?
    @Option(help: "Only this level and the more serious ones: error, warning, info or debug.") var level: String?
    @Option(help: "Only the entries with this text, without a difference between capitals and small letters.") var search: String?
    @Option(help: "The number of newest entries. The default is 20.") var lines = 20
    @Flag(help: "Stays open and shows each new entry. Press Control-C to stop.") var follow = false
    @Flag(help: "Prints one JSON line for each entry.") var json = false

    func validate() throws {
        if let level, LogLevelGroup(rawValue: level.lowercased()) == nil {
            throw ValidationError("Give --level as error, warning, info or debug.")
        }

        if lines < 1 || lines > 500 {
            throw ValidationError("Give --lines from 1 to 500.")
        }
    }

    func run() async throws {
        let folder = RealPath.of(URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory))
        let toolbox = NexusToolbox(folder: folder)
        let chosenLevel = level.flatMap { LogLevelGroup(rawValue: $0.lowercased()) }
        let reader: AppLogReader

        do {
            reader = try AppLogReader(place: try await toolbox.logPlace(site), paths: toolbox.nexusPaths, file: file)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            throw ExitCode.failure
        }

        let entries = reader.entries(count: lines, level: chosenLevel, containing: search)

        if entries.isEmpty, !follow {
            print("No entries match. The logs of \(reader.place.id) are: \(reader.files.map(\.name).joined(separator: ", ")).")
        }

        entries.forEach(show)

        guard follow else {
            return
        }

        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(500))
            reader.newEntries(level: chosenLevel, containing: search).forEach(show)
        }
    }

    private func show(_ entry: AppLogEntry) {
        guard json else {
            print(entry.text)
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        if let data = try? encoder.encode(entry) {
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
