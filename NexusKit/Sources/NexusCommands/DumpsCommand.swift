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
        abstract: "Shows the values of dump() and dd(), the queries, the log lines and the queue jobs that Nexus caught from PHP. Shows and changes the settings of the dump viewer too.",
        discussion: "nexus db dumps lists the database dumps in the Nexus trash.",
        subcommands: [List.self, Open.self, Settings.self],
        defaultSubcommand: List.self
    )

    static let defaultLimit = 20

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Shows the newest entries under the line of their request, the newest last, for example: nexus dumps --site shop.test --follow",
            discussion: "An entry is a dump() or dd() call, a query, a log line or a job row. A dump shows its file and line, and then the text of the value. A query shows its time, its tags (N+1, duplicate, slow), the SQL and its file and line. A log line shows its level, the message, the file and line and its context. A web request, a command and a job of a queue worker each count as one request. --limit counts entries, not requests. A request with more entries says how many of its older entries are not shown."
        )

        @Option(help: "Only the entries of this site or workspace, for example fix.shop.test. A site does not show the entries of its workspaces.") var site: String?
        @Option(help: "The number of newest entries of all kinds. The default is 20. With --follow, 0 shows only the new entries.") var limit: Int?
        @Flag(help: "Stays open and shows each new entry. Press Control-C to stop.") var follow = false
        @Flag(help: "Prints one JSON line for each entry, with its request and the tags of a query.") var json = false
        @Flag(help: "Removes all requests. With --site, only the requests of that site or workspace.") var clear = false

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
                    readRequest: DumpsCommand.queries(of:after:),
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
            var queries = KnownQueries()
            let tags = await queries.tags(for: latest, readRequest: DumpsCommand.queries(of:after:))

            if !printer.show(latest: latest, now: .now, tags: tags) {
                printer.say([DumpText.noRequests(of: target?.host)])
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
        @Option(name: .customLong("catch-queries"), help: "on or off. With on, Nexus collects the database queries of your Laravel and WordPress sites, each with its time and the line of your code that ran it. The default is off.") var catchQueries: OnOff?
        @Option(name: .customLong("catch-logs"), help: "on or off. With on, Nexus collects the log lines of Laravel and the PHP errors, warnings and notices of your PHP sites. The log files stay as they are.") var catchLogs: OnOff?
        @Option(name: .customLong("catch-jobs"), help: "on or off. With on, Nexus collects the queue jobs of Laravel, the WP-Cron events and the actions of Action Scheduler. Each job of a queue worker shows as its own request. The default is off.") var catchJobs: OnOff?
        @Option(help: "automatic, always or never: if the web page still shows a dump(). Without Nexus, PHP prints each dump in the page. automatic (Normal pages only in the app) shows it in a page of the browser, but an API answer or an update of Livewire, Inertia, htmx or Turbo stays clean. always shows it in each answer, also JSON. never keeps the page clean. dd() always shows, because it stops the request.") var page: DumpPageMode?
        @Option(help: "on or off. With on, Nexus also catches the dumps, queries, log lines and jobs of php artisan, queue workers and other PHP commands. The terminal still shows each dump.") var commands: OnOff?

        func run() async throws {
            // DumpPlace() is the place of the requests without a site. So nexusd reads no .env and
            // no .user.ini of a site for this state.
            var settings = try await DumpsCommand.state(place: DumpPlace()).settings
            let switches = [catchDumps, catchQueries, catchLogs, catchJobs, commands]

            guard page != nil || switches.contains(where: { choice in choice != nil }) else {
                DumpsCommand.write(DumpText.lines(of: settings))
                return
            }

            settings.catchDumps = catchDumps.map { choice in choice == .on } ?? settings.catchDumps
            settings.catchQueries = catchQueries.map { choice in choice == .on } ?? settings.catchQueries
            settings.catchLogs = catchLogs.map { choice in choice == .on } ?? settings.catchLogs
            settings.catchJobs = catchJobs.map { choice in choice == .on } ?? settings.catchJobs
            settings.pageMode = page ?? settings.pageMode
            settings.commands = commands.map { choice in choice == .on } ?? settings.commands
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

    // Only the queries. The tags need nothing else.
    static func queries(of request: String, after number: Int) async throws -> [CaughtDump] {
        let response = try await send(.requestEntries(request: request, afterNumber: number, kinds: [.query]))

        guard case .caughtDumps(let entries) = response else {
            try finish(response)
            throw ExitCode.failure
        }

        return entries
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

// The queries of each request that nexus dumps showed. The tags of a query need all queries of its
// request, and a batch can hold only some of them. So a request gets all its queries from nexusd
// the first time. After that --follow keeps them and asks only after the highest number that it
// knows. A query below the firstNumber of the header is gone from the store. So it goes here too.
struct KnownQueries {
    private var queries: [String: [CaughtDump]] = [:]

    // Each request of the batch gets its tags. A read that fails leaves the queries that it knows.
    mutating func tags(for batch: DumpBatch, readRequest: (String, Int) async throws -> [CaughtDump]) async -> [String: QueryTags] {
        let shown = Dictionary(grouping: batch.dumps.filter { entry in entry.kind == .query }, by: \.requestID)
        var tags: [String: QueryTags] = [:]

        for request in batch.requests {
            let isKnown = queries[request.id] != nil
            var known = merged(queries[request.id] ?? [], shown[request.id] ?? [], from: request.firstNumber)

            if known.count < request.queryCount {
                let after = isKnown ? known.last?.number ?? 0 : 0

                if let read = try? await readRequest(request.id, after) {
                    known = merged(known, read.filter { entry in entry.kind == .query }, from: request.firstNumber)
                }
            }

            if request.queryCount > 0 {
                queries[request.id] = known
            }

            tags[request.id] = QueryTags(known)
        }

        return tags
    }

    // A removed request and a clear free their queries. A query that the user removed no longer
    // counts in the tags of its request.
    mutating func forget(_ change: DumpChange) {
        if change.cleared {
            queries.removeAll()
        }

        for id in change.removed {
            queries[id] = nil
        }

        guard !change.removedDumps.isEmpty else {
            return
        }

        let removed = Set(change.removedDumps)
        queries = queries.mapValues { known in known.filter { query in !removed.contains(query.number) } }
    }

    mutating func forgetAll() {
        queries.removeAll()
    }

    // In the order of their numbers, each number once.
    private func merged(_ known: [CaughtDump], _ new: [CaughtDump], from firstNumber: Int) -> [CaughtDump] {
        var numbers = Set(known.map(\.number))
        let added = new.filter { query in numbers.insert(query.number).inserted }
        return (known + added).filter { query in query.number >= firstNumber }.sorted { $0.number < $1.number }
    }
}

// Writes the entries of nexus dumps. A request shows its line once above its entries. So the new
// entries of a running command in --follow stay under their request. write gets the lines and true
// for the errors.
struct DumpPrinter {
    let json: Bool
    private let times: DumpTimeText
    private let locale: Locale
    private let write: ([String], Bool) -> Void
    private var lastRequest: String?
    private var printed = false

    init(json: Bool, timeZone: TimeZone = .current, locale: Locale = .current, write: @escaping ([String], Bool) -> Void) {
        self.json = json
        self.times = DumpTimeText(timeZone: timeZone)
        self.locale = locale
        self.write = write
    }

    // The newest entries of lastDumps. The list mode and the first list of --follow show them. Each
    // request shows its line once, with all its shown entries under it. The request of the oldest
    // shown entry comes first. tags holds the tags of the queries of each request of the batch, as
    // KnownQueries gives them. Returns true when it showed an entry.
    @discardableResult
    mutating func show(latest batch: DumpBatch, now: Date, tags: [String: QueryTags]) -> Bool {
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
            if let request = headers[id], let requestTags = tags[id] {
                showed = show(grouped[id] ?? [], of: request, older: batch.olderCounts[id] ?? 0, now: now, tags: requestTags) || showed
            }
        }

        return showed
    }

    // The entries in the order in which they arrived, each under the line of its request.
    mutating func show(_ batch: DumpBatch, now: Date, tags: [String: QueryTags]) {
        let headers = Dictionary(batch.requests.map { ($0.id, $0) }) { first, _ in first }

        for entry in batch.dumps {
            if let request = headers[entry.requestID], let requestTags = tags[entry.requestID] {
                show([entry], of: request, now: now, tags: requestTags)
            }
        }
    }

    // older is the number of older entries of the request that the command does not show. An entry
    // that does not encode as JSON gets one line in the errors. The other entries follow. tags holds
    // the tags of all queries of the request.
    @discardableResult
    mutating func show(_ entries: [CaughtDump], of request: DumpedRequest, older: Int = 0, now: Date, tags: QueryTags) -> Bool {
        guard !entries.isEmpty else {
            return false
        }

        let olderNote = older > 0 ? [Self.olderText(older)] : []

        guard !json else {
            var lines: [String] = []
            var errors = olderNote.map { "Request \(request.id): \($0)" }

            for entry in entries {
                do {
                    lines.append(try DumpText.json(request: request, dump: entry, marks: tags.marks.marks(of: entry)))
                } catch {
                    errors.append("Nexus cannot write the entry \(entry.id) as JSON.")
                }
            }

            write(lines, false)
            write(errors, true)
            return true
        }

        let header = request.id == lastRequest ? [] : separated([DumpText.header(of: request, now: now, times: times)] + DumpText.details(of: request, locale: locale))
        lastRequest = request.id
        write(header + olderNote.map { "  \($0)" } + entries.flatMap { entry in DumpText.lines(of: entry, tags: tags, locale: locale) }, false)
        return true
    }

    static func olderText(_ older: Int) -> String {
        "\(Count.text(older, "older entry", plural: "older entries")) of this request \(older == 1 ? "is" : "are") not shown. Use --limit to see more."
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
    private let readRequest: (String, Int) async throws -> [CaughtDump]
    private let write: ([String], Bool) -> Void
    private let now: () -> Date
    private var follower: DumpFollower
    private var printer: DumpPrinter
    private var queries = KnownQueries()
    private var notes: [String] = []
    private var waiting = false
    private var unreadable = false

    // readRequest gives the queries of a request after a number, for their tags.
    init(
        place: DumpPlace?,
        limit: Int,
        json: Bool,
        timeZone: TimeZone = .current,
        readLatest: @escaping (DumpPlace?, Int, DumpCursor?) async throws -> DumpBatch,
        readNew: @escaping (DumpPlace?, DumpCursor) async throws -> DumpBatch,
        readRequest: @escaping (String, Int) async throws -> [CaughtDump],
        write: @escaping ([String], Bool) -> Void,
        now: @escaping () -> Date = { .now }
    ) {
        self.limit = limit
        self.readLatest = readLatest
        self.readNew = readNew
        self.readRequest = readRequest
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
                queries.forget(change)

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
        queries.forgetAll()

        if !first {
            printer.say([Self.againText])
        }

        if limit > 0, let latest = try? await readLatest(follower.place, limit, listCursor) {
            let tags = await queries.tags(for: latest, readRequest: readRequest)
            printer.show(latest: latest, now: now(), tags: tags)
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

        let tags = await queries.tags(for: batch, readRequest: readRequest)
        printer.show(batch, now: now(), tags: tags)
        follower.move(to: batch)
    }
}
