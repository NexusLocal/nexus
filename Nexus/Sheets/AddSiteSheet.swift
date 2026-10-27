import SwiftUI

struct AddSiteSheet: View {
    enum FolderType {
        case oneProject
        case manyProjects
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var folderType = FolderType.oneProject
    @State private var folder = "~/Documents/clients/acme"
    @State private var host = "acme.test"
    @State private var aliases = ""
    @State private var group = ""
    @State private var server = "nginx"
    @State private var php = ""

    private var protectedFolder: String? {
        ["Documents", "Desktop", "Downloads"].first { folder.hasPrefix("~/\($0)") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a site")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Folder type")
                    .fontWeight(.semibold)

                HStack(spacing: 10) {
                    FolderTypeCard(title: "One project", detail: "The folder becomes one site.", selected: folderType == .oneProject) {
                        folderType = .oneProject
                    }
                    FolderTypeCard(title: "Many projects", detail: "Each folder inside becomes a site. New folders become sites later too.", selected: folderType == .manyProjects) {
                        folderType = .manyProjects
                    }
                }
            }

            Form {
                Section {
                    LabeledContent("Folder") {
                        HStack {
                            PathText(folder)
                            Button("Choose…") {}
                        }
                    }
                } footer: {
                    if let protectedFolder {
                        Text("This folder is in \(protectedFolder). macOS asks one time if Nexus may read it. Click Allow.")
                    }
                }

                Section {
                    if folderType == .oneProject {
                        LabeledContent("Host") {
                            TextField("Host", text: $host)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 220)
                        }

                        LabeledContent("Aliases") {
                            TextField("Aliases", text: $aliases, prompt: Text("None"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .frame(width: 220)
                        }
                    }

                    Picker("Group", selection: $group) {
                        Text("None").tag("")
                        ForEach(model.groupNames, id: \.self) { Text($0).tag($0) }
                    }

                    Picker("Webserver", selection: $server) {
                        Text("nginx").tag("nginx")
                        Text("Apache").tag("apache")
                    }

                    Picker("PHP", selection: $php) {
                        ForEach(model.installedPHPVersions, id: \.self) { Text("PHP \($0)").tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(folderType == .oneProject ? "Add site" : "Add folder") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            server = model.settings.defaultServer
            php = model.settings.defaultPHP == "newest" ? model.installedPHPVersions.last ?? "" : model.settings.defaultPHP
        }
    }
}

private struct FolderTypeCard: View {
    let title: String
    let detail: String
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .fontWeight(.semibold)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? Color.accentSoft : Color.clear, in: .rect(cornerRadius: 10))
            .background(.fill.quaternary, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
