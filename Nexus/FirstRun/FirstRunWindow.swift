import AppKit
import SwiftUI

struct FirstRunWindow: View {
    static let id = "first-run"

    enum Step: Int, CaseIterable {
        case packages = 1
        case domains
        case settings

        var title: String {
            switch self {
            case .packages: "Packages"
            case .domains: "Domains"
            case .settings: "Settings"
            }
        }
    }

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(AppModel.self) private var model
    @Environment(BackgroundServices.self) private var background
    @State private var step = Step.packages
    @State private var selected: Set<String> = ["nginx 1.30", "PHP 8.5", "Composer"]

    var body: some View {
        HStack(spacing: 0) {
            StepList(step: step)
                .frame(width: 200)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                switch step {
                case .packages:
                    PackagesStep(selected: $selected)
                case .domains:
                    DomainsStep()
                case .settings:
                    SettingsStep(selected: selected)
                }

                Spacer(minLength: 16)

                footer
            }
            .padding(32)
        }
        .frame(width: 940, height: 640)
    }

    // Every site needs PHP, so the first run needs at least one version (D56).
    private var hasPHP: Bool {
        selected.contains { $0.hasPrefix("PHP ") }
    }

    private var footer: some View {
        HStack {
            if step != .packages {
                Button("Back") {
                    step = Step(rawValue: step.rawValue - 1) ?? .packages
                }
            }

            if step == .packages {
                Text("Download: 38 MB")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if step == .domains {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for the helper…")
                    .foregroundStyle(.secondary)
            }

            if step == .packages && !hasPHP {
                Text("Pick at least one PHP version.")
                    .foregroundStyle(Color.orangeText)
            }

            // "Start Nexus at login" is on by default (D5). Settings > General changes it later.
            Button(step == .settings ? "Done" : "Continue") {
                if let next = Step(rawValue: step.rawValue + 1) {
                    step = next
                } else {
                    background.login.setOn(model.settings.startAtLogin)
                    dismissWindow(id: Self.id)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!hasPHP)
        }
    }
}

private struct StepList: View {
    let step: FirstRunWindow.Step

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 32, height: 32)
                Text("Nexus")
                    .font(.title3.weight(.semibold))
            }
            .padding(.bottom, 16)

            ForEach(FirstRunWindow.Step.allCases, id: \.self) { item in
                HStack(spacing: 8) {
                    marker(for: item)
                    Text(item.title)
                        .fontWeight(item == step ? .semibold : .regular)
                        .foregroundStyle(item.rawValue > step.rawValue ? .secondary : .primary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(item == step ? Color.accentSoft : .clear, in: .rect(cornerRadius: 8))
            }

            Spacer()
        }
        .padding(16)
        .padding(.top, 24)
        .frame(maxHeight: .infinity)
        .background(.background.secondary)
    }

    @ViewBuilder
    private func marker(for item: FirstRunWindow.Step) -> some View {
        if item.rawValue < step.rawValue {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.statusGreen)
        } else {
            Text("\(item.rawValue)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(item == step ? .white : .secondary)
                .frame(width: 18, height: 18)
                .background(item == step ? Color.accentColor : Color.secondary.opacity(0.2), in: .circle)
        }
    }
}

private struct PackagesStep: View {
    @Environment(AppModel.self) private var model
    @Binding var selected: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What to install?")
                .font(.largeTitle.weight(.semibold))
            Text("Pick the versions you need. You can add or remove versions later in Packages.")
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            HStack(alignment: .top, spacing: 16) {
                column(["nginx", "PHP", "Composer", "Apache"])
                column(["MySQL", "MariaDB", "Node"])
                column(["PostgreSQL", "Redis"])
            }
        }
    }

    private func column(_ titles: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(titles, id: \.self) { title in
                PackageChoiceGroup(title: title, packages: packages(for: title), selected: $selected)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func packages(for title: String) -> [PackageItem] {
        model.packages
            .filter { $0.name.hasPrefix(title) }
            .reversed()
    }
}

private struct PackageChoiceGroup: View {
    let title: String
    let packages: [PackageItem]
    @Binding var selected: Set<String>

    private var requirement: String? {
        switch title {
        case "nginx", "Composer": "Required"
        case "PHP": "At least one"
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .fontWeight(.semibold)
                Spacer()
                if let requirement {
                    Text(requirement)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            RowGroup {
                ForEach(packages) { package in
                    HStack {
                        Toggle(isOn: binding(for: package)) {
                            Text("\(package.name.split(separator: " ").first ?? "") \(package.version)")
                                .lineLimit(1)
                        }
                        .disabled(package.required)

                        Spacer()

                        badge(for: package)
                    }
                    .frame(minHeight: 30)
                }
            }
        }
    }

    private func binding(for package: PackageItem) -> Binding<Bool> {
        Binding(
            get: { selected.contains(package.name) },
            set: { isOn in
                if isOn {
                    selected.insert(package.name)
                } else {
                    selected.remove(package.name)
                }
            }
        )
    }

    @ViewBuilder
    private func badge(for package: PackageItem) -> some View {
        if package.securityEnded {
            Badge(text: "No fixes", color: .orangeText, background: .warningBackground)
        } else if let end = package.securityEnd {
            Badge(text: "Ends \(end.prefix(4))", color: .orangeText, background: .warningBackground)
        } else if package.lts {
            Badge(text: "LTS", color: .accentText, background: .accentSoft)
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: .rect(cornerRadius: 4))
    }
}

private struct DomainsStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 8) {
            Text("Set up domains")
                .font(.largeTitle.weight(.semibold))
            Text("Each site gets its own .\(model.settings.tld) domain with a trusted certificate. macOS asks you to approve two steps.")
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            RowGroup {
                HStack {
                    StepIcon(systemImage: "checkmark.shield")
                    Text("Trust the Nexus certificate")
                    Spacer()
                    Label("Trusted", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)

                HStack {
                    StepIcon(systemImage: "network")
                    Text("Allow the Nexus helper")
                    Spacer()
                    Button("Open Login Items") {}
                }
                .frame(minHeight: 44)

                HStack {
                    StepIcon(systemImage: "globe")
                    Text("Domain for your sites")
                    Spacer()
                    Picker("Domain", selection: $model.settings.tld) {
                        ForEach(AppSettings.devDomains, id: \.self) { Text(".\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .frame(minHeight: 44)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Certificate: macOS asks for your password one time. Safari and Chrome then trust every Nexus site.")
                Text("Helper: it writes /etc/resolver/\(model.settings.tld), so every .\(model.settings.tld) name goes to Nexus. Turn on Nexus in Login Items.")
                Text("Domain: .test, .internal or .localhost. Other endings can send real traffic of this Mac to Nexus.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)

            InfoBanner(text: "Firefox uses its own certificate list. In Firefox, open Settings > Privacy & Security > View Certificates > Authorities > Import.") {
                Button("Show certificate") {}
            }
        }
    }
}

private struct StepIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(Color.accentText)
            .frame(width: 26, height: 26)
            .background(Color.accentSoft, in: .rect(cornerRadius: 6))
    }
}

private struct SettingsStep: View {
    @Environment(AppModel.self) private var model
    let selected: Set<String>

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 8) {
            Text("Settings")
                .font(.largeTitle.weight(.semibold))
            Text("You can change these later in the Nexus settings.")
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            RowGroup {
                Toggle("Start Nexus at login", isOn: $model.settings.startAtLogin)
                    .toggleStyle(SwitchAtTrailingStyle())
            }

            Text("Downloads")
                .fontWeight(.semibold)
                .padding(.top, 16)

            RowGroup {
                ForEach(model.packages.filter { selected.contains($0.name) }) { package in
                    HStack {
                        Text(package.name)
                        Spacer()
                        if package.name == "PHP 8.5" {
                            ProgressView(value: 0.64)
                                .frame(width: 160)
                            Text("64%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(Color.statusGreen)
                        }
                    }
                }
            }
        }
    }
}

private struct SwitchAtTrailingStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}
