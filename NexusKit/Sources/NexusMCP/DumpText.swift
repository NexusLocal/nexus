import Foundation
import NexusCore
import NexusIPC

// The text of the caught dumps for nexus dumps and the MCP tool read_dumps.

// One dump with its request, as one JSON line. Dates are ISO 8601. tree is the JSON of the tree as
// one string, as PHP sent it. The numbers of the store are values for the app. So the line leaves
// them out: a number of 0 has no key.
public struct CaughtDumpLine: Encodable, Sendable {
    public let request: DumpedRequest
    public let dump: CaughtDump

    public init(request: DumpedRequest, dump: CaughtDump) {
        var plainRequest = request
        plainRequest.lastNumber = 0
        plainRequest.firstNumber = 0
        var plainDump = dump
        plainDump.number = 0

        self.request = plainRequest
        self.dump = plainDump
    }
}

// The time of a request. A request of an earlier day shows its date too, because the list keeps
// the dumps of earlier runs. The formats are made once.
public struct DumpTimeText: Sendable {
    private let calendar: Calendar
    private let time: Date.VerbatimFormatStyle
    private let dateAndTime: Date.VerbatimFormatStyle

    public init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar

        time = Date.VerbatimFormatStyle(format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)", timeZone: timeZone, calendar: calendar)
        dateAndTime = Date.VerbatimFormatStyle(format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)", timeZone: timeZone, calendar: calendar)
    }

    public func text(_ date: Date, now: Date) -> String {
        calendar.isDate(date, inSameDayAs: now) ? date.formatted(time) : date.formatted(dateAndTime)
    }
}

public enum DumpText {
    public static func header(of request: DumpedRequest, now: Date, times: DumpTimeText) -> String {
        var parts = [times.text(request.started, now: now), request.displayMethod, request.url ?? request.target]
        parts += [request.statusText, request.durationText].compactMap { $0 }

        // The URL of a web request names its host already.
        if request.kind == .command, let site = request.site {
            parts.append(request.workspace.map { "workspace \($0) of \(site)" } ?? site)
        }

        return parts.joined(separator: "  ")
    }

    public static func lines(of dump: CaughtDump) -> [String] {
        let label = dump.label.map { " \"\($0)\"" } ?? ""
        let source = dump.file.map { file in " at \(file)\(dump.line.map { ":\($0)" } ?? "")" } ?? ""
        var text = Substring(dump.text)

        while text.hasSuffix("\n") {
            text = text.dropLast()
        }

        var lines = ["  \(dump.kind.rawValue)\(label)\(source)"]
        lines += text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : "    \($0)" }

        if dump.truncated {
            lines.append("    [The text stops here, because the dump is larger than 64 KB.]")
        }

        return lines
    }

    public static func json(request: DumpedRequest, dump: CaughtDump) throws -> String {
        String(decoding: try JSONEncoder.mcp.encode(CaughtDumpLine(request: request, dump: dump)), as: UTF8.self)
    }

    // The blocks of an event list hold all places. place keeps only the blocks of one site or
    // workspace. nil keeps all.
    public static func notes(of state: DumpState, place: DumpPlace?) -> [String] {
        var notes: [String] = []

        if !state.settings.catchDumps {
            notes.append("Catch dumps is off. So Nexus catches no new dumps. Turn it on with: nexus dumps settings --catch-dumps on")
        }

        notes += (state.problem ?? "").split(separator: "\n").map { "Warning: \($0)" }
        notes += state.blocked.filter { block in place.includes(block.place ?? DumpPlace()) }.map { "Warning: \(text(of: $0))" }
        return notes
    }

    public static func text(of block: DumpBlock) -> String {
        switch block.reason {
        case .varDumperFormat:
            let source = block.file ?? "the environment of PHP"
            return "Nexus catches no dumps of \(block.host), because \(source) sets VAR_DUMPER_FORMAT. Remove that key to catch them."
        case .userIni:
            let source = block.file ?? "a .user.ini"
            return "Nexus catches no dumps of \(block.host), because \(source) sets its own auto_prepend_file."
        }
    }

    public static func noDumps(of host: String?) -> String {
        host.map { "Nexus has no dumps of \($0)." } ?? "Nexus has no dumps."
    }

    public static func lines(of settings: DumpSettings) -> [String] {
        [
            "Catch dumps  \(settings.catchDumps ? "on" : "off")",
            "Page         \(settings.pageMode.rawValue) (\(settings.pageMode.title))",
            "Commands     \(settings.commands ? "on" : "off")",
        ]
    }
}
