import AppKit
import NexusCore
import NexusMCP
import Observation

// A failed change to the files of an agent. The alert offers the text that the user can paste
// into the file or run in Terminal. The first run closes before its changes end. So the main
// window shows all alerts.
struct AgentAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let copyText: String
}

// The coding agents of the Agents screen, the first run and the notice on the Overview. Only
// AgentSetup changes the files of the agents. Without a setup, the model holds the sample data of
// the design "Agents" and changes no file.
@Observable
final class AgentsModel {
    private(set) var settings = AgentSettings()
    private(set) var states: [AgentKind: AgentState] = [:]
    private(set) var onThisMac: Set<AgentKind> = []
    // The switch shows the asked state while the change runs.
    private(set) var asked: [AgentKind: Bool] = [:]
    // A connect that failed. The row then offers the entry to copy instead of a switch.
    private(set) var failures: [AgentKind: AgentSetupError] = [:]
    // The first run can start several changes. Each failure gets its own alert.
    var alerts: [AgentAlert] = []
    // The desktop apps that still run without Nexus, because they started before the connect.
    private(set) var restartNeeded: Set<AgentKind> = []
    @ObservationIgnored private var connectedAt: [AgentKind: Date] = [:]
    @ObservationIgnored private let setup: AgentSetup?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var settingsChanges = 0

    init(setup: AgentSetup?) {
        self.setup = setup

        guard setup != nil else {
            let sample: [AgentKind: AgentState] = [.claudeCode: .connected, .codex: .connected, .cursor: .connected, .vsCode: .notConnected]
            states = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0, sample[$0] ?? .notConnected) })
            onThisMac = Set(sample.keys)
            settings = AgentSettings(listed: sample.keys.map(\.rawValue), searched: true)
            restartNeeded = [.cursor]
            return
        }

        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateRestarts()
            }
        }
    }

    isolated deinit {
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
    }

    var serverName: String {
        setup?.serverName ?? "nexus"
    }

    // An agent with an entry of Nexus shows also when the user added it in another way.
    var rows: [AgentKind] {
        AgentKind.allCases.filter { settings.listed.contains($0.rawValue) || states[$0]?.hasEntry == true }
    }

    var found: [AgentKind] {
        AgentKind.allCases.filter(onThisMac.contains)
    }

    var otherEntry: String {
        setup?.entryText(for: nil) ?? "{\n  \"mcpServers\": {\n    \"nexus\": {\n      \"command\": \"~/Library/Application Support/Nexus/bin/nexus\",\n      \"args\": [\"mcp\"]\n    }\n  }\n}"
    }

    func isOn(_ agent: AgentKind) -> Bool {
        asked[agent] ?? (states[agent] == .connected)
    }

    // The settings file of an agent can change in another app. So the screens read the files
    // again each time they show. A user who fixed a file by hand then sees the real state. The
    // file of Claude Code can be large, so the read runs outside the main thread.
    func load() async {
        guard let setup else {
            return
        }

        let changes = settingsChanges
        let snapshot = await Task.detached { Self.read(setup) }.value
        keep(snapshot.settings, ifNoChangeSince: changes)
        onThisMac = snapshot.onThisMac
        states = snapshot.states
        failures = [:]
        updateRestarts()
    }

    // The notice needs the files of the agents only until it showed once.
    func loadForNotice() async {
        guard setup != nil else {
            return
        }

        let changes = settingsChanges
        keep(await Task.detached { AgentSettings.load() }.value, ifNoChangeSince: changes)

        guard !settings.noticeShown else {
            return
        }

        await load()
    }

    // The list fills itself once with the agents on this Mac. After that, only "Find agents" adds
    // agents. So an agent that the user removed does not come back by itself.
    func loadList() async {
        await load()

        if !settings.searched {
            listFoundAgents()
        }
    }

    // A found agent stays off until the user turns it on.
    func findAgents() async {
        await load()
        listFoundAgents()
    }

    func status(of agent: AgentKind) -> (text: String, warns: Bool, help: String?) {
        if let failure = failures[agent] {
            return (agent.entryIsCommand ? "Nexus cannot change its settings" : "Nexus cannot change its settings file", true, failure.description)
        }

        let state = states[agent] ?? .notConnected
        let text = state.summary(serverName: serverName)

        switch state {
        case .connected:
            return restartNeeded.contains(agent) ? ("Restart \(agent.name) to use Nexus", true, nil) : (text, false, nil)
        case .otherCommand(let command):
            return (text, true, "The entry runs \(command). Turn on the switch to use this Nexus.")
        case .unreadable(let file):
            return (text, true, "Nexus cannot read \(file). Copy the entry and paste it into the file yourself.")
        case .notConnected:
            return (text, false, nil)
        }
    }

    // The text that the user pastes when Nexus cannot change the file itself.
    func entryToCopy(for agent: AgentKind) -> String? {
        if let failure = failures[agent], !failure.entry.isEmpty {
            return failure.entry
        }

        guard case .unreadable = states[agent] else {
            return nil
        }

        return setup?.entryText(for: agent)
    }

    func copyLabel(for agent: AgentKind) -> String {
        agent.entryIsCommand ? "Copy command" : "Copy entry"
    }

    // The first run has no rows. So a failure there shows in an alert and not in the row.
    func setConnected(_ agent: AgentKind, _ on: Bool, inList: Bool = true) {
        change(agent, to: on, inList: inList) { setup, settings in
            if on {
                try await setup.connect(agent, askBeforeLooking: settings.askBeforeLooking)
            } else {
                try await setup.disconnect(agent)
            }
        }
    }

    // "Add" on the row of an agent that is not in the list adds its entry and turns it on.
    func add(_ agent: AgentKind) {
        update { settings in
            settings.list([agent])
        }

        setConnected(agent, true)
    }

    // The row stays when Nexus cannot remove its entry. Otherwise the agent would use Nexus without
    // a row in the list. A file that Nexus cannot read can hold the entry too.
    func remove(_ agent: AgentKind) {
        let removeRow = { [self] in
            update { settings in
                settings.listed.removeAll { $0 == agent.rawValue }
            }

            failures[agent] = nil
        }

        guard states[agent]?.mayHaveEntry == true else {
            removeRow()
            return
        }

        change(agent, to: false, inList: true) { setup, _ in
            try await setup.disconnect(agent)
        } done: {
            removeRow()
        }
    }

    // A change of the level needs no change in the files of the agents. The MCP server reads it at
    // each call.
    func setLevel(_ level: AgentLevel) {
        update { settings in
            settings.level = level
        }
    }

    func setAskBeforeLooking(_ ask: Bool) {
        update { settings in
            settings.askBeforeLooking = ask
        }

        guard let setup else {
            return
        }

        Task {
            do {
                try await setup.applyLooking(askBeforeLooking: ask)
            } catch {
                show(error, title: "Nexus did not change the questions of the agents")
            }

            await load()
        }
    }

    // The first run connects the agents that the user selected. The others stay in the list, off.
    // A Mac without agents skips the step. Its list then still fills itself once on the Agents
    // screen. The notice on the Overview is for users who never saw the first run.
    func finishFirstRun(connecting selected: Set<AgentKind>, level: AgentLevel) {
        update { settings in
            settings.level = level
            settings.noticeShown = true
        }

        if !found.isEmpty {
            listFoundAgents()
        }

        for agent in found where selected.contains(agent) && states[agent] != .connected {
            setConnected(agent, true, inList: false)
        }
    }

    #if DEBUG
    var showsNoticeForCheck = false
    #endif

    // Only for a Mac with an agent that does not use Nexus yet.
    var showsNotice: Bool {
        #if DEBUG
        if showsNoticeForCheck {
            return true
        }
        #endif

        return !settings.noticeShown && !found.isEmpty && !AgentKind.allCases.contains { states[$0] == .connected }
    }

    func hideNotice() {
        update { settings in
            settings.noticeShown = true
        }
    }

    // MARK: Private

    private struct Snapshot: Sendable {
        let settings: AgentSettings
        let onThisMac: Set<AgentKind>
        let states: [AgentKind: AgentState]
    }

    // A change of the user while a read runs is newer than the read. So the read does not replace
    // that change.
    private func keep(_ read: AgentSettings, ifNoChangeSince changes: Int) {
        guard changes == settingsChanges else {
            return
        }

        settings = read
    }

    private nonisolated static func read(_ setup: AgentSetup) -> Snapshot {
        Snapshot(
            settings: AgentSettings.load(),
            onThisMac: Set(AgentKind.allCases.filter(setup.isOnThisMac)),
            states: Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0, setup.state(of: $0)) })
        )
    }

    private func listFoundAgents() {
        let found = found

        update { settings in
            settings.list(found)
            settings.searched = true
        }
    }

    // The command nexus mcp install can change agents.json while the app shows it. So each change
    // starts from the file and not from the settings in memory.
    private func update(_ change: (inout AgentSettings) -> Void) {
        var fresh = setup == nil ? settings : AgentSettings.load()
        change(&fresh)
        settings = fresh
        settingsChanges += 1

        guard setup != nil else {
            return
        }

        do {
            try fresh.save()
        } catch {
            show(error, title: "Nexus did not save the settings of the agents")
        }
    }

    private func change(_ agent: AgentKind, to on: Bool, inList: Bool, _ work: @escaping @Sendable (AgentSetup, AgentSettings) async throws -> Void, done: (() -> Void)? = nil) {
        guard let setup else {
            states[agent] = on ? .connected : .notConnected
            done?()
            return
        }

        guard asked[agent] == nil else {
            return
        }

        asked[agent] = on
        failures[agent] = nil
        let settings = settings
        let wasConnected = states[agent] == .connected

        Task {
            var failure: (any Error)?

            do {
                try await work(setup, settings)
            } catch {
                failure = error
            }

            let state = await Task.detached { setup.state(of: agent) }.value
            asked[agent] = nil
            states[agent] = state

            guard let failure else {
                if on, !wasConnected {
                    connectedAt[agent] = .now
                    updateRestarts()
                }

                done?()
                return
            }

            // Claude Code can get its entry and then fail on its allow rules. Its row then shows it
            // as connected, and only the alert offers the rules.
            if on, inList, state != .connected, let setupError = failure as? AgentSetupError, !setupError.entry.isEmpty {
                failures[agent] = setupError
            } else {
                show(failure, title: on ? "Nexus did not connect \(agent.name)" : "Nexus did not remove its entry from \(agent.name)")
            }
        }
    }

    // A desktop app reads its settings only at its start. An app that started before the connect
    // still runs without Nexus. A quit of the app ends the hint.
    private func updateRestarts() {
        guard setup != nil else {
            return
        }

        let running = NSWorkspace.shared.runningApplications

        restartNeeded = Set(connectedAt.compactMap { agent, connected in
            let startedBefore = running.contains { app in
                guard let name = app.bundleURL?.lastPathComponent, agent.apps.contains(name), let launched = app.launchDate else {
                    return false
                }

                return launched < connected
            }

            return agent.needsRestart && states[agent] == .connected && startedBefore ? agent : nil
        })
    }

    private func show(_ error: any Error, title: String) {
        let setupError = error as? AgentSetupError
        alerts.append(AgentAlert(title: title, message: setupError?.description ?? ErrorText.plain(error), copyText: setupError?.entry ?? ""))
    }
}
