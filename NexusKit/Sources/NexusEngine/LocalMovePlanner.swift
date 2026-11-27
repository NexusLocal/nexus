import Foundation
import NexusCore
import NexusIPC

// What nexusd knows about this Mac when it plans the move from Local (group 11). The planner itself
// reads no file and starts no program, so the tests give it these facts.
struct LocalMoveFacts: Sendable {
    var home: URL
    var localRuns: Bool
    // The lines of the manifest and the installed lines, by package name.
    var offered: [String: [String]]
    // Installed packages as "<name>-<line>", for example "php-8.5" and "mysql-8.4".
    var installed: Set<String>
    var packageBytes: [String: Int64]
    // The ids of the sites whose database server answers on its socket now.
    var running: Set<String> = []
    // By the id of the site: the size of its data folder and the date of its local.sql.
    var dataBytes: [String: Int64] = [:]
    var dumpDates: [String: Date] = [:]
    var hasDataFolder: Set<String> = []
    var hasWPConfig: Set<String> = []
    var hasEnvrc: Set<String> = []
    var direnv = false
    // The domains whose Local certificate macOS trusts.
    var trusted: Set<String> = []
    var nexusHosts: Set<String> = []
    var nexusSiteCount = 0
    var nexusTLD = "test"
}

enum LocalMovePlanner {
    // Local sets 4000 for each site. PHP has 1000, and WordPress sends about 12 fields for each item
    // of a menu (owner, 2026-11-26).
    static let maxInputVars = "max_input_vars = 4000"

    static func plan(setup: LocalSetup, facts: LocalMoveFacts) -> HerdMovePlan {
        let phpLines = facts.offered["php"] ?? []
        var notes: [String] = []
        var sites: [HerdMovePlan.SiteItem] = []
        var databases: [HerdMovePlan.DatabaseItem] = []
        var inNexus: [String] = []
        var names: Set<String> = []

        for site in setup.sites {
            let hosts = [site.domain] + (site.network == .subdomains ? site.networkDomains : [])

            guard !hosts.contains(where: facts.nexusHosts.contains) else {
                inNexus.append(site.domain)
                continue
            }

            let line = site.php.flatMap { HerdMovePlanner.phpLine(for: $0, offered: phpLines) } ?? phpLines.last

            sites.append(HerdMovePlan.SiteItem(
                hosts: hosts,
                folder: HerdMovePlanner.folderPath(site.webRoot),
                kind: .php,
                herdPHP: site.php,
                php: line,
                phpChoices: phpLines,
                projectType: .wordpress,
                ownLines: site.ownLines,
                server: site.server,
                network: site.network
            ))

            if let local = site.php, let line, HerdMovePlanner.majorMinor(local) != line {
                notes.append(VersionLine.isOlder(HerdMovePlanner.majorMinor(local), than: line)
                    ? "\(site.domain) uses PHP \(HerdMovePlanner.majorMinor(local)). Nexus has PHP \(phpLines.first ?? line) and newer, so the site gets PHP \(line)."
                    : "\(site.domain) uses PHP \(HerdMovePlanner.majorMinor(local)). Nexus has no PHP \(HerdMovePlanner.majorMinor(local)) yet, so the site gets PHP \(line) until then.")
            }

            if site.headless {
                notes.append("\(site.domain) has a Node.js front end in Local. Only its WordPress moves.")
            }

            let target = uniqueName(DatabaseName.suggestion(from: site.domain), taken: &names)
            let lines = facts.offered[site.databaseKind] ?? []
            let choice = HerdMovePlanner.databaseLine(for: site.databaseVersion, offered: lines)
            let runs = facts.running.contains(site.id)
            let readsCopy = !runs && facts.hasDataFolder.contains(site.id)
            let dump = facts.dumpDates[site.id] != nil ? site.dump.path(percentEncoded: false) : nil

            databases.append(HerdMovePlan.DatabaseItem(
                name: site.database,
                kind: site.databaseKind,
                version: site.databaseVersion,
                port: site.databasePort,
                socket: site.socket.path(percentEncoded: false),
                account: DatabaseAccount(user: site.user, password: site.password),
                line: choice.line,
                lineChoices: choice.choices,
                bytes: facts.dataBytes[site.id],
                sites: [site.domain],
                target: target,
                runs: runs,
                dataFolder: readsCopy ? site.dataFolder.path(percentEncoded: false) : nil,
                readerLine: readsCopy ? choice.line : nil,
                dump: dump,
                dumpDate: facts.dumpDates[site.id]
            ))

            if let version = site.databaseVersion, let line = choice.line, HerdMovePlanner.majorMinor(version) != line, HerdMovePlanner.major(version) != line {
                notes.append("\(site.domain) uses \(HerdMoveText.packageTitle(site.databaseKind, HerdMovePlanner.majorMinor(version))). Nexus has \(HerdMoveText.packageTitle(site.databaseKind, lines.first ?? line)) and newer, so the database goes to \(HerdMoveText.packageTitle(site.databaseKind, line)).")
            }

            if !runs, !readsCopy {
                notes.append(dump == nil
                    ? "Nexus found no data of \(site.domain). Start the site in Local, then open this sheet again."
                    : "Nexus cannot read the data folder of \(site.domain). So it uses local.sql of the last stop of the site in Local. Changes after that stop are not in it.")
            }

            if site.network == .subdomains {
                notes.append("\(site.domain) is a network on subdomains. Nexus reads its subsites from the database and adds each one as an alias. A new subsite later needs a new alias on the Site screen.")
            }
        }

        if !inNexus.isEmpty {
            notes.insert("\(EnglishList.joined(inNexus)) \(inNexus.count == 1 ? "is" : "are") in Nexus already, so the move leaves \(inNexus.count == 1 ? "it" : "them") out.", at: 0)
        }

        if !sites.isEmpty {
            notes.append("When Local opens or quits, it stops each program with Local Sites in its command line, for example a wp command in Terminal. The sites of Nexus keep running.")
        }

        if setup.localhostRouting {
            notes.append("Local uses the router mode localhost. Each site gets the name of its domain in Nexus, and its URLs change to that name.")
        }

        let moved = Set(sites.map { $0.hosts[0] })
        let ini = iniItems(setup: setup, sites: sites, notes: &notes)

        var plan = HerdMovePlan(
            source: .local,
            herdRuns: facts.localRuns,
            tld: setup.tld,
            sites: sites,
            databases: databases,
            ini: ini,
            files: setup.sites.filter { moved.contains($0.domain) && facts.direnv && facts.hasEnvrc.contains($0.id) }.map { HerdMovePlan.FileItem(path: $0.envrc.path(percentEncoded: false), kind: .envrc, lines: []) },
            notes: notes,
            inNexus: inNexus,
            wpConfigs: setup.sites.filter { moved.contains($0.domain) && facts.hasWPConfig.contains($0.id) }.map { HerdMovePlan.EnvItem(host: $0.domain, file: $0.wpConfig.path(percentEncoded: false)) },
            httpsSites: sites.map { $0.hosts[0] },
            devTLD: facts.nexusTLD == "local" ? nil : HerdMovePlan.DevTLDItem(tld: "local", nexusSites: facts.nexusSiteCount),
            certificates: setup.sites.filter { facts.trusted.contains($0.domain) }.map { setup.certificate(of: $0.domain).path(percentEncoded: false) }
        )
        plan.packages = packages(plan, facts: facts)
        return plan
    }

    // shop.local becomes shop. A second shop gets shop_2.
    static func uniqueName(_ base: String, taken: inout Set<String>) -> String {
        var name = base
        var number = 2

        while taken.contains(name) {
            name = "\(base)_\(number)"
            number += 1
        }

        taken.insert(name)
        return name
    }

    // The php.ini lines of the sites go to the PHP version of each site in Nexus. Two sites with
    // another value on one PHP version: the larger value wins, and a note names both.
    static func iniItems(setup: LocalSetup, sites: [HerdMovePlan.SiteItem], notes: inout [String]) -> [HerdMovePlan.IniItem] {
        var byLine: [String: [(key: String, value: String, host: String)]] = [:]
        var order: [String] = []

        for site in sites {
            guard let line = site.php, let local = setup.sites.first(where: { $0.domain == site.hosts[0] }) else {
                continue
            }

            if byLine[line] == nil {
                order.append(line)
                byLine[line] = []
            }

            for raw in local.phpIniLines {
                let parts = raw.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }

                guard parts.count == 2 else {
                    continue
                }

                let (key, value) = (parts[0], parts[1])

                if let index = byLine[line]?.firstIndex(where: { $0.key == key }) {
                    let other = byLine[line]![index]

                    guard other.value != value else {
                        continue
                    }

                    let larger = isLarger(value, than: other.value)
                    notes.append("\(other.host) has \(key) = \(other.value) and \(site.hosts[0]) has \(key) = \(value). PHP \(line) gets \(larger ? value : other.value).")

                    if larger {
                        byLine[line]![index] = (key, value, site.hosts[0])
                    }

                    continue
                }

                byLine[line]!.append((key, value, site.hosts[0]))
            }
        }

        return order.map { line in
            var lines = (byLine[line] ?? []).map { "\($0.key) = \($0.value)" }

            if !(byLine[line] ?? []).contains(where: { $0.key == "max_input_vars" }) {
                lines.append(maxInputVars)
            }

            return HerdMovePlan.IniItem(herdPHP: line, line: line, lines: lines)
        }
    }

    // 512M is larger than 256M, and 1G is larger than 512M. A value that is no number keeps the
    // first one.
    static func isLarger(_ value: String, than other: String) -> Bool {
        guard let a = number(value), let b = number(other) else {
            return false
        }

        return a == -1 || (b != -1 && a > b)
    }

    static func number(_ value: String) -> Double? {
        let units: [Character: Double] = ["K": 1024, "M": 1024 * 1024, "G": 1024 * 1024 * 1024]
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).uppercased()

        if let last = trimmed.last, let unit = units[last], let base = Double(trimmed.dropLast()) {
            return base * unit
        }

        return Double(trimmed)
    }

    static func packages(_ plan: HerdMovePlan, facts: LocalMoveFacts) -> [HerdMovePlan.Package] {
        var needed: [(name: String, line: String, reasons: [String])] = []

        func need(_ name: String, _ line: String?, for reason: String) {
            guard let line, !facts.installed.contains("\(name)-\(line)") else {
                return
            }

            if let index = needed.firstIndex(where: { $0.name == name && $0.line == line }) {
                needed[index].reasons.append(reason)
                return
            }

            needed.append((name, line, [reason]))
        }

        for site in plan.sites {
            need("php", site.php, for: site.hosts[0])
        }

        for database in plan.databases {
            need(database.kind, database.line, for: database.sites.first ?? database.name)

            if let reader = database.readerLine, reader != database.line {
                need(database.kind, reader, for: "the data of \(database.sites.first ?? database.name)")
            }
        }

        if plan.sites.contains(where: { $0.server == .apache }), let line = facts.offered["httpd"]?.last, !facts.installed.contains(where: { $0.hasPrefix("httpd-") }) {
            need("httpd", line, for: plan.sites.filter { $0.server == .apache }.map { $0.hosts[0] }.joined(separator: ", "))
        }

        // The change of the URLs to https:// runs WP-CLI.
        if !plan.httpsSites.isEmpty, let line = facts.offered["wp-cli"]?.last, !facts.installed.contains(where: { $0.hasPrefix("wp-cli-") }) {
            need("wp-cli", line, for: "the URLs")
        }

        return needed.map { package in
            let reason = package.reasons.count > 3 ? "\(package.reasons.count) sites" : EnglishList.joined(package.reasons)
            return HerdMovePlan.Package(name: package.name, line: package.line, reason: "for \(reason)", bytes: facts.packageBytes["\(package.name)-\(package.line)"])
        }
    }

    // The plan with the choices of the user. A site and its database have one switch.
    static func applying(_ request: HerdMoveRequest, to plan: HerdMovePlan, facts: LocalMoveFacts) -> HerdMovePlan {
        let skipped = Set(request.skipped)
        var result = plan

        result.sites = plan.sites.filter { !skipped.contains($0.id) }.map { site in
            var chosen = site

            if let line = request.php[site.id], site.phpChoices.contains(line) {
                chosen = HerdMovePlan.SiteItem(hosts: site.hosts, folder: site.folder, kind: site.kind, herdPHP: site.herdPHP, php: line, phpChoices: site.phpChoices, projectType: site.projectType, ownLines: site.ownLines, server: site.server, network: site.network)
            }

            if skipped.contains(HerdMovePlan.ownLinesID) {
                chosen = HerdMovePlan.SiteItem(hosts: chosen.hosts, folder: chosen.folder, kind: chosen.kind, herdPHP: chosen.herdPHP, php: chosen.php, phpChoices: chosen.phpChoices, projectType: chosen.projectType, ownLines: [], server: chosen.server, network: chosen.network)
            }

            return chosen
        }

        let moved = Set(result.sites.map { $0.hosts[0] })

        result.databases = plan.databases.filter { !skipped.contains($0.id) && $0.sites.allSatisfy(moved.contains) }.map { database in
            guard let line = request.databaseLines[database.id], database.lineChoices.contains(line) else {
                return database
            }

            return database.choosing(line)
        }
        result.ini = plan.ini.filter { !skipped.contains($0.id) }
        result.wpConfigs = plan.wpConfigs.filter { moved.contains($0.host) }
        result.httpsSites = skipped.contains(HerdMovePlan.httpsID) ? [] : plan.httpsSites.filter(moved.contains)
        result.files = plan.files.filter { file in !skipped.contains(file.id) && result.sites.contains { file.path.hasPrefix(URL(filePath: $0.folder).deletingLastPathComponent().path(percentEncoded: false)) } }

        if let devTLD = plan.devTLD, !(request.useDevTLD ?? devTLD.isOnByDefault) {
            result.devTLD = nil
        }

        result.packages = packages(result, facts: facts)
        return result
    }
}
