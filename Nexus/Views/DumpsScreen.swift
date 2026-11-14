import AppKit
import NexusCore
import NexusIPC
import SwiftUI

// The Dumps screen (part 8, and part 2 of the dump viewer): the settings of the dump viewer, and
// the requests, commands and jobs of the sites with their dumps, queries, log lines and job rows.
// The design is the frame "Dumps" in nexus.pen, with "Dumps Queries", "Dumps Log Lines", "Dumps
// Jobs" and the states of "Dumps States".
struct DumpsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        DumpsForm()
            .screenTitle("Dumps", subtitle: subtitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.openDumpPage()
                    } label: {
                        Label("Open in Browser", systemImage: "arrow.up.forward.app")
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(model.dumpState?.page == nil)
                    .help(model.dumpState?.page == nil ? DumpState.pageMissingText : "Shows the requests on a web page of Nexus.")
                }
            }
            .onAppear {
                model.dumpsScreenAppeared()
            }
            .onDisappear {
                model.dumpsScreenDisappeared()
            }
            // A fix of a .env, a .user.ini or a wp-config.php happens in another app. The blocks are
            // fresh when Nexus comes to the front again.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.refreshDumpState() }
            }
    }

    private var subtitle: String {
        guard model.catchesAnything else {
            return "All Catch switches are off"
        }

        guard !model.visibleDumpRequests.isEmpty else {
            return model.dumpState?.loaded == false ? "Nexus loads the requests" : "No requests"
        }

        let requests = Count.text(model.visibleDumpRequests.count, "request")

        guard model.visibleDumpCount > 0 else {
            return requests
        }

        return "\(requests) with \(Count.text(model.visibleDumpCount, "dump"))"
    }
}

private struct DumpsForm: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsClear = false

    var body: some View {
        Form {
            DumpSettingsSection()

            Section {
                DumpRequestsContent()
            } header: {
                DumpRequestsHeader(confirmsClear: $confirmsClear)
            } footer: {
                Text("Nexus keeps the newest 500 requests. A click on a file opens it in your editor. Test runs send nothing.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(clearTitle, isPresented: $confirmsClear) {
            Button("Clear", role: .destructive) {
                model.clearDumps()
            }
        } message: {
            Text("This removes their dumps, queries, log lines and jobs. You cannot get them back.")
        }
    }

    private var clearTitle: String {
        model.dumpFilter.map { "Remove the requests of \($0.label)?" } ?? "Remove all requests?"
    }
}

// The settings are off until the first list of nexusd. A change before that would send the
// defaults for the other settings.
private struct DumpSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.shownDumpSettings

        let pageMode = (settings ?? DumpSettings()).pageMode

        Section {
            Toggle(isOn: setting(\.catchDumps)) {
                Text("Catch dumps")
                Text("Nexus collects each dump() and dd() of your PHP sites on this screen.")
            }

            Picker(selection: setting(\.pageMode)) {
                ForEach(DumpPageMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                Text("Show dumps on the web page")
                Text("Without Nexus, PHP prints each dump in the page. This choice decides if the page still shows it.\n\(pageMode.explanation)")
            }
            .disabled(!model.catchesDumps)

            Toggle(isOn: setting(\.catchQueries)) {
                Text("Catch queries")
                Text("Each database query of Laravel and WordPress sites, with its time and its line in your code. Nexus marks slow, duplicate and N+1 queries. Each query makes a page a little slower, so this is off by default.")
            }

            Toggle(isOn: setting(\.catchLogs)) {
                Text("Catch log lines")
                Text("Laravel: each line that the site writes to its log. WordPress and other PHP sites: PHP errors, warnings and notices. The log file still gets each line.")
            }

            Toggle(isOn: setting(\.catchJobs)) {
                Text("Catch queue jobs")
                Text("Laravel: the jobs of each request and of queue workers. WordPress: WP-Cron events and Action Scheduler actions. Each job that runs gets its own entry.")
            }

            Toggle(isOn: setting(\.commands)) {
                Text("Catch commands")
                Text("php artisan, wp, queue workers and other PHP commands. Nexus catches in them what the switches above catch. The terminal still shows each dump.")
            }
            .disabled(!model.catchesAnything)
        } header: {
            Text("Settings")
        } footer: {
            Text("dd() always shows on the page, because it stops the request.")
        }
        .toggleStyle(.switch)
        .disabled(settings == nil)
    }

    private func setting<Value>(_ key: WritableKeyPath<DumpSettings, Value>) -> Binding<Value> {
        Binding(
            get: { (model.shownDumpSettings ?? DumpSettings())[keyPath: key] },
            set: { value in
                guard var settings = model.shownDumpSettings else {
                    return
                }

                settings[keyPath: key] = value
                model.setDumpSettings(settings)
            }
        )
    }
}

// A form row on macOS cannot get the orange background. So the problems and the blocks are in the
// header, above the list. A block shows only while its kind is on (AppModel.visibleDumpBlocks).
private struct DumpRequestsHeader: View {
    @Environment(AppModel.self) private var model
    @Binding var confirmsClear: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Requests")
                Spacer()
                DumpFilter()
                Button("Clear…") {
                    confirmsClear = true
                }
                .disabled(model.visibleDumpRequests.isEmpty)
            }
            .disabled(!model.catchesAnything)

            if let problem = model.dumpState?.problem {
                WarningBanner(title: "The dump viewer has a problem", message: problem) {}
            }

            ForEach(model.visibleDumpBlocks, id: \.self) { block in
                DumpBlockBanner(block: block)
            }
        }
    }
}

private struct DumpFilter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let choices = model.dumpPlaceChoices

        Picker("Filter", selection: Binding(get: { model.dumpFilter?.place }, set: { place in model.filterDumps(by: choices.first { $0.place == place }) })) {
            Text("All sites and workspaces").tag(DumpPlace?.none)

            if !choices.isEmpty {
                Divider()
            }

            ForEach(choices) { choice in
                Text(choice.label).tag(Optional(choice.place))
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

// A site whose dumps or queries Nexus cannot catch, with the texts of the web page and nexus dumps.
// file is nil when the key does not come from a file of the site. So that banner has no button.
private struct DumpBlockBanner: View {
    @Environment(AppModel.self) private var model
    let block: DumpBlock

    var body: some View {
        WarningBanner(title: block.title, message: block.message) {
            if let file = block.file {
                Button("Open \(URL(filePath: file).lastPathComponent)") {
                    model.openInEditor(file)
                }
            }
        }
    }
}

// The lines of "Dumps States" in the design, or the list.
private struct DumpRequestsContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.catchesAnything {
            Text("Turn on one of the Catch switches above to see what your sites do.")
                .foregroundStyle(.secondary)
        } else if !model.visibleDumpRequests.isEmpty {
            // The browser fills the whole row, so it gets the rounded corners of the group.
            DumpBrowser()
                .frame(height: 465)
                .clipShape(.rect(cornerRadius: 10))
                .listRowInsets(EdgeInsets())
        } else if model.dumpState?.loaded == false {
            Text("Nexus loads the requests of its last run.")
                .foregroundStyle(.secondary)
        } else {
            Text(model.dumpFilter.map { "Nexus has no requests of \($0.label)." } ?? "No dumps yet. Add dump($value) to the code of a site and open the page.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct DumpBrowser: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ListDetailView(items: model.visibleDumpRequests, openID: model.openDumpRequestID, listWidth: 330, open: { model.openDumpRequest($0) }, remove: { model.removeOpenDumpRequest() }) { request, selected in
            DumpRequestRow(request: request, selected: selected)
        } detail: {
            DumpDetail()
        }
    }
}

private struct DumpRequestRow: View {
    let request: DumpedRequest
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(request.displayMethod)
                    .font(.subheadline.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(request.target)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(request.started.listTime)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text(DumpEntryText.summary(of: request))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)

                if request.job?.outcome == .failed {
                    SiteTag(text: "failed", tint: .error, monospaced: true)
                        .help("This job failed.")
                }

                if request.marks.contains(.nPlusOne) {
                    SiteTag(text: "N+1", tint: .warning, monospaced: true)
                        .help("A line of this request runs the same query many times with other values.")
                }

                if request.hasDD {
                    SiteTag(text: "dd()", tint: .warning, monospaced: true)
                        .help("This request called dd(). PHP stopped there.")
                }

                SiteTag(text: request.placeHost, isWorkspace: request.workspace != nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(selected ? Color.accentSelection : Color.clear)
        .contentShape(.rect)
    }
}

// The head reads only the open request. The entries are views of their own, so a change of the
// list does not draw them again. A request with only dumps has no tabs. The tab that the user
// chose stays for the next request with that kind.
private struct DumpDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let request = model.openDumpRequest {
            let tabs = DumpEntryTab.tabs(of: request)
            let tab = tabs.contains(model.chosenDumpTab) ? model.chosenDumpTab : tabs.first ?? .dumps

            VStack(spacing: 0) {
                if request.kind == .job {
                    DumpJobHead(request: request)
                } else {
                    DumpRequestHead(request: request)
                }

                Divider()

                if !tabs.isEmpty {
                    DumpTabBar(request: request, tabs: tabs, tab: tab)

                    Divider()
                }

                if tab == .queries {
                    OpenQueries(droppedQueries: request.droppedQueries)
                } else {
                    OpenTabEntries(tab: tab)
                }
            }
            .id(request.id)
        } else {
            Text("Choose a request.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct DumpRequestHead: View {
    @Environment(AppModel.self) private var model
    let request: DumpedRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: "\(request.displayMethod) \(request.target)")
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                SiteTag(text: request.placeHost, isWorkspace: request.workspace != nil)

                RowRemoveButton(help: "Remove this request and its entries") {
                    model.removeDumpRequest(request)
                }
            }

            if let url = request.url {
                HeaderLine(key: "URL", value: url, keyWidth: 48, truncation: .middle, link: request.pageURL)
            }

            if request.kind == .command {
                if let root = request.root {
                    HeaderLine(key: "Folder", value: (root as NSString).abbreviatingWithTildeInPath, keyWidth: 48, truncation: .middle)
                }
            }

            if let result = DumpScreenText.result(of: request) {
                HeaderLine(key: "Status", value: result, keyWidth: 48, truncation: .middle)
            }

            HeaderLine(key: "Time", value: DumpScreenText.date(request.started), keyWidth: 48, truncation: .middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// The head of a job that a worker ran. From links to the request that queued the job, while the
// list still has that request.
private struct DumpJobHead: View {
    @Environment(AppModel.self) private var model
    let request: DumpedRequest

    private let keyWidth: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: request.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                SiteTag(text: request.placeHost, isWorkspace: request.workspace != nil)

                RowRemoveButton(help: "Remove this job and its entries") {
                    model.removeDumpRequest(request)
                }
            }

            if let job = request.job {
                if let queue = DumpEntryText.queue(of: job) {
                    HeaderLine(key: "Queue", value: queue, keyWidth: keyWidth, truncation: .middle)
                }

                if let status = DumpEntryText.jobStatus(of: request) {
                    HeaderLine(key: "Status", value: status, keyWidth: keyWidth, truncation: .middle, color: job.outcome == .failed ? .redText : nil)
                }

                if let command = job.command {
                    HeaderLine(key: "Worker", value: command, keyWidth: keyWidth, truncation: .middle)
                }

                if let origin = job.queuedBy.flatMap({ id in model.dumpRequestsByID[id] }) {
                    HeaderLine(key: "From", value: DumpEntryText.origin(origin, time: origin.started.secondsTime), keyWidth: keyWidth, truncation: .middle, action: (help: "Show the request that queued this job", perform: { model.showDumpRequest(origin.id) }))
                }
            }

            HeaderLine(key: "Time", value: DumpScreenText.date(request.started), keyWidth: keyWidth, truncation: .middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// One segment for each kind that the request has. The time of all queries is on the right of the
// Queries tab. The grouped Form keeps its rows narrow. So four tabs and the time can be too wide
// for the pane, and a wider bar would make the whole section wider. The time then goes under the
// tabs, and then the tabs get smaller.
private struct DumpTabBar: View {
    @Environment(AppModel.self) private var model
    let request: DumpedRequest
    let tabs: [DumpEntryTab]
    let tab: DumpEntryTab

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                picker
                Spacer(minLength: 8)
                total
            }

            stacked(.regular)
            stacked(.small)
            stacked(.mini)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stacked(_ size: ControlSize) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            picker
                .controlSize(size)
            total
        }
    }

    private var picker: some View {
        Picker("Show", selection: Binding(get: { tab }, set: { chosen in model.chosenDumpTab = chosen })) {
            ForEach(tabs, id: \.self) { choice in
                Text(choice.title(in: request)).tag(choice)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder private var total: some View {
        if tab == .queries {
            Text(DumpEntryText.queryTotal(of: request))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// The entries of one tab, with the state of the load under them.
private struct EntryList<Content: View>: View {
    @Environment(AppModel.self) private var model
    let isEmpty: Bool
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                content

                if model.loadingDumps, isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                }

                if let problem = model.openDumpsProblem {
                    MessageText(problem)
                }
            }
            .padding(16)
        }
    }
}

// The dumps, the log lines or the job rows of the open request. The Queries tab has its groups, so
// it is a view of its own.
private struct OpenTabEntries: View {
    @Environment(AppModel.self) private var model
    let tab: DumpEntryTab

    var body: some View {
        let entries = model.openEntries.entries(of: tab)

        EntryList(isEmpty: entries.isEmpty) {
            ForEach(entries) { shown in
                switch shown.kind {
                case .dump, .dd: DumpBox(shown: shown)
                case .log: LogLineBox(shown: shown)
                case .job: JobRowBox(shown: shown)
                case .query: QueryBox(shown: shown, marks: model.openEntries.queryMarks.marks(of: shown.entry))
                }
            }
        }
    }
}

// One dump: the file and the line, the kind of call, the copy button and the tree. Without a tree
// the box shows the text of CliDumper.
private struct DumpBox: View {
    @Environment(AppModel.self) private var model
    let shown: ShownDump

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SourceLink(shown: shown)

                if let label = shown.label {
                    Text(label)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(shown.kind == .dd ? "dd()" : "dump()")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)

                CopyButton(help: "Copy the text of this dump") {
                    shown.text
                }

                // A dump of an older nexusd has no number. So nexusd cannot find it.
                RowRemoveButton(help: "Remove this dump") {
                    model.removeDump(shown)
                }
                .disabled(shown.number == 0)
            }
            .font(.callout)

            Group {
                if let tree = shown.tree {
                    DumpTreeNode(node: tree, isExpanded: (tree.children?.count ?? 0) <= DumpNode.openChildrenLimit)
                } else {
                    Text(shown.text)
                        .textSelection(.enabled)
                }
            }
            .entryBox()

            if shown.truncated {
                Text("Nexus shortened the text of this dump, because it is very large.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// The queries in their order. An N+1 or a duplicate is one group that starts closed. The marks
// come from the same code as the tags of the list. The groups stay open while the request is open.
struct OpenQueries: View {
    #if DEBUG
    // --dump-groups-open of DebugLaunch: each group starts open.
    @MainActor static var debugOpensGroups = false
    #endif

    @Environment(AppModel.self) private var model
    let droppedQueries: Int
    // The groups that are not in their first state.
    @State private var changedGroups: Set<String> = []

    private var groupsStartOpen: Bool {
        #if DEBUG
        Self.debugOpensGroups
        #else
        false
        #endif
    }

    var body: some View {
        let rows = model.openEntries.queryRows
        let marks = model.openEntries.queryMarks

        EntryList(isEmpty: rows.isEmpty) {
            ForEach(rows, id: \.entries[0].id) { row in
                if row.kind == .single {
                    QueryBox(shown: row.entries[0], marks: marks.marks(of: row.entries[0].entry))
                } else {
                    QueryGroupBox(row: row, marks: marks, isOpen: isOpen(row.entries[0].id))
                }
            }

            if droppedQueries > 0 {
                Text(DumpEntryText.droppedQueries(droppedQueries))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func isOpen(_ id: String) -> Binding<Bool> {
        Binding(
            get: { changedGroups.contains(id) != groupsStartOpen },
            set: { isOpen in
                if isOpen != groupsStartOpen {
                    changedGroups.insert(id)
                } else {
                    changedGroups.remove(id)
                }
            }
        )
    }
}

private struct QueryBox: View {
    let shown: ShownDump
    let marks: Set<QueryMark>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SourceLink(shown: shown)
                Spacer(minLength: 8)

                if marks.contains(.duplicate) {
                    SiteTag(text: "duplicate", tint: .warning, monospaced: true)
                }

                QueryTime(milliseconds: shown.milliseconds, isSlow: marks.contains(.slow))

                CopyButton(help: "Copy the SQL of this query") {
                    shown.text
                }
            }
            .font(.callout)

            Text(shown.text)
                .textSelection(.enabled)
                .entryBox()

            if shown.truncated {
                Text("Nexus shortened the text of this query, because it is very large.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// An N+1 shows its SQL with a ? for each value. A duplicate shows its SQL. The box opens to show
// each query of the group.
private struct QueryGroupBox: View {
    let row: QueryRow<ShownDump>
    let marks: QueryMarks
    @Binding var isOpen: Bool

    var body: some View {
        let first = row.entries[0]
        let sql = row.kind == .nPlusOne ? QueryMarks.pattern(of: first.entry) : first.text
        let isSlow = row.entries.contains { shown in marks.marks(of: shown.entry).contains(.slow) }

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SourceLink(shown: first)
                Spacer(minLength: 8)

                if let tag = DumpEntryText.groupTag(row.kind, count: row.entries.count) {
                    SiteTag(text: tag, tint: .warning, monospaced: true)
                }

                QueryTime(milliseconds: row.milliseconds, isSlow: isSlow)

                CopyButton(help: "Copy the SQL of this query") {
                    sql
                }
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    isOpen.toggle()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .foregroundStyle(.secondary)
                        Text(sql)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOpen ? "Hide the queries" : "Show the queries")

                if isOpen {
                    ForEach(row.entries) { shown in
                        Divider()
                            .padding(.vertical, 6)

                        QueryGroupLine(shown: shown, showsSource: shown.source != first.source, isSlow: marks.marks(of: shown.entry).contains(.slow))
                    }
                }
            }
            .entryBox()

            if row.kind == .nPlusOne {
                Text(DumpEntryText.nPlusOneNote(count: row.entries.count, isLaravel: first.pattern != nil))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// One query of an open group. A duplicate can come from another line. That query shows its line.
private struct QueryGroupLine: View {
    let shown: ShownDump
    let showsSource: Bool
    let isSlow: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                if showsSource {
                    SourceLink(shown: shown)
                        .font(.callout)
                }

                Text(shown.text)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            Group {
                QueryTime(milliseconds: shown.milliseconds, isSlow: isSlow)

                CopyButton(help: "Copy the SQL of this query") {
                    shown.text
                }
            }
            .font(.callout)
        }
    }
}

// A slow query has its tag and its time in red.
private struct QueryTime: View {
    let milliseconds: Double?
    let isSlow: Bool

    var body: some View {
        if isSlow {
            SiteTag(text: "slow", tint: .error, monospaced: true)
        }

        if let milliseconds {
            Text(DumpEntryText.milliseconds(milliseconds))
                .fontWeight(isSlow ? .semibold : .regular)
                .foregroundStyle(isSlow ? Color.redText : Color.secondary)
        }
    }
}

// A log line: the level, the message, the time, the file and the line with the channel or the kind
// of PHP error, and the context as the tree of a dump.
private struct LogLineBox: View {
    let shown: ShownDump

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SiteTag(text: shown.label ?? "log", tint: SiteTag.Tint(DumpEntryText.tone(of: shown.entry)), monospaced: true)
                Text(shown.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Text(shown.time.secondsTime)
                    .foregroundStyle(.secondary)

                CopyButton(help: "Copy the message and the context of this log line") {
                    DumpEntryText.copyText(message: shown.text, context: shown.tree)
                }
            }

            EntrySourceLine(shown: shown)

            if let tree = shown.tree {
                DumpTreeNode(node: tree, isExpanded: (tree.children?.count ?? 0) <= DumpNode.openChildrenLimit)
                    .entryBox()
            }

            if shown.truncated {
                Text("Nexus shortened the text of this log line, because it is very large.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

// A job that the request queued, ran at once (sync) or scheduled. A queued job links to its entry
// while the list has a job of a worker with its uuid. A sync job ran inside the request. So it
// shows its time. A sync job that threw has the red tag failed.
private struct JobRowBox: View {
    @Environment(AppModel.self) private var model
    let shown: ShownDump

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SiteTag(text: shown.label ?? "job", tint: SiteTag.Tint(DumpEntryText.tone(of: shown.entry)), monospaced: true)
                Text(shown.text)
                    .font(.callout.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                run
                    .fixedSize()
            }

            EntrySourceLine(shown: shown)
        }
        .font(.callout)
    }

    @ViewBuilder private var run: some View {
        if shown.entry.ranInRequest {
            if let milliseconds = shown.milliseconds {
                Text(DumpEntryText.milliseconds(milliseconds))
                    .foregroundStyle(.secondary)
            }
        } else if let job = model.dumpedJob(ref: shown.ref) {
            Button {
                model.showDumpRequest(job.id)
            } label: {
                Text(DumpEntryText.run(of: job, time: job.started.secondsTime))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentText)
            .pointerStyle(.link)
            .help("Show the entry of this job")
        }
    }
}

// The file and the line of a log line or a job row, with its detail on the right.
private struct EntrySourceLine: View {
    let shown: ShownDump

    var body: some View {
        HStack(spacing: 6) {
            SourceLink(shown: shown)
            Spacer(minLength: 8)

            if let detail = shown.detail {
                Text(detail)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// The file and the line of an entry. A click opens the file in the editor, as the error pages of
// the sites do.
private struct SourceLink: View {
    @Environment(AppModel.self) private var model
    let shown: ShownDump

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)

            if let file = shown.file {
                Button {
                    model.openInEditor(file, line: shown.line)
                } label: {
                    Text(shown.source ?? file)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentText)
                .pointerStyle(.link)
                .help("Open \(file) in your editor")
            } else {
                Text("No file")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension View {
    // The box of a dump, the SQL of a query and the context of a log line.
    func entryBox() -> some View {
        font(.callout.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator)
            }
    }
}

// A node of the tree. The top node starts open, as in the design, unless it has very many items.
// A node that refers to an object above has no children, so a loop in the data cannot make the
// tree endless. The children are lazy, so a large open node draws only the rows that show.
private struct DumpTreeNode: View {
    let node: DumpNode
    @State private var isExpanded: Bool

    init(node: DumpNode, isExpanded: Bool = false) {
        self.node = node
        _isExpanded = State(initialValue: isExpanded)
    }

    private var children: [DumpNode] {
        node.refersTo == nil ? node.children ?? [] : []
    }

    var body: some View {
        let children = children

        if children.isEmpty {
            DumpNodeLine(node: node, isExpanded: false, hasChildren: false)
                .padding(.leading, DumpTreeLayout.indent)
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(children.indices, id: \.self) { index in
                        DumpTreeNode(node: children[index])
                    }

                    if let cut = DumpScreenText.cut(of: node) {
                        Text(DumpScreenText.leftOut(cut, "item"))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, DumpTreeLayout.indent)
                            .padding(.vertical, 1)
                    }
                }
            } label: {
                DumpNodeLine(node: node, isExpanded: isExpanded, hasChildren: true)
            }
            .disclosureGroupStyle(DumpDisclosureStyle())
        }
    }
}

private enum DumpTreeLayout {
    static let chevron: CGFloat = 12
    static let indent: CGFloat = 16
}

// The chevron opens and closes the node. The text of the node stays selectable.
private struct DumpDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DumpTreeLayout.indent - DumpTreeLayout.chevron) {
                Button {
                    configuration.isExpanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: DumpTreeLayout.chevron, height: DumpTreeLayout.chevron)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(configuration.isExpanded ? "Hide the items" : "Show the items")

                configuration.label
            }

            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, DumpTreeLayout.indent)
            }
        }
    }
}

private struct DumpNodeLine: View {
    let node: DumpNode
    let isExpanded: Bool
    let hasChildren: Bool

    var body: some View {
        Text(DumpScreenText.line(of: node, isExpanded: isExpanded, hasChildren: hasChildren))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.vertical, 1)
    }
}

// The words and the colors of the Dumps screen. The tree follows CliDumper, with the colors of
// the design: green for a string, purple for a number, bold for a class. The texts of the entries
// that the web page and nexus dumps share are in DumpEntryText.
enum DumpScreenText {
    private static let tertiary = Color(nsColor: .tertiaryLabelColor)
    private static let secondary = Color(nsColor: .secondaryLabelColor)
    private static let boldFont = Font.callout.monospaced().weight(.semibold)
    private static let containerKinds: Set<DumpNode.Kind> = [.array, .object, .resource]

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    // "Today at 14:32:08".
    static func date(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    // "200 · 184 ms" or "exit 0 · 3.2 s", with the texts of nexus dumps. A request that still runs,
    // or that PHP ended without its shutdown functions, has none.
    static func result(of request: DumpedRequest) -> String? {
        let parts = [request.statusText, request.durationText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // The items or the characters that the cloner left out. A negative number means an unknown
    // number.
    static func cut(of node: DumpNode) -> Int? {
        guard let cut = node.cut else {
            return nil
        }

        return cut == 0 ? nil : cut
    }

    static func leftOut(_ cut: Int, _ word: String) -> String {
        cut < 0 ? "… some \(word)s left out" : "… \(Count.text(cut, word)) left out"
    }

    static func line(of node: DumpNode, isExpanded: Bool, hasChildren: Bool) -> AttributedString {
        var line = AttributedString()

        func add(_ text: String, _ color: Color? = nil, bold: Bool = false) {
            var part = AttributedString(text)
            part.foregroundColor = color

            if bold {
                part.font = boldFont
            }

            line += part
        }

        if let key = node.displayKey {
            if node.access == nil {
                add(key, node.index == true ? Color.accentText : Color.greenText)
                add(" => ", secondary)
            } else {
                add("\(key): ")
            }
        }

        switch node.kind {
        case .null, .bool, .int, .float:
            add(node.value ?? node.kind.rawValue, Color.accentText)
        case .label:
            add(node.value ?? "")
        case .string:
            add("\"\(node.value ?? "")\"", Color.greenText)

            if let cut = cut(of: node) {
                add(" \(leftOut(cut, "character"))", tertiary)
            }
        case .array:
            let count = node.count ?? node.children?.count ?? 0
            add(count == 0 ? "[]" : "array:\(count)", bold: true)
        case .object:
            add(node.className ?? "object", bold: true)

            if let ref = node.ref {
                add(" #\(ref)", tertiary)
            }
        case .resource:
            add("\(node.className ?? "unknown") resource", bold: true)

            if let ref = node.ref {
                add(" @\(ref)", tertiary)
            }
        }

        if let items = items(of: node, isExpanded: isExpanded, hasChildren: hasChildren) {
            add(" \(items)", tertiary)
        }

        return line
    }

    // A closed object or resource shows its number of items. An array shows it in "array:3". A
    // node without children shows the items that the cloner left out.
    private static func items(of node: DumpNode, isExpanded: Bool, hasChildren: Bool) -> String? {
        guard containerKinds.contains(node.kind) else {
            return nil
        }

        guard hasChildren else {
            return leftOutItems(of: node)
        }

        guard node.kind != .array else {
            return nil
        }

        guard !isExpanded else {
            return nil
        }

        return node.count.map { "· \(Count.text($0, "item"))" }
    }

    private static func leftOutItems(of node: DumpNode) -> String? {
        guard node.refersTo == nil else {
            return nil
        }

        return cut(of: node).map { leftOut($0, "item") }
    }
}
