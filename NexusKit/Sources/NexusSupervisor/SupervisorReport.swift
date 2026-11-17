import Darwin
import Foundation
import NexusCore

// How a program ended: with an exit status or with a signal. A parent cannot see who sent a
// signal. So the activity log names only the signal.
public enum ProcessEnd: Sendable, Equatable {
    case exit(status: Int32)
    case signal(Int32)

    init(reason: Process.TerminationReason, status: Int32) {
        self = reason == .uncaughtSignal ? .signal(status) : .exit(status: status)
    }

    var failed: Bool {
        self != .exit(status: 0)
    }

    var status: Int32 {
        switch self {
        case .exit(let status): status
        case .signal(let number): number
        }
    }

    public var text: String {
        switch self {
        case .exit(let status):
            "exit status \(status)"
        case .signal(let number):
            Self.signalNames[number].map { "signal \(number) (\($0))" } ?? "signal \(number)"
        }
    }

    // The failed state in the app and in nexus status uses plain words. The number stays for a
    // search in a log.
    var lastEndText: String {
        switch self {
        case .signal(let number) where [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP, SIGSYS].contains(number):
            "The last time it crashed (signal \(number))."
        case .signal(let number) where [SIGTERM, SIGINT, SIGHUP, SIGQUIT].contains(number):
            "The last time another program stopped it (signal \(number))."
        case .signal(SIGKILL):
            "The last time macOS or another program ended it (signal \(SIGKILL))."
        case .signal(let number):
            "The last time it ended with signal \(number)."
        case .exit(status: 0):
            "The last time it stopped by itself (exit status 0)."
        case .exit(let status):
            "The last time it stopped with an error (exit status \(status))."
        }
    }

    // The signals that end a process when it does not handle them.
    private static let signalNames: [Int32: String] = [
        SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGILL: "SIGILL", SIGTRAP: "SIGTRAP",
        SIGABRT: "SIGABRT", SIGEMT: "SIGEMT", SIGFPE: "SIGFPE", SIGKILL: "SIGKILL", SIGBUS: "SIGBUS",
        SIGSEGV: "SIGSEGV", SIGSYS: "SIGSYS", SIGPIPE: "SIGPIPE", SIGALRM: "SIGALRM", SIGTERM: "SIGTERM",
        SIGIO: "SIGIO", SIGXCPU: "SIGXCPU", SIGXFSZ: "SIGXFSZ", SIGVTALRM: "SIGVTALRM", SIGPROF: "SIGPROF",
        SIGUSR1: "SIGUSR1", SIGUSR2: "SIGUSR2",
    ]
}

// What the supervisor tells about a program for the activity log: each start, each stop that
// nexusd asked for with its cause, each end that nexusd did not ask for and each start that failed
// (bug 2026-11-17).
public struct SupervisorReport: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case started
        case stopped(cause: String)
        // A restart attempt of nil means that the supervisor does not start the program again.
        case ended(ProcessEnd, restartAttempt: Int?)
        case notStarted(reason: String)
    }

    public let id: String
    // Only a program of a workspace with this name gets a line.
    public let name: String?
    public let pid: Int32?
    public let ports: [Int]
    public let event: Event

    public init(id: String, name: String? = nil, pid: Int32?, ports: [Int], event: Event) {
        self.id = id
        self.name = name
        self.pid = pid
        self.ports = ports
        self.event = event
    }

    public var text: String {
        let name = name ?? id
        let process = pid.map { " (process \($0))" } ?? ""

        switch event {
        case .started where ports.isEmpty:
            return "\(name) started\(process)."
        case .started:
            return "\(name) started on \(ports.count == 1 ? "port" : "ports") \(EnglishList.joined(ports.map(String.init)))\(process)."
        case .stopped(let cause):
            return "\(name)\(process) stopped: \(cause)"
        case .ended(let end, let attempt?):
            return "\(name)\(process) ended with \(end.text). Nexus did not ask for this stop. Nexus starts it again, attempt \(attempt)."
        case .ended(let end, nil):
            return "\(name)\(process) ended with \(end.text). Nexus did not ask for this stop. Nexus does not start it again, because it stopped too often within a short time."
        case .notStarted(let reason):
            return "\(name) did not start: \(reason)"
        }
    }
}
