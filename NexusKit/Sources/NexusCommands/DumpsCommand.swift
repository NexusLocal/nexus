import ArgumentParser
import Foundation
import NexusCore
import NexusIPC
import NexusMCP

// nexus dumps (Part 9 of docs/dump-viewer-build.md). The name dump alone belongs to the database
// dumps: nexus db dumps lists them.
struct DumpsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dumps",
        abstract: "Shows the values of dump() and dd() that Nexus caught from PHP. Shows and changes the settings of the dump viewer too.",
        discussion: "nexus db dumps lists the database dumps in the Nexus trash.",
        subcommands: [List.self, Open.self, Settings.self],
        defaultSubcommand: List.self
    )

    static let defaultLimit = 20

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Shows the newest dumps under the line of their request, the newest last, for example: nexus dumps --site shop.test --follow",
            discussion: "Each dump shows the dump() or dd() call with its file and line, and then the text of the value. A web request and a command each count as one request. --limit counts dumps, not requests. A request with more dumps says how many of its older dumps are not shown."
        )

        @Option(help: "Only the dumps of this site or workspace, for example fix.shop.test. A site does not show the dumps of its workspaces.") var site: String?
        @Option(help: "The number of newest dumps. The default is 20. With --follow, 0 shows only the new dumps.") var limit: Int?
        @Flag(help: "Stays open and shows each new dump. Press Control-C to stop.") var follow = false
        @Flag(help: "Prints one JSON line for each dump, with its request.") var json = false
        @Flag(help: "Removes all dumps. With --site, only the dumps of that site or workspace.") var clear = false

        func validate() throws {
            if clear, follow {
                throw clearAlone()
            }

            if clear, json {
                throw clearAlone()
            }

            if clear, limit != nil {
                throw clearAlone()
            }

            if let limit, limit < 0 {
                throw ValidationError("Give a limit of 0 or more.")
            }

            if limit == 0, !follow {
                throw ValidationError("Give a limit of 1 or more. Only --follow takes 0.")
            }
        }

        private func clearAlone() -> ValidationError {
            ValidationError("Use --clear alone or with --site.")
        }

        func run() async throws {
            let target: (place: DumpPlace, host: String)? = if let site { try await DumpsCommand.place(of: site) } else { nil }
            let place = target?.place
            let write = DumpsCommand.write(_:toErrors:)

            if clear {
                try finish(try await send(.clearCaughtDumps(place: place)))
                return
            }

            if follow {
                let feed = NexusEventFeed()
                defer { feed.stop() }
                feed.start()

                var loop = DumpFollowLoop(
                    place: place,
                    limit: limit ?? DumpsCommand.defaultLimit,
                    json: json,
                    readLatest: DumpsCommand.lastDumps(place:limit:through:),
                    readNew: DumpsCommand.newDumps(place:after:),
                    write: write
                )
                try await loop.run(feed.updates)
                return
            }

            let state = try await DumpsCommand.state(place: place)

            guard state.loaded else {
                write([DumpList.notLoadedText], true)
                throw ExitCode.failure
            }

            var printer = DumpPrinter(json: json, write: write)
            printer.say(DumpText.notes(of: state, place: place))

            let latest = try await DumpsCommand.lastDumps(place: place, limit: limit ?? DumpsCommand.defaultLimit, through: nil)

            if !printer.show(latest: latest, now: .now) {
                printer.say([DumpText.noDumps(of: target?.host)])
            }
        }
    }

    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Opens the web page of the dumps in the browser, as nexus mail open opens the inbox.")

        func run() async throws {
            guard let page = try await DumpsCommand.state(place: DumpPlace()).page else {
                DumpsCommand.write([DumpState.pageMissingText], toErrors: true)
                throw ExitCode.failure
            }

            try await openWithSystem(page)
            print("The dumps open in the browser: \(page)")
        }
    }

    struct Settings: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shows or changes the settings of the dump viewer, for example: nexus dumps settings --page always")

        @Option(name: .customLong("catch-dumps"), help: "on or off. With on, Nexus collects each dump() and dd() of your PHP sites. With off, PHP prints each dump as without Nexus.") var catchDumps: OnOff?
        @Option(help: "automatic, always or never: if the web page still shows a dump(). Without Nexus, PHP prints each dump in the page. automatic (Normal pages only in the app) shows it in a page of the browser, but an API answer or an update of Livewire, Inertia, htmx or Turbo stays clean. always shows it in each answer, also JSON. never keeps the page clean. dd() always shows, because it stops the request.") var page: DumpPageMode?
        @Option(help: "on or off. With on, Nexus also catches the dumps of php artisan, queue workers and other PHP commands. The terminal still shows each dump.") var commands: OnOff?

        func run() async throws {
            // DumpPlace() is the place of the requests without a site. So nexusd reads no .env and
            // no .user.ini of a site for this state.
            var settings = try await DumpsCommand.state(place: DumpPlace()).settings

            guard catchDumps != nil || page != nil || commands != nil else {
                DumpsCommand.write(DumpText.lines(of: settings))
                return
            }

            settings.catchDumps = catchDumps.map { $0 == .on } ?? settings.catchDumps
            settings.pageMode = page ?? settings.pageMode
            settings.commands = commands.map { $0 == .on } ?? settings.commands
            try finish(try await send(.setDumpSettings(settings)))
        }
    }

    // nexusd knows the host of each site, alias and workspace. host is the first host of the site
    // or the workspace, for the text of an empty list.
    static func place(of host: String) async throws -> (place: DumpPlace, host: String) {
        let response = try await send(.dumpPlace(host: host))

        guard case .dumpPlace(let place, let firstHost) = response else {
            try finish(response)
            throw ExitCode.failure
        }

        return (place, firstHost)
    }

    static func state(place: DumpPlace?) async throws -> DumpState {
        let response = try await send(.dumpState(place: place))

        guard case .dumpState(let state) = response else {
            try finish(response)
            throw ExitCode.failure
        }

        return state
    }

    static func lastDumps(place: DumpPlace?, limit: Int, through cursor: DumpCursor?) async throws -> DumpBatch {
        try batch(in: try await send(.lastDumps(place: place, limit: limit, through: cursor)))
    }

    static func newDumps(place: DumpPlace?, after cursor: DumpCursor) async throws -> DumpBatch {
        try batch(in: try await send(.newDumps(place: place, after: cursor)))
    }

    private static func batch(in response: NexusResponse) throws -> DumpBatch {
        guard case .dumpBatch(let batch) = response else {
            try finish(response)
            throw ExitCode.failure
        }

        return batch
    }

    // One write for each group of lines, without a buffer. So --follow shows each dump at once,
    // also in a pipe.
    static func write(_ lines: [String], toErrors: Bool = false) {
        guard !lines.isEmpty else {
            return
        }

        let handle = toErrors ? FileHandle.standardError : FileHandle.standardOutput
        handle.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}

extension DumpPageMode: ExpressibleByArgument {}

// Writes the dumps of nexus dumps. A request shows its line once above its dumps. So the new dumps
// of a running command in --follow stay under their request. write gets the lines and true for the
// errors.
struct DumpPrinter {
    let json: Bool
    private let times: DumpTimeText
    private let write: ([String], Bool) -> Void
    private var lastRequest: String?
    private var printed = false

    init(json: Bool, timeZone: TimeZone = .current, write: @escaping ([String], Bool) -> Void) {
        self.json = json
        self.times = DumpTimeText(timeZone: timeZone)
        self.write = write
    }

    // The newest dumps of lastDumps. The list mode and the first list of --follow show them. Each
    // request shows its line once, with all its shown dumps under it. The request of the oldest
    // shown dump comes first. Returns true when it showed a dump.
    @discardableResult
    mutating func show(latest batch: DumpBatch, now: Date) -> Bool {
        let headers = Dictionary(batch.requests.map { ($0.id, $0) }) { first, _ in first }
        var order: [String] = []
        var grouped: [String: [CaughtDump]] = [:]

        for dump in batch.dumps {
            if grouped[dump.requestID] == nil {
                order.append(dump.requestID)
            }

            grouped[dump.requestID, default: []].append(dump)
        }

        var showed = false

        for id in order {
            if let request = headers[id] {
                showed = show(grouped[id] ?? [], of: request, older: batch.olderCounts[id] ?? 0, now: now) || showed
            }
        }

        return showed
    }

    // The dumps in the order in which they arrived, each under the line of its request.
    mutating func show(_ batch: DumpBatch, now: Date) {
        let headers = Dictionary(batch.requests.map { ($0.id, $0) }) { first, _ in first }

        for dump in batch.dumps {
            if let request = headers[dump.requestID] {
                show([dump], of: request, now: now)
            }
        }
    }

    // older is the number of older dumps of the request that the command does not show. A dump
    // that does not encode as JSON gets one line in the errors. The other dumps follow.
    @discardableResult
    mutating func show(_ dumps: [CaughtDump], of request: DumpedRequest, older: Int = 0, now: Date) -> Bool {
        guard !dumps.isEmpty else {
            return false
        }

        let olderNote = older > 0 ? [Self.olderText(older)] : []

        guard !json else {
            var lines: [String] = []
            var errors = olderNote.map { "Request \(request.id): \($0)" }

            for dump in dumps {
                do {
                    lines.append(try DumpText.json(request: request, dump: dump))
                } catch {
                    errors.append("Nexus cannot write the dump \(dump.id) as JSON.")
                }
            }

            write(lines, false)
            write(errors, true)
            return true
        }

        let header = request.id == lastRequest ? [] : separated([DumpText.header(of: request, now: now, times: times)])
        lastRequest = request.id
        write(header + olderNote.map { "  \($0)" } + dumps.flatMap(DumpText.lines(of:)), false)
        return true
    }

    static func olderText(_ older: Int) -> String {
        "\(Count.text(older, "older dump")) of this request \(older == 1 ? "is" : "are") not shown. Use --limit to see more."
    }

    // With --json the output holds only the dumps. So a script can read each line. A message then
    // goes to the errors. A message between the dumps ends the group of the request. So its next
    // dump shows the line of the request again.
    mutating func say(_ lines: [String]) {
        guard !lines.isEmpty else {
            return
        }

        guard !json else {
            write(lines, true)
            return
        }

        lastRequest = nil
        write(separated(lines), false)
    }

    private mutating func separated(_ lines: [String]) -> [String] {
        defer { printed = true }

        return (printed ? [""] : []) + lines
    }
}

// nexus dumps --follow. The command gives it the event feed, the reads and the output. The first
// loaded list of the feed gives the cursor. The command then shows the newest dumps up to that
// cursor, as the list mode does. After that each change of the place gives the dumps after the
// cursor. A later list of the same epoch reads them too and shows only the warnings that are new.
// A list or a read of another epoch starts again with the newest dumps.
struct DumpFollowLoop {
    static let waitText = "Nexus waits for new dumps. Press Control-C to stop."
    static let againText = "nexusd started a new list of dumps, for example after a clear of all dumps. The newest dumps follow."

    private let limit: Int
    private let readLatest: (DumpPlace?, Int, DumpCursor?) async throws -> DumpBatch
    private let readNew: (DumpPlace?, DumpCursor) async throws -> DumpBatch
    private let write: ([String], Bool) -> Void
    private let now: () -> Date
    private var follower: DumpFollower
    private var printer: DumpPrinter
    private var notes: [String] = []
    private var waiting = false
    private var unreadable = false

    init(
        place: DumpPlace?,
        limit: Int,
        json: Bool,
        timeZone: TimeZone = .current,
        readLatest: @escaping (DumpPlace?, Int, DumpCursor?) async throws -> DumpBatch,
        readNew: @escaping (DumpPlace?, DumpCursor) async throws -> DumpBatch,
        write: @escaping ([String], Bool) -> Void,
        now: @escaping () -> Date = { .now }
    ) {
        self.limit = limit
        self.readLatest = readLatest
        self.readNew = readNew
        self.write = write
        self.now = now
        follower = DumpFollower(place: place)
        printer = DumpPrinter(json: json, timeZone: timeZone, write: write)
    }

    mutating func run(_ updates: AsyncStream<NexusFeedUpdate>) async throws {
        for await update in updates {
            switch update {
            case .event(.dumpList(let list)):
                unreadable = false
                waiting = false

                guard let listCursor = list.cursor else {
                    continue
                }

                showNotes(of: list)

                guard follower.startsAgain(at: listCursor) else {
                    await showNewDumps()
                    continue
                }

                await begin(at: listCursor)
            case .event(.dumpChanges(let change)):
                unreadable = false

                if follower.reads(after: change) {
                    await showNewDumps()
                }
            case .event:
                unreadable = false
            case .unreachable(let reason):
                unreadable = false

                guard follower.cursor != nil else {
                    write([ErrorText.plain(NexusClientError.daemonNotRunning(reason))], true)
                    throw ExitCode.failure
                }

                if !waiting {
                    write(["\(reason) The command waits until nexusd answers again."], true)
                    waiting = true
                }
            case .unreadable(let message):
                if !unreadable {
                    write([message], true)
                    unreadable = true
                }
            }
        }
    }

    private mutating func showNotes(of list: DumpList) {
        let current = DumpText.notes(of: list.state, place: follower.place)
        printer.say(current.filter { !notes.contains($0) })
        notes = current
    }

    // A failed read of the newest dumps leaves them out. send() writes the reason.
    private mutating func begin(at listCursor: DumpCursor) async {
        let first = follower.cursor == nil
        follower.begin(at: listCursor)

        if !first {
            printer.say([Self.againText])
        }

        if limit > 0, let latest = try? await readLatest(follower.place, limit, listCursor) {
            printer.show(latest: latest, now: now())
        }

        if first {
            printer.say([Self.waitText])
        }
    }

    // A read that fails keeps the cursor. So the next event reads the same dumps again. The cursor
    // moves only after the dumps of the batch are written. An answer of another epoch has no dumps
    // and the current cursor. The follow starts again at that cursor.
    private mutating func showNewDumps() async {
        guard let cursor = follower.cursor, let batch = try? await readNew(follower.place, cursor) else {
            return
        }

        guard batch.cursor.epoch == cursor.epoch else {
            await begin(at: batch.cursor)
            return
        }

        printer.show(batch, now: now())
        follower.move(to: batch)
    }
}
