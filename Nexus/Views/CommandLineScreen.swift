import NexusCore
import SwiftUI

struct CommandLineScreen: View {
    @State private var search = ""

    // The app contains the nexus command. The PATH setting comes in step 7.
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
                    Text("nexus --help shows the same list. The nexus command is in the app. Copy its path to run it in your terminal.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Copy path") {
                        copyToPasteboard(Self.shellWord(Self.commandPath))
                    }
                    .help(Self.commandPath)
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
    }

    // A path with a space or another special character works in a terminal only in quotes.
    private static func shellWord(_ path: String) -> String {
        let isPlain = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) }

        return isPlain ? path : "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
