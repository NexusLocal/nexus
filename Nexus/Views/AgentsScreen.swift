import AppKit
import NexusMCP
import SwiftUI

// The pop-up button "Agents can" of the Agents screen and of the first run.
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

// The design is "Agents" in nexus.pen, with "Agents · List states" and "Agents · Levels".
struct AgentsScreen: View {
    @Environment(AppModel.self) private var model

    private var agents: AgentsModel {
        model.agents
    }

    var body: some View {
        Form {
            Section {
                ForEach(AgentKind.allCases) { agent in
                    if agents.rows.contains(agent) {
                        AgentRow(agent: agent)
                    } else {
                        AddableAgentRow(agent: agent)
                    }
                }
            } header: {
                Text("Agents")
            } footer: {
                Text("Turn on an agent to let it use Nexus in each project. It then sees the URL, database, logs and mail of the project. Nexus adds one entry \"\(agents.serverName)\" to the settings of the agent and changes nothing else. The trash icon removes Nexus from the agent. \"Find agents\" looks for agents again and adds them turned off.")
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
                    Text("Claude Code and Codex ask you before each action. With \"Ask me before agents look\" off, they do not ask when they only look. They still ask before each change. With it off, Claude Code also gets rules that let the tools that only look run without a question.")
                }
            }

            Section {
                Text(verbatim: agents.otherEntry)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                HStack {
                    Text("Another agent")
                    Spacer()
                    Button("Copy entry") {
                        copyToPasteboard(agents.otherEntry)
                    }
                }
            } footer: {
                Text("Paste this entry into the MCP settings of an agent that Nexus does not know. Most agents use this form. VS Code uses \"servers\" instead of \"mcpServers\".")
            }

            ToolsSection(level: .read, title: "Tools that look", footer: "These tools read and change nothing.")
            ToolsSection(level: .change, title: "Tools that set up", footer: "Claude Code and Codex ask you before each of these tools.")
            ToolsSection(level: .remove, title: "Tools that remove", footer: "Claude Code and Codex ask you before each of these tools.")
        }
        .formStyle(.grouped)
        .screenTitle("Agents", subtitle: "Coding agents use Nexus through its MCP server")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await agents.findAgents() }
                } label: {
                    Label("Find agents", systemImage: "magnifyingglass")
                }
                .labelStyle(.titleAndIcon)
            }
        }
        .task {
            await agents.loadList()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await agents.load() }
        }
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

// An agent that is not in the list: Nexus did not find it, or the user removed it. "Add" adds its
// entry also when Nexus did not find the agent, for example when it is in another place.
private struct AddableAgentRow: View {
    @Environment(AppModel.self) private var model
    let agent: AgentKind

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Text(model.agents.onThisMac.contains(agent) ? "Not in use" : "Not on this Mac")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .rowValue()

                Button("Add") {
                    model.agents.add(agent)
                }
            }
        } label: {
            Text(agent.name)
        }
        .labeledContentStyle(.rowValue)
    }
}

// The tools of one level. A tool above the level of "Agents can" gives the agent a refusal.
private struct ToolsSection: View {
    @Environment(AppModel.self) private var model
    let level: AgentLevel
    let title: String
    let footer: String

    private var isAllowed: Bool {
        level <= model.agents.settings.level
    }

    var body: some View {
        Section {
            ForEach(NexusTools.all.filter { $0.level == level }, id: \.name) { tool in
                HStack(spacing: 16) {
                    Text(tool.title)
                        .frame(width: 210, alignment: .leading)
                    MonoText(tool.name)
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .leading)
                    Text(tool.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Text(isAllowed ? "Allowed" : "Not allowed")
                    .fontWeight(.regular)
                    .foregroundStyle(isAllowed ? Color.greenText : .secondary)
            }
        } footer: {
            Text(isAllowed ? footer : "Choose \"\(level.title)\" at \"Agents can\" above to allow these tools.")
        }
    }
}

extension View {
    // The alert of a change to the files of an agent that failed. It offers the text to paste.
    func agentAlert(_ agents: AgentsModel) -> some View {
        let shown = agents.alerts.first

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
