import NexusCore
import NexusIPC
import SwiftUI
import UniformTypeIdentifiers

struct SettingsWindow: View {
    static let tabKey = "settingsTab"

    @Environment(AppModel.self) private var model
    @AppStorage(tabKey) private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") {
                GeneralSettings()
            }

            Tab("Sites", systemImage: "globe", value: "sites") {
                SitesSettings()
            }

            Tab("Databases", systemImage: "cylinder.split.1x2", value: "databases") {
                DatabasesSettings()
            }

            Tab("Network", systemImage: "network", value: "network") {
                NetworkSettings()
            }

            Tab("Certificates", systemImage: "checkmark.shield", value: "certificates") {
                CertificatesSettings()
            }

            Tab("Updates", systemImage: "arrow.triangle.2.circlepath", value: "updates") {
                UpdatesSettings()
            }

            Tab("Advanced", systemImage: "wrench.and.screwdriver", value: "advanced") {
                AdvancedSettings()
            }
        }
        .frame(width: 640)
        .alert(settingsFailure?.title ?? "", isPresented: showsFailure, presenting: settingsFailure) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.message)
        }
    }

    private var settingsFailure: ActionFailure? {
        model.failure.flatMap { $0.place == .settings ? $0 : nil }
    }

    private var showsFailure: Binding<Bool> {
        Binding(
            get: { settingsFailure != nil },
            set: { shown in
                if !shown {
                    model.failure = nil
                }
            }
        )
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(BackgroundServices.self) private var background
    @AppStorage(AppPreference.showInMenuBar) private var showInMenuBar = true
    @AppStorage(AppPreference.showInDock) private var showInDock = true
    @AppStorage(AppPreference.notifyServiceStops) private var notifyServiceStops = true
    @AppStorage(AppPreference.notifyImportDone) private var notifyImportDone = true

    var body: some View {
        Form {
            Section {
                Toggle("Start Nexus at login", isOn: Binding(get: { background.login.isOn }, set: { background.login.setOn($0) }))
                Toggle("Show Nexus in the menu bar", isOn: $showInMenuBar)
                    .disabled(!showInDock)
                Toggle("Show Nexus in the Dock", isOn: $showInDock)
                    .disabled(!showInMenuBar)
            } header: {
                Text("Start")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("One of the two always stays on. Without the Dock icon, open Nexus from the menu bar.")

                    if background.login.needsApproval {
                        Text("Turn on Nexus in System Settings > General > Login Items & Extensions. Then Nexus starts at login.")
                            .foregroundStyle(Color.orangeText)
                    }

                    if let error = background.login.lastError {
                        Text(error)
                            .foregroundStyle(Color.orangeText)
                    }
                }
            }

            Section {
                AppPicker(title: "Terminal", systemImage: "apple.terminal", apps: model.settings.terminals, selection: model.settings.terminal) {
                    model.chooseTerminal($0)
                } add: {
                    model.addApp($0, as: .terminal)
                }

                AppPicker(title: "Code editor", systemImage: "chevron.left.forwardslash.chevron.right", apps: model.settings.editors, selection: model.settings.editor) {
                    model.chooseEditor($0)
                } add: {
                    model.addApp($0, as: .editor)
                }
            } header: {
                Text("Apps")
            } footer: {
                Text("Nexus finds the terminal apps and code editors on this Mac. \"Choose another app\" adds an app that Nexus did not find.")
            }

            Section {
                Toggle("Add Nexus to PATH", isOn: Binding(get: { model.pathSetting != .off }, set: { model.setAddToPath($0) }))
            } header: {
                Text("Shell")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nexus adds one line at the end of ~/.zshrc. php, composer, node and npm in your terminal then use the versions of the site in the current folder. Turn it off to remove the line.")

                    if model.pathSetting == .notLast {
                        Text("Another line comes after the line of Nexus in ~/.zshrc. That line can put another PHP first on the PATH. Turn the setting off and on to move the line of Nexus to the end.")
                            .foregroundStyle(Color.orangeText)
                    }

                    if let problem = model.pathSettingProblem {
                        Text(problem)
                            .foregroundStyle(Color.orangeText)
                    }
                }
            }

            Section {
                Toggle("When a service stops or fails", isOn: $notifyServiceStops)
                Toggle("When an import is done", isOn: $notifyImportDone)
            } header: {
                Text("Notifications")
            } footer: {
                NotificationsBlockedNote()
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: notifyServiceStops || notifyImportDone) {
            if notifyServiceStops || notifyImportDone {
                Task { await model.requestNotificationPermission() }
            }
        }
        .onAppear {
            background.refresh()
            model.readPathSetting()

            if model.isLive {
                model.findApps()
            }
        }
    }
}

// "Choose another app…" opens a file dialog. The chosen app joins the list and becomes the
// selected app.
private struct AppPicker: View {
    let title: String
    let systemImage: String
    let apps: [AppChoice]
    let selection: String
    let choose: (String) -> Void
    let add: (URL) -> Void
    @State private var choosesApp = false

    // Its own tag, so it also opens the file dialog when no app is selected.
    private static let chooseAnotherTag = "\u{1}choose"

    private var chosenApp: Binding<String> {
        Binding(
            get: { selection },
            set: { name in
                if name == Self.chooseAnotherTag {
                    choosesApp = true
                } else if !name.isEmpty {
                    choose(name)
                }
            }
        )
    }

    var body: some View {
        Picker(title, selection: chosenApp) {
            if selection.isEmpty {
                Text("None")
                    .tag("")
            }

            ForEach(apps) { app in
                Label(app.name, systemImage: systemImage)
                    .tag(app.name)
            }

            Divider()

            Text("Choose another app…")
                .tag(Self.chooseAnotherTag)
        }
        .appChooser(isPresented: $choosesApp, add: add)
    }
}

private extension View {
    func appChooser(isPresented: Binding<Bool>, add: @escaping (URL) -> Void) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: [.applicationBundle]) { result in
            if case .success(let app) = result {
                add(app)
            }
        }
        .fileDialogDefaultDirectory(URL(filePath: "/Applications", directoryHint: .isDirectory))
    }
}

private struct SitesSettings: View {
    @Environment(AppModel.self) private var model

    // nexusd keeps the defaults (D59). "newest" stands for a PHP version of nil. A default that
    // is not installed anymore gives the newest version, in nexusd too.
    private var server: Binding<String> {
        Binding(
            get: { model.siteDefaults.server.rawValue },
            set: { value in
                var defaults = model.siteDefaults
                defaults.server = WebServer(rawValue: value) ?? .nginx
                model.setSiteDefaults(defaults)
            }
        )
    }

    private var php: Binding<String> {
        Binding(
            get: { model.siteDefaults.php.flatMap { model.installedPHPVersions.contains($0) ? $0 : nil } ?? "newest" },
            set: { value in
                var defaults = model.siteDefaults
                defaults.php = value == "newest" ? nil : value
                model.setSiteDefaults(defaults)
            }
        )
    }

    // A Node line of nil comes from the files of each project (D21).
    private var node: Binding<String> {
        Binding(
            get: { model.siteDefaults.node.flatMap { model.installedNodeVersions.contains($0) ? $0 : nil } ?? NodeLines.fromProject },
            set: { value in
                var defaults = model.siteDefaults
                defaults.node = value == NodeLines.fromProject ? nil : value
                model.setSiteDefaults(defaults)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Webserver", selection: server) {
                    Text("nginx").tag(WebServer.nginx.rawValue)
                    Text("Apache").tag(WebServer.apache.rawValue)
                }

                Picker("PHP", selection: php) {
                    Text("Newest installed").tag("newest")
                    ForEach(model.installedPHPVersions, id: \.self) { Text("PHP \($0)").tag($0) }
                }

                Picker("Node", selection: node) {
                    Text("From the project").tag(NodeLines.fromProject)
                    ForEach(model.installedNodeVersions, id: \.self) { Text("Node \($0)").tag($0) }
                }
            } header: {
                Text("Defaults for new sites")
            } footer: {
                Text("A new site starts with these values. A change here does not change the sites that you already have.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DatabasesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editedUser: String?
    @State private var editedPassword: String?
    @State private var selectedApp: String?
    @State private var addsApp = false

    private var account: DatabaseAccount {
        model.settings.newInstanceAccount
    }

    private var isChanged: Bool {
        (editedUser ?? account.user) != account.user || (editedPassword ?? account.password) != account.password
    }

    private var removableApp: AppChoice? {
        model.settings.databaseApps.first { $0.name == selectedApp && $0.added }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("User") {
                    TextField("User", text: Binding(get: { editedUser ?? account.user }, set: { editedUser = $0 }))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 180)
                }

                LabeledContent("Password") {
                    HStack {
                        SecureField("Password", text: Binding(get: { editedPassword ?? account.password }, set: { editedPassword = $0 }), prompt: Text("No password"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .frame(width: 180)
                        Button("Change") {
                            model.setNewInstanceAccount(DatabaseAccount(user: editedUser ?? account.user, password: editedPassword ?? account.password))
                        }
                        .disabled(!isChanged)
                    }
                }
            } header: {
                Text("New instances")
            } footer: {
                Text("A new MySQL, MariaDB or PostgreSQL instance gets this account. Change the account of an instance on its own screen.")
            }

            Section {
                ForEach(model.settings.databaseApps) { app in
                    LabeledContent {
                        Text(app.opens)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(app.name, systemImage: "cylinder.split.1x2")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(selectedApp == app.name ? Color.accentSoft : .clear, in: .rect(cornerRadius: 6))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -4)
                    .contentShape(.rect)
                    .onTapGesture {
                        selectedApp = selectedApp == app.name ? nil : app.name
                    }
                }

                ListButtons(canRemove: removableApp != nil) {
                    addsApp = true
                } remove: {
                    if let removableApp {
                        model.removeDatabaseApp(removableApp)
                        selectedApp = nil
                    }
                }
                .appChooser(isPresented: $addsApp) {
                    model.addApp($0, as: .database)
                }
            } header: {
                Text("Database apps")
            } footer: {
                Text("Nexus finds the database apps on this Mac. Click + to add an app that Nexus did not find. Select an app that you added to remove it with −.")
            }

            Section {
                Picker("MySQL and MariaDB", selection: Binding(get: { model.settings.mysqlApp }, set: { model.chooseDatabaseApp($0, for: .mysql) })) {
                    ForEach(model.databaseApps(for: .mysql)) { Text($0.name).tag($0.name) }
                }

                Picker("PostgreSQL", selection: Binding(get: { model.settings.postgresqlApp }, set: { model.chooseDatabaseApp($0, for: .postgresql) })) {
                    ForEach(model.databaseApps(for: .postgresql)) { Text($0.name).tag($0.name) }
                }
            } header: {
                Text("Open with")
            } footer: {
                Text("\"Open\" uses this app. The arrow next to \"Open\" shows the other apps.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        // The fields keep a refused account, so the user can correct it.
        .onChange(of: account) {
            editedUser = nil
            editedPassword = nil
        }
        .onAppear {
            if model.isLive {
                model.findApps()
            }
        }
    }
}

// The + and − of a list sit at the bottom right (owner).
struct ListButtons: View {
    var canRemove = true
    let add: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            Button(action: add) {
                Image(systemName: "plus")
            }
            .help("Add")
            Button(action: remove) {
                Image(systemName: "minus")
            }
            .help("Remove")
            .disabled(!canRemove)
        }
        .buttonStyle(.borderless)
    }
}

// One row of the port list. The names of the ports repeat, for example "Port" of each database.
// So the id names the service too. With the name alone, every database row showed the first
// database.
private struct PortLine: Identifiable {
    let service: ServiceVersion
    let port: ServicePort

    var id: String {
        "\(service.id) \(port.name)"
    }
}

private struct NetworkSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newTLD: String?

    private var tld: Binding<String> {
        Binding(
            get: { model.changingTLD ?? model.settings.tld },
            set: { value in
                if value != model.settings.tld {
                    newTLD = value
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Domain for sites", selection: tld) {
                    ForEach(AppSettings.devDomains, id: \.self) { Text(".\($0)").tag($0) }
                }
                .disabled(model.changingTLD != nil)

                Toggle("Allow other devices on the network", isOn: Binding(get: { model.isLANAccessOn }, set: { model.setLANAccess($0) }))
                    .toggleStyle(.switch)
            } header: {
                Text("Domains")
            } footer: {
                Text("Only .test, .internal and .localhost are possible. Other endings can send real traffic of this Mac to Nexus.")
            }

            Section {
                ForEach(model.services.flatMap { service in service.ports.map { PortLine(service: service, port: $0) } }) { row in
                    PortRow(title: portTitle(service: row.service, port: row.port), port: row.port.number) {
                        model.changePort(row.port, of: row.service, to: $0, place: .settings)
                    }
                }
            } header: {
                Text("Ports")
            } footer: {
                Text("Every service has its own port. Apache gets the requests of its sites from nginx, so it needs no HTTPS port. When a port is in use, Nexus shows the program that uses it.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Change the domain to .\(newTLD ?? "")?", isPresented: Binding(get: { newTLD != nil }, set: { if !$0 { newTLD = nil } }), presenting: newTLD) { tld in
            Button("Change") {
                model.changeTLD(to: tld)
            }
            Button("Cancel", role: .cancel) {}
        } message: { tld in
            Text(model.tldChangeMessage(to: tld))
        }
    }

    private func portTitle(service: ServiceVersion, port: ServicePort) -> String {
        if service.internalPort {
            return "\(service.name) (internal)"
        }

        return service.ports.count > 1 ? "\(service.name.split(separator: " ").first ?? "") \(port.name)" : service.name
    }
}

private struct CertificatesSettings: View {
    @Environment(AppModel.self) private var model

    private var certificateFile: String? {
        model.rootCertificate.flatMap { info in
            FileManager.default.fileExists(atPath: (info.file as NSString).expandingTildeInPath) ? info.file : nil
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Nexus Root CA") {
                    if let info = model.rootCertificate, info.trusted {
                        Label("Trusted · valid until \(info.validUntil?.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()) ?? "")", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Trust…") {
                            Task { await model.trustRootCertificate() }
                        }
                    }
                }

                LabeledContent("Certificate file") {
                    Button("Show in Finder") {
                        if let certificateFile {
                            model.showInFinder(certificateFile)
                        }
                    }
                    .disabled(certificateFile == nil)
                }

                LabeledContent("Keychain") {
                    Button("Open Keychain Access") {
                        model.openKeychainAccess()
                    }
                }
            } header: {
                Text("Root certificate")
            } footer: {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Nexus signs a certificate for each site with this root certificate. Its private key stays in your login keychain. macOS asks for your password when you trust it.")
                    InfoBanner(text: "Firefox uses its own certificate list. In Firefox, open Settings > Privacy & Security > View Certificates > Authorities > Import, and choose the certificate file.")
                        .foregroundStyle(.primary)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await model.loadRootCertificate()
        }
    }
}

private struct UpdatesSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppPreference.checkPackageUpdates) private var checkPackageUpdates = true
    @AppStorage(AppPreference.installPackageUpdates) private var installPackageUpdates = false

    var body: some View {
        Form {
            Section {
                Toggle("Check for package updates automatically", isOn: $checkPackageUpdates)
                Toggle("Install package updates automatically", isOn: $installPackageUpdates)
            } header: {
                Text("Packages")
            } footer: {
                Text("Nexus checks at launch and once a day. An update of a package keeps its data. Nexus restarts the service after the update.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: checkPackageUpdates) {
            if checkPackageUpdates {
                Task { await model.checkPackages() }
            }
        }
        .onChange(of: installPackageUpdates) {
            if installPackageUpdates {
                model.installUpdates()
            }
        }
    }
}

private struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(BackgroundServices.self) private var background
    @State private var confirmsUninstall = false

    private let paths = NexusPaths.standard

    var body: some View {
        Form {
            Section("Folders") {
                folderRow("Data", folder: paths.root)
                folderRow("Logs", folder: paths.logs)
            }

            Section {
                LabeledContent("nexusd") {
                    RegistrationState(registration: background.daemon, enabled: "Running")
                }

                LabeledContent("Helper") {
                    HStack {
                        RegistrationState(registration: background.helper, enabled: "Allowed")
                        Button("Open Login Items") {
                            background.helper.openLoginItemsSettings()
                        }
                    }
                }
            } header: {
                Text("Background items")
            } footer: {
                Text("nexusd runs the services. The helper writes /etc/resolver/\(model.settings.tld) and the lines in /etc/hosts.")
            }

            Section {
                LabeledContent("Remove Nexus from this Mac") {
                    Button("Uninstall…") {
                        confirmsUninstall = true
                    }
                }
            } header: {
                Text("Uninstall")
            } footer: {
                Text("Stops all services and removes the helper, the resolver file, the lines in /etc/hosts and the root CA. Your sites, data folder and databases stay on disk.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            background.refresh()
        }
        .alert("Remove Nexus from this Mac?", isPresented: $confirmsUninstall) {
            Button("Uninstall", role: .destructive) {
                model.uninstall()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nexus stops all services. It removes the helper, the resolver file, the lines in /etc/hosts and the root CA. Your sites, the data folder and the databases stay on disk.")
        }
        .alert("Nexus is removed", isPresented: Binding(get: { model.uninstalled != nil }, set: { if !$0 { model.uninstalled = nil } }), presenting: model.uninstalled) { _ in
            Button("Quit Nexus") {
                NSApplication.shared.terminate(nil)
            }
        } message: { message in
            Text(message)
        }
    }

    private func folderRow(_ title: String, folder: URL) -> some View {
        let path = ((folder.path(percentEncoded: false) as NSString).standardizingPath as NSString).abbreviatingWithTildeInPath

        return LabeledContent(title) {
            HStack {
                PathText(path)
                Button("Show in Finder") {
                    model.showInFinder(path)
                }
            }
        }
    }
}

private struct RegistrationState: View {
    let registration: BackgroundServiceRegistration
    let enabled: String

    var body: some View {
        if registration.isEnabled {
            Label(enabled, systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else {
            Text(registration.summary)
                .foregroundStyle(Color.orangeText)
        }
    }
}
