import AppKit
import NexusCore
import NexusIPC
import NexusSupervisor

// One move from Herd. The texts come from the plan and the choices at the start, because the plan
// can change while the move runs.
struct HerdMoveRun: Equatable {
    let request: HerdMoveRequest
    let summary: String
    let movedText: String
    let tld: String
    var result: HerdMoveResult?
}

enum HerdMoveResult: Equatable {
    case done(String)
    case failed(String)
    case stopped(String)
}

// The choices of the user in the sheet "Move from Herd". A switch that is off adds the id of its
// item to skipped. A popup keeps the chosen line by the id of its item.
struct HerdMoveChoices: Equatable {
    var skipped: Set<String> = []
    var php: [String: String] = [:]
    var databaseLines: [String: String] = [:]

    // One switch can stand for more items, for example the php.ini lines of each PHP version.
    func isOn(_ ids: [String]) -> Bool {
        !ids.allSatisfy(skipped.contains)
    }

    mutating func set(_ ids: [String], on: Bool) {
        if on {
            skipped.subtract(ids)
        } else {
            skipped.formUnion(ids)
        }
    }

    func phpLine(of site: HerdMovePlan.SiteItem) -> String? {
        php[site.id] ?? site.php
    }

    func line(of database: HerdMovePlan.DatabaseItem) -> String? {
        databaseLines[database.id] ?? database.line
    }

    func sites(of plan: HerdMovePlan) -> [HerdMovePlan.SiteItem] {
        plan.sites.filter { isOn([$0.id]) }
    }

    func databases(of plan: HerdMovePlan) -> [HerdMovePlan.DatabaseItem] {
        plan.databases.filter { isOn([$0.id]) }
    }

    func redis(of plan: HerdMovePlan) -> [HerdMovePlan.RedisItem] {
        plan.redis.filter { isOn([$0.id]) }
    }

    func movesItems(of plan: HerdMovePlan) -> Bool {
        !sites(of: plan).isEmpty || !databases(of: plan).isEmpty || !redis(of: plan).isEmpty
    }

    func movesSettings(of plan: HerdMovePlan) -> Bool {
        let ownLines = isOn([HerdMovePlan.ownLinesID]) && sites(of: plan).contains { !$0.ownLines.isEmpty }
        let ids = (plan.ini.map(\.id) + plan.envFiles.map(\.id) + plan.files.map(\.id)).filter { isOn([$0]) }

        return ownLines || !ids.isEmpty
    }

    func request(for plan: HerdMovePlan) -> HerdMoveRequest {
        HerdMoveRequest(
            skipped: skipped.sorted(),
            php: php.filter { id, line in plan.sites.first { $0.id == id }?.php != line },
            databaseLines: databaseLines.filter { id, line in plan.databases.first { $0.id == id }?.line != line }
        )
    }

    // "6 sites, 3 databases and your settings". Only the items that are on count.
    func summary(of plan: HerdMovePlan, settings: String) -> String {
        let sites = sites(of: plan).count
        let databases = databases(of: plan).count
        var parts: [String] = []

        if sites > 0 {
            parts.append(Count.text(sites, "site"))
        }

        if databases > 0 {
            parts.append(Count.text(databases, "database"))
        }

        if movesSettings(of: plan) {
            parts.append(settings)
        }

        return EnglishList.joined(parts)
    }

    // The packages follow the switches and the popups, as in the plan of nexusd. isMissing says
    // that Nexus does not have that version line yet.
    func packages(of plan: HerdMovePlan, isMissing: (String, String) -> Bool, bytes: (String, String) -> Int64?) -> [HerdMovePlan.Package] {
        var needed: [(name: String, line: String, reasons: [String])] = []

        func need(_ name: String, _ line: String?, for reason: String) {
            guard let line, isMissing(name, line) else {
                return
            }

            if let index = needed.firstIndex(where: { $0.name == name && $0.line == line }) {
                needed[index].reasons.append(reason)
                return
            }

            needed.append((name, line, [reason]))
        }

        for site in sites(of: plan) where site.kind == .php {
            need("php", phpLine(of: site), for: site.hosts[0])
        }

        for database in databases(of: plan) {
            need(database.kind, line(of: database), for: database.name)
        }

        for server in redis(of: plan) {
            need("redis", server.line, for: "the Redis keys")
        }

        return needed.map { package in
            HerdMovePlan.Package(name: package.name, line: package.line, reason: "for \(package.reasons.joined(separator: ", "))", bytes: bytes(package.name, package.line))
        }
    }
}

// The move from Herd or Valet (group 9, docs/group9-herd.md). The Overview shows a notice while the
// app has sites that did not move. The first run opens the sheet when it ends. nexusd reads the
// files of the app and runs the move as a task with steps. The request answers only at the end of
// the move.
extension AppModel {
    static let herdFolder = HerdReader.folder(home: FileManager.default.homeDirectoryForCurrentUser)
    private static let loginItemsSettings = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

    static func configFile(of source: MoveSource) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser

        switch source {
        case .herd: return herdFolder.appending(path: "config/valet/config.json")
        case .valet: return ValetReader.folder(home: home).appending(path: "config.json")
        }
    }

    static func certificate(of source: MoveSource) -> URL {
        switch source {
        case .herd: herdFolder.appending(path: "config/valet/CA/LaravelValetCASelfSigned.pem")
        case .valet: ValetReader.certificate(home: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    // The plan of nexusd knows which app has the sites. Before the plan, Herd comes first.
    var moveSource: MoveSource {
        herdMovePlan?.source ?? foundMoveSource ?? .herd
    }

    // An app without config.json has no sites, and nexusd then has no plan. An activation reads the
    // plan only for the notice, and at most once a minute.
    func findHerd() {
        let source = MoveSource.allCases.first { FileManager.default.fileExists(atPath: Self.configFile(of: $0).path(percentEncoded: false)) }
        let found = source != nil

        if found != herdFound {
            herdFound = found
        }

        if source != foundMoveSource {
            foundMoveSource = source
        }

        guard found, wantsHerdMoveNotice else {
            return
        }

        Task {
            await loadHerdMovePlan(reusingWithin: 60)
        }
    }

    // The sheet reads the plan each time it opens, because a package or a site can be new.
    func loadHerdMovePlan(reusingWithin seconds: TimeInterval = 0) async {
        guard isLive, herdFound, !loadingHerdMovePlan else {
            return
        }

        if let loaded = herdMovePlanLoaded, Date.now.timeIntervalSince(loaded) < seconds {
            return
        }

        loadingHerdMovePlan = true

        switch await outcome(of: .herdMovePlan) {
        case .answer(.herdMovePlan(let plan)):
            herdMovePlan = plan
            herdMovePlanProblem = nil
            herdMovePlanLoaded = .now
        case .failure(let message):
            herdMovePlanProblem = message
        default:
            break
        }

        loadingHerdMovePlan = false
    }

    private var wantsHerdMoveNotice: Bool {
        !hiddenHerdMoveNotice && herdMovedText == nil && herdMoveRun == nil
    }

    // A move from the command line has a task, but no run of this app.
    var liveHerdMoveTask: TaskInfo? {
        tasks.first { $0.work == .moveFromHerd }
    }

    var showsHerdMoveNotice: Bool {
        guard herdFound, wantsHerdMoveNotice, liveHerdMoveTask == nil, let plan = herdMovePlan else {
            return false
        }

        return !plan.isEmpty
    }

    // Each site of the app is in Nexus, for example after nexus import herd in Terminal.
    var herdSitesMoved: Bool {
        herdMovePlan.map { $0.isEmpty && !$0.inNexus.isEmpty } == true
    }

    var herdMoveNoticeText: String {
        guard let plan = herdMovePlan else {
            return ""
        }

        var parts = [Count.text(plan.sites.count, "site")]

        if !plan.databases.isEmpty {
            parts.append(Count.text(plan.databases.count, "database"))
        }

        if !plan.ini.isEmpty {
            parts.append("your PHP settings")
        }

        return "Nexus found \(EnglishList.joined(parts)) in \(plan.source.name). Nexus copies them to Nexus. \(plan.source.name) and its files stay as they are."
    }

    func hideHerdMoveNotice() {
        hiddenHerdMoveNotice = true
        UserDefaults.standard.set(true, forKey: AppPreference.hiddenHerdMoveNotice)
    }

    func hideHerdMoved() {
        herdMovedText = nil
        UserDefaults.standard.removeObject(forKey: AppPreference.herdMovedText)
    }

    // The first run ends with the sheet when Herd or Valet has sites (owner, 2026-11-24).
    func openHerdMoveAfterFirstRun() {
        guard herdFound else {
            return
        }

        Task {
            await loadHerdMovePlan()

            guard let plan = herdMovePlan, !plan.isEmpty, sheet == nil else {
                return
            }

            sheet = .moveFromHerd
        }
    }

    func startHerdMove(plan: HerdMovePlan, choices: HerdMoveChoices) {
        let settings = choices.isOn(plan.ini.map(\.id)) && !plan.ini.isEmpty ? "your PHP settings" : "your settings"
        let moved = choices.summary(of: plan, settings: settings)
        let verb = !moved.contains(" and ") && moved.hasPrefix("1 ") ? "is" : "are"

        herdMoveRun = HerdMoveRun(
            request: choices.request(for: plan),
            summary: choices.summary(of: plan, settings: "your settings"),
            movedText: "\(moved) \(verb) in Nexus now. Nexus kept a copy of each file that it changed.",
            tld: plan.tld
        )
        herdMoveTask = nil
        runHerdMove()
    }

    func tryHerdMoveAgain() {
        herdMoveRun?.result = nil
        herdMoveTask = nil
        runHerdMove()
    }

    private func runHerdMove() {
        guard let request = herdMoveRun?.request else {
            return
        }

        guard isLive else {
            showSampleHerdMove("progress")
            return
        }

        Task {
            switch await outcome(of: .moveFromHerd(request)) {
            case .answer(.done(let message)):
                finishHerdMove(with: .done(message))
            case .answer(.stopped(let message)):
                finishHerdMove(with: .stopped(message))
            case .failure(let message):
                finishHerdMove(with: .failed(message))
            case .portInUse(let conflict):
                finishHerdMove(with: .failed(conflict.description))
            default:
                finishHerdMove(with: .failed("nexusd gave no answer. The report of the move is in \(shortPath(NexusPaths.standard.moves))."))
            }
        }
    }

    // The sheet opens again at the end, so the user sees it. Another sheet that is open stays.
    private func finishHerdMove(with result: HerdMoveResult) {
        herdMoveRun?.result = result

        if case .done = result, let text = herdMoveRun?.movedText {
            herdMovedText = text
            UserDefaults.standard.set(text, forKey: AppPreference.herdMovedText)
            hideHerdMoveNotice()
            hideWebServerNotice(of: [moveSource.name])
        }

        if sheet == nil {
            sheet = .moveFromHerd
        }
    }

    func endHerdMove() {
        herdMoveRun = nil
        sheet = nil
    }

    func keepHerdMoveTask(from list: TaskList) {
        guard let task = list.tasks.first(where: { $0.work == .moveFromHerd }), task != herdMoveTask else {
            return
        }

        herdMoveTask = task
    }

    // The last event of the task can still show the step that ran at the end.
    func endedHerdMoveSteps(_ result: HerdMoveResult) -> [TaskStep] {
        (herdMoveTask?.steps ?? []).map { step in
            var step = step

            if case .done = result, step.state != .failed {
                step.state = .done
            } else if step.state == .running {
                step.state = .failed
            }

            return step
        }
    }

    func quitHerd() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: HerdReader.bundleIdentifier) {
            app.terminate()
        }
    }

    func openLoginItems() {
        if let url = Self.loginItemsSettings {
            NSWorkspace.shared.open(url)
        }
    }

    // The folder of each move has the app, the date and the time in its name, for example
    // valet-2026-11-25-101500. So the last date is the newest.
    var newestHerdReport: URL? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: NexusPaths.standard.moves, includingPropertiesForKeys: nil)) ?? []
        let dated = folders.compactMap { folder -> (date: String, folder: URL)? in
            let name = folder.lastPathComponent
            let source = MoveSource.allCases.first { name.hasPrefix("\($0.rawValue)-") }
            return source.map { (String(name.dropFirst($0.rawValue.count + 1)), folder) }
        }
        let report = dated.max { $0.date < $1.date }?.folder.appending(path: "report.md")

        return report.flatMap { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) ? $0 : nil }
    }

    func showHerdReport() {
        guard let report = newestHerdReport else {
            NSWorkspace.shared.open(NexusPaths.standard.moves)
            return
        }

        NSWorkspace.shared.open(report)
    }

    // The sample data shows the banner of the design also on a Mac without Herd or Valet.
    var hasHerdCertificate: Bool {
        !isLive || FileManager.default.fileExists(atPath: Self.certificate(of: moveSource).path(percentEncoded: false))
    }

    // Herd 2 trusts its certificate for this user only. Valet trusts its certificate for each user
    // of this Mac, in the System keychain (-d). macOS asks for the password in both cases. The answer
    // is the reason of a failure, in plain words.
    func removeHerdCertificateTrust() async -> String? {
        guard isLive else {
            return nil
        }

        let source = moveSource
        let domain = source == .valet ? ["-d"] : []
        let command = Command(executable: URL(filePath: "/usr/bin/security"), arguments: ["remove-trusted-cert"] + domain + [Self.certificate(of: source).path(percentEncoded: false)])

        do {
            try await CommandRunner.run(command)
            return nil
        } catch {
            let reason = ErrorText.plain(error)

            if reason.localizedCaseInsensitiveContains("cancel") {
                return "You canceled the password question. So macOS still trusts the \(source.name) certificate."
            }

            return "macOS did not remove the trust of the \(source.name) certificate. \(reason)"
        }
    }
}

// The plan of the design for --sample: the test Mac of docs/group9-herd.md. --herd-move states adds
// the cases of "Sheet Move From Herd · States". Valet parks ~/Sites and writes no shell lines.
extension AppModel {
    static func sampleHerdMovePlan(states: Bool = false, source: MoveSource = .herd) -> HerdMovePlan {
        let home = NSHomeDirectory()
        let parked = "\(home)/\(source == .herd ? "Herd" : "Sites")"
        let account = DatabaseAccount(user: "root", password: "")
        let mb: (Double) -> Int64 = { Int64($0 * 1_000_000) }
        let phpLines = ["8.2", "8.3", "8.4", "8.5"]
        var sites = [
            HerdMovePlan.SiteItem(hosts: ["shop.test"], folder: "\(parked)/shop", kind: .php, herdPHP: "8.5", php: "8.5", phpChoices: phpLines, parkedIn: parked, projectType: .laravel),
            HerdMovePlan.SiteItem(hosts: ["blog.test"], folder: "\(parked)/blog", kind: .php, herdPHP: "8.5", php: "8.5", phpChoices: phpLines, parkedIn: parked, projectType: .laravel),
            HerdMovePlan.SiteItem(hosts: ["news.test"], folder: "\(parked)/news", kind: .php, herdPHP: "8.5", php: "8.5", phpChoices: phpLines, parkedIn: parked, projectType: .wordpress),
            HerdMovePlan.SiteItem(hosts: ["api.test", "api-v2.test"], folder: "\(home)/Code/api-server", kind: .php, herdPHP: "8.3", php: "8.3", phpChoices: phpLines, ownLines: ["add_header Access-Control-Allow-Origin *;"]),
            HerdMovePlan.SiteItem(hosts: ["legacy.test"], folder: "\(home)/Code/legacy-app", kind: .php, herdPHP: "8.1", php: "8.2", phpChoices: phpLines),
            HerdMovePlan.SiteItem(hosts: ["admin.test"], folder: "", kind: .proxy, herdPHP: nil, php: nil, phpChoices: [], address: "127.0.0.1:3000"),
        ]
        var databases = [
            HerdMovePlan.DatabaseItem(name: "shop", kind: "mysql", version: "8.4.7", port: 3306, account: account, line: "8.4", lineChoices: ["8.4", "9.7"], bytes: mb(1.2), sites: ["shop.test"]),
            HerdMovePlan.DatabaseItem(name: "news", kind: "mysql", version: "8.4.7", port: 3306, account: account, line: "8.4", lineChoices: ["8.4", "9.7"], bytes: mb(0.9), sites: ["news.test"]),
            HerdMovePlan.DatabaseItem(name: "blog", kind: "postgresql", version: "17.7", port: 5432, account: account, line: "17", lineChoices: ["17", "18"], bytes: mb(0.4), sites: ["blog.test"]),
        ]
        var redis = [HerdMovePlan.RedisItem(port: 6379, password: nil, valkey: false, version: "8.2.3", keys: 3, line: "8.2", sites: ["shop.test"])]
        var notes = ["legacy.test uses PHP 8.1. Nexus has PHP 8.2 and newer, so the site gets PHP 8.2."]

        if states {
            sites.append(HerdMovePlan.SiteItem(hosts: ["next.test"], folder: "\(parked)/next", kind: .php, herdPHP: "8.6", php: "8.5", phpChoices: phpLines, parkedIn: parked, projectType: .laravel))
            databases.append(HerdMovePlan.DatabaseItem(name: "crm", kind: "mysql", version: "9.4.0", port: 3307, account: account, line: "9.7", lineChoices: ["9.7"], bytes: mb(2.1), sites: ["next.test"]))
            redis.append(HerdMovePlan.RedisItem(port: 6380, password: nil, valkey: true, version: "8.1.1", keys: 12, line: "8.2", sites: ["next.test"]))
            notes.append("next.test uses PHP 8.6. Nexus has no PHP 8.6 yet, so the site gets PHP 8.5 until then.")
        }

        let iniLines = source == .herd ? ["memory_limit=512M", "upload_max_filesize=64M", "max_execution_time=123"] : ["max_execution_time=123", "memory_limit=512M", "upload_max_filesize=512M", "post_max_size=512M"]
        let files = [
            HerdMovePlan.FileItem(path: "\(home)/.zshrc", kind: .shell, lines: ["# Herd injected PHP binary.", "export PATH=\"\(home)/Library/Application Support/Herd/bin/\":$PATH", "# Herd injected NVM configuration", "export NVM_DIR=\"\(home)/Library/Application Support/Herd/config/nvm\""]),
            HerdMovePlan.FileItem(path: "\(home)/Herd/shop/.mcp.json", kind: .project, lines: ["\"command\": \"\(home)/Library/Application Support/Herd/bin/php85\","]),
        ]

        return HerdMovePlan(
            source: source,
            herdRuns: true,
            tld: "test",
            packages: [
                HerdMovePlan.Package(name: "php", line: "8.3", reason: "for api.test", bytes: mb(31)),
                HerdMovePlan.Package(name: "php", line: "8.2", reason: "for legacy.test", bytes: mb(30)),
                HerdMovePlan.Package(name: "postgresql", line: "17", reason: "for blog", bytes: mb(42)),
                HerdMovePlan.Package(name: "redis", line: "8.2", reason: "for the Redis keys", bytes: mb(9)),
            ],
            parked: [HerdMovePlan.ParkedFolder(folder: parked, php: "8.5")],
            sites: sites,
            databases: databases,
            redis: redis,
            ini: [HerdMovePlan.IniItem(herdPHP: "8.5", line: "8.5", lines: iniLines)],
            envFiles: [
                HerdMovePlan.EnvItem(host: "shop.test", file: "\(parked)/shop/.env"),
                HerdMovePlan.EnvItem(host: "blog.test", file: "\(parked)/blog/.env"),
            ],
            files: source == .herd ? files : [],
            notes: notes
        )
    }

    // --herd-move review|states|progress|quit-herd|done|failed opens a state of the sheet. The steps
    // have the order of NexusEngine.herdMoveSteps.
    func showSampleHerdMove(_ state: String, source: MoveSource = .herd) {
        herdFound = true
        foundMoveSource = source
        herdMovePlan = Self.sampleHerdMovePlan(states: state == "states", source: source)

        guard !["review", "states"].contains(state) else {
            herdMoveRun = nil
            return
        }

        if herdMoveRun == nil, let plan = herdMovePlan {
            herdMoveRun = HerdMoveRun(request: HerdMoveRequest(), summary: "6 sites, 3 databases and your settings", movedText: "", tld: plan.tld)
        }

        let running = ["progress": 2, "quit-herd": 4, "failed": 0][state]
        let shell = source == .herd ? [("~/.zshrc and ~/Herd/shop/.mcp.json", 1)] : []
        let plannedSteps = [("Install PHP 8.3, PHP 8.2, PostgreSQL 17 and Redis 8.2", 38), ("php.ini lines", 1), ("Databases: shop, news and blog", 9), ("Redis keys", 1), (source.stopStep, 14), ("Ports 80 and 443 and the domain .test", 2), ("Sites: 6", 2), ("nginx lines", 1), (".env of shop.test and blog.test", 1)] + shell + [("Open each site once", 3)]
        let titles = plannedSteps.map(\.0)
        let seconds = plannedSteps.map(\.1)
        let steps = titles.indices.map { index in
            guard let running else {
                return TaskStep(title: titles[index], state: .done, seconds: seconds[index])
            }

            if index < running {
                return TaskStep(title: titles[index], state: .done, seconds: seconds[index])
            }

            return TaskStep(title: titles[index], state: index == running ? .running : .waiting)
        }
        let log = ["== Databases: shop, news and blog", "$ nexus db copy shop --to mysql-8.4 --from-port 3306", "Copied 14 tables of shop.", "$ nexus db copy news --to mysql-8.4 --from-port 3306"]
        let task = TaskInfo(id: "move-from-herd", work: .moveFromHerd, started: .now, steps: steps, log: log, logFile: "\(NexusPaths.standard.moves.path(percentEncoded: false))/\(source.rawValue)-sample/move.log")

        herdMoveTask = task
        show(TaskList(tasks: running == nil || state == "failed" ? [] : [task]))

        switch state {
        case "done":
            herdMoveRun?.result = .done("Nexus moved 6 sites and 3 databases from \(source.name). The report is in ~/Library/Application Support/Nexus/moves/\(source.rawValue)-sample/report.md.")
        case "failed":
            herdMoveRun?.result = .failed("Nexus could not download PostgreSQL 17. The connection to the download server ended.")
        default:
            herdMoveRun?.result = nil
        }
    }

    // --herd-notice move|moved shows a notice of the Overview.
    func showSampleHerdNotice(_ state: String, source: MoveSource = .herd) {
        herdFound = true
        foundMoveSource = source
        herdMovePlan = Self.sampleHerdMovePlan(source: source)
        hiddenHerdMoveNotice = false
        herdMovedText = state == "moved" ? "6 sites, 3 databases and your PHP settings are in Nexus now. Nexus kept a copy of each file that it changed." : nil
    }
}
