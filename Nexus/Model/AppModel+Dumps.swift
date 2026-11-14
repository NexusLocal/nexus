import AppKit
import NexusCore
import NexusIPC

// An entry of the open request as the screen shows it: a dump, a query, a log line or a job row.
// The tree decodes outside the main thread, because one request can hold up to 10 MB of dumps. An
// entry without a tree shows its text. source is the file from the project folder of the request,
// with the line. entry keeps the other values without the JSON of the tree. So the marks of the
// queries come from the same code as in nexusd.
@dynamicMemberLookup
nonisolated struct ShownDump: Identifiable, Sendable {
    let entry: CaughtDump
    let source: String?
    let tree: DumpNode?

    var id: String {
        entry.id
    }

    subscript<Value>(dynamicMember key: KeyPath<CaughtDump, Value>) -> Value {
        entry[keyPath: key]
    }

    init(_ dump: CaughtDump, projectFolder: String?) {
        var entry = dump
        entry.treeJSON = nil
        self.entry = entry
        source = dump.file.map { Self.shortPath(of: $0, in: projectFolder) + (dump.line.map { ":\($0)" } ?? "") }
        tree = dump.decodedTree()
    }

    // A file outside the project folder keeps its full path.
    private static func shortPath(of file: String, in projectFolder: String?) -> String {
        guard let projectFolder, file.hasPrefix("\(projectFolder)/") else {
            return (file as NSString).abbreviatingWithTildeInPath
        }

        return String(file.dropFirst(projectFolder.count + 1))
    }
}

// The entries of the open request for the tabs: the entries of each tab, and the rows of the
// Queries tab with the marks of the queries. They change only with the entries. So a draw of a tab
// does not sort or mark the entries again.
struct OpenEntries {
    private(set) var byTab: [DumpEntryTab: [ShownDump]] = [:]
    private(set) var queryMarks = QueryMarks([CaughtDump]())
    private(set) var queryRows: [QueryRow<ShownDump>] = []

    init() {}

    init(_ entries: [ShownDump]) {
        byTab = Dictionary(grouping: entries) { shown in DumpEntryTab(shown.kind) }

        let queries = byTab[.queries] ?? []
        queryMarks = QueryMarks(queries.map(\.entry))
        queryRows = QueryRow.rows(of: queries, marks: queryMarks) { shown in shown.entry }
    }

    func entries(of tab: DumpEntryTab) -> [ShownDump] {
        byTab[tab] ?? []
    }
}

// A place of the filter with its label: the first host of the site or the workspace from nexusd,
// or "No site".
struct DumpPlaceChoice: Hashable, Identifiable {
    let place: DumpPlace
    let label: String

    var id: DumpPlace {
        place
    }
}

// The answer of one load of the open dumps, with the trees decoded.
private enum DumpLoad {
    case shown([ShownDump])
    case failure(String)
}

// The dump viewer (part 8). nexusd sends the request headers as events: dumpList replaces them and
// dumpChanges changes them. The app never sorts them. It loads the dumps of the open request only
// when the user opens it, and later only the dumps that are new.
extension AppModel {
    var shownDumpSettings: DumpSettings? {
        pendingDumpSettings ?? dumpState?.settings
    }

    var catchesDumps: Bool {
        shownDumpSettings?.catchDumps != false
    }

    var catchesAnything: Bool {
        shownDumpSettings?.catchesAnything != false
    }

    // A block of an older nexusd has no place. It shows only without a filter. A block shows only
    // while Nexus catches a kind that it stops.
    var visibleDumpBlocks: [DumpBlock] {
        let settings = shownDumpSettings ?? DumpSettings()
        let blocks = (dumpState?.blocked ?? []).filter { block in block.isShown(for: settings) }

        guard let dumpFilter else {
            return blocks
        }

        return blocks.filter { $0.place == dumpFilter.place }
    }

    // The job of a worker that ran the job of a row of the Jobs tab, with its last try.
    func dumpedJob(ref: String?) -> DumpedRequest? {
        ref.flatMap { ref in dumpJobsByUUID[ref] }
    }

    // A link to another request of the list, for example from a job row to its job. A filter that
    // hides that request goes, so the list can show it.
    func showDumpRequest(_ id: String) {
        if !visibleDumpRequests.contains(where: { request in request.id == id }) {
            filterDumps(by: nil)
        }

        openDumpRequest(id)
    }

    // The views read openEntries. So each change of the open entries goes through here.
    private func setOpenDumps(_ entries: [ShownDump]) {
        openDumps = entries
        openEntries = OpenEntries(entries)
    }

    func show(_ list: DumpList) {
        dumpRequests = list.requests
        show(list.state)
        dumpRequestsChanged()
    }

    func show(_ change: DumpChange) {
        change.apply(to: &dumpRequests)
        removeDumps(change.removedDumps)
        dumpRequestsChanged()
    }

    // A load that started before the removal can bring a removed dump back. So that load goes, and
    // the next load asks after the highest dump that stays.
    private func removeDumps(_ numbers: [Int]) {
        if numbers.isEmpty {
            return
        }

        let gone = Set(numbers)
        removeOpenDumps { gone.contains($0.number) }
        dumpLoadGeneration += 1
        loadingDumps = false
        requestedLastNumber = nil
    }

    // Each write wakes the views of the dumps, so only a real removal writes.
    private func removeOpenDumps(where shouldGo: (ShownDump) -> Bool) {
        guard openDumps.contains(where: shouldGo) else {
            return
        }

        setOpenDumps(openDumps.filter { shown in !shouldGo(shown) })
    }

    func show(_ state: DumpState) {
        dumpState = state
    }

    private func dumpRequestsChanged() {
        visibleDumpRequests = dumpRequests.filter { (dumpFilter?.place).includes($0.place) }
        visibleDumpCount = visibleDumpRequests.reduce(0) { $0 + $1.dumpCount }
        dumpPlaceChoices = placeChoices()
        indexDumpRequests()
        updateOpenDumpRequest()

        guard showsDumps else {
            return
        }

        openFirstDumpRequestIfNeeded()
        loadOpenDumps()
    }

    // Each write wakes the views that read the open request. So only a real change writes.
    private func updateOpenDumpRequest() {
        guard let id = openDumpRequestID else {
            return
        }

        guard let open = dumpRequestsByID[id] else {
            closeDumpRequest()
            return
        }

        if open != openDumpRequest {
            openDumpRequest = open
        }
    }

    // The list has the newest first. So a job that a worker tried again keeps its last try.
    private func indexDumpRequests() {
        var byID: [String: DumpedRequest] = [:]
        var jobs: [String: DumpedRequest] = [:]

        for request in dumpRequests {
            byID[request.id] = byID[request.id] ?? request

            if request.kind == .job, let uuid = request.job?.uuid, jobs[uuid] == nil {
                jobs[uuid] = request
            }
        }

        // Each write wakes the views of the links. So only a real change writes.
        if byID != dumpRequestsByID {
            dumpRequestsByID = byID
        }

        if jobs != dumpJobsByUUID {
            dumpJobsByUUID = jobs
        }
    }

    // The places that have requests, and the place of the filter also when it has none. The
    // requests without a site come last.
    private func placeChoices() -> [DumpPlaceChoice] {
        var choices: [DumpPlace: DumpPlaceChoice] = [:]

        for request in dumpRequests where choices[request.place] == nil {
            choices[request.place] = DumpPlaceChoice(place: request.place, label: request.placeHost ?? "No site")
        }

        if let dumpFilter {
            choices[dumpFilter.place] = choices[dumpFilter.place] ?? dumpFilter
        }

        return choices.values.sorted { first, second in
            if (first.place.site == nil) != (second.place.site == nil) {
                return second.place.site == nil
            }

            return first.label.localizedStandardCompare(second.label) == .orderedAscending
        }
    }

    func dumpsScreenAppeared() {
        showsDumps = true
        openFirstDumpRequestIfNeeded()
        loadOpenDumps()
        Task { await refreshDumpState() }
    }

    // The open request stays. Its dumps load again when the screen shows again.
    func dumpsScreenDisappeared() {
        showsDumps = false
        forgetOpenDumps()
    }

    // nexusd does not watch the .env and the .user.ini of the sites. Each state reads them again.
    // So a fix of the user shows when the screen shows again or the app comes to the front.
    func refreshDumpState() async {
        guard case .answer(.dumpState(let state))? = await outcome(of: .dumpState(place: nil)) else {
            return
        }

        show(state)
    }

    func filterDumps(by choice: DumpPlaceChoice?) {
        dumpFilter = choice
        dumpRequestsChanged()
    }

    private func openFirstDumpRequestIfNeeded() {
        guard !visibleDumpRequests.contains(where: { $0.id == openDumpRequestID }) else {
            return
        }

        guard let first = visibleDumpRequests.first else {
            closeDumpRequest()
            return
        }

        openDumpRequest(first.id)
    }

    // A second click on a request whose dumps did not load tries again.
    func openDumpRequest(_ id: String) {
        if id == openDumpRequestID {
            guard openDumpsProblem != nil else {
                return
            }
        }

        closeDumpRequest()
        openDumpRequestID = id
        openDumpRequest = dumpRequestsByID[id]
        loadOpenDumps()
    }

    private func closeDumpRequest() {
        openDumpRequestID = nil
        openDumpRequest = nil
        forgetOpenDumps()
    }

    // A new generation drops the answer of a load that still runs. That load belongs to an earlier
    // open of a request, or to an earlier visit of the screen. So the next open loads from the start.
    private func forgetOpenDumps() {
        dumpLoadGeneration += 1
        loadingDumps = false
        requestedLastNumber = nil
        setOpenDumps([])
        openDumpsProblem = nil
    }

    // The numbers of the store follow the order in which the dumps arrived. PHP can send a lower
    // seq after a higher one, so the app asks for the dumps after the highest number that it has.
    // It asks once for each lastNumber. So a list that is a moment behind the store cannot start a
    // loop of requests.
    private func loadOpenDumps() {
        guard showsDumps else {
            return
        }

        guard let request = openDumpRequest else {
            return
        }

        removeGoneDumps(of: request)

        guard !loadingDumps else {
            return
        }

        let highestNumber = openDumps.map(\.number).max() ?? 0

        guard hasDumpsToLoad(request, highestNumber: highestNumber) else {
            return
        }

        guard request.lastNumber != requestedLastNumber else {
            return
        }

        let generation = dumpLoadGeneration
        requestedLastNumber = request.lastNumber
        loadingDumps = true

        Task {
            let answer = await dumpsAnswer(of: request, afterNumber: highestNumber)

            guard generation == dumpLoadGeneration else {
                return
            }

            let load = await decoded(answer, for: request)

            guard generation == dumpLoadGeneration else {
                return
            }

            loadingDumps = false
            receive(load)
            loadOpenDumps()
        }
    }

    // An older nexusd sends no numbers. The app then asks once for each open, so the answer or the
    // error of that nexusd shows and the pane is not empty without a reason.
    private func hasDumpsToLoad(_ request: DumpedRequest, highestNumber: Int) -> Bool {
        if request.lastNumber > highestNumber {
            return true
        }

        guard request.lastNumber == 0 else {
            return false
        }

        return request.entryCount > openDumps.count
    }

    private func dumpsAnswer(of request: DumpedRequest, afterNumber: Int) async -> RequestOutcome? {
        guard isLive else {
            return .answer(.caughtDumps(Self.sampleDumps(of: request.id).filter { $0.number > afterNumber }))
        }

        return await outcome(of: .requestDumps(request: request.id, afterNumber: afterNumber))
    }

    private func decoded(_ answer: RequestOutcome?, for request: DumpedRequest) async -> DumpLoad? {
        switch answer {
        case .failure(let message)?:
            return .failure(message)
        case .answer(.caughtDumps(let dumps))?:
            let projectFolder = request.projectFolder
            return .shown(await Task.detached { dumps.map { ShownDump($0, projectFolder: projectFolder) } }.value)
        default:
            return nil
        }
    }

    // A later load can give a dump again, for example a dump that the store did not number yet.
    // Its id stays the same.
    private func receive(_ load: DumpLoad?) {
        switch load {
        case .failure(let message)?:
            openDumpsProblem = message
        case .shown(let shown)?:
            let known = Set(openDumps.map(\.id))
            let new = shown.filter { !known.contains($0.id) }

            if !new.isEmpty {
                setOpenDumps(openDumps + new)
            }

            openDumpsProblem = nil

            if let openDumpRequest {
                removeGoneDumps(of: openDumpRequest)
            }
        case nil:
            break
        }
    }

    // The limits of nexusd remove the oldest entries. firstNumber is the lowest store number that
    // nexusd keeps of the request. A job of a worker stays in the list without entries. Its
    // numbers are then 0.
    private func removeGoneDumps(of request: DumpedRequest) {
        guard request.entryCount > 0 else {
            removeOpenDumps { _ in true }
            return
        }

        removeOpenDumps { $0.number < request.firstNumber }
    }

    // The switch shows the new setting while nexusd works. nexusd then sends the list with the new
    // settings and the problems to each watcher. The state of the answer is there at once.
    func setDumpSettings(_ settings: DumpSettings) {
        guard settings != shownDumpSettings else {
            return
        }

        guard isLive else {
            if let state = dumpState {
                show(DumpState(settings: settings, blocked: state.blocked, receiving: state.receiving, problem: state.problem, loaded: state.loaded, page: state.page))
            }

            return
        }

        pendingDumpSettings = settings

        Task {
            if await perform(.setDumpSettings(settings), failure: "The settings of the dump viewer did not change", place: .window) != nil {
                await refreshDumpState()
            }

            if pendingDumpSettings == settings {
                pendingDumpSettings = nil
            }
        }
    }

    // The filter decides which requests go: all, or the requests of one site or workspace.
    func clearDumps() {
        guard isLive else {
            dumpRequests.removeAll { (dumpFilter?.place).includes($0.place) }
            dumpRequestsChanged()
            return
        }

        send(.clearCaughtDumps(place: dumpFilter?.place), failure: "Nexus did not remove the requests", place: .window)
    }

    // One dump or one request goes without a question. nexusd then sends the change to each window
    // and to the web page.
    func removeDump(_ shown: ShownDump) {
        guard isLive else {
            show(Self.sampleRemoval(of: shown, from: openDumpRequest))
            return
        }

        send(.removeCaughtDump(number: shown.number), failure: "Nexus did not remove the dump", place: .window)
    }

    func removeDumpRequest(_ request: DumpedRequest) {
        guard isLive else {
            show(DumpChange(removed: [request.id]))
            return
        }

        send(.removeDumpedRequest(id: request.id), failure: "Nexus did not remove the request", place: .window)
    }

    // The change that nexusd would send for the sample data.
    private static func sampleRemoval(of shown: ShownDump, from request: DumpedRequest?) -> DumpChange {
        guard var request else {
            return DumpChange(removedDumps: [shown.number])
        }

        request.count(shown.entry, by: -1)

        guard request.staysInList else {
            return DumpChange(removed: [request.id], removedDumps: [shown.number])
        }

        return DumpChange(changed: [request], removedDumps: [shown.number])
    }

    // nexusd serves the web page, as Mailpit serves its inbox.
    func openDumpPage() {
        if let page = dumpState?.page, let url = URL(string: page) {
            NSWorkspace.shared.open(url)
        }
    }

    // The Delete key in the list, as in the Mail screen.
    func removeOpenDumpRequest() {
        guard let openDumpRequest else {
            return
        }

        removeDumpRequest(openDumpRequest)
    }
}
