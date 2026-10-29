import NexusCore
import SwiftUI

struct CommandLineScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var search = ""

    // Without the PATH setting, a user can still run the nexus command in the app by its path.
    private static let commandPath = Bundle.main.bundleURL.appending(path: "Contents/Helpers/nexus").path(percentEncoded: false)

    private var sections: [CommandSection] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()

        guard !query.isEmpty else {
            return CommandSection.all
        }

        return CommandSection.all.compactMap { section in
            let commands = section.commands.filter {
                $0.command.lowercased().contains(query) || $0.help.lowercased().contains(query)
            }

            return commands.isEmpty ? nil : CommandSection(title: section.title, commands: commands)
        }
    }

    // The note is a row of the form. Outside the form, its text sets a minimum height that makes
    // the window content taller than the window.
    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Color.accentText)

                    if model.pathSetting == .off {
                        Text("Turn on \"Add Nexus to PATH\" in Settings > General to use nexus in your terminal. nexus --help shows the same list.")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Copy path") {
                            copyToPasteboard(Self.shellWord(Self.commandPath))
                        }
                        .help("Copies the path of the nexus command in the app: \(Self.commandPath)")
                        Button("Open settings") {
                            UserDefaults.standard.set("general", forKey: SettingsWindow.tabKey)
                            openSettings()
                        }
                    } else {
                        Text("nexus --help shows the same list.")
                        Spacer()
                    }
                }
            }

            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.commands) { command in
                        HStack(spacing: 16) {
                            MonoText(command.command)
                                .frame(width: 360, alignment: .leading)
                            Text(command.help)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button {
                                copyToPasteboard(command.command)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .screenTitle("Command line", subtitle: "The nexus command does everything that the app does")
        .searchable(text: $search, placement: .toolbar, prompt: "Search commands")
        .onAppear {
            model.readPathSetting()
        }
    }

    // A path with a space or another special character works in a terminal only in quotes.
    private static func shellWord(_ path: String) -> String {
        let isPlain = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) }

        return isPlain ? path : "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
