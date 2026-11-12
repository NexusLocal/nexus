import Foundation
import NexusConfig
import NexusCore
import NexusDumps
import NexusIPC
import Synchronization

// The reader threads of the receiver wake the actor once for each group of changes. So a loop of
// dumps in PHP does not make a task for each dump.
final class DumpChangeSignal: Sendable {
    private let pending = Atomic(false)

    func raise() -> Bool {
        !pending.exchange(true, ordering: .acquiringAndReleasing)
    }

    func lower() {
        pending.store(false, ordering: .releasing)
    }
}

// The dump viewer (Part 7 of docs/dump-viewer-build.md). The app gets only the request headers as
// events. It asks for the dumps of one request when the user selects it. So a change of the list
// never sends the dumps again.
extension NexusEngine {
    static let dumpEventBlockLimit = 100
    static let varDumperFormatKey = "VAR_DUMPER_FORMAT"

    struct DumpBlockKey: Hashable {
        let host: String
        let reason: DumpBlock.Reason
    }

    // A web request and a command can have another VAR_DUMPER_FORMAT, for example from the shell.
    // So each kind keeps its own block.
    struct EventDumpBlockKey: Hashable {
        let block: DumpBlockKey
        let kind: DumpedRequest.Kind
    }

    struct EventDumpBlock {
        let place: DumpPlace
        let started: Date
        let arrived: ContinuousClock.Instant

        // A later request of the same place and kind that sends a dump shows that PHP catches
        // these dumps again.
        func isAnswered(by header: DumpedRequest, kind: DumpedRequest.Kind) -> Bool {
            guard header.place == place else {
                return false
            }

            guard header.kind == kind else {
                return false
            }

            return header.started > started
        }
    }

    // Runs before applyWeb starts PHP-FPM. The sites can have changed while nexusd did not run. So
    // each loaded request gets its place again. A watcher that connected before the load gets the
    // loaded list at once, before the services start. A receiver that cannot start never stops
    // nexusd. PHP then pauses its dumps. The list says why.
    func startDumpReceiver() async {
        guard dumpReceiver == nil else {
            return
        }

        siteMap.set(buildSiteMap(await stateStore.current()))
        dumpStore.load()
        dumpStore.relocate()
        await startDumpPage()
        await publishDumpList()

        let store = dumpStore
        let signal = dumpSignal
        let receiver = DumpReceiver(socket: paths.dumpSocket, folder: paths.dumpFolder) { [weak self] event in
            store.add(event)

            if case .blocked(let request, let reason, _) = event {
                Task { await self?.dumpBlocked(request.header, reason: reason) }
                return
            }

            if signal.raise() {
                Task { await self?.dumpsChanged() }
            }
        }

        do {
            try receiver.start()
            dumpReceiver = receiver
            dumpReceiverProblem = nil
        } catch {
            let problem = "Nexus catches no dumps, because nexusd cannot listen on its socket. \(ErrorText.plain(error))"
            dumpReceiverProblem = problem
            activity?.write("dumps", problem)
        }
    }

    // No event reaches the store after the stop. The store then writes its last lines. A blocked
    // event and a problem of this run do not count for the next start.
    func stopDumpReceiver() {
        dumpReceiver?.stop()
        dumpReceiver = nil
        stopDumpPage()
        dumpTicker?.cancel()
        dumpTicker = nil
        dumpEventBlocks = [:]
        dumpReceiverProblem = nil
        dumpStore.waitForWrites()
    }

    // The list shows each block with the host of a site. So a block outside every site goes.
    func dumpBlocked(_ request: DumpedRequest, reason: DumpBlock.Reason) async {
        guard let entry = siteMap.current.entry(of: request) else {
            return
        }

        let key = EventDumpBlockKey(block: DumpBlockKey(host: entry.host, reason: reason), kind: request.kind)
        dumpEventBlocks[key] = EventDumpBlock(place: entry.place, started: request.started, arrived: .now)

        let first = dumpEventBlocks.count > Self.dumpEventBlockLimit ? dumpEventBlocks.min { $0.value.arrived < $1.value.arrived }?.key : nil

        if let first {
            dumpEventBlocks[first] = nil
        }

        await publishDumpList()
    }

    // nexusd does not watch the .env and the .user.ini files. So it reads them for each list, but
    // only the files of the place of the list. A block of a file wins over a blocked event with the
    // same host and reason, because it names the file for the banner.
    func dumpBlocks(in place: DumpPlace?) -> [DumpBlock] {
        let fileBlocks = siteMap.current.phpSites
            .filter { files in place.includes(files.entry.place) }
            .flatMap(Self.dumpBlocks(of:))
        let named = Set(fileBlocks.map { block in DumpBlockKey(host: block.host, reason: block.reason) })
        var eventPlaces: [DumpBlockKey: DumpPlace] = [:]

        for (key, blocked) in dumpEventBlocks where place.includes(blocked.place) && !named.contains(key.block) {
            eventPlaces[key.block] = blocked.place
        }

        let eventBlocks = eventPlaces.map { key, blockedPlace in DumpBlock(host: key.host, reason: key.reason, place: blockedPlace) }

        return (fileBlocks + eventBlocks).sorted { ($0.host, $0.reason.rawValue) < ($1.host, $1.reason.rawValue) }
    }

    // A .env with VAR_DUMPER_FORMAT gives the site its own dump handler, also with an empty value:
    // VarDumper::setHandler() of Symfony checks the key with isset(). A .user.ini with its own
    // prepend file replaces the prepend file of Nexus.
    static func dumpBlocks(of files: SiteMap.PHPFiles) -> [DumpBlock] {
        let userIni = (try? String(contentsOf: files.userIni, encoding: .utf8)) ?? ""
        var blocks: [DumpBlock] = []

        if EnvFile.values(of: files.env)[varDumperFormatKey] != nil {
            blocks.append(DumpBlock(host: files.entry.host, reason: .varDumperFormat, file: files.env.path(percentEncoded: false), place: files.entry.place))
        }

        if PHPConfig.setsPrependFile(userIni: userIni) {
            blocks.append(DumpBlock(host: files.entry.host, reason: .userIni, file: files.userIni.path(percentEncoded: false), place: files.entry.place))
        }

        return blocks
    }

    private func dropAnsweredDumpBlocks(_ changed: [DumpedRequest]) -> Bool {
        let count = dumpEventBlocks.count

        dumpEventBlocks = dumpEventBlocks.filter { key, blocked in
            !changed.contains { header in blocked.isAnswered(by: header, kind: key.kind) }
        }

        return dumpEventBlocks.count != count
    }

    // The problems show only while "Catch dumps" is on. Without it PHP sends nothing.
    private func dumpProblem(_ settings: DumpSettings) -> String? {
        guard settings.catchDumps else {
            return nil
        }

        let problems = [dumpReceiverProblem, dumpLibraryProblem(settings), dumpPageProblem].compactMap { $0 }
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    func dumpList(place: DumpPlace?) async -> DumpList {
        dumpList(place: place, settings: await stateStore.current().dumpSettings)
    }

    func dumpList(place: DumpPlace?, settings: DumpSettings) -> DumpList {
        dumpState(place: place, settings: settings).list(of: dumpStore.listAndCursor(place: place))
    }

    // The map of the sites holds each host of a site and of a workspace, also each alias. The host
    // can come as Shop.test, https://shop.test/ or shop.test:443.
    func dumpPlace(host: String) -> NexusResponse {
        guard let entry = siteMap.current.hosts[HostName.plain(host)] else {
            return .failure(message: "Nexus has no site or workspace \(host). See: nexus site list")
        }

        return .dumpPlace(place: entry.place, host: entry.host)
    }

    // The state is the part of the list that dumpChanges does not carry. A change of it sends the
    // whole list again. loaded is part of it. So the end of the load sends the list again.
    func dumpState(place: DumpPlace?, settings: DumpSettings) -> DumpState {
        DumpState(settings: settings, blocked: dumpBlocks(in: place), receiving: dumpReceiver?.isListening == true, problem: dumpProblem(settings), loaded: dumpStore.isLoaded, page: dumpPageServer?.url)
    }

    // A clear before the load would remove nothing. The dumps of the file would then come back.
    func clearCaughtDumps(place: DumpPlace?) -> NexusResponse {
        guard dumpStore.isLoaded else {
            return .failure(message: DumpList.notLoadedText)
        }

        let removed = dumpStore.clear(place: place)
        dumpsChanged()

        guard removed > 0 else {
            return .done(message: "The list has no dumps to remove.")
        }

        return .done(message: "Nexus removed \(Count.text(removed, "dump")).")
    }

    // Another window or the limits of the store can have removed the dump already.
    func removeCaughtDump(number: Int) -> NexusResponse {
        guard dumpStore.isLoaded else {
            return .failure(message: DumpList.notLoadedText)
        }

        guard dumpStore.remove(dump: number) else {
            return .failure(message: "Nexus has no such dump anymore.")
        }

        dumpsChanged()
        return .done(message: "Nexus removed the dump.")
    }

    func removeDumpedRequest(id: String) -> NexusResponse {
        guard dumpStore.isLoaded else {
            return .failure(message: DumpList.notLoadedText)
        }

        guard let removed = dumpStore.remove(request: id) else {
            return .failure(message: "Nexus has no such request anymore.")
        }

        dumpsChanged()
        return .done(message: "Nexus removed the request with \(Count.text(removed, "dump")).")
    }

    // The changes that did not go out yet go out later. The app replaces the requests that it has
    // already.
    // Without a watcher and a page the last list goes nowhere. So the next list goes out also when
    // the state is the same as before.
    func publishDumpList() async {
        guard hasWatchers || dumpPageServer?.hasPages == true else {
            publishedDumpHead = nil
            return
        }

        let head = dumpState(place: nil, settings: await stateStore.current().dumpSettings)

        guard head != publishedDumpHead else {
            return
        }

        publishedDumpHead = head
        publish(.dumpList(head.list(of: dumpStore.listAndCursor())))
    }

    // The ticker also takes the changes without a watcher. So the store does not keep them.
    func dumpsChanged() {
        guard dumpTicker == nil else {
            return
        }

        dumpTicker = Task {
            while !Task.isCancelled, await self.publishDumpChanges() {
                try? await Task.sleep(for: Self.publishInterval)
            }
        }
    }

    // A change that comes after the lower raises the signal again and starts a new ticker. So no
    // change waits.
    private func publishDumpChanges() async -> Bool {
        dumpSignal.lower()
        let change = dumpStore.takeChanges()

        guard !change.isEmpty else {
            dumpTicker = nil
            return false
        }

        publish(.dumpChanges(change))

        if dropAnsweredDumpBlocks(change.changed) {
            await publishDumpList()
        }

        return true
    }
}

extension DumpState {
    func list(of listing: (requests: [DumpedRequest], cursor: DumpCursor?)) -> DumpList {
        DumpList(requests: listing.requests, settings: settings, blocked: blocked, receiving: receiving, problem: problem, cursor: listing.cursor, loaded: listing.cursor != nil, page: page)
    }
}
