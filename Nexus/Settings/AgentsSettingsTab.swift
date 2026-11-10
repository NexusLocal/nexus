import AppKit
import NexusMCP
import SwiftUI

// The pop-up button "Agents can" of the settings and of the first run.
struct AgentLevelPicker: View {
    @Binding var level: AgentLevel

    var body: some View {
        Picker("Agents can", selection: $level) {
            ForEach(AgentLevel.allCases, id: \.self) { level in
                Text(level.title)
                    .tag(level)
            }
        }
    }
}

// Settings > Agents. The design is "Settings Agents" in nexus.pen, with "Settings Agents · List
// states" and "Settings Agents · Levels".
struct AgentsSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var addsOtherAgent = false

    private var agents: AgentsModel {
        model.agents
    }

    var body: some View {
        Form {
            Section {
                if agents.rows.isEmpty {
                    Text("Nexus found no coding agent on this Mac.")
                        .foregroundStyle(.secondary)
                }

                ForEach(agents.rows) { agent in
                    AgentRow(agent: agent)
                }

                HStack {
                    Button("Find agents") {
                        Task { await agents.findAgents() }
                    }

                    addMenu
                }
                .trailingInRow()
            } header: {
                Text("Coding agents")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("These agents are on this Mac. Turn on an agent to let it use Nexus in every project. It then sees the URL, database, logs and mail of the project. Nexus adds one entry \"\(agents.serverName)\" to the settings of the agent. With \"Ask me before agents look\" off, Claude Code also gets rules that let the tools that only look run without a question. Nexus changes nothing else.")
                    Text("The trash icon removes Nexus from the agent and removes the agent from this list. \"Find agents\" looks for agents again and adds them turned off.")
                }
            }

            Section {
                AgentLevelPicker(level: Binding(get: { agents.settings.level }, set: { agents.setLevel($0) }))

                Toggle("Ask me before agents look", isOn: Binding(get: { agents.settings.askBeforeLooking }, set: { agents.setAskBeforeLooking($0) }))
                    .toggleStyle(.switch)
            } header: {
                Text("What agents can do")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(agents.settings.level.summary)
                    Text("Claude Code and Codex ask you before each action. With \"Ask me before agents look\" off, they do not ask when they only look. They still ask before each change.")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await agents.loadList()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await agents.load() }
        }
        .sheet(isPresented: $addsOtherAgent) {
            OtherAgentSheet(entry: agents.otherEntry)
        }
        .agentAlert(agents, place: .settings)
    }

    // The agents on this Mac that the user removed come first. An agent that Nexus did not find
    // can be in another place, or the user installs it later.
    private var addMenu: some View {
        let addable = agents.addable

        return Menu("Add agent…") {
            ForEach([("On this Mac", addable.onThisMac), ("Not found on this Mac", addable.notFound)].filter { !$0.1.isEmpty }, id: \.0) { title, kinds in
                Section(title) {
                    ForEach(kinds) { agent in
                        Button(agent.name) {
                            agents.add(agent)
                        }
                    }
                }
            }

            Divider()

            Button("Other agent…") {
                addsOtherAgent = true
            }
        }
        .fixedSize()
    }
}

private struct AgentRow: View {
    @Environment(AppModel.self) private var model
    let agent: AgentKind

    var body: some View {
        let agents = model.agents
        let status = agents.status(of: agent)

        LabeledContent {
            HStack(spacing: 10) {
                Text(status.text)
                    .font(.callout)
                    .foregroundStyle(status.warns ? Color.orangeText : .secondary)
                    .rowValue()
                    .help(status.help ?? "")

                if let entry = agents.entryToCopy(for: agent) {
                    Button(agents.copyLabel(for: agent)) {
                        copyToPasteboard(entry)
                    }
                } else {
                    if agents.asked[agent] != nil {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Toggle(agent.name, isOn: Binding(get: { agents.isOn(agent) }, set: { agents.setConnected(agent, $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(agents.asked[agent] != nil)
                }

                RowRemoveButton(help: "Remove \(agent.name)") {
                    agents.remove(agent)
                }
                .disabled(agents.asked[agent] != nil)
            }
        } label: {
            Text(agent.name)
        }
        .labeledContentStyle(.rowValue)
    }
}

// "Other agent…" of the menu "Add agent…". Most agents use the form of mcpServers.
private struct OtherAgentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Nexus to another agent")
                .font(.headline)

            Text("Paste this entry into the MCP settings of your agent. Most agents use this form. VS Code uses \"servers\" instead of \"mcpServers\".")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: entry)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.fill.quaternary, in: .rect(cornerRadius: 8))

            HStack {
                Spacer()

                Button("Copy entry") {
                    copyToPasteboard(entry)
                }

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

extension View {
    // The alert of a change to the files of an agent that failed. It offers the text to paste.
    func agentAlert(_ agents: AgentsModel, place: ActionPlace) -> some View {
        let shown = agents.alerts.first { $0.place == place }

        return alert(shown?.title ?? "", isPresented: Binding(get: { shown != nil }, set: { isShown in
            if !isShown {
                agents.alerts.removeAll { $0.id == shown?.id }
            }
        }), presenting: shown) { alert in
            if !alert.copyText.isEmpty {
                Button("Copy") {
                    copyToPasteboard(alert.copyText)
                }
            }

            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
    }
}
