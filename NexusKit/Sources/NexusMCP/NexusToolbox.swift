import Foundation
import NexusCore
import NexusIPC
import NexusMail
import NexusRuntime
import NexusSupervisor

// nexusd over XPC, or a fake nexusd in a test.
public protocol NexusConnecting: Sendable {
    func send(_ request: NexusRequest) async throws -> NexusResponse
}

extension NexusClient: NexusConnecting {}

public struct ToolFailure: Error, CustomStringConvertible, Equatable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

// nexusd does not answer. The status tool reports it as a state and not as an error.
struct NexusNotRunning: Error {}

// folder is the project folder of the session: CLAUDE_PROJECT_DIR, else the working directory.
public struct NexusToolbox: MCPHandler {
    public static let notRunning = "Nexus does not run now. Ask the user to open Nexus."

    let connection: any NexusConnecting
    let paths: NexusPaths
    let folder: String
    let loadSettings: @Sendable () -> AgentSettings
    let makeInbox: @Sendable (Int) -> any MailInbox
    let now: @Sendable () -> Date
    let activity: ActivityLog?

    public init(
        connection: any NexusConnecting = NexusClient(),
        paths: NexusPaths = .standard,
        folder: String,
        loadSettings: @escaping @Sendable () -> AgentSettings = { AgentSettings.load() },
        makeInbox: @escaping @Sendable (Int) -> any MailInbox = { MailpitAPI(port: $0) },
        now: @escaping @Sendable () -> Date = { .now },
        activity: ActivityLog? = nil
    ) {
        self.connection = connection
        self.paths = paths
        self.folder = folder
        self.loadSettings = loadSettings
        self.makeInbox = makeInbox
        self.now = now
        self.activity = activity
    }

    public func instructions(agent: String?) async -> String {
        let level = loadSettings().level
        let tld = NexusVariant.current.tld

        guard let sites = try? await sites() else {
            return AgentInstructions.text(for: .nexusDoesNotRun, level: level, tld: tld)
        }

        guard let target = try? SiteTarget.find(host: nil, folder: folder, in: sites, example: "") else {
            return AgentInstructions.text(for: .notASite(folder: folder), level: level, tld: tld)
        }

        let connections = (try? await databaseConnections(target)) ?? []
        let database = connections.first { $0.instance != nil && !$0.database.isEmpty } ?? connections.first
        return AgentInstructions.text(for: .site(target, database: database, tests: testDatabase(of: target)), level: level, tld: tld)
    }

    public func tools(agent: String?) async -> [MCPTool] {
        let level = loadSettings().level
        return NexusTools.all.filter { $0.level <= level }.map(\.tool)
    }

    public func knows(_ name: String) -> Bool {
        NexusTools.spec(name) != nil
    }

    public func call(_ name: String, arguments: [String: JSONValue], agent: String?) async -> MCPToolResult {
        guard let spec = NexusTools.spec(name) else {
            return .error("Nexus has no tool \(name).")
        }

        let level = loadSettings().level

        guard spec.level <= level else {
            return .error(level.refusal)
        }

        return await outcome { try await run(name, CallArguments(arguments), agent: AgentName.display(agent)) }
    }

    // nexus site info, nexus errors, nexus mail wait and nexus mail links run the read tools with
    // the same code. The user runs them. So the access level of agents does not apply.
    public func look(_ name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
        guard NexusTools.spec(name)?.level == .read else {
            return .error("\(name) is not a tool that only reads.")
        }

        return await outcome { try await run(name, CallArguments(arguments), agent: "nexus") }
    }

    private func outcome(_ body: () async throws -> MCPToolResult) async -> MCPToolResult {
        do {
            return try await body()
        } catch is NexusNotRunning {
            return .error(Self.notRunning)
        } catch let failure as ToolFailure {
            return .error(failure.description)
        } catch is CancellationError {
            return .error("The call stopped.")
        } catch let error as MailpitAPIError {
            return .error(error.description)
        } catch {
            return .error(ErrorText.plain(error))
        }
    }

    private func run(_ name: String, _ arguments: CallArguments, agent: String) async throws -> MCPToolResult {
        switch name {
        case "site_info": try await siteInfo(arguments)
        case "list_sites": try .value(SiteRows(sites: try await sites().map(AgentSiteRow.init)))
        case "status": try await status()
        case "list_packages": try await packages()
        case "php_extensions": try await phpExtensions(arguments)
        case "last_errors": try await lastErrors(arguments)
        case "read_dumps": try await readDumps(arguments, agent: agent)
        case "read_log": try await readLog(arguments)
        case "list_mail": try await listMail(arguments)
        case "read_mail": try .value(try await mailReader().read(id: arguments.string("id") ?? "latest", tags: try await mailScope(arguments.string("site")).tags))
        case "wait_for_mail": try await waitForMail(arguments)
        case "start_service": try await startService(arguments, agent: agent)
        case "install_package": try .message(try await done(.install(name: try arguments.required("package"), line: try arguments.required("version")), agent: agent))
        case "set_php_extension": try await setExtension(arguments, agent: agent)
        case "create_database": try await createDatabase(arguments, agent: agent)
        case "create_workspace": try await createWorkspace(arguments, agent: agent)
        case "add_site": try await addSite(arguments, agent: agent)
        case "remove_workspace": try await removeWorkspace(arguments, agent: agent)
        case "remove_site": try await removeSite(arguments, agent: agent)
        case "stop_service": try .message(try await done(.stop(service: try arguments.required("service")), agent: agent))
        case "clear_mail": try await clearMail(arguments, agent: agent)
        default: .error("Nexus has no tool \(name).")
        }
    }

    // MARK: Sites

    private func siteInfo(_ arguments: CallArguments) async throws -> MCPToolResult {
        let target = try await target(arguments.string("site"))
        async let connections = try? await databaseConnections(target)
        async let mail = try? await siteMail(host: target.siteHost)

        return try .value(AgentSite(target: target, connections: await connections ?? [], mail: await mail, testDatabase: testDatabase(of: target)))
    }

    // Only the main folder of a Laravel site, because a workspace has its own database.
    func testDatabase(of target: SiteTarget) -> TestDatabaseCheck? {
        guard target.workspace == nil, target.site.kind == .php, target.site.projectType == .laravel else {
            return nil
        }

        return TestDatabaseCheck.check(projectFolder: URL(filePath: target.projectFolder, directoryHint: .isDirectory))
    }

    private func phpExtensions(_ arguments: CallArguments) async throws -> MCPToolResult {
        let target = try await target(arguments.string("site"))

        guard target.site.kind == .php else {
            throw ToolFailure("\(target.host) is a \(AgentSite.type(of: target.site)). It has no PHP.")
        }

        let required = ComposerExtensions.required(in: URL(filePath: target.projectFolder, directoryHint: .isDirectory))
        async let toggleList = try? await extensionToggles(php: target.site.php)
        let loaded = try await loadedModules(of: target)
        let toggles = await toggleList ?? []
        let states = required.keys.sorted().map { name in
            let toggle = toggles.first { ComposerExtensions.normalized($0.name) == name }
            let on = loaded.contains(name)
            return ExtensionState(name: name, requiredBy: required[name] ?? [], on: on, canTurnOn: !on && toggle != nil)
        }

        let missing = states.filter { !$0.on }
        let note: String = if required.isEmpty {
            "composer.json and composer.lock require no PHP extensions."
        } else if missing.isEmpty {
            "PHP \(target.site.php) has each required extension on."
        } else {
            "PHP \(target.site.php) does not have \(missing.map(\.name).joined(separator: ", ")) on. set_php_extension turns on an extension with canTurnOn true. Nexus has no package for the others."
        }

        return try .value(ExtensionsResult(site: target.host, php: target.site.php, missing: missing, on: states.filter(\.on).map(\.name), note: note))
    }

    // php -m with the PHP of the site, as the site runs it. A php.ini that makes PHP wait at its
    // start must not hold the call. So PHP gets 10 seconds. A cancel of the call stops PHP. This is
    // a PHP run of Nexus. So it gets no folder of the dump viewer.
    private func loadedModules(of target: SiteTarget) async throws -> Set<String> {
        let response = try await send(.tool(.php, folder: target.folder, argumentFolder: nil))

        guard case .tool(let tool) = response else {
            throw failure(response)
        }

        var environment = tool.environment
        environment["PATH"] = (tool.path + [ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        let command = Command(executable: URL(filePath: tool.executable), arguments: tool.arguments + ["-m"], environment: environment, workingDirectory: URL(filePath: target.folder, directoryHint: .isDirectory), name: "php")

        let output = try await withThrowingTaskGroup(of: CommandOutput?.self) { group in
            group.addTask { try await CommandRunner.run(command) }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return nil
            }

            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let output else {
            throw ToolFailure("PHP \(target.site.php) did not answer php -m within 10 seconds. Check the custom php.ini lines of this version.")
        }

        return ComposerExtensions.modules(inPHPOutput: output.standardOutput)
    }

    private func lastErrors(_ arguments: CallArguments) async throws -> MCPToolResult {
        let target = try await target(arguments.string("site"))
        let site = target.site
        let project = URL(filePath: target.projectFolder, directoryHint: .isDirectory)
        let limit = min(max(arguments.int("limit") ?? 5, 1), 20)
        let timeZone = EnvFile.values(of: project.appending(path: ".env"))["APP_TIMEZONE"].flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!
        let wordPressLogs = [URL(filePath: target.folder, directoryHint: .isDirectory).appending(path: "wp-content/debug.log"), project.appending(path: "wp-content/debug.log"), project.appending(path: "web/app/debug.log")]
        let hosts = target.workspace.map { $0.hosts ?? [] } ?? site.hosts
        let accessLogs = hosts.map(paths.siteLog).filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        let appLog = (target.workspace?.app ?? (target.workspace == nil ? site.app : nil)).map { URL(filePath: $0.log) }

        let sources = ErrorReader.Sources(
            laravelLogs: site.kind == .php && site.projectType == .laravel ? project.appending(path: "storage/logs", directoryHint: .isDirectory) : nil,
            wordPressLog: site.isWordPress ? wordPressLogs.first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } : nil,
            phpLog: site.kind == .php ? paths.log(ServiceID.php(line: site.php)) : nil,
            siteFolder: target.projectFolder,
            otherFolders: target.workspace == nil ? (site.workspaces ?? []).map(\.worktree) : [],
            accessLogs: accessLogs,
            appLog: appLog,
            timeZone: timeZone
        )

        let errors = ErrorReader.errors(in: sources, limit: limit)
        let note = errors.isEmpty ? "Nexus finds no errors of \(target.host) in its logs. read_log gives the full logs." : nil
        return try .value(ErrorsResult(site: target.host, errors: errors, note: note))
    }

    private func readLog(_ arguments: CallArguments) async throws -> MCPToolResult {
        let sites = (try? await sites()) ?? []

        guard let name = arguments.string("log") else {
            return try .value(LogList(logs: LogReader.logs(paths: paths, sites: sites)))
        }

        guard let lines = LogReader.read(name, lines: arguments.int("lines") ?? LogReader.defaultLines, containing: arguments.string("contains"), paths: paths, sites: sites) else {
            throw ToolFailure("Nexus has no log \(name). Call read_log without log to see the logs.")
        }

        return try .value(lines)
    }

    // MARK: Dumps

    // The longest text of read_dumps. An agent reads it all. So the oldest requests go first when
    // the text gets longer than this.
    static let dumpTextLimit = 60_000
    // read_dumps reads this many requests at the same time. It starts no new reads when less
    // room than smallestBlock is left, because a request with its header needs at least that.
    static let dumpReadsAtOnce = 8
    static let smallestBlock = 200

    // The text of nexus dumps for the newest requests of a place or for one request, with the id
    // of each request. The text of each request is complete, so the tags of its queries count all
    // its queries.
    private func readDumps(_ arguments: CallArguments, agent: String) async throws -> MCPToolResult {
        let limit = min(max(arguments.int("limit") ?? 20, 1), 50)
        let requestID = arguments.string("request")
        let scope = requestID == nil ? try await dumpScope(arguments.string("site"), agent: agent) : (place: nil, host: nil)
        let list = try await caughtDumpList(place: scope.place, agent: agent)

        guard list.loaded else {
            throw ToolFailure(DumpList.notLoadedText)
        }

        var requests = Array(list.requests.prefix(limit))
        var notes = DumpText.notes(of: list.state, place: scope.place)

        if let requestID {
            guard let request = list.requests.first(where: { $0.id == requestID }) else {
                throw ToolFailure("Nexus has no request \(requestID). The user can have removed it, or newer requests took its place. Call read_dumps without request to see the newest requests.")
            }

            requests = [request]
            notes = DumpText.notes(of: list.state, place: request.place)
        }

        guard !requests.isEmpty else {
            return MCPToolResult(text: (notes + [DumpText.noRequests(of: scope.host)]).joined(separator: "\n"), structured: nil)
        }

        let times = DumpTimeText()
        var blocks: [String] = []
        var size = 0
        var next = 0

        // The newest requests come first. Each group of reads keeps its order in the text.
        reading: while next < requests.count, Self.dumpTextLimit - size >= Self.smallestBlock {
            let group = Array(requests[next..<min(next + Self.dumpReadsAtOnce, requests.count)])
            next += group.count

            for (request, entries) in zip(group, try await caughtEntries(of: group, agent: agent)) {
                let tags = QueryTags(entries)
                var lines = [DumpText.header(of: request, now: now(), times: times)] + DumpText.details(of: request, id: true)
                lines += entries.flatMap { entry in DumpText.lines(of: entry, tags: tags) }
                var block = lines.joined(separator: "\n")

                if !blocks.isEmpty, size + block.count > Self.dumpTextLimit {
                    break reading
                }

                if block.count > Self.dumpTextLimit {
                    block = String(block.prefix(Self.dumpTextLimit)) + "\n[The text of this request stops here, because it is too long.]"
                }

                blocks.append(block)
                size += block.count
            }
        }

        let leftOut = requests.count - blocks.count

        if leftOut > 0 {
            notes.append("The text leaves out the \(leftOut == 1 ? "oldest request" : "\(leftOut) oldest requests"), because it is too long. Give a lower limit or a request.")
        }

        let text = (notes.isEmpty ? [] : [notes.joined(separator: "\n")]) + blocks.reversed()
        return MCPToolResult(text: text.joined(separator: "\n\n"), structured: nil)
    }

    // A site does not include its workspaces, as in nexus dumps. A session outside the sites reads
    // the entries of all places. host names the place in the text of an empty list.
    private func dumpScope(_ site: String?, agent: String) async throws -> (place: DumpPlace?, host: String?) {
        if site == "all" {
            return (nil, nil)
        }

        let target: SiteTarget

        do {
            target = try await self.target(site)
        } catch is ToolFailure where site == nil {
            return (nil, nil)
        }

        let response = try await send(.fromAgent(agent: agent, request: .dumpPlace(host: target.host)))

        guard case .dumpPlace(let place, let host) = response else {
            throw failure(response)
        }

        return (place, host)
    }

    private func caughtDumpList(place: DumpPlace?, agent: String) async throws -> DumpList {
        let response = try await send(.fromAgent(agent: agent, request: .dumpList(place: place)))

        guard case .dumpList(let list) = response else {
            throw failure(response)
        }

        return list
    }

    // read_dumps shows each kind. So it reads all entries of each request, the reads at the same
    // time. The answer has the order of the requests.
    private func caughtEntries(of requests: [DumpedRequest], agent: String) async throws -> [[CaughtDump]] {
        try await withThrowingTaskGroup(of: (Int, [CaughtDump]).self) { reads in
            for (index, request) in requests.enumerated() {
                reads.addTask {
                    let response = try await send(.fromAgent(agent: agent, request: .requestDumps(request: request.id, afterNumber: 0)))

                    guard case .caughtDumps(let entries) = response else {
                        throw failure(response)
                    }

                    return (index, entries)
                }
            }

            var found = Array(repeating: [CaughtDump](), count: requests.count)

            for try await (index, entries) in reads {
                found[index] = entries
            }

            return found
        }
    }

    // MARK: Status and packages

    private func status() async throws -> MCPToolResult {
        let list: ServiceList
        async let taskAnswer = try? await send(.tasks)

        do {
            let response = try await send(.serviceList)

            guard case .serviceList(let services) = response else {
                throw failure(response)
            }

            list = services
        } catch is NexusNotRunning {
            return try .value(StatusResult(running: false, services: [], tasks: [], problems: [Self.notRunning]))
        }

        let tasks: [TaskRow] = if case .tasks(let running)? = await taskAnswer {
            running.tasks.map(TaskRow.init)
        } else {
            []
        }

        let services = list.services.map(ServiceRow.init)
        let problems = list.services.compactMap { service -> String? in
            if case .failed(let reason) = service.state {
                return "\(service.id) does not run: \(reason)"
            }

            return service.portConflict.map { "\(service.id): \($0.description)" } ?? service.problem.map { "\(service.id): \($0)" }
        }

        return try .value(StatusResult(running: true, services: services, tasks: tasks, problems: problems))
    }

    private func packages() async throws -> MCPToolResult {
        async let availableAnswer = send(.available)
        let installedResponse = try await send(.installed)

        guard case .installed(let installed) = installedResponse else {
            throw failure(installedResponse)
        }

        let availableResponse = try await availableAnswer
        var available: [PackageRow] = []

        if case .available(let packages) = availableResponse {
            var seen: Set<String> = []

            for package in packages where seen.insert("\(package.name) \(package.line)").inserted {
                available.append(PackageRow(package: package.name, line: package.line, version: package.version, installed: installed.contains { $0.name == package.name && $0.line == package.line }))
            }
        }

        let rows = installed.map { PackageRow(package: $0.name, line: $0.line, version: $0.version, installed: true) }
        return try .value(PackagesResult(installed: rows, available: available))
    }

    // MARK: Mail

    private func listMail(_ arguments: CallArguments) async throws -> MCPToolResult {
        async let scopeAnswer = mailScope(arguments.string("site"))
        let reader = try await mailReader()
        let scope = try await scopeAnswer
        let limit = min(max(arguments.int("limit") ?? 20, 1), 100)
        let mails = try await reader.list(tags: scope.tags, limit: limit).map(MailRow.init)
        var note: String?

        if mails.isEmpty {
            let others = scope.tags == nil ? [] : try await reader.list(tags: nil, limit: 1)
            note = others.isEmpty ? "The inbox has no mail of \(scope.label)." : "The inbox has no mail of \(scope.label), but it has other mail. A site with other mail settings sends mail without its tag. Call list_mail with site all."
        }

        return try .value(MailList(scope: scope.label, mails: mails, note: note))
    }

    private func waitForMail(_ arguments: CallArguments) async throws -> MCPToolResult {
        let to = arguments.string("to")
        let subject = arguments.string("subject")
        let seconds = min(max(arguments.int("seconds") ?? MailReader.defaultWait, 1), MailReader.longestWait)
        var since = now().addingTimeInterval(-MailReader.lookBack)

        if let text = arguments.string("since") {
            guard let date = MailReader.date(text) else {
                throw ToolFailure("since must be an ISO 8601 time, for example 2026-11-10T11:00:00Z.")
            }

            since = date
        }

        let reader = try await mailReader()
        let scope = to == nil ? try await mailScope(arguments.string("site")) : (tags: nil, label: "the whole inbox")

        if let mail = try await reader.wait(to: to, subject: subject, tags: scope.tags, since: since, seconds: seconds) {
            return try .value(mail)
        }

        let filter = [to.map { "to \($0)" }, subject.map { "with \"\($0)\" in the subject" }].compactMap { $0 }.joined(separator: " ")
        let what = filter.isEmpty ? "a mail of \(scope.label)" : "a mail \(filter)"
        return try .value(NoMail(found: false, message: "No mail yet. Nexus waited \(Count.text(seconds, "second")) for \(what). Call wait_for_mail again. When the mail does not come, call last_errors: the site can have failed to send it."))
    }

    private func clearMail(_ arguments: CallArguments, agent: String) async throws -> MCPToolResult {
        let reader = try await mailReader()
        let id = arguments.string("id")
        let scope = id != nil && id != "latest" ? (tags: nil, label: "the inbox") : try await mailScope(arguments.string("site"), wholeInboxOutsideSites: false)
        let count = try await reader.clear(id: id, tags: scope.tags)
        let message: String = if let id {
            "Nexus removed the mail \(id) from the inbox."
        } else if let count {
            "Nexus removed \(Count.text(count, "mail")) of \(scope.label) from the inbox."
        } else {
            "The inbox is empty."
        }

        activity?.write("request", "clearMail \(id ?? scope.label) (\(agent)): done")
        return try .message(message)
    }

    private func mailReader() async throws -> MailReader {
        let response = try await send(.mailStatus)

        guard case .mailStatus(let status) = response else {
            throw failure(response)
        }

        guard status.installed else {
            throw ToolFailure("The mail service of Nexus is not installed. Install it with install_package (package mailpit, version 1), or ask the user.")
        }

        guard status.running, let port = status.inboxPort else {
            throw ToolFailure("The mail service of Nexus does not run. Start it with start_service (service mail), or ask the user.")
        }

        return MailReader(inbox: makeInbox(port))
    }

    // The tags of the mail of a site and its workspaces, or of one workspace. all gives the whole
    // inbox. A session outside the sites reads the whole inbox too. A removal never does that by
    // itself: it needs all.
    private func mailScope(_ site: String?, wholeInboxOutsideSites: Bool = true) async throws -> (tags: [String]?, label: String) {
        if site == "all" {
            return (nil, "the whole inbox")
        }

        let target: SiteTarget

        do {
            target = try await self.target(site)
        } catch let failure as ToolFailure where site == nil {
            guard wholeInboxOutsideSites else {
                throw ToolFailure("\(failure.description) To remove the mail of all sites, give site all.")
            }

            return (nil, "the whole inbox")
        }

        if let workspace = target.workspace {
            return (workspace.hosts ?? [target.host], "the workspace \(target.host)")
        }

        let workspaceHosts = (target.site.workspaces ?? []).flatMap { $0.hosts ?? [] }
        return (target.site.hosts + workspaceHosts, workspaceHosts.isEmpty ? target.siteHost : "\(target.siteHost) and its workspaces")
    }

    // MARK: Changes

    private func startService(_ arguments: CallArguments, agent: String) async throws -> MCPToolResult {
        let service = try arguments.required("service")
        let request: NexusRequest = arguments.bool("restart") == true ? .restart(service: service) : .start(service: service)
        return try .message(try await done(request, agent: agent))
    }

    private func setExtension(_ arguments: CallArguments, agent: String) async throws -> MCPToolResult {
        let name = try arguments.required("extension")

        guard let on = arguments.bool("on") else {
            throw ToolFailure("Give on: true to turn the extension on, or on: false to turn it off.")
        }

        let php: String

        if let given = arguments.string("php") {
            php = given
        } else {
            let target = try await target(arguments.string("site"))

            guard target.site.kind == .php else {
                throw ToolFailure("\(target.host) has no PHP. Give php, for example 8.4.")
            }

            php = target.site.php
        }

        return try .message(try await done(.setExtension(php: php, name: name, enabled: on), agent: agent))
    }

    private func createDatabase(_ arguments: CallArguments, agent: String) async throws -> MCPToolResult {
        let name = try arguments.required("name")
        let target = try await target(arguments.string("site"))

        guard let server = DatabaseTarget.server(of: target, connections: try await databaseConnections(target)) else {
            throw ToolFailure("Nexus finds no database of \(target.host) on a server of Nexus. So it does not know where to make \(name).")
        }

        return try .message(try await done(.createDatabase(server, name: name), agent: agent))
    }

    private func createWorkspace(_ arguments: CallArguments, agent: String) async throws -> MCPToolResult {
        let branch = try arguments.required("branch")
        let target = try await target(arguments.string("site"))
        let databases = try arguments.string("databases").map { value in
            guard let kind = WorkspaceDatabaseKind(rawValue: value) else {
                throw ToolFailure("databases must be copy, empty or dump.")
            }

            return kind
        }

        let project = ProjectFolder.projectFolder(ofSiteFolder: URL(filePath: target.site.folder, directoryHint: .isDirectory))
        let message = try await done(.createWorktree(folder: project, branch: branch, databases: databases), agent: agent)
        let start = ContinuousClock.now

        while ContinuousClock.now - start < .seconds(50) {
            try await Task.sleep(for: .seconds(1))

            let site = try await sites().first { $0.hosts.first == target.siteHost }

            guard let workspace = site?.workspaces?.first(where: { $0.branch == branch || $0.name == branch }), workspace.state != .preparing, workspace.state != nil else {
                continue
            }

            return try .value(WorkspaceResult(message: message, workspace: AgentWorkspace(workspace)))
        }

        return try .message("\(message) The workspace is not ready after 50 seconds. Call site_info with the worktree folder later.")
    }

    private func addSite(_ arguments: CallArguments, agent: String) async throws -> MCPToolResult {
        let path = arguments.string("folder").map(resolvedFolder) ?? folder
        let message = try await done(.addSite(folder: path, host: arguments.string("host"), aliases: [], php: arguments.string("php"), server: nil), agent: agent)
        let site = (try? await sites())?.first { RealPath.of(URL(filePath: $0.folder, directoryHint: .isDirectory)) == path || $0.folder == path }

        return try .value(AddedSite(message: message, site: site.map(AgentSiteRow.init)))
    }

    private func removeWorkspace(_ arguments: CallArguments, agent: String) async throws -> MCPToolResult {
        let value = arguments.string("workspace")
        let sites = try await sites()
        let target: WorkspaceTarget

        do {
            if let value, !Self.isFolder(value) {
                target = try WorkspaceTarget.find(name: value, site: arguments.string("site"), folder: folder, in: sites)
            } else {
                target = try WorkspaceTarget.find(name: nil, site: nil, folder: value.map(resolvedFolder) ?? folder, in: sites)
            }
        } catch let error as WorkspaceTargetError {
            let text = switch error.reason {
            case .noSite(let host): "Nexus has no site \(host). Call list_sites to see the sites."
            case .notInWorkspace(let folder): "\(folder) is in no workspace. Give the name or the folder of a workspace."
            case .sameName(let name, let hosts): "More sites have a workspace \(name): \(hosts.joined(separator: ", ")). Give the host of the site as site."
            case .noWorkspace(let name): "Nexus has no workspace \(name). Call list_sites to see the workspaces."
            }

            throw ToolFailure(text)
        }

        return try .message(try await done(.removeWorkspace(host: target.site.hosts.first ?? "", name: target.workspace.name, force: false), agent: agent))
    }

    private func removeSite(_ arguments: CallArguments, agent: String) async throws -> MCPToolResult {
        let host = try arguments.required("site")

        guard try await sites().contains(where: { $0.hosts.contains(host) }) else {
            throw ToolFailure("\(host) is not a site of Nexus. Call list_sites to see the sites. A workspace goes with remove_workspace.")
        }

        return try .message(try await done(.removeSite(host: host), agent: agent))
    }

    // MARK: nexusd

    func sites() async throws -> [SiteInfo] {
        let response = try await send(.sites)

        guard case .sites(let sites) = response else {
            throw failure(response)
        }

        return sites
    }

    private func databaseConnections(_ target: SiteTarget) async throws -> [DatabaseConnectionInfo] {
        let response = try await send(.databaseConnections(host: target.siteHost, workspace: target.workspace?.name))

        guard case .databaseConnections(let connections) = response else {
            throw failure(response)
        }

        return connections
    }

    private func siteMail(host: String) async throws -> SiteMail {
        let response = try await send(.siteMail(host: host))

        guard case .siteMail(let mail) = response else {
            throw failure(response)
        }

        return mail
    }

    private func extensionToggles(php: String) async throws -> [Toggle] {
        let response = try await send(.extensions(php: php))

        guard case .toggles(let toggles) = response else {
            throw failure(response)
        }

        return toggles
    }

    // A change names the agent. So activity.log says who asked for it.
    private func done(_ request: NexusRequest, agent: String) async throws -> String {
        let response = try await send(.fromAgent(agent: agent, request: request))

        guard case .done(let message) = response else {
            throw failure(response)
        }

        return message
    }

    private func send(_ request: NexusRequest) async throws -> NexusResponse {
        let response: NexusResponse

        do {
            response = try await connection.send(request)
        } catch is NexusClientError {
            throw NexusNotRunning()
        }

        guard response != .unreadableRequest else {
            throw ToolFailure("nexusd is older than this nexus command. Ask the user to quit Nexus and open it again.")
        }

        return response
    }

    private func failure(_ response: NexusResponse) -> ToolFailure {
        switch response {
        case .failure(let message), .toolNotInstalled(let message), .stopped(let message):
            ToolFailure(Self.withLogHint(message))
        case .portInUse(let conflict):
            ToolFailure(conflict.description)
        case .invalidSettings(let error):
            ToolFailure(error.description)
        case .siteNotCreated(let failure):
            ToolFailure(failure.message)
        default:
            ToolFailure("nexusd gave an answer that this nexus command does not expect. Ask the user to quit Nexus and open it again.")
        }
    }

    static func withLogHint(_ message: String) -> String {
        guard ErrorDetails.split(message).id != nil else {
            return message
        }

        return "\(message) The full output is in the log errors. Call read_log with log errors."
    }

    // MARK: Targets

    private func target(_ site: String?) async throws -> SiteTarget {
        let sites = try await sites()

        if let site, !Self.isFolder(site) {
            guard let target = try? SiteTarget.find(host: site, folder: folder, in: sites, example: "") else {
                throw ToolFailure("Nexus has no site or workspace \(site). Call list_sites to see the sites.")
            }

            return target
        }

        let path = site.map(resolvedFolder) ?? folder

        guard let target = try? SiteTarget.find(host: nil, folder: path, in: sites, example: "") else {
            throw ToolFailure("\(path) is not a Nexus site. Call list_sites to see the sites, or add_site to serve this folder.")
        }

        return target
    }

    static func isFolder(_ value: String) -> Bool {
        value.contains("/") || value.hasPrefix("~") || value == "."
    }

    private func resolvedFolder(_ value: String) -> String {
        let expanded = NSString(string: value).expandingTildeInPath
        let url = URL(filePath: expanded, directoryHint: .isDirectory, relativeTo: URL(filePath: folder, directoryHint: .isDirectory)).standardizedFileURL
        return RealPath.of(url)
    }
}

// An empty text counts as no value.
struct CallArguments {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) {
        self.values = values
    }

    func string(_ key: String) -> String? {
        guard let text = values[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        return text
    }

    func int(_ key: String) -> Int? {
        values[key]?.int
    }

    func bool(_ key: String) -> Bool? {
        values[key]?.bool
    }

    func required(_ key: String) throws -> String {
        guard let value = string(key) else {
            throw ToolFailure("Give \(key).")
        }

        return value
    }
}

enum AgentName {
    static func display(_ client: String?) -> String {
        guard let client, !client.isEmpty else {
            return "an MCP client"
        }

        let lower = client.lowercased()
        let known: [(String, AgentKind)] = [
            ("claude-code", .claudeCode), ("claude code", .claudeCode), ("claude", .claude), ("codex", .codex),
            ("cursor", .cursor), ("gemini", .geminiCLI), ("junie", .junie), ("opencode", .openCode),
            ("visual studio code", .vsCode), ("vscode", .vsCode), ("copilot", .vsCode), ("windsurf", .windsurf), ("zed", .zed),
        ]

        if let agent = known.first(where: { lower.contains($0.0) })?.1 {
            return agent.name
        }

        return String(client.filter { $0.isLetter || $0.isNumber || " -_.".contains($0) }.prefix(40))
    }
}

extension MCPToolResult {
    static func message(_ text: String) throws -> MCPToolResult {
        try .value(["message": text])
    }
}

struct SiteRows: Encodable {
    let sites: [AgentSiteRow]
}

// Only a missing extension comes with the packages that require it. The result stays short.
struct ExtensionsResult: Encodable {
    let site: String
    let php: String
    let missing: [ExtensionState]
    let on: [String]
    let note: String
}

struct ErrorsResult: Encodable {
    let site: String
    let errors: [SiteError]
    let note: String?
}

struct LogList: Encodable {
    let logs: [LogInfo]
}

struct MailList: Encodable {
    let scope: String
    let mails: [MailRow]
    let note: String?
}

struct NoMail: Encodable {
    let found: Bool
    let message: String
}

struct WorkspaceResult: Encodable {
    let message: String
    let workspace: AgentWorkspace
}

struct AddedSite: Encodable {
    let message: String
    let site: AgentSiteRow?
}

struct StatusResult: Encodable {
    let running: Bool
    let services: [ServiceRow]
    let tasks: [TaskRow]
    let problems: [String]
}

struct ServiceRow: Encodable {
    let id: String
    let package: String
    let version: String
    let state: String
    let ports: [Int]

    init(_ service: ServiceInfo) {
        id = service.id
        package = service.name
        version = service.version
        ports = service.ports

        switch service.state {
        case .running: state = "running"
        case .restarting: state = "restarting"
        case .stopped: state = "stopped"
        case .failed: state = "failed"
        }
    }
}

struct TaskRow: Encodable {
    let task: String
    let started: Date
    let progress: String?

    init(_ info: TaskInfo) {
        started = info.started
        progress = info.total.map { total in total > 0 ? "\(min(100, Int(Double(info.completed) / Double(total) * 100)))%" : "0%" }
            ?? info.steps?.first { $0.state == .running }.map(\.title)

        task = switch info.work {
        case .install(let name, let line, let version, let update): "\(update ? "Updates" : "Installs") \(name) \(line) (\(version))"
        case .copyDatabase(let database, let instance, let name): "Copies the database \(database) to \(instance) as \(name)"
        case .dumpDatabase(let name, let instance): "Writes a dump of \(name) on \(instance)"
        case .importDump(let file, let instance, let name): "Loads \(file) into \(name) on \(instance)"
        case .createSite(let name, let template): "Makes the site \(name) from the template \(template.rawValue)"
        case .importSite(let name): "Imports the site \(name)"
        }
    }
}

struct PackageRow: Encodable {
    let package: String
    let line: String
    let version: String
    let installed: Bool
}

struct PackagesResult: Encodable {
    let installed: [PackageRow]
    let available: [PackageRow]
}
