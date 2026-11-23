import AppKit
import NexusCore
import NexusIPC
import SwiftUI

// The Logs screen (group 7): the log files of the apps of a site or a workspace. The design is the
// frame "Logs" in nexus.pen, with "Logs States", "Logs Entry States" and "Alert Clear Log".
struct LogsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var clearsFile: LogFile?

    private var logs: LogsModel {
        model.logs
    }

    var body: some View {
        Form {
            Section {
                LogsContent()
            } header: {
                LogsHeader()
            } footer: {
                Text("Nexus reads the log files where the app writes them. A click on a file opens it in your editor at the line. Times are in the time zone of this Mac.")
            }
        }
        .formStyle(.grouped)
        .screenTitle("Logs", subtitle: subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.openLogPage()
                } label: {
                    Label("Open in Browser", systemImage: "arrow.up.forward.app")
                }
                .labelStyle(.titleAndIcon)
                .disabled(model.dumpState?.page == nil || logs.place == nil)
                .help(model.dumpState?.page == nil ? DumpState.pageMissingText : "Shows the logs on a web page of Nexus.")
            }

            ToolbarItem(placement: .primaryAction) {
                MoreMenu {
                    LogsMoreItems(clearsFile: $clearsFile)
                }
            }
        }
        .alert(clearsFile.map { "Clear \($0.name)?" } ?? "", isPresented: Binding(get: { clearsFile != nil }, set: { if !$0 { clearsFile = nil } })) {
            Button("Clear log", role: .destructive) {
                if let file = clearsFile {
                    do {
                        try logs.clear(file)
                    } catch {
                        model.failure = ActionFailure(title: "\(file.name) was not cleared", message: error.localizedDescription, place: .window)
                    }
                }
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You cannot get these entries back.")
        }
        .onAppear {
            logs.setPlaces(model.logPlaces)
            logs.appeared()
        }
        .onDisappear {
            logs.disappeared()
        }
        .onChange(of: model.allSites) {
            logs.setPlaces(model.logPlaces)
        }
    }

    private var subtitle: String {
        guard let place = logs.place else {
            return "No sites"
        }

        let bytes = logs.files.reduce(Int64(0)) { $0 + $1.bytes }
        return "\(place.id) · \(Count.text(logs.files.count, "file")) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }
}

private struct LogsMoreItems: View {
    @Environment(AppModel.self) private var model
    @Binding var clearsFile: LogFile?

    var body: some View {
        let logs = model.logs
        let file = logs.chosenFile ?? (logs.files.count == 1 ? logs.files.first : nil)

        if let editor = model.editorApp {
            Button("Open in \(editor.name)", systemImage: "chevron.left.forwardslash.chevron.right") {
                if let file {
                    model.openInEditor(file.path)
                }
            }
            .disabled(file == nil)
        }

        Button("Show in Finder", systemImage: "folder") {
            if let path = file?.path ?? logs.appFiles.first?.path {
                model.showInFinder(path)
            }
        }
        .disabled(file == nil && logs.appFiles.isEmpty)

        Divider()

        Button("Clear log…", systemImage: "eraser", role: .destructive) {
            clearsFile = file
        }
        .disabled(file?.canClear != true)
        .help(file == nil ? "Choose one file first." : "")
    }
}

private struct LogsHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let logs = model.logs

        HStack {
            Text("Entries")
            Spacer()

            Picker("Site", selection: Binding(get: { logs.placeID }, set: { logs.choosePlace($0) })) {
                ForEach(logs.places) { place in
                    Text(place.workspace == nil ? place.id : "\(place.id) (workspace)").tag(Optional(place.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(logs.places.isEmpty)

            Picker("File", selection: Binding(get: { logs.query.fileID }, set: { logs.chooseFile($0) })) {
                Text("All files").tag(String?.none)

                let appFiles = logs.files.filter { $0.kind == .app }
                let other = logs.files.filter { $0.kind != .app }

                if !appFiles.isEmpty {
                    Divider()
                }

                ForEach(appFiles) { file in
                    Text("\(file.name)  \(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file))").tag(Optional(file.id))
                }

                if !other.isEmpty {
                    Divider()
                }

                ForEach(other) { file in
                    Text(file.name).tag(Optional(file.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(logs.files.isEmpty)
        }
    }
}

private struct LogsContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let logs = model.logs

        if logs.places.isEmpty {
            Text("Add a site to see the logs of its app.")
                .foregroundStyle(.secondary)
        } else if !logs.isLoaded {
            Text("Nexus reads the logs.")
                .foregroundStyle(.secondary)
        } else if logs.files.isEmpty {
            LogsEmpty(place: logs.place)
        } else {
            LogBrowserBox()
                .containerRelativeFrame(.vertical) { height, _ in max(440, height - 150) }
                .clipShape(.rect(cornerRadius: 10))
                .listRowInsets(EdgeInsets())
        }
    }
}

// "Logs States" in the design: WordPress without WP_DEBUG_LOG, and a site without log files.
private struct LogsEmpty: View {
    let place: LogPlace?
    static let wordPressLines = "define( 'WP_DEBUG', true );\ndefine( 'WP_DEBUG_LOG', true );\ndefine( 'WP_DEBUG_DISPLAY', false );"

    var body: some View {
        if place?.kind == .wordpress {
            VStack(spacing: 8) {
                Image(systemName: "doc.badge.ellipsis")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("WordPress writes no log file")
                    .font(.title3.bold())
                Text("Add these lines to wp-config.php, above \"That's all, stop editing!\".")
                    .foregroundStyle(.secondary)
                Text(Self.wordPressLines)
                    .textSelection(.enabled)
                    .entryBox()
                    .frame(maxWidth: 460)
                Button("Copy lines") {
                    copyToPasteboard(Self.wordPressLines)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            Text(place?.kind == .proxy ? "A site that sends its requests to a port has no logs in Nexus." : "This site has no log files yet. Each file that the app writes shows here.")
                .foregroundStyle(.secondary)
        }
    }
}

// The filter bar, the hidden entries, the list with the open entry, and the status bar.
private struct LogBrowserBox: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let logs = model.logs

        VStack(spacing: 0) {
            LogFilterBar()
            Divider()

            if !logs.query.hiddenMessages.isEmpty || logs.result.hiddenTestRuns > 0 {
                LogHiddenBar()
                Divider()
            }

            if logs.query.searchText != nil, !logs.isSearching {
                LogSearchBar()
                Divider()
            }

            if logs.rows.isEmpty {
                Text(logs.result.total == 0 ? "The log has no entries." : "No entries match the filters.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ListDetailView(items: logs.rows, openID: logs.openRowID, listWidth: 360, open: { logs.open($0) }) { item, selected in
                    LogRowView(item: item, selected: selected)
                } detail: {
                    LogDetailView()
                }
            }

            Divider()
            LogStatusBar()
        }
    }
}

private struct LogFilterBar: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        let logs = model.logs

        HStack(spacing: 8) {
            TextField("Search all files", text: $search, prompt: Text("Search all files"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 110, maxWidth: 200)
                .onChange(of: search) { _, text in
                    logs.setSearch(text)
                }
                .onChange(of: logs.query.search) { _, text in
                    if text != search {
                        search = text
                    }
                }
                .onAppear {
                    search = logs.query.search
                }

            if logs.isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            ForEach(LogLevelGroup.allCases, id: \.self) { group in
                LevelChip(group: group, count: logs.countProgress == nil ? logs.result.levelCounts[group] ?? 0 : nil, isOn: logs.query.levels.contains(group)) {
                    logs.toggleLevel(group)
                }
            }

            Spacer(minLength: 8)

            // A narrow window gets the short label.
            let groups = Binding(get: { logs.query.groupsEqualEntries }, set: { logs.setGroupsEqualEntries($0) })

            ViewThatFits(in: .horizontal) {
                Toggle("Group equal entries", isOn: groups)
                    .fixedSize()
                Toggle("Group", isOn: groups)
                    .fixedSize()
                    .help("Group equal entries")
            }
            .toggleStyle(.checkbox)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct LevelChip: View {
    let group: LogLevelGroup
    let count: Int?
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isOn ? group.color : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(group.title)
                    .foregroundStyle(isOn ? .primary : .tertiary)
                Text(count.map(String.init) ?? "…")
                    .foregroundStyle(isOn ? .secondary : .tertiary)
                    .monospacedDigit()
            }
            .font(.callout)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isOn ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.separator)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isOn ? "Hide the \(group.title.lowercased()) entries" : "Show the \(group.title.lowercased()) entries")
    }
}

private struct LogHiddenBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let logs = model.logs

        HStack(spacing: 6) {
            Text("Hidden:")
                .foregroundStyle(.secondary)

            if logs.query.hidesTestRuns, logs.result.hiddenTestRuns > 0 {
                HiddenChip(text: "Test runs · \(logs.result.hiddenTestRuns)", help: "Show the entries of test runs. They have the tag testing.") {
                    logs.setHidesTestRuns(false)
                }
            }

            ForEach(logs.query.hiddenMessages.sorted { $0.value < $1.value }, id: \.key) { hash, text in
                HiddenChip(text: "“\(text)” · \(logs.result.hiddenByMessage[hash] ?? 0)", help: "Show these entries again") {
                    logs.showHidden(hash)
                }
            }

            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct HiddenChip: View {
    let text: String
    let help: String
    let show: () -> Void

    var body: some View {
        Button(action: show) {
            HStack(spacing: 4) {
                Text(text)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 5)
            .padding(.vertical, 2)
            .background(.quaternary, in: .rect(cornerRadius: 5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// "Logs Entry States": the count of each file after a search. A click shows only that file.
private struct LogSearchBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let logs = model.logs

        HStack(spacing: 6) {
            Text("\(Count.text(logs.result.matching, "entry", plural: "entries")):")
                .foregroundStyle(.secondary)

            ForEach(logs.searchCounts, id: \.file.id) { file, count in
                Button {
                    logs.chooseFile(logs.query.fileID == file.id ? nil : file.id)
                } label: {
                    HStack(spacing: 6) {
                        Text(file.name)
                        Text(String(count))
                            .monospacedDigit()
                    }
                    .foregroundStyle(count > 0 ? Color.accentText : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(count > 0 ? AnyShapeStyle(Color.accentSoft) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
                    .overlay {
                        if count == 0 {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.separator)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(count == 0)
            }

            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct LogStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let logs = model.logs

        HStack(spacing: 6) {
            Circle()
                .fill(Color.statusGreen)
                .frame(width: 7, height: 7)
            Text("Live")
                .fontWeight(.semibold)
                .foregroundStyle(Color.greenText)

            if let progress = logs.countProgress {
                Text("Counting: \(Int(progress * 100))%")
                    .foregroundStyle(.secondary)
            } else {
                Text("Shows \(String(logs.rows.count)) of \(Count.text(logs.result.total, "entry", plural: "entries"))")
                    .foregroundStyle(.secondary)
            }

            if logs.result.rowCount > logs.rows.count {
                Button("Show older entries") {
                    logs.showOlder()
                }
                .buttonStyle(.link)
            }

            Spacer(minLength: 8)

            Text(logs.chosenFile?.name ?? logs.files.map(\.name).joined(separator: ", "))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct LogRowView: View {
    @Environment(AppModel.self) private var model
    let item: LogRowItem
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let day = item.dayTitle {
                Text(day)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .windowBackgroundColor))

                Divider()
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    LevelTag(level: item.row.entry.level)

                    if item.row.entry.isTestRun {
                        SiteTag(text: "testing", tint: .neutral, monospaced: true)
                            .help("A test run wrote this entry.")
                    }

                    Text(item.summary.message.isEmpty ? " " : item.summary.message)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 8)

                    if let date = item.row.entry.date {
                        Text(LogTimeText.time(date))
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    Text(LogRowText.info(of: item, project: model.logs.place?.projectFolder ?? ""))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)

                    if item.row.count > 1 {
                        SiteTag(text: "×\(item.row.count)", tint: .neutral, monospaced: true)
                            .help("\(item.row.count) equal entries")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? Color.accentSelection : Color.clear)
        }
        .contentShape(.rect)
        .contextMenu {
            Button("Hide entries like this") {
                model.logs.hideEntriesLike(item)
            }

            if item.row.entry.isTestRun {
                Button("Hide test runs") {
                    model.logs.setHidesTestRuns(true)
                }
            }
        }
    }
}

private struct LevelTag: View {
    let level: String

    var body: some View {
        if !level.isEmpty {
            SiteTag(text: level, tint: LogLevelGroup.of(level: level).tint, monospaced: true)
        }
    }
}

// The second line of a row: the exception and its file, or the file name and the context.
enum LogRowText {
    static func info(of item: LogRowItem, project: String) -> String {
        var parts: [String] = []
        let summary = item.summary

        if let exception = summary.exceptionClass {
            parts.append(exception)
        } else {
            parts.append(item.file.name)
        }

        if let file = summary.sourceFile {
            parts.append("\(LogEntryParser.relative(file, to: project)):\(summary.sourceLine ?? 0)")
        } else if item.file.kind == .requests {
            parts.append("status \(item.row.entry.level)")
        }

        if summary.exceptionClass != nil, summary.sourceFile == nil {
            parts.append(item.file.name)
        }

        return (parts + summary.context).joined(separator: " · ")
    }
}

extension LogLevelGroup {
    var color: Color {
        switch self {
        case .error: .statusRed
        case .warning: .statusOrange
        case .info, .debug: .statusGray
        }
    }

    var tint: SiteTag.Tint {
        switch self {
        case .error: .error
        case .warning: .warning
        case .info, .debug: .neutral
        }
    }
}

// The open entry: the message, the time, the exception with its stack trace, and the context.
private struct LogDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let item = model.logs.detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LogDetailHead(item: item)
                    Divider()

                    ForEach(Array(item.detail.exceptions.enumerated()), id: \.offset) { offset, exception in
                        LogExceptionBlock(exception: exception, isPrevious: offset > 0)
                        Divider()
                    }

                    if let context = item.detail.context {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Context and extra")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            LogContextTree(context: context, ids: item.detail.ids)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(item.row.id)
        } else if model.logs.openRowID != nil {
            ProgressView()
                .controlSize(.small)
        } else {
            Text("Choose an entry.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct LogDetailHead: View {
    @Environment(AppModel.self) private var model
    let item: LogDetailItem

    var body: some View {
        let logs = model.logs
        let entry = item.row.row.entry
        let file = item.row.file

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                LevelTag(level: entry.level)
                Text(item.detail.message.isEmpty ? item.row.summary.message : item.detail.message)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)

                Menu {
                    Button("Copy") {
                        copyToPasteboard(item.text)
                    }

                    Button("Copy as Markdown") {
                        copyToPasteboard(item.detail.markdown(level: entry.level, time: timeText, file: file.name, project: logs.place?.projectFolder ?? ""))
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("Copy this entry")
            }

            if item.detail.isCut {
                HStack(spacing: 6) {
                    Image(systemName: "scissors")
                        .foregroundStyle(.secondary)
                    Text("Nexus shows \(LogEntryParser.shownCharacters) of the \(item.detail.characters) characters of this entry.")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)

                    if let editor = model.editorApp {
                        Button("Open in \(editor.name)") {
                            model.openInEditor(file.path, line: entry.line > 0 ? entry.line : nil)
                        }
                    }
                }
                .font(.callout)
            }

            if entry.date != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Time")
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)

                    // The log of Laravel has the time of APP_TIMEZONE. The screen shows the time of
                    // the Mac, so the time of the log helps to find the line in the file. It goes
                    // under the time when the line is too narrow.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(timeText)
                            logTimeText(file: file)
                        }
                        .fixedSize()

                        VStack(alignment: .leading, spacing: 2) {
                            Text(timeText)
                            logTimeText(file: file)
                        }
                    }
                    .textSelection(.enabled)
                }
                .font(.callout)
            }

            if item.row.row.count > 1 {
                HeaderLine(key: "Count", value: countText, keyWidth: 56)
            }

            HeaderLine(key: "File", value: entry.line > 0 ? "\(file.name), line \(entry.line)" : file.name, keyWidth: 56, action: (help: "Open \(file.path) in your editor", perform: { model.openInEditor(file.path, line: entry.line > 0 ? entry.line : nil) }))

            if let channel = item.detail.channel {
                HeaderLine(key: "Channel", value: channel, keyWidth: 56)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func logTimeText(file: LogFile) -> some View {
        let logs = model.logs

        if let logTime = item.detail.logTime, file.kind == .app, logs.timeZone(of: file).secondsFromGMT() != TimeZone.current.secondsFromGMT() {
            Text("\(String(logTime.suffix(8))) \(LogTimeText.zoneName(logs.timeZone(of: file))) in the log")
                .foregroundStyle(.tertiary)
        }
    }

    private var timeText: String {
        item.row.row.entry.date.map(LogTimeText.full) ?? "No time in the log"
    }

    private var countText: String {
        guard let first = item.row.row.firstDate else {
            return "\(item.row.row.count) times"
        }

        let calendar = Calendar.current
        let sameDay = item.row.row.entry.date.map { calendar.isDate(LogTimeText.date($0), inSameDayAs: LogTimeText.date(first)) } ?? false
        return "\(item.row.row.count) times, the first \(sameDay ? "at \(LogTimeText.time(first))" : LogTimeText.since(first))"
    }
}

private struct LogExceptionBlock: View {
    @Environment(AppModel.self) private var model
    let exception: LogException
    let isPrevious: Bool
    @State private var showsVendor = false

    var body: some View {
        let project = model.logs.place?.projectFolder ?? ""
        let vendorCount = exception.frames.filter { $0.isVendor && $0.file != nil }.count

        VStack(alignment: .leading, spacing: 6) {
            Text(isPrevious ? "Previous exception" : "Exception")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            (Text(exception.namespace).foregroundStyle(.secondary) + Text(exception.shortClassName).fontWeight(.semibold))
                .font(.callout.monospaced())
                .textSelection(.enabled)

            if isPrevious || exception.message != (model.logs.detail?.detail.message ?? "") {
                Text(exception.message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let file = exception.file {
                SourceButton(path: file, line: exception.line, project: project)
            }

            if !exception.frames.isEmpty {
                HStack {
                    Text("Stack trace")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Count.text(exception.frames.count - vendorCount, "frame")) of the app, \(vendorCount) in vendor/")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 6)

                ForEach(LogFrameGroup.groups(of: exception.frames, showsVendor: showsVendor), id: \.id) { group in
                    switch group {
                    case .frame(let frame):
                        LogFrameLine(frame: frame, project: project)
                    case .vendor(let count, _):
                        Button {
                            showsVendor = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .frame(width: 26, alignment: .leading)
                                Text("\(Count.text(count, "frame")) in vendor/")
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// The frames of the app one by one, and each run of frames in vendor/ as one row until a click.
enum LogFrameGroup {
    case frame(LogFrame)
    case vendor(count: Int, first: Int)

    var id: String {
        switch self {
        case .frame(let frame): "f\(frame.number ?? 0)-\(frame.call.hashValue)"
        case .vendor(_, let first): "v\(first)"
        }
    }

    static func groups(of frames: [LogFrame], showsVendor: Bool) -> [LogFrameGroup] {
        guard !showsVendor else {
            return frames.map(LogFrameGroup.frame)
        }

        var groups: [LogFrameGroup] = []
        var run = 0
        var first = 0

        for (index, frame) in frames.enumerated() {
            if frame.isVendor, frame.file != nil {
                if run == 0 {
                    first = index
                }

                run += 1
                continue
            }

            if run > 0 {
                groups.append(.vendor(count: run, first: first))
                run = 0
            }

            groups.append(.frame(frame))
        }

        if run > 0 {
            groups.append(.vendor(count: run, first: first))
        }

        return groups
    }
}

private struct LogFrameLine: View {
    let frame: LogFrame
    let project: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(frame.number.map { "#\($0)" } ?? "")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 26, alignment: .leading)

            if let file = frame.file {
                SourceButton(path: file, line: frame.line, project: project, showsIcon: false)
                    .layoutPriority(1)
            }

            Text(frame.call)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

// A file and its line. A click opens it in the editor, as on the Dumps screen.
private struct SourceButton: View {
    @Environment(AppModel.self) private var model
    let path: String
    let line: Int?
    let project: String
    var showsIcon = true

    var body: some View {
        HStack(spacing: 6) {
            if showsIcon {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
            }

            Button {
                model.openInEditor(path, line: line)
            } label: {
                Text(line.map { "\(LogEntryParser.relative(path, to: project)):\($0)" } ?? LogEntryParser.relative(path, to: project))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentText)
            .pointerStyle(.link)
            .help("Open \(path) in your editor")
        }
        .font(.callout)
    }
}

// The context with the tree of the Dumps screen. A value of request_id, trace_id and the other ID
// keys gets "Find all" under the tree.
private struct LogContextTree: View {
    @Environment(AppModel.self) private var model
    let context: DumpNode
    let ids: [LogID]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array((context.children ?? []).enumerated()), id: \.offset) { _, node in
                    DumpTreeNode(node: node, isExpanded: (node.children?.count ?? 0) <= 10)
                }
            }
            .entryBox()

            ForEach(ids, id: \.self) { id in
                Button {
                    model.logs.findAll(id.value)
                } label: {
                    Label("Find all entries with \(id.key) \(id.value)", systemImage: "magnifyingglass")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
    }
}
