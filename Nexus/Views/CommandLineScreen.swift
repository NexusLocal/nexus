import SwiftUI

struct CommandLineScreen: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    private var sections: [CommandSection] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()

        guard !query.isEmpty else {
            return model.commandSections
        }

        return model.commandSections.compactMap { section in
            let commands = section.commands.filter {
                $0.command.lowercased().contains(query) || $0.help.lowercased().contains(query)
            }

            return commands.isEmpty ? nil : CommandSection(title: section.title, commands: commands)
        }
    }

    var body: some View {
        Form {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.commands) { command in
                        HStack(spacing: 16) {
                            MonoText(command.command)
                                .frame(width: 340, alignment: .leading)
                            Text(command.help)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
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
}
