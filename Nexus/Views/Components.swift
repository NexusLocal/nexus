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

struct PortRow: View {
    let title: String
    @Binding var port: Int

    var body: some View {
        LabeledContent(title) {
            HStack {
                PortField(port: $port)
                Button("Change") {}
            }
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
    @Binding var toggle: ToggleItem

    var body: some View {
        HStack(spacing: 6) {
            HelpName(name: toggle.name, help: toggle.help)
            Spacer()
            Toggle(toggle.name, isOn: $toggle.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(toggle.required)
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

// Extensions and modules in two columns. Two columns keep a long list short.
struct ToggleGrid: View {
    @Binding var toggles: [ToggleItem]

    var body: some View {
        ForEach(Array(stride(from: 0, to: toggles.count, by: 2)), id: \.self) { index in
            HStack(spacing: 24) {
                ToggleCell(toggle: $toggles[index])

                if index + 1 < toggles.count {
                    ToggleCell(toggle: $toggles[index + 1])
                } else {
                    Spacer()
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct LogSection: View {
    let lines: [String]

    var body: some View {
        Section {
            ScrollView {
                Text(lines.isEmpty ? "No log lines yet." : lines.suffix(100).joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(lines.isEmpty ? .tertiary : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 96)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
        } header: {
            HStack {
                Text("Log")
                Spacer()
                Button("Open log file") {}
            }
        } footer: {
            Text("The newest 100 lines. \"Open log file\" shows the full log.")
        }
    }
}

struct OpenDatabaseButton: View {
    @Environment(AppModel.self) private var model
    let kind: ServiceKind
    let url: String

    private var defaultApp: String {
        kind == .postgresql ? model.settings.postgresqlApp : model.settings.mysqlApp
    }

    private var apps: [AppChoice] {
        model.settings.databaseApps.filter { $0.canOpen(kind) }
    }

    var body: some View {
        Menu("Open") {
            Section("Open with") {
                ForEach(apps) { app in
                    Button(app.name == defaultApp ? "\(app.name) (default)" : app.name, systemImage: "cylinder.split.1x2") {}
                }
            }

            Divider()

            Button("Copy URL", systemImage: "link") {
                copyToPasteboard(url)
            }

            Text(url)
        } primaryAction: {}
        .fixedSize()
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
