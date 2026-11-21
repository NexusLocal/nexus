import ArgumentParser
import Darwin
import Dispatch
import Foundation
import NexusCore
import NexusIPC
import Synchronization

// nexus share (group 4, 4b). It asks no "Type yes" question (decision 10). A value that the command
// line does not give takes its default from Settings > Sharing.
struct ShareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "share",
        abstract: "Opens, stops and lists the public links of the sites.",
        subcommands: [Start.self, Stop.self, List.self],
        defaultSubcommand: Start.self
    )

    enum ErrorDetails: EnumerableFlag {
        case hideErrors
        case showErrors
    }

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Opens a public link to the site or the workspace of the current folder, for example: nexus share",
            discussion: "Anyone with the link can open the site. Links go through Cloudflare. The terms of Cloudflare apply to each link. An option that you leave out takes its default from Settings > Sharing."
        )

        @Argument(help: "The host of a site or a workspace. The default is the site or the workspace of the current folder.") var host: String?
        @Option(name: .customLong("for"), help: "Ends the link after 1h, 4h or 8h.") var duration: ShareDuration?
        @Flag(help: "Keeps the link open until you stop it.") var untilStopped = false
        @Flag(inversion: .prefixedNo, help: "Asks visitors for a password, or not.") var password: Bool?
        @Flag(help: "Hides or shows error details and debug tools for visitors.") var errorDetails: ErrorDetails?
        @Option(help: "Gives visitors the styles and scripts of Vite from the dev server (live) or from a build (build).") var vite: ShareViteMode?
        @Flag(inversion: .prefixedNo, help: "Keeps a list of the requests in the dump viewer, or not.") var requests: Bool?
        @Option(help: ArgumentHelp(ShareText.OwnDomain.addressHelp)) var address: String?
        @Flag(help: "Prints the link as JSON.") var json = false

        func validate() throws {
            if duration != nil, untilStopped {
                throw ValidationError(ShareText.forOrUntilStopped)
            }

            if let label, let problem = OwnDomainName.labelProblem(label) {
                throw ValidationError(problem)
            }
        }

        // --address random gives a new random address. Another value is a label on the own domain
        // (4h). So the label random is possible only in the confirmation window.
        static let randomAddress = "random"

        private var typedAddress: String? {
            address.map(OwnDomainName.label)
        }

        private var label: String? {
            typedAddress == Self.randomAddress ? nil : typedAddress
        }

        // The options that the command line does not give are nil. nexusd then takes the defaults.
        func shareStart(host: String) -> ShareStart {
            ShareStart(
                host: host,
                duration: untilStopped ? .untilStopped : duration,
                password: password,
                hidesErrors: errorDetails.map { $0 == .hideErrors },
                viteMode: vite,
                keepsRequests: requests,
                address: typedAddress.map { $0 == Self.randomAddress ? .random : .ownDomain },
                label: label
            )
        }

        // With --json the lines for the user go to standard error. So standard output holds only the
        // JSON.
        func run() async throws {
            let target = try await siteTarget(host: host, example: "nexus share shop.test")
            let note = { (line: String) in
                if json {
                    FileHandle.standardError.write(Data("\(line)\n".utf8))
                } else {
                    print(line)
                }
            }

            note(ShareText.warning)
            note(ShareText.opening(target.host))

            // The message coder keeps whole seconds only. So a link that this command opened can
            // have a start time just before the exact time of the request.
            let begin = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
            let (response, interrupted) = try await InterruptStop.during(host: target.host) {
                try await send(.startShare(shareStart(host: target.host)))
            }

            if let stop = interrupted {
                await stop.report()
                throw ExitCode(130)
            }

            guard case .share(let info) = response else {
                try finish(response)
                return
            }

            guard !json else {
                print(try shareJSON(info))
                return
            }

            if info.started < begin {
                print(ShareText.openAlready(info.host))
            }

            // 4e: an old Vite version makes the link use Build. The text says why.
            if let liveBlocked = info.liveBlocked {
                print(liveBlocked)
            }

            print(info.url ?? "")
            print(info.endsAt.map { ShareText.endsAt($0) } ?? ShareText.staysOpen)

            if let password = info.password {
                print(ShareText.passwordLine(password))
            }

            if isatty(STDOUT_FILENO) == 1, let url = info.url {
                print("")
                TerminalQRCode.lines(for: url).forEach { print("\u{1B}[30;107m\($0)\u{1B}[0m") }
                print("")
            }

            print(ShareText.stopHint(info.host))
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stops the public link of the site or the workspace of the current folder, for example: nexus share stop")

        @Argument(help: "The host of a site or a workspace. The default is the site or the workspace of the current folder.") var host: String?
        @Flag(help: "Stops each public link.") var all = false

        // A given host goes to nexusd as it is. So the link of a site that went away can still stop.
        func run() async throws {
            if all {
                try finish(try await send(.stopAllShares(appQuit: false)))
                return
            }

            guard let host else {
                let target = try await siteTarget(host: nil, example: "nexus share stop shop.test")
                try finish(try await send(.stopShare(host: target.host)))
                return
            }

            try finish(try await send(.stopShare(host: host)))
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Lists the public links that are open.")

        @Flag(help: "Prints the links as JSON.") var json = false

        func run() async throws {
            let response = try await send(.shares)

            guard case .shares(let links) = response else {
                try finish(response)
                return
            }

            guard !json else {
                print(try shareJSON(links))
                return
            }

            let open = links.filter(\.state.isActive)

            guard !open.isEmpty else {
                print(ShareText.noLinkOpen)
                return
            }

            Self.lines(open).forEach { print($0) }
        }

        // The columns of nexus site list: the host, the URL, the end and the visitors.
        static func lines(_ links: [ShareInfo]) -> [String] {
            let rows = links.map { link in
                [link.host, link.url ?? ShareText.opensNow, ShareText.until(link.endsAt), Count.text(link.visitors, "visitor")]
            }
            let widths = (0..<3).map { column in rows.map { $0[column].count }.max() ?? 0 }

            return rows.map { row in
                (row.prefix(3).enumerated().map { $0.element.padding(to: widths[$0.offset]) } + [row[3]]).joined(separator: "  ")
            }
        }
    }
}

// Ctrl-C during the wait stops the link that opens (owner, review-4ab question 17). Without it the
// link opens and the user never sees its address. A second Ctrl-C ends the command at once. After the
// open Ctrl-C ends the command as usual. So the QR code prints in full.
final class InterruptStop: Sendable {
    private let source: any DispatchSourceSignal
    private let stop = Mutex<Task<NexusResponse?, Never>?>(nil)

    init(host: String) {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())

        source.setEventHandler { [self] in
            self.stop.withLock { stop in
                guard stop == nil else {
                    Darwin.exit(130)
                }

                stop = Task { try? await NexusClient().send(.stopShare(host: host)) }
            }
        }

        source.resume()
    }

    // The stop that Ctrl-C sent, or nil without Ctrl-C.
    func end() -> Task<NexusResponse?, Never>? {
        source.cancel()
        signal(SIGINT, SIG_DFL)
        return stop.withLock { $0 }
    }

    // Runs body while Ctrl-C stops the link. Ctrl-C gets its usual effect again also when body
    // throws. A second end() changes nothing.
    static func during<Value>(host: String, _ body: () async throws -> Value) async throws -> (value: Value, stop: Task<NexusResponse?, Never>?) {
        let interrupt = InterruptStop(host: host)
        defer { _ = interrupt.end() }

        let value = try await body()
        return (value, interrupt.end())
    }
}

extension Task where Success == NexusResponse?, Failure == Never {
    // The answer of the stop after Ctrl-C.
    func report() async {
        switch await value {
        case .done(let message)?:
            print(message)
        case .failure(let message)?:
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        default:
            break
        }
    }
}

// The JSON of a link uses ISO 8601 times, as the IPC does.
func shareJSON(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

extension ShareDuration: ExpressibleByArgument {
    public init?(argument: String) {
        guard let value = Self.allCases.first(where: { $0.argumentName == argument }) else {
            return nil
        }

        self = value
    }

    public static var allValueStrings: [String] {
        allCases.compactMap(\.argumentName)
    }

    // --until-stopped gives the case without a time.
    var argumentName: String? {
        switch self {
        case .oneHour: "1h"
        case .fourHours: "4h"
        case .eightHours: "8h"
        case .untilStopped: nil
        }
    }
}

extension ShareViteMode: ExpressibleByArgument {}
