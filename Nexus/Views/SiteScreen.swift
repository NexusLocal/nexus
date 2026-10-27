import SwiftUI

struct SiteScreen: View {
    @Environment(AppModel.self) private var model
    let site: SiteItem

    @State private var group: String
    @State private var server: String
    @State private var php: String

    init(site: SiteItem) {
        self.site = site
        _group = State(initialValue: site.group ?? "")
        _server = State(initialValue: site.server)
        _php = State(initialValue: site.php)
    }

    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Host") {
                    Text(site.host)
                }

                LabeledContent("Aliases") {
                    HStack {
                        Text(site.aliases.isEmpty ? "None" : site.aliases.joined(separator: ", "))
                            .foregroundStyle(site.aliases.isEmpty ? .tertiary : .secondary)
                            .lineLimit(1)
                        Button("Edit…") {}
                    }
                }

                Picker("Group", selection: $group) {
                    Text("None").tag("")
                    ForEach(model.groupNames, id: \.self) { Text($0).tag($0) }
                }

                LabeledContent("Folder") {
                    HStack {
                        PathText(site.folder)
                        Button("Show in Finder") {}
                    }
                }

                LabeledContent("Document root") {
                    PathText(site.documentRoot)
                }

                LabeledContent("URL") {
                    HStack {
                        if let url = URL(string: site.url) {
                            Link(site.url, destination: url)
                                .foregroundStyle(Color.accentText)
                        } else {
                            Text(site.url)
                        }

                        Button("Copy") {
                            copyToPasteboard(site.url)
                        }
                    }
                }
            }

            Section {
                Picker("Webserver", selection: $server) {
                    Text("nginx").tag("nginx")
                    Text("Apache").tag("apache")
                }

                Picker("PHP", selection: $php) {
                    ForEach(model.installedPHPVersions, id: \.self) { Text("PHP \($0)").tag($0) }
                }
            } header: {
                Text("Server")
            } footer: {
                Text("nginx handles HTTPS for every site. For an Apache site, nginx sends each request on to Apache.")
            }
        }
        .formStyle(.grouped)
        .screenTitle(site.host, subtitle: "\(server == "apache" ? "Apache" : "nginx") · PHP \(php)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                } label: {
                    Label("Open in browser", systemImage: "safari")
                }
                .labelStyle(.titleAndIcon)
            }

            ToolbarItem(placement: .primaryAction) {
                MoreMenu {
                    SiteActions(site: site, includeBrowser: false)
                }
            }
        }
        .onChange(of: site) {
            group = site.group ?? ""
            server = site.server
            php = site.php
        }
    }
}
