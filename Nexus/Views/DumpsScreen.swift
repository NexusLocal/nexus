import AppKit
import NexusCore
import NexusIPC
import SwiftUI

// The Dumps screen (part 8): the settings of the dump viewer, and the requests and commands of the
// sites with their dumps. The design is the frame "Dumps" in nexus.pen, with the states of "Dumps
// States".
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
                    .help(model.dumpState?.page == nil ? DumpState.pageMissingText : "Shows the dumps on a web page of Nexus.")
                }
            }
            .onAppear {
                model.dumpsScreenAppeared()
            }
            .onDisappear {
                model.dumpsScreenDisappeared()
            }
            // A fix of a .env or a .user.ini happens in another app. The blocks are fresh when Nexus
            // comes to the front again.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.refreshDumpState() }
            }
    }

    private var subtitle: String {
        guard model.catchesDumps else {
            return "Catch dumps is off"
        }

        guard !model.visibleDumpRequests.isEmpty else {
            return model.dumpState?.loaded == false ? "Nexus loads the dumps" : "No dumps"
        }

        return "\(Count.text(model.visibleDumpRequests.count, "request")) with \(Count.text(model.visibleDumpCount, "dump"))"
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
                Text("Nexus keeps the newest 1000 dumps. A click on a file opens it in your editor. Test runs never send dumps.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(clearTitle, isPresented: $confirmsClear) {
            Button("Clear dumps", role: .destructive) {
                model.clearDumps()
            }
        } message: {
            Text("You cannot get these dumps back.")
        }
    }

    private var clearTitle: String {
        model.dumpFilter.map { "Remove the dumps of \($0.label)?" } ?? "Remove all dumps?"
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

            Group {
                Picker(selection: setting(\.pageMode)) {
                    ForEach(DumpPageMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Text("Show dumps on the web page")
                    Text("Without Nexus, PHP prints each dump in the page. This choice decides if the page still shows it.\n\(pageMode.explanation)")
                }

                Toggle(isOn: setting(\.commands)) {
                    Text("Catch dumps of commands")
                    Text("php artisan, queue workers and other PHP commands. The terminal still shows each dump.")
                }
            }
            .disabled(!model.catchesDumps)
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
// header, above the list. The problem is nil while "Catch dumps" is off.
private struct DumpRequestsHeader: View {
    @Environment(AppModel.self) private var model
    @Binding var confirmsClear: Bool

    var body: some View {
        let blocks = model.catchesDumps ? model.visibleDumpBlocks : []

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
            .disabled(!model.catchesDumps)

            if let problem = model.dumpState?.problem {
                WarningBanner(title: "The dump viewer has a problem", message: problem) {}
            }

            ForEach(blocks, id: \.self) { block in
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

// A site whose dumps Nexus cannot catch. file is nil when the key does not come from a file of
// the site. So that banner has no button.
private struct DumpBlockBanner: View {
    @Environment(AppModel.self) private var model
    let block: DumpBlock

    private var message: String {
        let source = block.file.map { "The \(URL(filePath: $0).lastPathComponent) of \(block.host)" } ?? block.host

        switch block.reason {
        case .varDumperFormat:
            return "\(source) sets VAR_DUMPER_FORMAT. Remove this key to see its dumps here."
        case .userIni:
            return "\(source) sets its own prepend file. PHP then runs that file and not the file of Nexus."
        }
    }

    var body: some View {
        WarningBanner(title: "Nexus cannot catch the dumps of \(block.host)", message: message) {
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
        if !model.catchesDumps {
            Text("Turn on Catch dumps to see the dumps of your sites.")
                .foregroundStyle(.secondary)
        } else if !model.visibleDumpRequests.isEmpty {
            // The browser fills the whole row, so it gets the rounded corners of the group.
            DumpBrowser()
                .frame(height: 465)
                .clipShape(.rect(cornerRadius: 10))
                .listRowInsets(EdgeInsets())
        } else if model.dumpState?.loaded == false {
            Text("Nexus loads the dumps of its last run.")
                .foregroundStyle(.secondary)
        } else {
            Text(model.dumpFilter.map { "\($0.label) has no dumps." } ?? "No dumps yet. Add dump($value) to the code of a site and open the page.")
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
                Text(DumpScreenText.summary(of: request))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)

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

// The head reads only the open request. The dumps are a view of their own, so a change of the list
// does not draw them again.
private struct DumpDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let request = model.openDumpRequest {
            VStack(spacing: 0) {
                DumpRequestHead(request: request)

                Divider()

                OpenDumps()
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

                RowRemoveButton(help: "Remove this request and its dumps") {
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

private struct OpenDumps: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(model.openDumps) { shown in
                    DumpBox(shown: shown)
                }

                if model.loadingDumps, model.openDumps.isEmpty {
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

// One dump: the file and the line, the kind of call, the copy button and the tree. Without a tree
// the box shows the text of CliDumper.
private struct DumpBox: View {
    @Environment(AppModel.self) private var model
    let shown: ShownDump

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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

                if let label = shown.label {
                    Text(label)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(shown.kind == .dd ? "dd()" : "dump()")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)

                Button {
                    copyToPasteboard(shown.text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Copy the text of this dump")

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
            .font(.callout.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator)
            }

            if shown.truncated {
                Text("Nexus shortened the text of this dump, because it is very large.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
// the design: green for a string, purple for a number, bold for a class.
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

    static func summary(of request: DumpedRequest) -> String {
        ([Count.text(request.dumpCount, "dump")] + [result(of: request)].compactMap { $0 }).joined(separator: " · ")
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
