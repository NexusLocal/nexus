import NexusCore
import SwiftUI

struct SettingsWindow: View {
    static let tabKey = "settingsTab"

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
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppPreference.showInMenuBar) private var showInMenuBar = true
    @AppStorage(AppPreference.showInDock) private var showInDock = true

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Toggle("Start Nexus at login", isOn: $model.settings.startAtLogin)
                Toggle("Show Nexus in the menu bar", isOn: $showInMenuBar)
                    .disabled(!showInDock)
                Toggle("Show Nexus in the Dock", isOn: $showInDock)
                    .disabled(!showInMenuBar)
            } header: {
                Text("Start")
            } footer: {
                Text("One of the two always stays on. Without the Dock icon, open Nexus from the menu bar.")
            }

            Section {
                AppPicker(title: "Terminal", systemImage: "apple.terminal", apps: model.settings.terminals, selection: $model.settings.terminal)
                AppPicker(title: "Code editor", systemImage: "chevron.left.forwardslash.chevron.right", apps: model.settings.editors, selection: $model.settings.editor)
            } header: {
                Text("Apps")
            } footer: {
                Text("Nexus finds the terminal apps and code editors on this Mac. \"Choose another app\" adds an app that Nexus did not find.")
            }

            Section("Notifications") {
                Toggle("When a service stops or fails", isOn: $model.settings.notifyServiceStops)
                Toggle("When an import is done", isOn: $model.settings.notifyImportDone)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AppPicker: View {
    let title: String
    let systemImage: String
    let apps: [AppChoice]
    @Binding var selection: String

    // "Choose another app…" adds an app that Nexus did not find. It never becomes the selected app.
    private var chosenApp: Binding<String> {
        Binding(
            get: { selection },
            set: { name in
                if !name.isEmpty {
                    selection = name
                }
            }
        )
    }

    var body: some View {
        Picker(title, selection: chosenApp) {
            ForEach(apps) { app in
                Label(app.name, systemImage: systemImage)
                    .tag(app.name)
            }

            Divider()

            Text("Choose another app…")
                .tag("")
        }
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

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                LabeledContent("User") {
                    TextField("User", text: $model.settings.newInstanceAccount.user)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 180)
                }

                LabeledContent("Password") {
                    SecureField("Password", text: $model.settings.newInstanceAccount.password, prompt: Text("No password"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 180)
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
                }

                ListButtons()
            } header: {
                Text("Database apps")
            } footer: {
                Text("Nexus finds the database apps on this Mac. Click + to add an app that Nexus did not find.")
            }

            Section {
                Picker("MySQL and MariaDB", selection: $model.settings.mysqlApp) {
                    ForEach(model.settings.databaseApps.filter { $0.canOpen(.mysql) }) { Text($0.name).tag($0.name) }
                }

                Picker("PostgreSQL", selection: $model.settings.postgresqlApp) {
                    ForEach(model.settings.databaseApps.filter { $0.canOpen(.postgresql) }) { Text($0.name).tag($0.name) }
                }
            } header: {
                Text("Open with")
            } footer: {
                Text("\"Open\" uses this app. The arrow next to \"Open\" shows the other apps.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// The + and − of a list sit at the bottom right (owner).
struct ListButtons: View {
    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            Button {
            } label: {
                Image(systemName: "plus")
            }
            Button {
            } label: {
                Image(systemName: "minus")
            }
        }
        .buttonStyle(.borderless)
    }
}

private struct NetworkSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Picker("Domain for sites", selection: $model.settings.tld) {
                    ForEach(AppSettings.devDomains, id: \.self) { Text(".\($0)").tag($0) }
                }

                Toggle("Allow other devices on the network", isOn: Binding(get: { model.isLANAccessOn }, set: { model.setLANAccess($0) }))
                    .toggleStyle(.switch)
            } header: {
                Text("Domains")
            } footer: {
                Text("Only .test, .internal and .localhost are possible. Other endings can send real traffic of this Mac to Nexus.")
            }

            Section {
                ForEach($model.services) { $service in
                    ForEach($service.ports) { $port in
                        LabeledContent(portTitle(service: service, port: port)) {
                            PortField(port: $port.number)
                        }
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

    var body: some View {
        Form {
            Section {
                LabeledContent("Nexus Root CA") {
                    if model.settings.caTrusted {
                        Label("Trusted · valid until \(model.settings.caValidUntil)", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Trust…") {}
                    }
                }

                LabeledContent("Certificate file") {
                    Button("Show in Finder") {}
                }

                LabeledContent("Keychain") {
                    Button("Open Keychain Access") {}
                }
            } header: {
                Text("Root certificate")
            } footer: {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Nexus signs a certificate for each site with this root certificate. Its private key stays in your login keychain.")
                    InfoBanner(text: "Firefox uses its own certificate list. In Firefox, open Settings > Privacy & Security > View Certificates > Authorities > Import, and choose the certificate file.")
                        .foregroundStyle(.primary)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct UpdatesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Toggle("Check for package updates automatically", isOn: $model.settings.checkPackageUpdates)
                Toggle("Install package updates automatically", isOn: $model.settings.installPackageUpdates)
            } header: {
                Text("Packages")
            } footer: {
                Text("An update of a package keeps its data. Nexus restarts the service after the update.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AdvancedSettings: View {
    @Environment(BackgroundServices.self) private var background

    var body: some View {
        Form {
            Section("Folders") {
                folderRow("Data", path: "~/Library/Application Support/Nexus")
                folderRow("Logs", path: "~/Library/Application Support/Nexus/logs")
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
                Text("nexusd runs the services. The helper writes /etc/resolver/test and the lines in /etc/hosts.")
            }

            Section {
                LabeledContent("Remove Nexus from this Mac") {
                    Button("Uninstall…") {}
                }
            } header: {
                Text("Uninstall")
            } footer: {
                Text("Stops all services and removes the helper, the resolver file and the lines in /etc/hosts. Your sites, data folder and databases stay on disk.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            background.refresh()
        }
    }

    private func folderRow(_ title: String, path: String) -> some View {
        LabeledContent(title) {
            HStack {
                PathText(path)
                Button("Show in Finder") {}
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
