import AppKit
import NexusCore
import NexusIPC
import SwiftUI

// The first run shows at each launch until the user clicks "Done". A Mac that is set up already
// skips it. The launch argument --first-run shows it again. It removes nothing. An installed
// package stays. Each setting starts at its current value.
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
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var model
    @Environment(BackgroundServices.self) private var background
    @State private var step = Step.packages
    // Nil until the user changes the preselection. Until then the preselection follows the list
    // of packages.
    @State private var picked: Set<String>?
    @State private var started: [String] = []
    @State private var resolverOwner = ResolverFileOwner.missing
    @State private var startAtLogin = true

    // The rows need the manifest and the installed packages. Without the installed packages, an
    // installed version shows as a download.
    private var packagesLoaded: Bool {
        !model.isLive || model.installedLoaded && !model.manifestPackages.isEmpty && !model.packages.isEmpty
    }

    private var domainsReady: Bool {
        model.rootCertificate?.trusted == true && helperReady
    }

    private var helperReady: Bool {
        guard model.isLive else {
            return true
        }

        return background.helper.isEnabled && resolverOwner == .nexus
    }

    // The step waits for the helper, or for an action of the user.
    private var domainsHint: (text: String, waits: Bool)? {
        if !helperReady {
            return background.helper.isEnabled && resolverOwner == .otherApp
                ? ("Choose another domain, or remove the file of the other app.", false)
                : ("Waiting for the helper…", true)
        }

        return model.rootCertificate?.trusted == true ? nil : ("Trust the certificate to continue.", false)
    }

    var body: some View {
        let choice = FirstRunPackages(packages: model.packages)
        let pickedPackages = picked ?? choice.preselection

        HStack(spacing: 0) {
            StepList(step: step)
                .frame(width: 200)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                switch step {
                case .packages:
                    PackagesStep(choice: choice, picked: Binding(get: { pickedPackages }, set: { picked = $0 }), loaded: packagesLoaded)
                case .domains:
                    DomainsStep(resolverOwner: $resolverOwner, helperReady: helperReady)
                case .settings:
                    SettingsStep(startAtLogin: $startAtLogin, started: started)
                }

                Spacer(minLength: 16)

                footer(choice: choice, picked: pickedPackages)
            }
            .padding(32)
        }
        .frame(width: 940, height: 640)
        .onAppear {
            model.firstRunIsOpen = true
            background.refresh()

            if AppPreference.isOn(AppPreference.firstRunDone) {
                startAtLogin = background.login.isOn
            }
        }
        .onDisappear {
            model.firstRunIsOpen = false
        }
        .alert(firstRunFailure?.title ?? "", isPresented: showsFailure, presenting: firstRunFailure) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.message)
        }
    }

    private var firstRunFailure: ActionFailure? {
        model.failure.flatMap { $0.place == .firstRun ? $0 : nil }
    }

    private var showsFailure: Binding<Bool> {
        Binding(
            get: { firstRunFailure != nil },
            set: { shown in
                if !shown {
                    model.failure = nil
                }
            }
        )
    }

    private func footer(choice: FirstRunPackages, picked: Set<String>) -> some View {
        HStack {
            if step != .packages {
                Button("Back") {
                    step = Step(rawValue: step.rawValue - 1) ?? .packages
                }
            }

            if step == .packages, packagesLoaded {
                Text(downloadSummary(of: choice.downloads(picked: picked)))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if step == .domains, let hint = domainsHint {
                if hint.waits {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(hint.text)
                    .foregroundStyle(.secondary)
            }

            Button(step == .settings ? "Done" : "Continue") {
                next(choice: choice, picked: picked)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue(choice: choice, picked: picked))
        }
    }

    private func downloadSummary(of downloads: [PackageItem]) -> String {
        guard !downloads.isEmpty else {
            return "Nothing to download"
        }

        let sizes = downloads.compactMap(\.downloadSize)

        guard !sizes.isEmpty else {
            return "Download: size unknown"
        }

        let total = Int64(sizes.reduce(0, +)).formatted(.byteCount(style: .file))

        return sizes.count == downloads.count ? "Download: \(total)" : "Download: more than \(total)"
    }

    private func canContinue(choice: FirstRunPackages, picked: Set<String>) -> Bool {
        switch step {
        case .packages: packagesLoaded && choice.hasRequired(picked: picked)
        case .domains: domainsReady
        case .settings: true
        }
    }

    private func next(choice: FirstRunPackages, picked pickedPackages: Set<String>) {
        switch step {
        case .packages:
            let downloads = choice.downloads(picked: pickedPackages)
            picked = pickedPackages
            downloads.forEach { model.install($0, from: .firstRun) }
            started += downloads.map(\.id).filter { !started.contains($0) }
            step = .domains
        case .domains:
            step = .settings
        case .settings:
            finish()
        }
    }

    // "Start Nexus at login" is on by default (D5). A login item that macOS refuses keeps the
    // window open. So the user sees why.
    private func finish() {
        if startAtLogin != background.login.isOn {
            background.login.setOn(startAtLogin)

            guard background.login.lastError == nil else {
                return
            }
        }

        UserDefaults.standard.set(true, forKey: AppPreference.firstRunDone)
        openWindow(id: MainWindow.id)
        dismissWindow(id: Self.id)
    }
}

// The rules of the Packages step (D56). Every site needs nginx and PHP. Workspaces need
// Composer. An installed package stays picked, because the first run removes nothing.
struct FirstRunPackages {
    static let required = ["nginx", "php", "composer"]
    static let columns = [["nginx", "php", "composer", "httpd"], ["mysql", "mariadb", "node"], ["postgresql", "redis"]]

    let packages: [PackageItem]
    private let rowsByName: [String: [PackageItem]]

    // The newest version first. Redis 8 is newer than Redis 8.2. So the order uses the version
    // and not the version line.
    init(packages: [PackageItem]) {
        self.packages = packages
        rowsByName = Dictionary(grouping: packages, by: \.package).mapValues { rows in
            rows.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        }
    }

    func rows(of name: String) -> [PackageItem] {
        rowsByName[name] ?? []
    }

    // nginx, the newest PHP and Composer, when no version of it is installed (D56).
    var preselection: Set<String> {
        Set(Self.required.compactMap { name in
            let rows = rows(of: name)
            return rows.contains(where: isKept) ? nil : rows.first?.id
        })
    }

    func isKept(_ package: PackageItem) -> Bool {
        package.isInstalled || package.isDownloading
    }

    func isPicked(_ package: PackageItem, in picked: Set<String>) -> Bool {
        isKept(package) || picked.contains(package.id)
    }

    // A required package can only go when another version of it stays.
    func isLocked(_ package: PackageItem, in picked: Set<String>) -> Bool {
        if isKept(package) {
            return true
        }

        guard Self.required.contains(package.package), isPicked(package, in: picked) else {
            return false
        }

        return rows(of: package.package).filter { isPicked($0, in: picked) }.count == 1
    }

    func hasRequired(picked: Set<String>) -> Bool {
        Self.required.allSatisfy { name in
            rows(of: name).contains { isPicked($0, in: picked) }
        }
    }

    func downloads(picked: Set<String>) -> [PackageItem] {
        packages.filter { picked.contains($0.id) && $0.state == .available }
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
    let choice: FirstRunPackages
    @Binding var picked: Set<String>
    let loaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What to install?")
                .font(.largeTitle.weight(.semibold))
            Text("Pick the versions you need. You can add or remove versions later in Packages.")
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            if loaded {
                ScrollView {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(FirstRunPackages.columns, id: \.self) { column in
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(column, id: \.self) { name in
                                    PackageChoiceGroup(name: name, choice: choice, picked: $picked)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            } else if let problem {
                InfoBanner(text: problem) {
                    Button("Try again") {
                        Task { await model.checkPackages() }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Nexus loads the list of packages…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            if !loaded {
                await model.checkPackages()
            }
        }
    }

    private var problem: String? {
        switch model.nexusdProblem {
        case .unreachable(let reason):
            return "The background service of Nexus does not answer. \(reason)"
        case .otherVersion(let reason):
            return "The background service of Nexus has another version. \(reason)"
        case nil:
            break
        }

        if let reason = model.packagesProblem {
            return "Nexus cannot load the list of packages. \(reason)"
        }

        return model.installedProblemText
    }
}

private struct PackageChoiceGroup: View {
    let name: String
    let choice: FirstRunPackages
    @Binding var picked: Set<String>

    private var requirement: String? {
        switch name {
        case "nginx", "composer": "Required"
        case "php": "At least one"
        default: nil
        }
    }

    var body: some View {
        let rows = choice.rows(of: name)

        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(AppModel.packageTitle(name))
                        .fontWeight(.semibold)
                    Spacer()
                    if let requirement {
                        Text(requirement)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                RowGroup {
                    ForEach(rows) { package in
                        HStack(spacing: 6) {
                            Toggle(isOn: binding(for: package)) {
                                Text(verbatim: "\(AppModel.packageTitle(package.package)) \(package.version)")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.9)
                            }
                            .disabled(choice.isLocked(package, in: picked))
                            .layoutPriority(1)

                            Spacer(minLength: 0)

                            badge(for: package)
                        }
                    }
                }
            }
        }
    }

    private func binding(for package: PackageItem) -> Binding<Bool> {
        Binding(
            get: { choice.isPicked(package, in: picked) },
            set: { isOn in
                if isOn {
                    picked.insert(package.id)
                } else {
                    picked.remove(package.id)
                }
            }
        )
    }

    @ViewBuilder
    private func badge(for package: PackageItem) -> some View {
        if package.isInstalled {
            Text("Installed")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if package.isDownloading {
            Text("Downloading")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if package.securityEnded {
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
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(background, in: .rect(cornerRadius: 4))
            .fixedSize()
    }
}

// The helper writes /etc/resolver/<tld> and needs the approval of the user. nexusd asks the
// helper again every few seconds until it answers. So the step checks the state every second
// until the file is there.
private struct DomainsStep: View {
    @Environment(AppModel.self) private var model
    @Environment(BackgroundServices.self) private var background
    @Binding var resolverOwner: ResolverFileOwner
    let helperReady: Bool
    @State private var trusting = false
    @State private var newTLD: String?

    private var tld: String {
        model.settings.tld
    }

    private var dns: ServiceVersion? {
        model.versions(of: .dns).first
    }

    private var certificateFile: String? {
        model.rootCertificate.flatMap { info in
            FileManager.default.fileExists(atPath: (info.file as NSString).expandingTildeInPath) ? info.file : nil
        }
    }

    // The helper writes the resolver file of the new domain. So the picker waits only for the
    // helper. A user whose domain belongs to another app can then choose another one.
    private var canChangeTLD: Bool {
        guard model.changingTLD == nil else {
            return false
        }

        return !model.isLive || background.helper.isEnabled
    }

    // A change renames the sites. So it needs a confirmation only when there are sites.
    private var tldSelection: Binding<String> {
        Binding(
            get: { model.changingTLD ?? tld },
            set: { value in
                guard value != tld else {
                    return
                }

                if model.allSites.isEmpty {
                    model.changeTLD(to: value, from: .firstRun)
                } else {
                    newTLD = value
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set up domains")
                .font(.largeTitle.weight(.semibold))
            Text("Each site gets its own .\(tld) domain with a trusted certificate. macOS asks you to approve two steps.")
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            RowGroup {
                HStack {
                    StepIcon(systemImage: "checkmark.shield")
                    Text("Trust the Nexus certificate")
                    Spacer()
                    certificateState
                }
                .frame(minHeight: 44)

                HStack {
                    StepIcon(systemImage: "network")
                    Text("Allow the Nexus helper")
                    Spacer()
                    helperState
                }
                .frame(minHeight: 44)

                HStack {
                    StepIcon(systemImage: "globe")
                    Text("Domain for your sites")
                    Spacer()
                    Picker("Domain", selection: tldSelection) {
                        ForEach(AppSettings.devDomains, id: \.self) { Text(verbatim: ".\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!canChangeTLD)
                }
                .frame(minHeight: 44)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Certificate: macOS asks for your password one time. Safari and Chrome then trust every Nexus site.")
                Text("Helper: it writes /etc/resolver/\(tld). So every .\(tld) name goes to Nexus. Turn on Nexus in Login Items.")
                Text("Domain: .test, .internal or .localhost. Other endings can send real traffic of this Mac to Nexus.")

                if resolverOwner == .otherApp {
                    Text("/etc/resolver/\(tld) belongs to another app. So Nexus does not change it. Remove that file, or choose another domain.")
                        .foregroundStyle(Color.orangeText)
                }

                if let error = background.helper.lastError, !background.helper.isOn {
                    Text(error)
                        .foregroundStyle(Color.orangeText)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)

            InfoBanner(text: "Firefox uses its own certificate list. In Firefox, open Settings > Privacy & Security > View Certificates > Authorities > Import.") {
                Button("Show certificate") {
                    if let certificateFile {
                        model.showInFinder(certificateFile)
                    }
                }
                .disabled(certificateFile == nil)
            }
        }
        .task {
            await model.loadRootCertificate()
        }
        .task(id: tld) {
            while model.isLive, !Task.isCancelled {
                background.helper.refresh()

                let owner = ResolverFile.owner(of: ResolverFile.folder.appending(path: tld, directoryHint: .notDirectory))

                if owner != resolverOwner {
                    resolverOwner = owner
                }

                if background.helper.isEnabled, resolverOwner == .nexus {
                    return
                }

                try? await Task.sleep(for: .seconds(1))
            }
        }
        .alert("Change the domain to .\(newTLD ?? "")?", isPresented: Binding(get: { newTLD != nil }, set: { if !$0 { newTLD = nil } }), presenting: newTLD) { tld in
            Button("Change") {
                model.changeTLD(to: tld, from: .firstRun)
            }
            Button("Cancel", role: .cancel) {}
        } message: { tld in
            Text(model.tldChangeMessage(to: tld))
        }
    }

    @ViewBuilder
    private var certificateState: some View {
        if model.rootCertificate?.trusted == true {
            Label("Trusted", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else if trusting {
            ProgressView()
                .controlSize(.small)
        } else {
            Button("Trust…") {
                trusting = true

                Task {
                    await model.trustRootCertificate(from: .firstRun)
                    trusting = false
                }
            }
        }
    }

    // The resolver file names the port of the DNS server. So nexusd writes it only while the
    // DNS server runs.
    @ViewBuilder
    private var helperState: some View {
        if helperReady {
            Label("Allowed", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else if background.helper.isEnabled, resolverOwner == .otherApp {
            Text("Another app has .\(tld)")
                .foregroundStyle(Color.orangeText)
        } else if background.helper.isEnabled, let dns, !dns.isActive {
            Button("Start DNS") {
                model.setRunning(true, service: dns, from: .firstRun)
            }
        } else if background.helper.isEnabled {
            ProgressView()
                .controlSize(.small)
        } else if background.helper.needsApproval {
            Button("Open Login Items") {
                background.helper.openLoginItemsSettings()
            }
        } else {
            Button("Try again") {
                background.helper.registerIfNeeded()
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

// Both notification settings are on by default. So macOS asks for the permission while the user
// looks at them. Otherwise macOS asks at the first notification. The user can miss that question.
private struct SettingsStep: View {
    @Environment(AppModel.self) private var model
    @Environment(BackgroundServices.self) private var background
    @AppStorage(AppPreference.notifyServiceStops) private var notifyServiceStops = true
    @AppStorage(AppPreference.notifyImportDone) private var notifyImportDone = true
    @Binding var startAtLogin: Bool
    let started: [String]

    private var notifies: Bool {
        notifyServiceStops || notifyImportDone
    }

    private var downloads: [PackageItem] {
        started.compactMap { id in model.packages.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings")
                .font(.largeTitle.weight(.semibold))
            Text("You can change these later in the Nexus settings.")
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            RowGroup {
                Toggle("Start Nexus at login", isOn: $startAtLogin)
                    .toggleStyle(SwitchAtTrailingStyle())
            }

            if let error = background.login.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Color.orangeText)
            }

            Text("Notifications")
                .fontWeight(.semibold)
                .padding(.top, 16)

            RowGroup {
                Toggle("When a service stops or fails", isOn: $notifyServiceStops)
                    .toggleStyle(SwitchAtTrailingStyle())
                Toggle("When an import is done", isOn: $notifyImportDone)
                    .toggleStyle(SwitchAtTrailingStyle())
            }

            NotificationsBlockedNote()
                .font(.callout)

            if !downloads.isEmpty {
                Text("Downloads")
                    .fontWeight(.semibold)
                    .padding(.top, 16)

                RowGroup {
                    ForEach(downloads) { package in
                        HStack {
                            Text(package.name)
                            Spacer()
                            downloadState(of: package)
                        }
                    }
                }
            }
        }
        .task {
            if notifies {
                await model.requestNotificationPermission()
            }
        }
        .onChange(of: notifies) {
            if notifies {
                Task { await model.requestNotificationPermission() }
            }
        }
    }

    // A download that failed shows its alert. Its row offers a new try.
    @ViewBuilder
    private func downloadState(of package: PackageItem) -> some View {
        switch package.state {
        case .downloading(let fraction):
            ProgressView(value: fraction)
                .frame(width: 160)
            Text(verbatim: "\(Int(fraction * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        case .installed, .update:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(Color.statusGreen)
        case .available:
            Text("Not installed")
                .font(.caption)
                .foregroundStyle(Color.orangeText)
            Button("Try again") {
                model.install(package, from: .firstRun)
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
