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

// A choice of the filter: the requests of a place, or the requests of the public link of a local
// host (group 4, 4f). The label of a link changes with the number of links. So the picker uses the
// id, which has only the place or the host.
enum DumpFilterChoice: Hashable, Identifiable {
    enum Key: Hashable {
        case place(DumpPlace)
        case link(String)
    }

    case place(DumpPlaceChoice)
    case link(host: String, label: String)

    var id: Key {
        switch self {
        case .place(let choice): .place(choice.place)
        case .link(let host, _): .link(host)
        }
    }

    var label: String {
        switch self {
        case .place(let choice): choice.label
        case .link(_, let label): label
        }
    }

    var place: DumpPlace? {
        guard case .place(let choice) = self else {
            return nil
        }

        return choice.place
    }

    var linkHost: String? {
        guard case .link(let host, _) = self else {
            return nil
        }

        return host
    }

    // A request of a link shows in the filter of its link and in the filter of its place.
    func includes(_ request: DumpedRequest) -> Bool {
        switch self {
        case .place(let choice): choice.place == request.place
        case .link(let host, _): request.publicLink?.host == host
        }
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

    // The list of a public link shows also without a Catch switch. The option of the link decides
    // (group 4, 4f).
    var showsDumpList: Bool {
        if catchesAnything {
            return true
        }

        if dumpState?.linkHosts.isEmpty == false {
            return true
        }

        return dumpRequests.contains { request in request.publicLink != nil }
    }

    // A block of an older nexusd has no place. It shows only without a filter. A block shows only
    // while Nexus catches a kind that it stops. The filter of a link shows no block.
    var visibleDumpBlocks: [DumpBlock] {
        let settings = shownDumpSettings ?? DumpSettings()
        let blocks = (dumpState?.blocked ?? []).filter { block in block.isShown(for: settings) }

        guard let dumpFilter else {
            return blocks
        }

        guard let place = dumpFilter.place else {
            return []
        }

        return blocks.filter { $0.place == place }
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

    // The hosts of the links can change with the state. So the choices of the filter follow it.
    func show(_ state: DumpState) {
        let linkHostsChanged = state.linkHosts != dumpState?.linkHosts
        dumpState = state

        if linkHostsChanged {
            dumpLinkChoices = linkChoices()
        }
    }

    private func dumpRequestsChanged() {
        visibleDumpRequests = dumpFilter.map { filter in dumpRequests.filter(filter.includes) } ?? dumpRequests
        visibleDumpCount = visibleDumpRequests.reduce(0) { $0 + $1.dumpCount }
        dumpPlaceChoices = placeChoices()
        dumpLinkChoices = linkChoices()
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
            loadOpenLinkDetail()
        }
    }

    // The headers and the body of the open request of a public link load once for each open (group
    // 4, 4f). A request of PHP can get its link after its open. A new generation drops the answer of
    // an earlier open.
    private func loadOpenLinkDetail() {
        guard let request = openDumpRequest, request.publicLink != nil, linkDetailID != request.id else {
            return
        }

        linkDetailID = request.id
        linkDetailGeneration += 1
        let generation = linkDetailGeneration
        openLinkDetail = nil
        openLinkDetailProblem = nil

        Task {
            let answer = await linkDetailAnswer(of: request.id)

            guard generation == linkDetailGeneration else {
                return
            }

            switch answer {
            case .answer(.shareRequest(let detail))?:
                openLinkDetail = detail
            case .failure(let message)?:
                openLinkDetailProblem = message
            default:
                openLinkDetailProblem = LinkRequestText.detailGone
            }
        }
    }

    private func linkDetailAnswer(of id: String) async -> RequestOutcome? {
        guard isLive else {
            return Self.sampleShareRequest(id: id).map { detail in .answer(.shareRequest(detail)) }
        }

        return await outcome(of: .shareRequest(id: id))
    }

    private func forgetOpenLinkDetail() {
        linkDetailID = nil
        linkDetailGeneration += 1
        openLinkDetail = nil
        openLinkDetailProblem = nil
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

        if case .place(let filter)? = dumpFilter {
            choices[filter.place] = choices[filter.place] ?? filter
        }

        return choices.values.sorted { first, second in
            if (first.place.site == nil) != (second.place.site == nil) {
                return second.place.site == nil
            }

            return first.label.localizedStandardCompare(second.label) == .orderedAscending
        }
    }

    // One choice for each link with a list and for each link of a request in the list, sorted by
    // host. The link of the filter stays also after its end (group 4, 4f).
    private func linkChoices() -> [DumpFilterChoice] {
        var hosts = Set(dumpState?.linkHosts ?? [])
        hosts.formUnion(dumpRequests.compactMap { request in request.publicLink?.host })

        if let host = dumpFilter?.linkHost {
            hosts.insert(host)
        }

        let sorted = hosts.sorted()
        let choices = sorted.map { host in DumpFilterChoice.link(host: host, label: LinkRequestText.filterLabel(host: host, linkCount: sorted.count)) }

        // A label can change with the number of links. The filter then gets the new label.
        if let host = dumpFilter?.linkHost, let current = choices.first(where: { $0.linkHost == host }), current != dumpFilter {
            dumpFilter = current
        }

        return choices
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

    func filterDumps(by choice: DumpFilterChoice?) {
        dumpFilter = choice
        dumpRequestsChanged()
    }

    // The button "Requests (12)" of the share panel opens the Dumps screen with the filter of one
    // link (group 4, 4g calls it).
    func showLinkRequests(host: String) {
        let linkCount = Set((dumpState?.linkHosts ?? []) + [host]).count
        selection = .dumps
        filterDumps(by: .link(host: host, label: LinkRequestText.filterLabel(host: host, linkCount: linkCount)))
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

    // A second click on a request whose dumps or whose detail of a link did not load tries again.
    func openDumpRequest(_ id: String) {
        if id == openDumpRequestID {
            guard openDumpsProblem != nil || openLinkDetailProblem != nil else {
                return
            }
        }

        closeDumpRequest()
        openDumpRequestID = id
        openDumpRequest = dumpRequestsByID[id]
        loadOpenDumps()
        loadOpenLinkDetail()
    }

    private func closeDumpRequest() {
        openDumpRequestID = nil
        openDumpRequest = nil
        forgetOpenDumps()
        forgetOpenLinkDetail()
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
                show(DumpState(settings: settings, blocked: state.blocked, receiving: state.receiving, problem: state.problem, loaded: state.loaded, page: state.page, linkHosts: state.linkHosts))
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

    // The filter decides which requests go: all, the requests of one site or workspace, or the
    // requests of one public link (group 4, 4f).
    func clearDumps() {
        guard isLive else {
            dumpRequests.removeAll { request in dumpFilter?.includes(request) ?? true }
            dumpRequestsChanged()
            return
        }

        if let host = dumpFilter?.linkHost {
            send(.clearLinkRequests(host: host), failure: "Nexus did not remove the requests", place: .window)
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
