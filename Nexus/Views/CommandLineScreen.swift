import NexusCore
import SwiftUI

struct CommandLineScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var search = ""

    // Without the PATH setting, a user can still run the nexus command in the app by its path.
    private static let commandPath = AppModel.nexusCommand.path(percentEncoded: false)

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

    // The note and the warning are in the form. Outside the form, their text sets a minimum height
    // that makes the window content taller than the window. A form row on macOS cannot get the
    // orange background. So the warning is the footer of a section without rows.
    var body: some View {
        Form {
            if model.otherShellCommands.isEmpty {
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
                            openSettingsButton
                        } else {
                            Text("nexus --help shows the same list.")
                            Spacer()
                        }
                    }
                }
            } else {
                Section {
                } footer: {
                    WarningBanner(title: model.shellWarningTitle, message: "Settings > General shows why. nexus --help shows the same list.") {
                        openSettingsButton
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

    private var openSettingsButton: some View {
        Button("Open settings") {
            UserDefaults.standard.set("general", forKey: SettingsWindow.tabKey)
            openSettings()
        }
    }

    // A path with a space or another special character works in a terminal only in quotes.
    private static func shellWord(_ path: String) -> String {
        let isPlain = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) }

        return isPlain ? path : "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
