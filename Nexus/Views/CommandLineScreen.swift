import NexusCore
import SwiftUI

struct CommandLineScreen: View {
    @Environment(AppModel.self) private var model
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

    var body: some View {
        Form {
            Section {
                Toggle("Add Nexus to PATH", isOn: Binding(get: { model.pathSetting != .off }, set: { model.setAddToPath($0) }))
                    .toggleStyle(.switch)
            } header: {
                Text("Setup")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !model.otherShellCommands.isEmpty {
                        WarningBanner(title: model.shellWarningTitle) {
                            ForEach(model.otherShellCommands, id: \.self) { other in
                                Text(other.description)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                            }

                            ForEach(model.shellWarningReasons, id: \.self) { reason in
                                Text(reason)
                            }
                        } actions: {
                            Button("Check again") {
                                model.checkShellCommands(again: true)
                            }
                        }
                        .padding(.bottom, 4)
                    }

                    Text("Nexus adds one line at the end of ~/.zshrc. nexus, php, composer, node, npm and wp in your terminal then use the versions of the site in the current folder. Turn it off to remove the line. nexus --help shows the same list as this screen.")

                    if model.pathSetting == .off {
                        Text("Without it, run the nexus command by its path in the app: \(Self.commandPath)")
                            .textSelection(.enabled)
                    }

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
                            CopyButton(help: "Copy") {
                                command.command
                            }
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
}
