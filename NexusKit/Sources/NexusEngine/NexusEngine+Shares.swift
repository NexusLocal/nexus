import Foundation
import NexusConfig
import NexusCore
import NexusDNS
import NexusIPC
import NexusRuntime
import NexusSupervisor

// The share engine (group 4, 4b). A quick link is a cloudflared of processSupervisor and a share
// block of nginx. An own-domain link has only a share block. One cloudflared serves all of them
// (4h, NexusEngine+OwnDomain.swift). One site and one workspace each have at most one link. The
// parts 4c to 4h add their lines in the section of the other parts.

// The site or the workspace of a link (group 4, 4b). host is its first host. One site and one
// workspace each have at most one link. names holds each host that names this target, without a
// name with *.
struct ShareTarget: Sendable, Equatable {
    let host: String
    let site: String
    let workspace: String?
    let owner: String
    let names: [String]
}

// The sites of a link (shareProject). site is the main site or the site of the workspace in its
// worktree, nil while Nexus serves no site for the workspace. folder is the project folder of the
// main checkout or of the workspace.
struct ShareProject: Sendable, Equatable {
    let main: Site
    let site: Site?
    let folder: URL
}

extension EngineState {
    func share(id: String) -> ShareRecord? {
        shares.first { $0.id == id }
    }
}

// What 4e knows about the Vite of a target (group 4, 4e). usesVite shows the dropdown.
// liveBlocked is the text of an old or unknown version. buildRefusal says why Build cannot run.
// refusal says why the share cannot start at all. inTerminal gives the warning viteInTerminal.
// mixHot gives the warning mixHot of a Laravel Mix site with npm run hot.
struct ShareViteCheck: Sendable, Equatable {
    var usesVite = false
    var liveBlocked: String?
    var buildRefusal: String?
    var refusal: String?
    var inTerminal = false
    var mixHot = false

    static let none = ShareViteCheck()

    // The warnings of 4e for the confirm sheet.
    var warnings: [ShareWarning] {
        (inTerminal ? [.viteInTerminal] : []) + (mixHot ? [.mixHot] : [])
    }
}

// The program of one link. processID is the id in processSupervisor. It holds the share id,
// because two sites of one project have one owner.
struct ShareProgram: Sendable, Equatable {
    let processID: String
    let owner: String
}

// The visitors of one link in memory. A visitor is one address of CF-Connecting-IP.
struct ShareVisits: Sendable, Equatable {
    var visitors: Set<String> = []
    var last: Date?
}

// The checks of the metrics server and of the public DNS. A test gives its own answers. So no
// unit test connects to Cloudflare or to 1.1.1.1.
struct ShareChecks: Sendable {
    var quickTunnelHost: @Sendable (Int) async -> String?
    var isReady: @Sendable (Int) async -> Bool?
    var resolves: @Sendable (String) async -> Bool?

    static let live = ShareChecks(
        quickTunnelHost: { await CloudflaredMetrics.quickTunnelHost(port: $0) },
        isReady: { await CloudflaredMetrics.isReady(port: $0) },
        resolves: { await PublicDNSLookup.resolves($0) }
    )
}

// The waits of the start of a link, of the check after a wake and of the check each minute
// (overview, 4b). A test gives short times. A new public host needs 3 to 33 seconds in DNS. A network
// can block DNS to 1.1.1.1. After noAnswerLimit without any answer the link opens openWithoutAnswer
// after the first true of /ready (owner, review-4ab question 16). cloudflared sees a closed
// connection about 5 seconds after a wake (research 5, fact 2).
struct ShareWaits: Sendable {
    var poll: Duration = .milliseconds(250)
    var blockLimit: Duration = .seconds(5)
    var hostLimit: Duration = .seconds(30)
    var readyLimit: Duration = .seconds(60)
    var addressInterval: Duration = .seconds(2)
    var addressLimit: Duration = .seconds(60)
    var noAnswerLimit: Duration = .seconds(10)
    var openWithoutAnswer: Duration = .seconds(35)
    var firstWakeCheck: Duration = .seconds(10)
    var wakeInterval: Duration = .seconds(5)
    var wakeEnd: Duration = .seconds(600)
    var connectionInterval: Duration = .seconds(60)
    // The wait for nginx after a new start of nexusd with an own-domain link (4h).
    var resumeLimit: Duration = .seconds(30)

    static let standard = ShareWaits()
}

// A link that ended during its start. The start then answers with the line "did not open".
struct ShareEndedDuringStart: Error {
    let reason: ShareEndReason
}

// The end of the wait for the address of a link. noAnswer: 1.1.1.1 did not answer within
// noAnswerLimit.
private enum AddressWait: Sendable {
    case resolves
    case noAnswer
}

// The steps of the parts of group 4 around the start and the end of a link.
extension NexusEngine {
    // The work before the ports of the parts 4a, 4c, 4d, 4e and 4f: the install of cloudflared, the
    // probe of F1, the password file, the stop of the dev server and the request log. It gives the
    // binary of cloudflared. project is shareProject(of: target).
    func prepareShare(_ record: ShareRecord, target: ShareTarget, project: ShareProject?) async throws -> URL {
        let cloudflared = try await prepareCloudflaredAndHosts(record, target: target, project: project)
        try await prepareSharePassword(record)
        try await prepareShareBuild(record, target: target, project: project)
        try prepareShareRequests(record)
        return cloudflared
    }

    // The install and the probe wait for the network and for the site. So they run at the same time.
    // The first failure cancels the other step. So the start ends with that failure at once.
    private func prepareCloudflaredAndHosts(_ record: ShareRecord, target: ShareTarget, project: ShareProject?) async throws -> URL {
        try await withThrowingTaskGroup(of: URL?.self) { group in
            group.addTask {
                try await self.prepareCloudflared(forShare: record.id)
            }

            group.addTask {
                try await self.prepareShareHosts(record, target: target, project: project)
                return nil
            }

            var binary: URL?

            for try await case let url? in group {
                binary = url
            }

            guard let binary else {
                throw CancellationError()
            }

            return binary
        }
    }

    // The work of 4e and 4f at each end of a link, in endShares and in endSharesOfEarlierRun.
    func shareEnded(_ record: ShareRecord) async {
        await endShareVite(record)
        endLinkRequests(of: [record])
    }
}

// MARK: The targets

extension NexusEngine {
    func shareTargets(_ state: EngineState) -> [String: ShareTarget] {
        let sites = resolvedSites(state).map(\.site)
        let workspaces = workspaceSites(state, resolved: sites)

        return shareTargets(state, sites: sites, sitesOfRecord: workspaces.sitesOfRecord, conflicts: workspaces.conflicts)
    }

    // One target for each site and for each workspace without a conflict, by its first host. The
    // owners come from the same inputs as accessLogOwners.
    func shareTargets(_ state: EngineState, sites: [Site], sitesOfRecord: [String: [Site]], conflicts: [Workspace: String]) -> [String: ShareTarget] {
        var targets: [String: ShareTarget] = [:]

        for site in sites {
            let owner = Self.processOwner(key: ProjectFolder.workspaceKey(of: site), workspace: nil)
            targets[site.host] = ShareTarget(host: site.host, site: site.host, workspace: nil, owner: owner, names: Self.shareNames(site.hosts))
        }

        for (key, sitesOfProject) in sitesOfRecord {
            guard let main = sitesOfProject.first else {
                continue
            }

            for workspace in state.worktrees[key]?.workspaces ?? [] where conflicts[workspace] == nil {
                let hosts = workspace.hosts(of: sitesOfProject, tld: state.tld)

                guard let host = hosts.first, targets[host] == nil else {
                    continue
                }

                targets[host] = ShareTarget(host: host, site: main.host, workspace: workspace.name, owner: Self.processOwner(key: key, workspace: workspace.name), names: Self.shareNames(hosts))
            }
        }

        return targets
    }

    // An alias names the same link as the first host (owner, review-4ab question 19).
    func shareTarget(naming host: String, in state: EngineState) throws -> ShareTarget {
        try shareTarget(naming: host, among: shareTargets(state))
    }

    func shareTarget(naming host: String, among targets: [String: ShareTarget]) throws -> ShareTarget {
        if let target = targets[host] {
            return target
        }

        guard let target = targets.values.sorted(by: { $0.host < $1.host }).first(where: { $0.names.contains(host) }) else {
            throw RuntimeError.unsupported("Nexus has no site or workspace \(host). See: nexus site list")
        }

        return target
    }

    // The one lookup of the site of a link for the parts 4c, 4d and 4e: the main site, the site of
    // the target and the project folder. A workspace has its site and its folder in its worktree.
    func shareProject(of target: ShareTarget, in state: EngineState) -> ShareProject? {
        let sites = resolvedSites(state).map(\.site)

        guard let main = sites.first(where: { $0.host == target.site }) else {
            return nil
        }

        guard let name = target.workspace else {
            return ShareProject(main: main, site: main, folder: URL(filePath: ProjectFolder.projectFolder(of: main), directoryHint: .isDirectory))
        }

        guard let workspace = state.worktrees[ProjectFolder.workspaceKey(of: main)]?.workspaces.first(where: { $0.name == name }) else {
            return nil
        }

        let site = workspaceSites(state, resolved: sites).sites.first { $0.host == target.host }
        return ShareProject(main: main, site: site, folder: URL(filePath: workspace.folder, directoryHint: .isDirectory))
    }

    // The active link of a host or of the target that the host names. A host that Nexus no longer
    // has still finds its own link.
    func activeShare(naming host: String, in state: EngineState) -> ShareRecord? {
        state.shares.first { $0.host == host && $0.state.isActive }
            ?? (try? shareTarget(naming: host, in: state)).flatMap { target in state.shares.first { $0.host == target.host && $0.state.isActive } }
    }

    func activeShareIDs() async -> [String] {
        await stateStore.current().shares.filter(\.state.isActive).map(\.id)
    }

    // Each link that starts or is open keeps its owner awake. A link of the own domain (4h) and a
    // link that prepares have no program. So the owner comes from the record. sites are the resolved
    // sites of state.
    func ownersWithLinks(_ state: EngineState, sites: [Site]) -> Set<String> {
        let active = state.shares.filter(\.state.isActive)

        guard !active.isEmpty else {
            return []
        }

        let mains = Dictionary(sites.map { ($0.host, $0) }) { first, _ in first }

        return Set(active.compactMap { record in
            mains[record.site].map { Self.processOwner(key: ProjectFolder.workspaceKey(of: $0), workspace: record.workspace) }
        })
    }

    private static func shareNames(_ hosts: [String]) -> [String] {
        hosts.filter { !$0.contains("*") }
    }
}

// MARK: The reads and the defaults

extension NexusEngine {
    // url names the public host only while the link is open, because the address does not work in
    // the other states.
    func shareInfo(_ record: ShareRecord) -> ShareInfo {
        let visits = shareVisits[record.id]

        return ShareInfo(
            host: record.host,
            site: record.site,
            workspace: record.workspace,
            url: record.state == .open ? record.publicHost.map { "https://\($0)" } : nil,
            state: record.state,
            options: record.options,
            started: record.started,
            endsAt: record.endsAt,
            password: record.password,
            visitors: visits?.visitors.count ?? 0,
            lastVisit: Self.wholeMinute(of: visits?.last),
            requestCount: shareRequestCount(record),
            usesVite: record.usesVite,
            liveBlocked: record.liveBlocked,
            log: (record.options.address == .ownDomain ? paths.ownDomainTunnelLog : paths.tunnelLog(record.host)).path(percentEncoded: false)
        )
    }

    func shareInfos() async -> [ShareInfo] {
        await stateStore.current().shares.sorted { $0.host < $1.host }.map(shareInfo)
    }

    // One host has one record: the active link or the last one that ended.
    func activeOrLastShare(host: String, in state: EngineState) -> ShareRecord? {
        state.shares.first { $0.host == host }
    }

    // The sites resolve once. The checks of 4d and 4e read files and run commands. So they run at
    // the same time.
    func sharePreview(host: String) async throws -> SharePreview {
        let state = await stateStore.current()
        let targets = shareTargets(state)
        let target = try shareTarget(naming: host, among: targets)
        let project = shareProject(of: target, in: state)
        async let vite = viteCheck(of: target, project: project)
        async let protection = protectionWarnings(of: target, project: project)
        let check = await vite
        let open = state.shares.first { $0.host == target.host && $0.state.isActive }
        let domain = try? usableOwnDomain(state)
        var defaults = shareDefaults(in: state)

        // An old Vite version keeps Build (4e).
        if check.usesVite, check.liveBlocked != nil {
            defaults.viteMode = .build
        }

        return SharePreview(
            host: target.host,
            defaults: defaults,
            usesVite: check.usesVite,
            liveBlocked: check.liveBlocked,
            refusal: check.refusal,
            warnings: await protection + check.warnings,
            extraHosts: sharePreviewHosts(of: target, project: project, targets: targets),
            ownDomain: domain?.domain,
            label: domain.flatMap { _ in try? ownDomainLabel(for: target, asked: nil, in: state, targets: targets) },
            openLink: open.map(shareInfo)
        )
    }

    // The defaults of Settings. An address on the own domain needs a domain that Nexus can use
    // (4h).
    func shareDefaults(in state: EngineState) -> ShareOptions {
        var defaults = state.shareDefaults

        if (try? usableOwnDomain(state)) == nil {
            defaults.address = .random
        }

        return defaults
    }

    func setShareDefaults(_ options: ShareOptions) async throws -> String {
        try await stateStore.update { $0.shareDefaults = options }
        return ShareText.defaultsSaved
    }

    static func newShareID() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
}

// MARK: The start

extension NexusEngine {
    // A second start of an open link gives that link with its options. A start during a start of the
    // same target gives the answer of the first start.
    func startShare(_ start: ShareStart) async throws -> ShareInfo {
        let state = await stateStore.current()
        let targets = shareTargets(state)
        let target = try shareTarget(naming: start.host, among: targets)

        if let open = state.shares.first(where: { $0.host == target.host && $0.state == .open }) {
            return shareInfo(open)
        }

        if let running = shareStarts[target.host] {
            return try await running.value
        }

        let starting = Task { try await self.openShare(start, target: target, targets: targets) }
        shareStarts[target.host] = starting
        return try await starting.value
    }

    // The end time counts from the click on Share (owner, review-4ab question 20). A stop before the
    // record exists holds in stoppedStarts. So Ctrl-C of nexus share never leaves a link open.
    private func openShare(_ start: ShareStart, target: ShareTarget, targets: [String: ShareTarget]) async throws -> ShareInfo {
        defer {
            shareStarts[target.host] = nil
            stoppedStarts[target.host] = nil
        }

        if target.workspace != nil {
            noteActivity(owner: target.owner)
        }

        let state = await stateStore.current()
        var options = start.options(defaults: shareDefaults(in: state))
        let project = shareProject(of: target, in: state)
        let check = await viteCheck(of: target, project: project)

        if let refusal = check.refusal {
            throw RuntimeError.unsupported(refusal)
        }

        if check.usesVite, check.liveBlocked != nil {
            options.viteMode = .build
        }

        let builds = check.usesVite && options.viteMode == .build

        if builds, let refusal = check.buildRefusal {
            throw RuntimeError.unsupported(refusal)
        }

        var label: String?
        var publicHost: String?

        // An own-domain link knows its address before its start (4h).
        if options.address == .ownDomain {
            let domain = try usableOwnDomain(state)
            let chosen = try ownDomainLabel(for: target, asked: start.label, in: state, targets: targets)
            label = chosen
            publicHost = OwnDomainName.address(label: chosen, domain: domain.domain)
        }

        guard await supervisor.state(of: ServiceCatalog.nginxID)?.isActive == true else {
            throw RuntimeError.unsupported(ShareText.nginxNotRunning)
        }

        let firstStep = await firstCloudflaredStep()
        let mode = await linkHostMode(of: target, project: project)

        if let reason = stoppedStarts[target.host] {
            throw RuntimeError.unsupported(ShareText.notOpenedLine(target.host, reason: reason))
        }

        let started = Date.now
        let planned = ShareRecord(
            id: Self.newShareID(),
            host: target.host,
            site: target.site,
            workspace: target.workspace,
            options: options,
            mode: mode,
            label: label,
            publicHost: publicHost,
            started: started,
            endsAt: options.duration.end(from: started),
            state: .starting(builds && firstStep == .openLink ? .buildAssets : firstStep),
            usesVite: check.usesVite,
            liveBlocked: check.usesVite ? check.liveBlocked : nil
        )

        // The record reserves its label in the same update. A start of another site at the same time
        // can take the default label first. This start then gets the next free label. A label that
        // the user asked for gives text 15.
        let record = try await stateStore.update { state -> Result<ShareRecord, any Error> in
            var reserved = planned

            if let domain = state.ownDomain, planned.label != nil {
                do {
                    let chosen = try Self.ownDomainLabel(for: target, asked: start.label, domain: domain, in: state, targets: targets)
                    reserved.label = chosen
                    reserved.publicHost = OwnDomainName.address(label: chosen, domain: domain.domain)
                } catch {
                    return .failure(error)
                }
            }

            state.shares.removeAll { $0.host == reserved.host }
            state.shares.append(reserved)
            return .success(reserved)
        }.get()

        publishSites()
        startShareChecks()
        activity?.write("share", ShareText.opensLine(host: record.host, options: options, endsAt: record.endsAt, usesVite: record.usesVite))

        do {
            return try await runShare(record, target: target, project: project, builds: builds, hosts: Set(targets.keys))
        } catch let ended as ShareEndedDuringStart {
            // A stop that found no record yet holds only in stoppedStarts. Its link ends here.
            await endShares([record.id], reason: ended.reason)
            throw RuntimeError.unsupported(ShareText.notOpenedLine(record.host, reason: ended.reason))
        } catch {
            let text = ErrorText.plain(error)
            await endShares([record.id], reason: .failed(text))

            // A stop can come during the work of the failure. Its reason then wins.
            if case .ended(let reason)? = await stateStore.current().shares.first(where: { $0.id == record.id })?.state, reason != .failed(text) {
                throw RuntimeError.unsupported(ShareText.notOpenedLine(record.host, reason: reason))
            }

            throw RuntimeError.unsupported(text)
        }
    }

    // The steps after the record (overview, "The flow of one link"). Each wait checks that the link
    // still starts.
    private func runShare(_ record: ShareRecord, target: ShareTarget, project: ShareProject?, builds: Bool, hosts: Set<String>) async throws -> ShareInfo {
        let id = record.id
        let waits = shareWaits
        let checks = shareChecks

        try await ensureStarting(id)
        let binary = try await prepareShare(record, target: target, project: project)
        try await updateShare(id) { $0.state = .starting(builds ? .buildAssets : .openLink) }

        // One cloudflared serves each own-domain link (4h).
        if record.options.address == .ownDomain {
            return try await runOwnDomainShare(record, target: target, project: project, hosts: hosts)
        }

        let ports = try await openShareBlock(id, withMetricsPort: true)
        let metricsPort = ports.metricsPort ?? 0

        var linked = record
        linked.port = ports.port
        let definition = cloudflaredDefinition(linked, binary: binary, metricsPort: metricsPort)

        try await ensureStarting(id)
        try await startCloudflared(definition, config: CloudflaredConfig.quickLinkFile, at: paths.cloudflaredConfig, logName: "cloudflared-\(record.host)")

        // A stop can reach the record during the start of the program. Then nothing else ends it.
        do {
            try await ensureStarting(id)
        } catch {
            await processSupervisor.end(definition.id, cause: "a stop during its start")
            throw error
        }

        sharePrograms[id] = ShareProgram(processID: definition.id, owner: target.owner)
        await observeProcessChanges()

        // The program can end before this point. Its change then came before sharePrograms knew it.
        await shareProgramsChanged()

        let publicHost = try await poll(id, every: waits.poll, limit: waits.hostLimit, failure: ShareText.noAddress) {
            await checks.quickTunnelHost(metricsPort)
        }

        try await updateShare(id) { $0.publicHost = publicHost }
        try await buildLinkAssets(id, target: target, project: project)
        try await updateShare(id) { $0.state = .starting(.openLink) }

        _ = try await poll(id, every: waits.poll, limit: waits.readyLimit, failure: ShareText.noConnection) {
            await checks.isReady(metricsPort) == true ? true : nil
        }

        try await waitForAddress(id, publicHost: publicHost, readyAt: .now)
        return try await finishOpen(id, record: record)
    }

    // The ports and nginx wait in the queue of the changes. The rest of the start does not. A quick
    // link also takes the port of its metrics server. One cloudflared serves each own-domain link
    // (4h). So that link takes only the port of its share block.
    func openShareBlock(_ id: String, withMetricsPort: Bool) async throws -> (port: Int, metricsPort: Int?) {
        let names = ["share-\(id)"] + (withMetricsPort ? ["share-metrics-\(id)"] : [])

        let ports = try await serialWeb {
            let state = await self.stateStore.current()
            let ports = await self.freePorts(for: names, keeping: [:], from: Self.firstSharePort, in: state)

            try await self.updateShare(id) { record in
                record.port = ports["share-\(id)"] ?? 0
                record.metricsPort = ports["share-metrics-\(id)"]
            }

            _ = try await self.applyWeb(.shares)
            return ports
        }

        let port = ports["share-\(id)"] ?? 0
        let blockAnswers = shareBlockAnswers

        _ = try await poll(id, every: .milliseconds(100), limit: shareWaits.blockLimit, failure: ShareText.portNotOpen(port)) {
            blockAnswers(port) ? true : nil
        }

        return (port, ports["share-metrics-\(id)"])
    }

    // The four steps of each start of cloudflared: the folder, the config file, the command line in
    // the log and the start by the supervisor.
    func startCloudflared(_ definition: ServiceDefinition, config: String, at file: URL, logName: String) async throws {
        try FileManager.default.createDirectory(at: paths.cloudflaredHome, withIntermediateDirectories: true)
        _ = try Self.writeIfChanged(config, to: file)
        writeToLog(of: logName, "$ cloudflared \(definition.arguments.joined(separator: " "))\n")
        try await processSupervisor.start(definition)
    }

    // The end of each start: the state open, the line "is open", the watches and the site list.
    func finishOpen(_ id: String, record: ShareRecord) async throws -> ShareInfo {
        try await updateShare(id) { $0.state = .open }
        activity?.write("share", ShareText.openLine(record.host))

        let state = await stateStore.current()
        watchShareLogs(state)
        await watchLinkRequests()
        startPowerWatch()
        publishSites()

        return shareInfo(state.share(id: id) ?? record)
    }

    // nexusd never asks the resolver of macOS before the link opens. A network can block DNS to
    // 1.1.1.1. Then only the ready check of cloudflared decides (owner, review-4ab question 16).
    func waitForAddress(_ id: String, publicHost: String, readyAt: Date) async throws {
        let waits = shareWaits
        let begin = ContinuousClock.now
        var answered = false

        let found = try await waitFor(limit: waits.addressLimit, every: waits.addressInterval) { () async throws -> AddressWait? in
            try await ensureStarting(id)
            let answer = await shareChecks.resolves(publicHost)

            if answer == true {
                return .resolves
            }

            answered = answered || answer != nil
            return !answered && ContinuousClock.now - begin >= waits.noAnswerLimit ? .noAnswer : nil
        }

        switch found {
        case .resolves?:
            return
        case .noAnswer?:
            try await waitUntil(id, readyAt.addingTimeInterval(waits.openWithoutAnswer.timeInterval))
        case nil:
            throw RuntimeError.unsupported(ShareText.addressFails)
        }
    }

    // Asks until the answer is not nil, while the link starts.
    func poll<Value: Sendable>(_ id: String, every interval: Duration, limit: Duration, failure: String, _ ask: () async -> Value?) async throws -> Value {
        let value = try await waitFor(limit: limit, every: interval) { () async throws -> Value? in
            try await ensureStarting(id)
            return await ask()
        }

        guard let value else {
            throw RuntimeError.unsupported(failure)
        }

        return value
    }

    // Asks until the answer is not nil. nil after the limit. A cancel throws CancellationError. So a
    // caller can tell a cancel from the end of the limit.
    func waitFor<Value: Sendable>(limit: Duration, every interval: Duration, _ ask: () async throws -> Value?) async throws -> Value? {
        let deadline = ContinuousClock.now + limit

        while true {
            if let value = try await ask() {
                return value
            }

            try Task.checkCancellation()
            let left = deadline - ContinuousClock.now

            guard left > .zero else {
                return nil
            }

            try await Task.sleep(for: min(interval, left))
        }
    }

    private func waitUntil(_ id: String, _ end: Date) async throws {
        while Date.now < end {
            try await ensureStarting(id)
            try? await Task.sleep(for: min(shareWaits.poll, .milliseconds(Int(max(end.timeIntervalSinceNow, 0) * 1_000) + 1)))
        }

        try await ensureStarting(id)
    }

    // Changes one record in one update of the state, only while the link starts. The update holds
    // the checks of ensureStarting.
    func updateShare(_ id: String, _ change: @Sendable (inout ShareRecord) -> Void) async throws {
        let stopped = stoppedStarts

        let reason = try await stateStore.update { state -> ShareEndReason? in
            guard let index = state.shares.firstIndex(where: { $0.id == id }) else {
                return .stopped
            }

            if let reason = Self.startEnd(of: state.shares[index]) ?? stopped[state.shares[index].host] {
                return reason
            }

            change(&state.shares[index])
            return nil
        }

        if let reason {
            throw ShareEndedDuringStart(reason: reason)
        }
    }

    // The one check of each step of a start (4b to 4f). A stop can come before the record exists
    // or while stopShare reads the state. It then holds only in stoppedStarts. openShare ends the
    // record with its reason.
    func ensureStarting(_ id: String) async throws {
        let record = await stateStore.current().share(id: id)

        if let reason = Self.startEnd(of: record) ?? record.flatMap({ stoppedStarts[$0.host] }) {
            throw ShareEndedDuringStart(reason: reason)
        }
    }

    // nil while the link starts. A record that went or that opened counts as a stop.
    private static func startEnd(of record: ShareRecord?) -> ShareEndReason? {
        switch record?.state {
        case .starting?:
            nil
        case .ended(let reason)?:
            reason
        case .open?, nil:
            .stopped
        }
    }

    // The cloudflared of a quick link. A new tunnel gets a new address. So the supervisor does not
    // start it again.
    func cloudflaredDefinition(_ record: ShareRecord, binary: URL, metricsPort: Int) -> ServiceDefinition {
        cloudflaredDefinition(
            id: "share\n\(record.id)",
            displayName: "cloudflared for \(record.host)",
            binary: binary,
            arguments: CloudflaredConfig.quickLinkArguments(config: paths.cloudflaredConfig, metricsPort: metricsPort, port: record.port),
            metricsPort: metricsPort,
            logFile: paths.tunnelLog(record.host),
            restartsAfterExit: false
        )
    }

    // Each cloudflared of Nexus (4b and 4h). The definition has no activityName. So the supervisor
    // writes no line with the share id. cloudflared gets the HOME of Nexus and a config file of
    // Nexus (owner, 2026-11-17). The marker lets a new start of nexusd end it after a crash. A key
    // goes into the environment, never on the command line.
    func cloudflaredDefinition(id: String, displayName: String, binary: URL, arguments: [String], metricsPort: Int, logFile: URL, key: [String: String] = [:], restartsAfterExit: Bool) -> ServiceDefinition {
        ServiceDefinition(
            id: id,
            displayName: displayName,
            executable: binary,
            arguments: arguments,
            environment: ["HOME": paths.cloudflaredHome.path(percentEncoded: false), Self.processMarker: processMarkerValue].merging(key) { first, _ in first },
            workingDirectory: paths.cloudflaredHome,
            ports: [metricsPort],
            logFile: logFile,
            stopTimeout: .seconds(5),
            restartsAfterExit: restartsAfterExit
        )
    }
}

// MARK: The end

extension NexusEngine {
    func stopShare(host: String) async -> String {
        let state = await stateStore.current()
        let target = try? shareTarget(naming: host, in: state)

        guard let record = activeShare(naming: host, in: state) else {
            guard let target, shareStarts[target.host] != nil else {
                return ShareText.noOpenLink(host)
            }

            stoppedStarts[target.host] = .stopped

            // The start can add its record during the read of the state above.
            if let added = await stateStore.current().shares.first(where: { $0.host == target.host && $0.state.isActive }) {
                await endShares([added.id], reason: .stopped)
            }

            return ShareText.linkStopped(target.host)
        }

        await endShares([record.id], reason: .stopped)
        return ShareText.linkStopped(record.host)
    }

    // The quit of the app sends appQuit. The alert before the quit is part of 4g (owner,
    // review-4ab question 1).
    func stopAllShares(reason: ShareEndReason) async -> String {
        let ids = await activeShareIDs()

        for host in shareStarts.keys {
            stoppedStarts[host] = reason
        }

        guard !ids.isEmpty else {
            return ShareText.noLinkOpen
        }

        await endShares(ids, reason: reason)
        return ShareText.stoppedLinks(ids.count)
    }

    // Ends links (overview, "The flow of one link", step 10). The record keeps the reason until the
    // next link of its host. It keeps no port, no program, no password and no address. holdsWebQueue
    // is true when the caller holds the queue of the changes. Then a call of serialWeb would wait for
    // itself. The end does not wait for the new rules of the own domain. So the stop of a link shows
    // at once. The rules can also take a port in the queue of the changes.
    func endShares(_ ids: [String], reason: ShareEndReason, holdsWebQueue: Bool = false) async {
        let taken = ids.filter { endingShares.insert($0).inserted }

        guard !taken.isEmpty else {
            return
        }

        defer { endingShares.subtract(taken) }

        let ended = (try? await stateStore.update { state in
            Self.end(&state.shares, ids: Set(taken), reason: reason)
        }) ?? []

        guard !ended.isEmpty else {
            return
        }

        for record in ended {
            await shareEnded(record)
        }

        let programs = ended.compactMap { sharePrograms[$0.id]?.processID }
        let supervisor = processSupervisor

        await withTaskGroup { group in
            for program in programs {
                group.addTask {
                    try? await supervisor.stop(program, cause: reason.logText)
                }
            }
        }

        // A failure of nginx does not stop the end.
        if holdsWebQueue {
            _ = try? await applyWeb(.shares)
        } else {
            _ = try? await serialWeb { try await self.applyWeb(.shares) }
        }

        if ended.contains(where: { $0.options.address == .ownDomain }) {
            ownDomainLinksChanged()
        }

        for record in ended {
            forgetShare(record)
            activity?.write("share", Self.endLine(of: record, reason: reason))
        }

        watchShareLogs(await stateStore.current())
        await watchLinkRequests()
        publishSites()
    }

    // A stop of nexusd ends each quick link. Its address does not come back (overview, 4b). The
    // programs ended with nexusd. An own-domain link stays for 4h. An ended record of a host that
    // Nexus no longer has goes.
    func endSharesOfEarlierRun() async {
        let state = await stateStore.current()

        guard !state.shares.isEmpty else {
            return
        }

        let hosts = Set(shareTargets(state).keys)
        let quick = Set(state.shares.filter { $0.state.isActive && $0.options.address == .random }.map(\.id))

        let ended = (try? await stateStore.update { state -> [ShareRecord] in
            let ended = Self.end(&state.shares, ids: quick, reason: .nexusdStopped)
            state.shares.removeAll { !$0.state.isActive && !hosts.contains($0.host) }
            return ended
        }) ?? []

        for record in ended {
            await shareEnded(record)
            forgetShare(record)
            activity?.write("share", Self.endLine(of: record, reason: .nexusdStopped))
        }

        if state.shares.contains(where: { $0.state.isActive && !quick.contains($0.id) }) {
            watchShareLogs(await stateStore.current())
            startShareChecks()
        }
    }

    // Returns the records as they were before the end.
    private static func end(_ shares: inout [ShareRecord], ids: Set<String>, reason: ShareEndReason) -> [ShareRecord] {
        var ended: [ShareRecord] = []

        for index in shares.indices where ids.contains(shares[index].id) && shares[index].state.isActive {
            ended.append(shares[index])
            shares[index].state = .ended(reason)
            shares[index].password = nil
            shares[index].publicHost = nil
            shares[index].port = 0
            shares[index].metricsPort = nil
        }

        return ended
    }

    private static func endLine(of record: ShareRecord, reason: ShareEndReason) -> String {
        record.state == .open ? ShareText.stoppedLine(record.host, reason: reason) : ShareText.notOpenedLine(record.host, reason: reason)
    }

    // The files of a link hold its id, its visitors and its password. They go at its end.
    private func forgetShare(_ record: ShareRecord) {
        for file in [paths.shareVisitorLog(record.id), paths.shareRequestLog(record.id), paths.sharePasswordFile(record.id)] {
            try? FileManager.default.removeItem(at: file)
        }

        sharePrograms[record.id] = nil
        shareVisits[record.id] = nil
        notReadySince[record.id] = nil
        wakeChecks.remove(record.id)
        forgetShareHosts(record.id)
    }

    // A program that fails ends its link. The supervisor does not start cloudflared again. A 429 of
    // api.trycloudflare.com makes cloudflared exit at its start (research 5, fact 7).
    func shareProgramsChanged() async {
        await ownDomainProgramChanged()

        guard !sharePrograms.isEmpty else {
            return
        }

        let state = await stateStore.current()
        var failures: [(id: String, text: String)] = []

        for (id, program) in sharePrograms {
            guard case .failed? = await processSupervisor.state(of: program.processID), let record = state.shares.first(where: { $0.id == id }), record.state.isActive else {
                continue
            }

            let log = paths.tunnelLog(record.host)
            let tail = TerminalOutput.tail(of: log, lines: 30)

            if tail.contains(where: { $0.range(of: #"\b429\b"#, options: .regularExpression) != nil }) {
                failures.append((id, ShareText.tooManyLinks))
            } else if record.state == .open {
                failures.append((id, ShareText.cloudflaredStopped(log: log.path(percentEncoded: false))))
            } else {
                failures.append((id, ShareText.stoppedBeforeOpen(log: log.path(percentEncoded: false))))
            }
        }

        for failure in failures {
            await endShares([failure.id], reason: .failed(failure.text))
        }
    }
}

// MARK: The web configuration

extension NexusEngine {
    // The records with a share block: active, with their ports and with a host that Nexus has.
    func linkedShares(_ state: EngineState, targets: [String: ShareTarget]) -> [ShareRecord] {
        state.shares.filter { $0.state.isActive && $0.port != 0 && targets[$0.host] != nil }
    }

    // phpLine is the PHP version of a PHP site in nginx or in Apache. Only such a site gets the pool
    // nexus-share (4d).
    func siteShare(for host: String, in linked: [ShareRecord], phpLine: String?) -> SiteShare? {
        linked.first { $0.host == host }.map { record in
            SiteShare(id: record.id, fastcgiValues: shareFastCGIValues(of: record).merging(ShareProtection.fastcgiValues(for: record.options)) { _, protection in protection }, shareSocket: shareSocket(for: record, phpLine: phpLine))
        }
    }

    // site is the site block of the host of the link, when that host runs.
    func shareBlock(for record: ShareRecord, site: WebSite?) -> ShareBlock {
        ShareBlock(
            id: record.id,
            host: record.host,
            port: record.port,
            mode: record.mode,
            options: record.options,
            redirectHost: shareHostPlans[record.id]?.redirectHost,
            extraHosts: shareHostPlans[record.id]?.extraHosts ?? [],
            reverb: shareHostPlans[record.id]?.reverb,
            vite: shareViteTarget(for: record, site: site),
            passwordFile: record.password == nil ? nil : paths.sharePasswordFile(record.id),
            visitorLog: paths.shareVisitorLog(record.id),
            requestLog: record.options.keepsRequests ? paths.shareRequestLog(record.id) : nil,
            rewriteScript: paths.shareScript(record.id),
            debugPaths: record.options.hidesErrors ? Self.shareDebugPaths(site: site) : [],
            composerInDocumentRoot: Self.composerInDocumentRoot(site: site)
        )
    }

    // A removal of the site or the workspace, a new host and a new TLD end its link. The task waits
    // for the queue of the changes. So the share block of such a link is gone already.
    func endSharesOfGoneHosts(_ state: EngineState, targets: [String: ShareTarget]) {
        let gone = state.shares.filter { $0.state.isActive && targets[$0.host] == nil }.map(\.id)

        guard !gone.isEmpty else {
            return
        }

        Task { await self.endShares(gone, reason: .siteGone) }
    }
}

// MARK: The visitors

extension NexusEngine {
    // Only the logs of the active links.
    func watchShareLogs(_ state: EngineState) {
        let active = state.shares.filter(\.state.isActive)

        guard !active.isEmpty || shareLogWatch != nil else {
            return
        }

        let watch = shareLogWatch ?? ShareLogWatch { [weak self] id, lines in
            Task { await self?.linkLinesArrived(id: id, lines: lines.map(\.line)) }
        }

        shareLogWatch = watch
        watch.watch(Dictionary(active.map { (paths.shareVisitorLog($0.id).path(percentEncoded: false), $0.id) }) { first, _ in first })
    }

    // A visitor is one address of CF-Connecting-IP (owner, review-4ab question 18). The site list
    // changes only when the count or the minute of the last visit changes.
    func linkLinesArrived(id: String, lines: [ShareLogLine], now: Date = .now) async {
        let state = await stateStore.current()

        guard let record = state.shares.first(where: { $0.id == id }), record.state.isActive else {
            return
        }

        let before = shareVisits[id] ?? ShareVisits()
        var visits = before

        visits.visitors.formUnion(lines.map(\.visitor).filter { !$0.isEmpty })
        visits.last = now
        shareVisits[id] = visits

        // A link of the own domain (4h) has no program of its own. It finds its owner through its
        // target.
        let owner = sharePrograms[id]?.owner ?? shareTargets(state)[record.host]?.owner

        if let owner, now.timeIntervalSince(linkPageTimes[owner] ?? .distantPast) >= 1 {
            await linkRequested(by: owner, now: now)
        }

        if visits.visitors.count != before.visitors.count || Self.wholeMinute(of: visits.last) != Self.wholeMinute(of: before.last) {
            publishSiteList()
        }
    }

    // A request through a link is a page of its owner (overview, 4b). It starts a stopped workspace
    // and the programs that start with a page. A link with Build starts no dev server (4e, the guard
    // of devServerProcesses).
    func linkRequested(by owner: String, now: Date = .now) async {
        linkPageTimes[owner] = now
        await pageRequested(by: owner, now: now)
    }
}

// MARK: The checks

extension NexusEngine {
    // The loop runs while a link starts or is open. A link without a program also needs its end
    // time. Each new record and the start of nexusd with an active record start the loop.
    func startShareChecks() {
        guard shareCheck == nil else {
            return
        }

        shareCheck = Task { [weak self, interval = shareCheckInterval] in
            while (try? await Task.sleep(for: interval)) != nil, let engine = self, await engine.checkSharesAgain() {}
        }
    }

    // A record can come during the read of the state. Its start then found the loop and started no
    // new loop. So the loop ends first and reads the state again.
    private func checkSharesAgain() async -> Bool {
        await checkShares()

        guard await activeShareIDs().isEmpty else {
            return true
        }

        shareCheck = nil

        if await !activeShareIDs().isEmpty {
            startShareChecks()
        }

        return false
    }

    // The ready check of each link at the same time. A check without an answer gives nil.
    private func readiness(of records: [ShareRecord]) async -> [(record: ShareRecord, ready: Bool?)] {
        let checks = shareChecks

        let answers = await withTaskGroup(of: (record: ShareRecord, ready: Bool?).self) { group in
            for record in records {
                guard let port = record.metricsPort else {
                    continue
                }

                group.addTask {
                    (record, await checks.isReady(port))
                }
            }

            var answers: [(record: ShareRecord, ready: Bool?)] = []

            for await answer in group {
                answers.append(answer)
            }

            return answers
        }

        return answers.sorted { $0.record.id < $1.record.id }
    }

    // The end time ends a link within one interval. At most each minute, each open quick link reads
    // /ready. A link without a connection for shareConnectionLimit ends only when 1.1.1.1 says that
    // its host has no address. No answer never ends a link.
    func checkShares(now: Date = .now) async {
        let state = await stateStore.current()
        let due = state.shares.filter { record in
            record.state == .open && record.endsAt.map { $0 <= now } == true
        }.map(\.id)

        if !due.isEmpty {
            await endShares(due, reason: .endTime)
        }

        guard now.timeIntervalSince(lastConnectionCheck) >= shareWaits.connectionInterval.timeInterval else {
            return
        }

        lastConnectionCheck = now
        var lost: [String] = []
        let checked = state.shares.filter { record in
            record.state == .open && record.options.address == .random && !due.contains(record.id) && !wakeChecks.contains(record.id)
        }

        for (record, ready) in await readiness(of: checked) {
            switch ready {
            case true?:
                notReadySince[record.id] = nil
            case false?:
                let since = notReadySince[record.id] ?? now
                notReadySince[record.id] = since

                if now.timeIntervalSince(since) >= shareConnectionLimit, let host = record.publicHost, await shareChecks.resolves(host) == false {
                    lost.append(record.id)
                }
            case nil:
                break
            }
        }

        if !lost.isEmpty {
            await endShares(lost, reason: .connectionLost)
        }
    }

    // One watch for the life of nexusd, after the first open link. An open link does not keep the
    // Mac awake (decision 6).
    func startPowerWatch() {
        guard powerWatch == nil else {
            return
        }

        let watch = SystemPowerWatch { [weak self] event in
            guard event == .didWake else {
                return
            }

            Task { await self?.sharesAfterWake(at: .now) }
        }

        powerWatch = watch
        _ = watch.start()
    }

    // The check after a wake (research 5, "What Nexus must do in all cases"). A short sleep keeps the
    // tunnel. Cloudflare removes a quick tunnel after a long sleep. cloudflared then tries again
    // without an end. So /ready stays 503 and 1.1.1.1 has no address for the host. 10 minutes after
    // the wake the check each minute takes over.
    func sharesAfterWake(at wake: Date) async {
        let ids = await stateStore.current().shares.filter { record in
            record.state == .open && record.options.address == .random && !wakeChecks.contains(record.id)
        }.map(\.id)

        guard !ids.isEmpty else {
            return
        }

        let waits = shareWaits
        var waiting = Set(ids)
        wakeChecks.formUnion(ids)

        // A cancel ends the checks as the end of the wait does.
        do {
            try await Task.sleep(for: waits.firstWakeCheck)
            let left = waits.wakeEnd - .seconds(Date.now.timeIntervalSince(wake))

            _ = try await waitFor(limit: left, every: waits.wakeInterval) { () async -> Bool? in
                await checkAfterWake(&waiting, wake: wake)
                return waiting.isEmpty ? true : nil
            }
        } catch {}

        for id in waiting {
            notReadySince[id] = wake
            wakeChecks.remove(id)
        }
    }

    // One check of the links in waiting. A link that is ready or that ended leaves waiting.
    private func checkAfterWake(_ waiting: inout Set<String>, wake: Date) async {
        let state = await stateStore.current()
        var lost: [String] = []
        var checked: [ShareRecord] = []

        for id in waiting.sorted() {
            guard let record = state.share(id: id), record.state == .open, record.metricsPort != nil else {
                waiting.remove(id)
                wakeChecks.remove(id)
                continue
            }

            checked.append(record)
        }

        for (record, ready) in await readiness(of: checked) {
            let id = record.id

            switch ready {
            case true?:
                notReadySince[id] = nil
                waiting.remove(id)
                wakeChecks.remove(id)
            case false?:
                if Date.now.timeIntervalSince(wake) >= shareWakeLimit, let host = record.publicHost, await shareChecks.resolves(host) == false {
                    lost.append(id)
                }
            case nil:
                break
            }
        }

        if !lost.isEmpty {
            waiting.subtract(lost)
            await endShares(lost, reason: .sleep)
        }
    }
}
