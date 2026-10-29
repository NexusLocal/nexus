import AppKit
import SwiftUI

// A box of rows with a line between them, for the screens that cannot use a grouped Form.
struct RowGroup<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }

            Group(subviews: content) { rows in
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 12)
                        }

                        rows[index]
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                    }
                }
            }
            .background(.fill.quaternary, in: .rect(cornerRadius: 10))
        }
    }
}

struct MonoText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .lineLimit(1)
    }
}

struct PathText: View {
    let path: String

    init(_ path: String) {
        self.path = path
    }

    var body: some View {
        Text(path)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }
}

struct PortField: View {
    @Binding var port: Int
    @State private var text = ""

    var body: some View {
        TextField("Port", text: $text)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(.system(.body, design: .monospaced))
            .frame(width: 72)
            .digitsOnly($text)
            .onChange(of: port, initial: true) {
                text = String(port)
            }
            .onChange(of: text) {
                guard let value = Int(text) else {
                    return
                }

                guard value <= 65535 else {
                    text = String(port)
                    return
                }

                if value > 0, value != port {
                    port = value
                }
            }
    }
}

extension View {
    // Removes every character that is not a digit, also from pasted text.
    func digitsOnly(_ text: Binding<String>, maxLength: Int = 5) -> some View {
        onChange(of: text.wrappedValue) {
            let digits = String(text.wrappedValue.filter { $0.isASCII && $0.isNumber }.prefix(maxLength))

            if digits != text.wrappedValue {
                text.wrappedValue = digits
            }
        }
    }

    func plainTextInput() -> some View {
        writingToolsBehavior(.disabled)
            .autocorrectionDisabled()
    }
}

// The field keeps the new number until nexusd sends the new port. A refused port stays in the
// field, so the user can correct it.
struct PortRow: View {
    let title: String
    let port: Int
    let change: (Int) -> Void
    @State private var newPort: Int?

    var body: some View {
        LabeledContent(title) {
            HStack {
                PortField(port: Binding(get: { newPort ?? port }, set: { newPort = $0 }))
                Button("Change") {
                    if let newPort {
                        change(newPort)
                    }
                }
                .disabled(newPort == nil || newPort == port)
            }
        }
        .onChange(of: port) {
            newPort = nil
        }
    }
}

struct InfoBanner<Actions: View>: View {
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.accentText)

            Text(text)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            actions
        }
        .padding(12)
        .background(Color.accentSoft, in: .rect(cornerRadius: 10))
    }
}

extension InfoBanner where Actions == EmptyView {
    init(text: String) {
        self.text = text
        self.actions = EmptyView()
    }
}

struct ToggleCell: View {
    let toggle: ToggleItem
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 6) {
            HelpName(name: toggle.name, help: toggle.help)
            Spacer()
            // macOS draws a disabled switch that is on almost as an enabled one. The design
            // shows a switch that cannot change at 45 percent.
            Toggle(toggle.name, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(toggle.required)
                .opacity(toggle.required ? 0.45 : 1)
                .help(toggle.required ? "Always on" : "")
        }
    }
}

// A name with an ⓘ. A tooltip shows its help on hover. A click shows the help at once.
struct HelpName: View {
    let name: String
    let help: String

    @State private var showsHelp = false

    var body: some View {
        HStack(spacing: 6) {
            MonoText(name)
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .imageScale(.small)
        }
        .contentShape(.rect)
        .onTapGesture {
            showsHelp.toggle()
        }
        .help(help)
        .popover(isPresented: $showsHelp, arrowEdge: .bottom) {
            Text(help)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }
}

// Extensions and modules in two columns. Two columns keep a long list short. A switch sends its
// change to nexusd and shows the asked state while nexusd works.
struct ToggleGrid: View {
    @Environment(AppModel.self) private var model
    let service: ServiceVersion

    var body: some View {
        let toggles = service.toggles

        ForEach(Array(stride(from: 0, to: toggles.count, by: 2)), id: \.self) { index in
            HStack(spacing: 24) {
                cell(toggles[index])

                if index + 1 < toggles.count {
                    cell(toggles[index + 1])
                } else {
                    Spacer()
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func cell(_ toggle: ToggleItem) -> some View {
        ToggleCell(toggle: toggle, isOn: Binding(
            get: { model.isToggleOn(toggle, of: service) },
            set: { model.setToggle(toggle, of: service, to: $0) }
        ))
    }
}

// Shows the newest 100 lines of a log file. The lines change while the service writes. Without a
// file, the section shows the lines of the sample data.
struct LogSection: View {
    let file: String?
    let sampleLines: [String]
    @State private var lines: [String] = []
    @State private var position = ScrollPosition(edge: .bottom)

    var body: some View {
        let shown = file == nil ? sampleLines : lines

        Section {
            ScrollView {
                Text(shown.isEmpty ? "No log lines yet." : shown.suffix(100).joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(shown.isEmpty ? .tertiary : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 96)
            .scrollPosition($position)
            .defaultScrollAnchor(.top, for: .alignment)
            .onChange(of: shown) {
                position.scrollTo(edge: .bottom)
            }
        } header: {
            HStack {
                Text("Log")
                Spacer()
                Button("Open log file") {
                    if let file {
                        NSWorkspace.shared.open(URL(filePath: file))
                    }
                }
                .disabled(file == nil)
            }
        } footer: {
            Text("The newest 100 lines. \"Open log file\" shows the full log.")
        }
        .task(id: file) {
            guard let file else {
                return
            }

            for await tail in LogTail.lines(of: URL(filePath: file)) {
                lines = tail
            }
        }
    }
}

// The last lines of a log file, again after each write. It reads only the end of the file. So a
// large log costs no time. It works off the main thread.
nonisolated enum LogTail {
    static func lines(of file: URL, count: Int = 100) -> AsyncStream<[String]> {
        AsyncStream { continuation in
            let source = Watcher(file: file) {
                continuation.yield(read(file, count: count))
            }
            continuation.yield(read(file, count: count))
            continuation.onTermination = { _ in source.cancel() }
        }
    }

    static func read(_ file: URL, count: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return []
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 65_536 ? size - 65_536 : 0
        try? handle.seek(toOffset: start)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init)

        // A read from the middle of the file starts in the middle of a line.
        return Array((start > 0 ? lines.dropFirst() : lines[...]).suffix(count))
    }

    // A log can be replaced or truncated. So the watch starts again on the new file. After a
    // cancel no new watch starts, because only the cancel handler of a source closes its file.
    private final class Watcher: @unchecked Sendable {
        private let file: URL
        private let changed: @Sendable () -> Void
        private let queue = DispatchQueue(label: "nexus.log-tail")
        private var source: (any DispatchSourceFileSystemObject)?
        private var cancelled = false

        init(file: URL, changed: @escaping @Sendable () -> Void) {
            self.file = file
            self.changed = changed
            queue.async { self.watch() }
        }

        func cancel() {
            queue.async {
                self.cancelled = true
                self.source?.cancel()
                self.source = nil
            }
        }

        private func watch() {
            guard !cancelled else {
                return
            }

            let descriptor = open(file.path(percentEncoded: false), O_EVTONLY)
            guard descriptor >= 0 else {
                queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.watch() }
                return
            }

            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else {
                    return
                }

                self.changed()

                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    source.cancel()
                    self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.watch() }
                }
            }
            source.setCancelHandler { close(descriptor) }
            self.source = source
            source.resume()
        }
    }
}

// The database apps are the apps of Settings > Databases that open this kind (D36): the apps
// that macOS knows for the link, and the apps that the user added. The primary action uses the
// app of "Open with".
struct OpenDatabaseButton: View {
    @Environment(AppModel.self) private var model
    let kind: ServiceKind
    let url: URL?

    private var chosenApp: String {
        kind == .postgresql ? model.settings.postgresqlApp : model.settings.mysqlApp
    }

    var body: some View {
        let apps = model.databaseApps(for: kind)
        let primaryApp = apps.first { $0.name == chosenApp } ?? apps.first

        Menu("Open") {
            Section("Open with") {
                ForEach(apps) { app in
                    Button(app == primaryApp ? "\(app.name) (default)" : app.name, systemImage: "cylinder.split.1x2") {
                        open(with: app)
                    }
                }
            }

            Divider()

            Button("Copy URL", systemImage: "link") {
                copyToPasteboard(url?.absoluteString ?? "")
            }

            Text(url?.absoluteString ?? "")
        } primaryAction: {
            if let primaryApp {
                open(with: primaryApp)
            }
        }
        .fixedSize()
        .disabled(url == nil)
    }

    private func open(with app: AppChoice) {
        guard let url, let location = app.location else {
            return
        }

        NSWorkspace.shared.open([url], withApplicationAt: location, configuration: NSWorkspace.OpenConfiguration())
    }
}

// Starts or stops a service. It shows the asked state while nexusd works.
struct ServiceSwitch: View {
    @Environment(AppModel.self) private var model
    let service: ServiceVersion
    var place: ActionPlace = .window

    var body: some View {
        Toggle(service.name, isOn: Binding(
            get: { model.isSwitchedOn(service) },
            set: { model.setRunning($0, service: service, from: place) }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
    }
}

struct MoreMenu<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("More")
    }
}

// macOS blocks the notifications of Nexus when the user said no, or did not see the question.
// The note checks again when Nexus becomes the active app. So the note disappears when the user
// comes back from System Settings.
struct NotificationsBlockedNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading) {
            if model.notificationsBlocked {
                HStack {
                    Text("macOS blocks the notifications of Nexus. Allow them in System Settings > Notifications > Nexus.")
                        .foregroundStyle(Color.orangeText)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    Button("Open Notifications") {
                        if let link = Notifier.settingsLink {
                            NSWorkspace.shared.open(link)
                        }
                    }
                }
            }
        }
        .task {
            await model.checkNotificationPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.checkNotificationPermission() }
        }
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

extension View {
    // A screen title in the toolbar with a second line under it, as in the design.
    func screenTitle(_ title: String, subtitle: String) -> some View {
        navigationTitle(title)
            .navigationSubtitle(subtitle)
    }
}
