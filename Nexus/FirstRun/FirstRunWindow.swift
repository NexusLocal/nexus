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
        case permissions = 1
        case packages
        case settings

        var title: String {
            switch self {
            case .permissions: "Permissions"
            case .packages: "Packages"
            case .settings: "Settings"
            }
        }
    }

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var model
    @Environment(BackgroundServices.self) private var background
    @State private var step = Step.permissions
    // Nil until the user changes the preselection. Until then the preselection follows the list
    // of packages.
    @State private var picked: Set<String>?
    @State private var started: [String] = []
    @State private var resolverOwner = ResolverFileOwner.missing
    @State private var startAtLogin = true
    @State private var addToPath = false

    // The rows need the manifest and the installed packages. Without the installed packages, an
    // installed version shows as a download.
    private var packagesLoaded: Bool {
        !model.isLive || model.installedLoaded && !model.manifestPackages.isEmpty && !model.packages.isEmpty
    }

    private var backgroundAllowed: Bool {
        !model.isLive || background.isAllowed
    }

    // Notifications stay optional. Nexus works without them.
    private var permissionsReady: Bool {
        model.rootCertificate?.trusted == true && backgroundAllowed
    }

    private var helperReady: Bool {
        guard model.isLive else {
            return true
        }

        return background.helper.isEnabled && resolverOwner == .nexus
    }

    // The step waits for the helper, or for an action of the user.
    private var hint: (text: String, waits: Bool)? {
        switch step {
        case .permissions:
            if !backgroundAllowed {
                return ("Allow Nexus to run in the background to continue.", false)
            }

            return model.rootCertificate?.trusted == true ? nil : ("Trust the certificate to continue.", false)
        case .packages:
            return nil
        case .settings:
            if helperReady {
                return nil
            }

            if !background.helper.isEnabled {
                return ("Go back and allow Nexus to run in the background.", false)
            }

            if resolverOwner == .otherApp {
                return ("Choose another domain, or remove the file of the other app.", false)
            }

            return model.versions(of: .dns).first?.isActive == false
                ? ("Start DNS to continue.", false)
                : ("Waiting for the helper…", true)
        }
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
                case .permissions:
                    PermissionsStep()
                case .packages:
                    PackagesStep(choice: choice, picked: Binding(get: { pickedPackages }, set: { picked = $0 }), loaded: packagesLoaded)
                case .settings:
                    SettingsStep(startAtLogin: $startAtLogin, addToPath: $addToPath, resolverOwner: $resolverOwner, helperReady: helperReady, started: started)
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
            model.readPathSetting()
            addToPath = model.pathSetting != .off

            if AppPreference.isOn(AppPreference.firstRunDone) {
                startAtLogin = background.login.isOn
            }
        }
        .onDisappear {
            model.firstRunIsOpen = false

            // A user who closes the window early still gets the main window of a working Nexus.
            if !AppPreference.isOn(AppPreference.firstRunDone) {
                background.registerIfNeeded()
            }
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
            if step != .permissions {
                Button("Back") {
                    step = Step(rawValue: step.rawValue - 1) ?? .permissions
                }
            }

            if step == .packages, packagesLoaded {
                Text(downloadSummary(of: choice.downloads(picked: picked)))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let hint {
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
        case .permissions: permissionsReady
        case .packages: packagesLoaded && choice.hasRequired(picked: picked)
        case .settings: helperReady
        }
    }

    private func next(choice: FirstRunPackages, picked pickedPackages: Set<String>) {
        switch step {
        case .permissions:
            step = .packages
        case .packages:
            let downloads = choice.downloads(picked: pickedPackages)
            picked = pickedPackages
            downloads.forEach { model.install($0, from: .firstRun) }
            started += downloads.map(\.id).filter { !started.contains($0) }
            step = .settings
        case .settings:
            finish(services: choice.services(picked: pickedPackages))
        }
    }

    // "Start Nexus at login" is on by default (D5). "Add Nexus to PATH" is off by default (D39).
    // A login item that macOS refuses keeps the window open. A ~/.zshrc that Nexus cannot change
    // does the same. So the user sees why. The user picked the services to use them, so they
    // start now. A download that still runs starts its service when it ends.
    private func finish(services: Set<String>) {
        if startAtLogin != background.login.isOn {
            background.login.setOn(startAtLogin)

            guard background.login.lastError == nil else {
                return
            }
        }

        if addToPath != (model.pathSetting != .off) {
            guard model.setAddToPath(addToPath) else {
                return
            }
        }

        UserDefaults.standard.set(true, forKey: AppPreference.firstRunDone)
        model.startAfterFirstRun(services)
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

    // Only the new choices. A service that was installed before can be off on purpose, and a start
    // turns it on for each next start of nexusd.
    func services(picked: Set<String>) -> Set<String> {
        Set(packages.filter { picked.contains($0.id) }.compactMap(\.serviceID))
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

private extension NexusdProblem {
    var firstRunText: String {
        switch self {
        case .unreachable(let reason): "The background service of Nexus does not answer. \(reason)"
        case .otherVersion(let reason): "The background service of Nexus has another version. \(reason)"
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
        .task(id: model.nexusdProblem == nil) {
            if !loaded {
                await model.checkPackages()
            }
        }
    }

    private var problem: String? {
        if let problem = model.nexusdProblem {
            return problem.firstRunText
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

// All that macOS must allow comes first, because Nexus cannot work without it. Nexus registers its
// background services only after the click, so the question of macOS has a reason. The user
// answers in System Settings. So the step checks the state every second.
private struct PermissionsStep: View {
    @Environment(AppModel.self) private var model
    @Environment(BackgroundServices.self) private var background
    @State private var trusting = false

    private var certificateFile: String? {
        model.rootCertificate.flatMap { info in
            FileManager.default.fileExists(atPath: (info.file as NSString).expandingTildeInPath) ? info.file : nil
        }
    }

    // nexusd trusts the certificate.
    private var nexusdAnswers: Bool {
        !model.isLive || background.daemon.isEnabled && model.nexusdProblem == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Allow Nexus")
                    .font(.largeTitle.weight(.semibold))
                Text("macOS asks you to approve these. Nexus needs the first two to work.")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)

                RowGroup {
                    HStack {
                        StepIcon(systemImage: "gearshape.2")
                        Text("Run in the background")
                        Spacer()
                        backgroundState
                    }
                    .frame(minHeight: 44)

                    HStack {
                        StepIcon(systemImage: "checkmark.shield")
                        Text("Trust the Nexus certificate")
                        Spacer()
                        certificateState
                    }
                    .frame(minHeight: 44)

                    HStack {
                        StepIcon(systemImage: "bell")
                        Text("Show notifications")
                        Spacer()
                        notificationsState
                    }
                    .frame(minHeight: 44)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Background: Nexus runs your services and sends the names of your sites to them. macOS shows this in Login Items.")
                    Text("Certificate: macOS asks for your password one time. Safari and Chrome then trust every Nexus site, with each domain.")
                    Text("Notifications: Nexus tells you when a service stops or an import ends.")

                    if let error = background.registrationError, !background.isAllowed, !background.needsApproval {
                        Text(error)
                            .foregroundStyle(Color.orangeText)
                    }

                    if background.daemon.isEnabled, model.rootCertificate?.trusted != true, let problem = model.nexusdProblem {
                        Text(problem.firstRunText)
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task {
            await model.loadRootCertificate()

            while model.isLive, !Task.isCancelled {
                background.refresh()
                await model.checkNotificationPermission()

                if model.rootCertificate == nil, background.daemon.isEnabled {
                    await model.loadRootCertificate()
                }

                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private var backgroundState: some View {
        if !model.isLive || background.isAllowed {
            Label("Allowed", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else if background.needsApproval {
            Button("Open Login Items") {
                background.helper.openLoginItemsSettings()
            }
        } else {
            Button("Allow…") {
                background.registerIfNeeded()
            }
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
            .disabled(!nexusdAnswers)
        }
    }

    @ViewBuilder
    private var notificationsState: some View {
        if model.notificationsAllowed {
            Label("Allowed", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else if model.notificationsBlocked {
            Button("Open Notifications") {
                if let link = Notifier.settingsLink {
                    NSWorkspace.shared.open(link)
                }
            }
        } else {
            Button("Allow…") {
                Task { await model.requestNotificationPermission() }
            }
        }
    }
}

// The helper writes /etc/resolver/<tld>. nexusd asks the helper again every few seconds until it
// answers. So the row checks the state every second until the file is there.
private struct DomainRow: View {
    @Environment(AppModel.self) private var model
    @Environment(BackgroundServices.self) private var background
    @Binding var resolverOwner: ResolverFileOwner
    let helperReady: Bool
    @State private var newTLD: String?

    private var tld: String {
        model.settings.tld
    }

    private var dns: ServiceVersion? {
        model.versions(of: .dns).first
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
        HStack {
            Text("Domain for your sites")
            Spacer()

            // The resolver file names the port of the DNS server. So nexusd writes it only while
            // the DNS server runs.
            if !helperReady, resolverOwner != .otherApp, background.helper.isEnabled, let dns, !dns.isActive {
                Button("Start DNS") {
                    model.setRunning(true, service: dns, from: .firstRun)
                }
            }

            Picker("Domain", selection: tldSelection) {
                ForEach(AppSettings.devDomains, id: \.self) { Text(verbatim: ".\($0)").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!canChangeTLD)
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

// A user who skipped the notifications in the first step and turns on a setting here gets the
// question of macOS then. Otherwise macOS asks at the first notification. The user can miss that.
private struct SettingsStep: View {
    @Environment(AppModel.self) private var model
    @Environment(BackgroundServices.self) private var background
    @AppStorage(AppPreference.notifyServiceStops) private var notifyServiceStops = true
    @AppStorage(AppPreference.notifyImportDone) private var notifyImportDone = true
    @Binding var startAtLogin: Bool
    @Binding var addToPath: Bool
    @Binding var resolverOwner: ResolverFileOwner
    let helperReady: Bool
    let started: [String]

    private var notifies: Bool {
        notifyServiceStops || notifyImportDone
    }

    private var downloads: [PackageItem] {
        started.compactMap { id in model.packages.first { $0.id == id } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Settings")
                    .font(.largeTitle.weight(.semibold))
                Text("You can change these later in the Nexus settings.")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)

                RowGroup {
                    Toggle("Start Nexus at login", isOn: $startAtLogin)
                        .toggleStyle(SwitchAtTrailingStyle())
                    Toggle("Add Nexus to PATH", isOn: $addToPath)
                        .toggleStyle(SwitchAtTrailingStyle())
                    DomainRow(resolverOwner: $resolverOwner, helperReady: helperReady)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("\"Add Nexus to PATH\" adds one line to the end of ~/.zshrc. Then php, composer, node and npm in your terminal use the Nexus versions. Turn it off to remove the line.")
                    Text("Domain: .test, .internal or .localhost. Other endings can send real traffic of this Mac to Nexus.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                if resolverOwner == .otherApp {
                    Text("/etc/resolver/\(model.settings.tld) belongs to another app. So Nexus does not change it. Remove that file, or choose another domain.")
                        .font(.callout)
                        .foregroundStyle(Color.orangeText)
                }

                ForEach([background.login.lastError, model.pathSettingProblem].compactMap { $0 }, id: \.self) { error in
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
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
