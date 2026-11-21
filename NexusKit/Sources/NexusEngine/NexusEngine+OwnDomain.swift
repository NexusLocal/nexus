import Foundation
import NexusConfig
import NexusCore
import NexusDNS
import NexusIPC
import NexusRuntime
import NexusSupervisor
import NexusTLS
import SystemConfiguration

// The own domain (group 4, 4h). The setup, one cloudflared for all own-domain links, the DNS
// records and Disconnect. Way R applies: a remotely managed tunnel (check E, decisions.md
// 2026-11-20). The login runs with the HOME of ownDomainFolder and with the --config of Nexus. So
// the ~/.cloudflared of the user never changes. The tunnel, its rules and the DNS records go
// through the API of Cloudflare with the key of the login. So the cert is never a file after the
// login.

// A setup that runs or that failed (group 4, 4h). A connected domain is in EngineState.ownDomain.
// The task of a setup changes ownDomainSetup only while the id is the same.
struct OwnDomainSetup: Sendable {
    let id = UUID()
    let domain: String
    var state: OwnDomainState
    var task: Task<Void, Never>?
}

// The cloudflared of the own-domain links. rules maps each public host to the port of its share
// block. takenPorts holds these ports until new rules or the stop. So no new link gets a port that
// cloudflared can still send a visitor to.
struct OwnDomainTunnel: Sendable, Equatable {
    let processID: String
    let metricsPort: Int
    let rules: [String: Int]
}

// The seams of the own domain. A test gives its own answers and a short time limit. configLimit is
// the wait for new rules in a tunnel that runs.
struct OwnDomainSeams: Sendable {
    var nameservers: @Sendable (String) async -> [String]?
    var computerName: @Sendable () -> String
    var api: CloudflareAPI
    var configVersion: @Sendable (Int) async -> Int?
    var loginLimit: Duration = .seconds(660)
    var configLimit: Duration = .seconds(30)

    static let live = OwnDomainSeams(
        nameservers: { await PublicDNSLookup.nameservers(of: $0) },
        computerName: { (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "" },
        api: .live,
        configVersion: { await CloudflaredMetrics.configVersion(port: $0) }
    )
}

// MARK: The queue, the files and the keys

extension NexusEngine {
    static let ownDomainLogName = "cloudflared-own-domain"
    static let ownDomainMetricsName = "own-domain-metrics"

    // Runs one change at Cloudflare or of the tunnel at a time, as serialWeb. A caller never waits for
    // the queue while it holds the queue.
    func serialOwnDomain<Result: Sendable>(_ operation: @escaping @Sendable () async throws -> Result) async throws -> Result {
        try await ownDomainQueue.run(operation).value
    }

    // The leftovers of a stop of nexusd during the login: the cert file and the login log.
    func removeOwnDomainLeftovers() {
        for file in [paths.ownDomainLoginCert, paths.ownDomainLoginLog] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // The connected domain while no Disconnect runs. Else the text of 4g that names the setup.
    func usableOwnDomain(_ state: EngineState) throws -> OwnDomainRecord {
        guard let domain = state.ownDomain, !ownDomainLeaving else {
            throw RuntimeError.unsupported(ShareText.ownDomainMissing)
        }

        return domain
    }

    // The cert of the Keychain. No key gives text 11.
    func ownDomainCert() throws -> CloudflareCert {
        guard let data = try? cloudflareKeys.read(.cert), let cert = CloudflareCert.parse(data) else {
            throw RuntimeError.unsupported(ShareText.OwnDomain.keyMissing)
        }

        return cert
    }

    private func removeOwnDomainKeys() {
        for key in CloudflareKey.allCases {
            try? cloudflareKeys.remove(key)
        }
    }

    private func writeToOwnDomainLog(_ line: String) {
        writeToLog(of: Self.ownDomainLogName, "\(line)\n")
    }

    private var ownDomainLogPath: String {
        paths.ownDomainTunnelLog.path(percentEncoded: false)
    }

    private func ownDomainBinary() async throws -> URL {
        if let installed = await usableCloudflared() {
            return CloudflaredPackage.binary(in: installed.folder)
        }

        return try await prepareCloudflared(onDownload: {})
    }

    // The active links on the own domain.
    static func ownDomainShares(_ state: EngineState) -> [ShareRecord] {
        state.shares.filter { $0.state.isActive && $0.options.address == .ownDomain }
    }
}

// MARK: The check and the setup

extension NexusEngine {
    // Step 1 of the sheet. A text that is not a domain gives text 1.
    func checkOwnDomain(_ text: String) async throws -> OwnDomainCheck {
        let tld = await stateStore.current().tld

        guard let domain = OwnDomainName.domain(text, tld: tld) else {
            throw RuntimeError.unsupported(ShareText.OwnDomain.notADomain)
        }

        let names = await ownDomainSeams.nameservers(domain)
        let usesCloudflare = names.map { found in !found.isEmpty && found.allSatisfy { $0.lowercased().hasSuffix(".ns.cloudflare.com") } }

        return OwnDomainCheck(domain: domain, usesCloudflare: usesCloudflare, nameservers: names ?? [])
    }

    // Answers at once with the text of step 2. The progress comes in SiteList.ownDomain. A second
    // connect of the same domain while it connects gives the same answer and starts nothing.
    func connectOwnDomain(_ text: String) async throws -> String {
        let state = await stateStore.current()

        guard let domain = OwnDomainName.domain(text, tld: state.tld) else {
            throw RuntimeError.unsupported(ShareText.OwnDomain.notADomain)
        }

        if let connected = state.ownDomain {
            throw RuntimeError.unsupported(ShareText.OwnDomain.inUse(connected.domain))
        }

        if let setup = ownDomainSetup, setup.domain == domain, case .connecting = setup.state, setup.task?.isCancelled != true {
            return ShareText.OwnDomain.connectSteps(domain)
        }

        // The new setup owns the sheet at once. Its task waits for the cleanup of the setup before
        // it. So two setups never use the files and the keys at the same time.
        let previous = ownDomainSetup?.task
        previous?.cancel()

        let setup = OwnDomainSetup(domain: domain, state: .connecting(loginPage: nil))
        ownDomainSetup = setup
        ownDomainSetup?.task = Task {
            await previous?.value
            await self.runOwnDomainSetup(domain, id: setup.id)
        }

        publishSiteList()
        return ShareText.OwnDomain.connectSteps(domain)
    }

    // The cancel stops the login. The task then removes what the setup made.
    func cancelOwnDomain() async -> String {
        guard let setup = ownDomainSetup else {
            return ShareText.OwnDomain.noSetup
        }

        setup.task?.cancel()
        await setup.task?.value

        if ownDomainSetup?.id == setup.id {
            ownDomainSetup = nil
        }

        publishSiteList()
        return ShareText.OwnDomain.setupStopped(setup.domain)
    }

    // The stop of nexusd waits a short time for the cleanup of a setup: the delete of its new
    // tunnel and of its keys. The task of the newest setup ends after the tasks of the setups before
    // it. A setup that does not end within the limit runs on.
    func stopOwnDomainSetup(within limit: Duration) async {
        guard let task = ownDomainSetup?.task else {
            return
        }

        task.cancel()

        let (ended, end) = AsyncStream<Void>.makeStream()
        let limitTask = Task {
            try? await Task.sleep(for: limit)
            end.finish()
        }

        Task {
            await task.value
            end.finish()
        }

        for await _ in ended {}
        limitTask.cancel()
    }

    private func showOwnDomainSetup(_ id: UUID, _ state: OwnDomainState) {
        guard ownDomainSetup?.id == id else {
            return
        }

        ownDomainSetup?.state = state
        publishSiteList()
    }

    // The steps of the setup (contract 4h, "The setup"). A failure or a cancel after the new tunnel
    // deletes that tunnel. Each failure and each cancel removes both keys. A setup that a newer
    // connect cancelled before its start makes nothing and removes nothing. The setup before this
    // one can connect its domain after the check of connectOwnDomain. This setup then makes nothing.
    // So it never changes the keys of that domain.
    private func runOwnDomainSetup(_ domain: String, id: UUID) async {
        guard !Task.isCancelled else {
            return
        }

        guard await stateStore.current().ownDomain == nil else {
            if ownDomainSetup?.id == id {
                ownDomainSetup = nil
            }

            publishSiteList()
            return
        }

        var keyMade = false
        var madeTunnel: (id: String, name: String, cert: CloudflareCert)?

        do {
            let binary = try await ownDomainBinary()
            removeOwnDomainLeftovers()
            try prepareOwnDomainFolder()

            let pem = try await loginAtCloudflare(binary: binary, setup: id)
            keyMade = true

            guard let cert = CloudflareCert.parse(pem) else {
                throw RuntimeError.unsupported(ShareText.OwnDomain.noKey)
            }

            try await checkZone(of: cert, domain: domain)
            try saveOwnDomainKey(pem, as: .cert)

            let api = ownDomainSeams.api
            let made = try await createOwnDomainTunnel(NexusVariant.current.tunnelName(computer: ownDomainSeams.computerName()), cert: cert)
            madeTunnel = (made.id, made.name, cert)
            try Task.checkCancellation()

            let token: Data

            do {
                token = try await api.tunnelToken(cert.accountID, made.id, cert.apiToken)
            } catch {
                try Task.checkCancellation()
                writeToOwnDomainLog("Nexus did not get the token of the tunnel \(made.name): \(error)")
                throw RuntimeError.unsupported(ShareText.OwnDomain.tunnelNotMade(made.name, log: ownDomainLogPath))
            }

            try saveOwnDomainKey(token, as: .tunnel)

            // A newer connect or Cancel can come while this setup waits for the state. The check in
            // the update makes sure that a cancelled setup never writes the domain.
            let written = try await stateStore.update { state -> Bool in
                guard !Task.isCancelled else {
                    return false
                }

                state.ownDomain = OwnDomainRecord(domain: domain, tunnelID: made.id, tunnelName: made.name, metricsPort: 0)
                return true
            }

            guard written else {
                throw CancellationError()
            }

            madeTunnel = nil

            if ownDomainSetup?.id == id {
                ownDomainSetup = nil
            }

            activity?.write("share", ShareText.OwnDomain.connectedLine(domain, tunnel: made.name))
            publishSiteList()
        } catch {
            let cancelled = Task.isCancelled
            removeOwnDomainLeftovers()

            if let madeTunnel {
                await removeTunnelOfSetup(domain, id: madeTunnel.id, name: madeTunnel.name, cert: madeTunnel.cert)
            }

            removeOwnDomainKeys()

            guard !cancelled else {
                return
            }

            showOwnDomainSetup(id, .failed(ErrorText.plain(error), keyMade: keyMade))
        }
    }

    private func prepareOwnDomainFolder() throws {
        let folder = paths.ownDomainFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path(percentEncoded: false))
        _ = try Self.writeIfChanged(CloudflaredConfig.commandFile, to: paths.ownDomainCommandConfig)
    }

    // cloudflared opens the browser itself and writes the address of the login page to its log.
    // The login ends at the time limit or at a cancel, because the end of the child task stops
    // cloudflared. cloudflared can also stop its wait for the click itself, before the time limit.
    // nexusd reads the cert file and not the exit code (research 6 section 2). The cert file goes
    // at once.
    private func loginAtCloudflare(binary: URL, setup: UUID) async throws -> Data {
        let log = paths.ownDomainLoginLog
        let folder = paths.ownDomainFolder.path(percentEncoded: false)
        let limit = ownDomainSeams.loginLimit
        let poll = shareWaits.poll

        guard FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RuntimeError.unsupported(ShareText.OwnDomain.noKey)
        }

        let command = Command(
            executable: binary,
            arguments: CloudflaredConfig.loginArguments(config: paths.ownDomainCommandConfig),
            environment: ["HOME": folder, Self.processMarker: processMarkerValue],
            workingDirectory: paths.ownDomainFolder,
            name: "cloudflared"
        )

        let noClick = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await CommandRunner.run(command, appendingTo: log)
                return CloudflaredOutput.loginWaitEnded(in: (try? String(contentsOf: log, encoding: .utf8)) ?? "")
            }

            group.addTask {
                await self.watchLoginPage(log, setup: setup, limit: limit, poll: poll)
            }

            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        try Task.checkCancellation()
        defer { removeOwnDomainLeftovers() }

        guard let pem = try? Data(contentsOf: paths.ownDomainLoginCert), !pem.isEmpty else {
            throw RuntimeError.unsupported(noClick ? ShareText.OwnDomain.loginTimedOut : ShareText.OwnDomain.noKey)
        }

        return pem
    }

    // true after the time limit. The sheet gets the address of the login page once.
    private func watchLoginPage(_ log: URL, setup: UUID, limit: Duration, poll: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit

        let page: String?

        do {
            page = try await waitFor(limit: limit, every: poll) { () -> String? in
                (try? String(contentsOf: log, encoding: .utf8)).flatMap(CloudflaredOutput.loginPage(in:))
            }
        } catch {
            return false
        }

        guard let page else {
            return true
        }

        showOwnDomainSetup(setup, .connecting(loginPage: page))

        do {
            try await Task.sleep(until: deadline, clock: .continuous)
        } catch {
            return false
        }

        return true
    }

    // The user can select another domain at Cloudflare (owner, question 2).
    private func checkZone(of cert: CloudflareCert, domain: String) async throws {
        let zone: String

        do {
            zone = try await ownDomainSeams.api.zoneName(cert.zoneID, cert.apiToken)
        } catch let error as CloudflareAPIError {
            try Task.checkCancellation()
            writeToOwnDomainLog("Nexus did not read the domain of the key: \(error)")

            switch error {
            case .refused, .notFound:
                throw RuntimeError.unsupported(ShareText.OwnDomain.noKey)
            case .conflict, .failed, .noAnswer:
                throw RuntimeError.unsupported(ShareText.OwnDomain.noAnswer)
            }
        }

        guard zone.lowercased() == domain else {
            throw RuntimeError.unsupported(ShareText.OwnDomain.otherDomain(selected: zone.lowercased(), asked: domain))
        }
    }

    private func saveOwnDomainKey(_ data: Data, as key: CloudflareKey) throws {
        do {
            try cloudflareKeys.save(data, as: key)
        } catch {
            throw RuntimeError.unsupported(ShareText.OwnDomain.keyNotSaved(ErrorText.plain(error)))
        }
    }

    // A name that exists gives the name with -2, then -3, up to -9. A cancel does not stop the call
    // of the API. Cloudflare can make the tunnel after a cancel. With its id the setup can delete it.
    private func createOwnDomainTunnel(_ base: String, cert: CloudflareCert) async throws -> (id: String, name: String) {
        let api = ownDomainSeams.api

        for name in [base] + (2...9).map({ "\(base)-\($0)" }) {
            do {
                let id = try await Task { try await api.createTunnel(cert.accountID, name, cert.apiToken) }.value
                return (id, name)
            } catch CloudflareAPIError.conflict {
                continue
            } catch {
                try Task.checkCancellation()
                writeToOwnDomainLog("Nexus did not make the tunnel \(name): \(error)")
                throw RuntimeError.unsupported(ShareText.OwnDomain.tunnelNotMade(base, log: ownDomainLogPath))
            }
        }

        writeToOwnDomainLog("Nexus did not make the tunnel \(base): the names \(base) to \(base)-9 exist.")
        throw RuntimeError.unsupported(ShareText.OwnDomain.tunnelNotMade(base, log: ownDomainLogPath))
    }

    // A cancel stops the calls of a task. So the delete runs in a task of its own.
    private func removeTunnelOfSetup(_ domain: String, id: String, name: String, cert: CloudflareCert) async {
        let api = ownDomainSeams.api

        let deleted = await Task {
            do {
                try await api.deleteTunnel(cert.accountID, id, cert.apiToken)
                return true
            } catch CloudflareAPIError.notFound {
                return true
            } catch {
                return false
            }
        }.value

        activity?.write("share", deleted ? ShareText.OwnDomain.setupTunnelDeletedLine(domain, tunnel: name) : ShareText.OwnDomain.setupTunnelKeptLine(domain, tunnel: name))
    }

    // SiteList.ownDomain: the connected domain, else a setup that runs or that failed.
    func ownDomainInfo(_ state: EngineState) -> OwnDomainInfo? {
        if let domain = state.ownDomain {
            return OwnDomainInfo(domain: domain.domain, tunnelName: domain.tunnelName, state: .connected, addresses: domain.dnsRecords.sorted())
        }

        return ownDomainSetup.map { OwnDomainInfo(domain: $0.domain, state: $0.state) }
    }
}

// MARK: The links

extension NexusEngine {
    // The label of a link of target. asked is the label of the sheet or of nexus share. Without it the
    // label of labels[target.host] applies, else defaultLabel with -2 to -9 when another host of Nexus
    // has the label. A host that Nexus no longer has gives its label free.
    func ownDomainLabel(for target: ShareTarget, asked: String?, in state: EngineState, targets: [String: ShareTarget]) throws -> String {
        try Self.ownDomainLabel(for: target, asked: asked, domain: usableOwnDomain(state), in: state, targets: targets)
    }

    // The same choice for a connected domain. The reservation of a start uses it in its update of
    // the state.
    static func ownDomainLabel(for target: ShareTarget, asked: String?, domain: OwnDomainRecord, in state: EngineState, targets: [String: ShareTarget]) throws -> String {
        let holder = { (label: String) in
            Self.activeLabelHolder(label, besides: target.host, in: state)
                ?? domain.labels.sorted { $0.key < $1.key }.first { $0.value == label && $0.key != target.host && targets[$0.key] != nil }?.key
        }

        if let asked {
            if let problem = OwnDomainName.labelProblem(asked) {
                throw RuntimeError.unsupported(problem)
            }

            if let host = holder(asked) {
                throw RuntimeError.unsupported(ShareText.OwnDomain.labelInUse(host: host, address: OwnDomainName.address(label: asked, domain: domain.domain)))
            }

            return asked
        }

        if let own = domain.labels[target.host] {
            return own
        }

        let base = OwnDomainName.defaultLabel(of: target.host)

        if let problem = OwnDomainName.labelProblem(base) {
            throw RuntimeError.unsupported(problem)
        }

        let candidates = [base] + (2...9).map { "\(base)-\($0)" }

        guard let free = candidates.first(where: { OwnDomainName.labelProblem($0) == nil && holder($0) == nil }) else {
            let host = holder(base) ?? target.host
            throw RuntimeError.unsupported(ShareText.OwnDomain.labelInUse(host: host, address: OwnDomainName.address(label: base, domain: domain.domain)))
        }

        return free
    }

    // The host of another active own-domain link with this label. A link that starts has its label
    // before its record at Cloudflare.
    static func activeLabelHolder(_ label: String, besides host: String, in state: EngineState) -> String? {
        ownDomainShares(state).first { $0.host != host && $0.label == label }?.host
    }

    // The start of an own-domain link after prepareShare (group 4, 4h). hosts are the local hosts of
    // Nexus. The DNS record and the build come at the same time. The first failure ends the start at
    // once and cancels the other work. The start waits for the end of that work.
    func runOwnDomainShare(_ record: ShareRecord, target: ShareTarget, project: ShareProject?, hosts: Set<String>) async throws -> ShareInfo {
        let id = record.id

        _ = try await openShareBlock(id, withMetricsPort: false)

        // The build comes before the rule. So no visitor gets a page without its styles.
        try await withThrowingTaskGroup { group in
            group.addTask { try await self.routeInOwnDomainTurn(record, hosts: hosts) }
            group.addTask { try await self.buildLinkAssets(id, target: target, project: project) }

            for try await _ in group {}
        }

        try await updateShare(id) { $0.state = .starting(.openLink) }
        try await ensureStarting(id)
        try await serialOwnDomain { try await self.applyOwnDomainRules() }

        // A new record needs some seconds in DNS.
        try await waitForAddress(id, publicHost: record.publicHost ?? "", readyAt: .now)
        return try await finishOpen(id, record: record)
    }

    // routeOwnDomainLabel in the queue of the own domain. A cancel of the start also cancels its
    // turn. The start then waits for the end of the turn.
    private func routeInOwnDomainTurn(_ record: ShareRecord, hosts: Set<String>) async throws {
        let turn = ownDomainQueue.run { try await self.routeOwnDomainLabel(record, hosts: hosts) }

        try await withTaskCancellationHandler {
            try await turn.value
        } onCancel: {
            turn.cancel()
        }
    }

    // Adds the DNS record of the address through the API (way R, check E). A CNAME to the tunnel of
    // Nexus is the record of Nexus. It stays as it is. Each other record with that name belongs to
    // the user. Nexus never changes it (decisions.md). A record that the user deleted comes back. A
    // cancel does not stop the call that adds the record. So Nexus always knows a record that
    // Cloudflare made.
    func routeOwnDomainLabel(_ record: ShareRecord, hosts: Set<String>) async throws {
        let state = await stateStore.current()
        let domain = try usableOwnDomain(state)

        guard let label = record.label, let address = record.publicHost else {
            throw RuntimeError.unsupported(ShareText.ownDomainMissing)
        }

        let cert = try ownDomainCert()
        let api = ownDomainSeams.api
        let target = domain.tunnelTarget
        var added = false

        do {
            let records = try await api.records(cert.zoneID, address, cert.apiToken)

            if !records.contains(where: { $0.points(to: target) }) {
                guard records.isEmpty else {
                    throw RuntimeError.unsupported(ShareText.OwnDomain.recordExists(address))
                }

                // Disconnect can start during the lookup.
                guard !ownDomainLeaving else {
                    throw RuntimeError.unsupported(ShareText.ownDomainMissing)
                }

                try Task.checkCancellation()
                try await Task { try await api.addRecord(cert.zoneID, address, target, cert.apiToken) }.value
                added = true
            }
        } catch let error as CloudflareAPIError {
            try Task.checkCancellation()
            writeToOwnDomainLog("Nexus did not add the DNS record \(address): \(error)")
            throw RuntimeError.unsupported(error == .noAnswer ? ShareText.OwnDomain.noAnswer : ShareText.OwnDomain.recordNotAdded(address, log: ownDomainLogPath))
        }

        try await stateStore.update { state in
            guard var own = state.ownDomain else {
                return
            }

            own.labels = own.labels.filter { $0.value != label || hosts.contains($0.key) }
            own.labels[record.host] = label

            if !own.dnsRecords.contains(address) {
                own.dnsRecords.append(address)
            }

            state.ownDomain = own
        }

        if added {
            activity?.write("share", ShareText.OwnDomain.addedRecordLine(host: record.host, domain: domain.domain))
        }
    }
}

// MARK: The tunnel

extension NexusEngine {
    // The rules of the active own-domain links with a port and an address.
    static func ownDomainRules(_ state: EngineState) -> [String: Int] {
        Dictionary(ownDomainShares(state).compactMap { record in record.port == 0 ? nil : record.publicHost.map { ($0, record.port) } }) { first, _ in first }
    }

    // Gives the tunnel the rules of the active own-domain links. It runs in serialOwnDomain. A
    // failure throws. ownDomainTunnel and its ports change only after a success. Way R: one PUT of
    // the rules. The program starts only when none runs. A program that runs takes the new rules
    // without a new process (check E). /config of its metrics server then gives the new version.
    func applyOwnDomainRules() async throws {
        let state = await stateStore.current()
        let rules = Self.ownDomainRules(state)

        guard !rules.isEmpty else {
            await stopOwnDomainTunnel(cause: "no own-domain link is open")
            return
        }

        guard rules != ownDomainTunnel?.rules else {
            return
        }

        let domain = try usableOwnDomain(state)
        let cert = try ownDomainCert()
        let notChanged = RuntimeError.unsupported(ShareText.OwnDomain.rulesNotChanged(domain.tunnelName, log: ownDomainLogPath))
        let version: Int

        do {
            version = try await ownDomainSeams.api.putRules(cert.accountID, domain.tunnelID, rules, cert.apiToken)
        } catch {
            try Task.checkCancellation()
            writeToOwnDomainLog("Nexus did not change the addresses of the tunnel \(domain.tunnelName): \(error)")
            throw (error as? CloudflareAPIError) == .noAnswer ? RuntimeError.unsupported(ShareText.OwnDomain.noAnswer) : notChanged
        }

        if let tunnel = ownDomainTunnel, await processSupervisor.state(of: tunnel.processID)?.isActive == true {
            guard try await waitForOwnDomainRules(tunnel.processID, port: tunnel.metricsPort, version: version, limit: ownDomainSeams.configLimit, needsReady: false) else {
                writeToOwnDomainLog("cloudflared did not take version \(version) of the addresses within \(ownDomainSeams.configLimit.components.seconds) seconds.")
                throw notChanged
            }

            ownDomainTunnel = OwnDomainTunnel(processID: tunnel.processID, metricsPort: tunnel.metricsPort, rules: rules)
            return
        }

        await stopOwnDomainTunnel(cause: "a new start of the tunnel")
        let binary = try await ownDomainBinary()

        guard let key = try? cloudflareKeys.read(.tunnel), let token = String(data: key, encoding: .utf8), !token.isEmpty else {
            throw RuntimeError.unsupported(ShareText.OwnDomain.keyMissing)
        }

        // The ports of the quick links come from the same queue. So no two programs get one port.
        let port = try await serialWeb {
            let current = await self.stateStore.current()
            let port = await self.freePorts(for: [Self.ownDomainMetricsName], keeping: [:], from: Self.firstSharePort, in: current)[Self.ownDomainMetricsName] ?? 0

            try await self.stateStore.update { $0.ownDomain?.metricsPort = port }
            return port
        }

        // The supervisor starts it again after an exit, because a named tunnel keeps its address
        // (corrections 9 and 10).
        ownDomainGeneration += 1

        let definition = cloudflaredDefinition(
            id: "share\nown-domain\n\(ownDomainGeneration)",
            displayName: "cloudflared for the own domain",
            binary: binary,
            arguments: CloudflaredConfig.ownDomainRunArguments(config: paths.ownDomainConfig, metricsPort: port),
            metricsPort: port,
            logFile: paths.ownDomainTunnelLog,
            key: ["TUNNEL_TOKEN": token],
            restartsAfterExit: true
        )

        try await startCloudflared(definition, config: CloudflaredConfig.remoteTunnelFile, at: paths.ownDomainConfig, logName: Self.ownDomainLogName)

        guard try await waitForOwnDomainRules(definition.id, port: port, version: version, limit: shareWaits.readyLimit, needsReady: true) else {
            try? await processSupervisor.stop(definition.id, cause: "no connection to Cloudflare")
            throw RuntimeError.unsupported(ShareText.noConnection)
        }

        ownDomainTunnel = OwnDomainTunnel(processID: definition.id, metricsPort: port, rules: rules)
        await observeProcessChanges()
    }

    // true when cloudflared uses the version of the rules, or a newer one. A program that failed
    // gives false at once.
    private func waitForOwnDomainRules(_ processID: String, port: Int, version: Int, limit: Duration, needsReady: Bool) async throws -> Bool {
        let checks = shareChecks
        let seams = ownDomainSeams

        let taken = try await waitFor(limit: limit, every: shareWaits.poll) { () async -> Bool? in
            if case .failed? = await processSupervisor.state(of: processID) {
                return false
            }

            let ready = needsReady ? await checks.isReady(port) == true : true

            guard ready, let current = await seams.configVersion(port), current >= version else {
                return nil
            }

            return true
        }

        return taken ?? false
    }

    private func stopOwnDomainTunnel(cause: String) async {
        guard let tunnel = ownDomainTunnel else {
            return
        }

        ownDomainTunnel = nil
        try? await processSupervisor.stop(tunnel.processID, cause: cause)
    }

    // After the end of an own-domain link (endShares). The end marks the rules as changed and does
    // not wait. One job in the queue of the own domain then gives the tunnel the newest rules. More
    // ends before the start of that job add no second job.
    func ownDomainLinksChanged() {
        guard !ownDomainRulesChanged else {
            return
        }

        ownDomainRulesChanged = true
        _ = ownDomainQueue.run { await self.applyChangedOwnDomainRules() }
    }

    // The job of ownDomainLinksChanged. An end after the start of the job adds a new job. A failure
    // writes activity line 23e. The ports of the old rules then stay taken.
    private func applyChangedOwnDomainRules() async {
        ownDomainRulesChanged = false

        do {
            try await applyOwnDomainRules()
        } catch {
            let tunnel = await stateStore.current().ownDomain?.tunnelName ?? "of the own domain"
            activity?.write("share", ShareText.OwnDomain.rulesNotChangedLine(tunnel, reason: ErrorText.plain(error)))
        }
    }

    // The program of the own domain failed after 5 quick restarts. Each own-domain link ends with
    // text 17 of 4b and the log of the own domain.
    func ownDomainProgramChanged() async {
        guard let tunnel = ownDomainTunnel, case .failed? = await processSupervisor.state(of: tunnel.processID) else {
            return
        }

        ownDomainTunnel = nil
        let ids = Self.ownDomainShares(await stateStore.current()).map(\.id)

        if !ids.isEmpty {
            await endShares(ids, reason: .failed(ShareText.cloudflaredStopped(log: ownDomainLogPath)))
        }
    }

    // A new start of nexusd (startEnabledServices). An open own-domain link keeps its state. Nexus
    // shows nothing, as after a wake. The resume holds the queue of the own domain. So the rules job
    // of each end during the resume comes after the checks.
    func resumeOwnDomainLinks() async {
        _ = try? await serialOwnDomain { try await self.resumeOwnDomainLinksInTurn() }
    }

    private func resumeOwnDomainLinksInTurn() async throws {
        let state = await stateStore.current()
        let own = Self.ownDomainShares(state)

        guard !own.isEmpty else {
            return
        }

        // The start task of a record that starts ended with nexusd. No tunnel runs yet. The rules
        // come once, after the checks.
        let starting = own.filter { $0.state != .open }.map(\.id)

        if !starting.isEmpty {
            await endShares(starting, reason: .nexusdStopped)
        }

        var open = own.filter { $0.state == .open }

        guard state.ownDomain != nil else {
            await endShares(open.map(\.id), reason: .failed(ShareText.ownDomainMissing))
            return
        }

        let due = open.filter { $0.endsAt.map { $0 <= .now } == true }.map(\.id)

        if !due.isEmpty {
            await endShares(due, reason: .endTime)
            open.removeAll { due.contains($0.id) }
        }

        guard !open.isEmpty else {
            return
        }

        guard try await waitForNginx() else {
            await endShares(open.map(\.id), reason: .failed(ShareText.nginxNotRunning))
            return
        }

        // One limit for all the share blocks.
        let blockAnswers = shareBlockAnswers
        var silent = open

        _ = try await waitFor(limit: shareWaits.blockLimit, every: .milliseconds(100)) { () -> Bool? in
            silent.removeAll { blockAnswers($0.port) }
            return silent.isEmpty ? true : nil
        }

        for block in silent {
            await endShares([block.id], reason: .failed(ShareText.portNotOpen(block.port)))
        }

        let left = open.map(\.id).filter { id in !silent.contains { $0.id == id } }

        guard !left.isEmpty else {
            return
        }

        do {
            try await applyOwnDomainRules()
        } catch {
            await endShares(left, reason: .failed(ErrorText.plain(error)))
            return
        }

        await watchLinkRequests()
        publishSites()
    }

    private func waitForNginx() async throws -> Bool {
        let running = try await waitFor(limit: shareWaits.resumeLimit, every: shareWaits.poll) { () async -> Bool? in
            await supervisor.state(of: ServiceCatalog.nginxID)?.isActive == true ? true : nil
        }

        return running ?? false
    }
}

// MARK: Disconnect

extension NexusEngine {
    // "Disconnect…" (ux-texts.md). Nexus deletes only a record of dnsRecords that is a CNAME to its
    // own tunnel. A record with another content stays (decisions.md).
    func disconnectOwnDomain() async throws -> OwnDomainRemoval {
        guard await stateStore.current().ownDomain != nil else {
            if ownDomainSetup != nil {
                _ = await cancelOwnDomain()
            }

            return Self.nothingRemoved
        }

        ownDomainDisconnects += 1
        defer { ownDomainDisconnects -= 1 }

        let ids = Self.ownDomainShares(await stateStore.current()).map(\.id)

        if !ids.isEmpty {
            await endShares(ids, reason: .stopped)
        }

        return try await serialOwnDomain { try await self.removeOwnDomain() }
    }

    private static let nothingRemoved = OwnDomainRemoval(removedRecords: [], keptRecords: [])

    // The state of the turn. A link that started before Disconnect can add a record until then.
    private func removeOwnDomain() async throws -> OwnDomainRemoval {
        guard let domain = await stateStore.current().ownDomain else {
            return Self.nothingRemoved
        }

        await stopOwnDomainTunnel(cause: "Disconnect")
        let names = domain.dnsRecords.sorted()

        guard let cert = try? ownDomainCert() else {
            return try await forgetOwnDomain(domain, removal: OwnDomainRemoval(removedRecords: [], keptRecords: names, keptTunnel: domain.tunnelName))
        }

        let api = ownDomainSeams.api
        let outcomes = await removeOwnRecords(names, target: domain.tunnelTarget, cert: cert)
        let removed = names.filter { (try? outcomes[$0]?.get()) == true }
        let kept = names.filter { (try? outcomes[$0]?.get()) == false }

        // The first failure in the order of the names decides, as one after the other.
        let failure = names.lazy.compactMap { name -> (any Error)? in
            guard case .failure(let error)? = outcomes[name] else {
                return nil
            }

            return error
        }.first

        if let failure {
            guard failure as? CloudflareAPIError == .refused else {
                throw try await stopDisconnect(domain, removed: removed, reason: failure)
            }

            let left = names.filter { !removed.contains($0) }
            return try await forgetOwnDomain(domain, removal: OwnDomainRemoval(removedRecords: removed, keptRecords: left, keptTunnel: domain.tunnelName))
        }

        do {
            try await api.deleteTunnel(cert.accountID, domain.tunnelID, cert.apiToken)
        } catch CloudflareAPIError.notFound {
        } catch CloudflareAPIError.refused {
            return try await forgetOwnDomain(domain, removal: OwnDomainRemoval(removedRecords: removed, keptRecords: kept, keptTunnel: domain.tunnelName))
        } catch {
            throw try await stopDisconnect(domain, removed: removed, reason: error)
        }

        return try await forgetOwnDomain(domain, removal: OwnDomainRemoval(removedRecords: removed, keptRecords: kept))
    }

    // Cloudflare limits the calls of one key. So at most this number of names run at the same time.
    static let recordRemovalsAtOnce = 4

    // The lookups and the deletes of the names run at the same time, with recordRemovalsAtOnce as
    // the limit. A refused key starts no new name. The names that run go on to their end. A name
    // that did not start has no outcome. true: Nexus deleted its record or the name has no record.
    // false: only records of the user have the name.
    private func removeOwnRecords(_ names: [String], target: String, cert: CloudflareCert) async -> [String: Result<Bool, any Error>] {
        let api = ownDomainSeams.api

        return await withTaskGroup(of: (name: String, outcome: Result<Bool, any Error>).self) { group in
            var waiting = names[...]
            var running = 0
            var refused = false
            var outcomes: [String: Result<Bool, any Error>] = [:]

            while true {
                while !refused, running < Self.recordRemovalsAtOnce, let name = waiting.popFirst() {
                    running += 1
                    group.addTask {
                        (name, await Self.removeOwnRecord(name, target: target, cert: cert, api: api))
                    }
                }

                guard let finished = await group.next() else {
                    return outcomes
                }

                running -= 1
                outcomes[finished.name] = finished.outcome

                if case .failure(let error) = finished.outcome, error as? CloudflareAPIError == .refused {
                    refused = true
                }
            }
        }
    }

    private static func removeOwnRecord(_ name: String, target: String, cert: CloudflareCert, api: CloudflareAPI) async -> Result<Bool, any Error> {
        do {
            let records = try await api.records(cert.zoneID, name, cert.apiToken)
            let own = records.filter { $0.points(to: target) }

            for record in own {
                do {
                    try await api.deleteRecord(cert.zoneID, record.id, cert.apiToken)
                } catch CloudflareAPIError.notFound {}
            }

            return .success(!own.isEmpty || records.isEmpty)
        } catch CloudflareAPIError.notFound {
            return .success(true)
        } catch {
            return .failure(error)
        }
    }

    // No answer: the domain stays with the names that are left. The user clicks Disconnect again.
    private func stopDisconnect(_ domain: OwnDomainRecord, removed: [String], reason: any Error) async throws -> any Error {
        try Task.checkCancellation()
        writeToOwnDomainLog("Nexus did not disconnect \(domain.domain): \(reason)")

        try await stateStore.update { state in
            state.ownDomain?.dnsRecords.removeAll { removed.contains($0) }
        }

        publishSiteList()
        return RuntimeError.unsupported(ShareText.OwnDomain.noAnswerAtDisconnect)
    }

    private func forgetOwnDomain(_ domain: OwnDomainRecord, removal: OwnDomainRemoval) async throws -> OwnDomainRemoval {
        removeOwnDomainKeys()

        for file in [paths.ownDomainFolder, paths.ownDomainConfig] {
            try? FileManager.default.removeItem(at: file)
        }

        try await stateStore.update { state in
            state.ownDomain = nil
            state.shareDefaults.address = .random
        }

        let line = removal.keptTunnel == nil
            ? ShareText.OwnDomain.removedLine(domain.domain, tunnel: domain.tunnelName, keptRecords: removal.keptRecords.count)
            : ShareText.OwnDomain.removedWithTunnelLine(domain.domain, tunnel: domain.tunnelName, keptRecords: removal.keptRecords.count)

        activity?.write("share", line)
        publishSiteList()
        return removal
    }
}
