import Foundation
import NexusConfig
import NexusCore
import NexusLaravel
import NexusRuntime
import NexusSupervisor

// The host that each kind of site sees and the values of the rewrite (group 4, 4c). Laravel in nginx
// without a cached config sees the public host. Each other kind sees its local host. nginx changes
// the answers for it.

// What 4c knows of one link (group 4, 4c). nexusd makes it before the ports and keeps it in memory
// until the end of the link. envValues holds the .env keys of F3 with their value for nginx.
// $http_x_nexus_share_host stands for the public host. phpInNginx says that nginx gives the site
// its FastCGI values.
struct ShareHostPlan: Sendable, Equatable {
    let redirectHost: String?
    let extraHosts: [String]
    let envValues: [String: String]
    let reverb: ShareReverb?
    let usesWordPress: Bool
    let php: String?
    let phpInNginx: Bool

    static let plain = ShareHostPlan(redirectHost: nil, extraHosts: [], envValues: [:], reverb: nil, usesWordPress: false, php: nil, phpInNginx: false)
}

extension NexusEngine {
    // Vite gives a value of the environment priority over the .env files. A site without Reverb gets
    // none.
    static func viteReverbValues(publicHost: String, usesReverb: Bool) -> [String: String] {
        guard usesReverb else {
            return [:]
        }

        return ["VITE_REVERB_HOST": publicHost, "VITE_REVERB_PORT": "443", "VITE_REVERB_SCHEME": "https"]
    }

    static let shareProbeWait: Duration = .seconds(15)
    static let shareProbeInterval: Duration = .seconds(1)
    static let reverbDefaultPort = 8080
    static let njsModule = "ngx_http_js_module"
    // The public host in a value for nginx. The share block sends it in X-Nexus-Share-Host.
    static let publicHostValue = ShareConfig.Header.host.variable

    // The host that the site of a link sees. A target without a site sees its local host. project
    // is shareProject(of: target).
    func linkHostMode(of target: ShareTarget, project: ShareProject?) async -> ShareHostMode {
        guard let site = project?.site else {
            return .localHost
        }

        let state = await stateStore.current()
        let isNotice = target.workspace != nil && workspaceSites(state).noticeHosts.contains(target.host)
        return Self.hostMode(of: site, layout: SiteLayout(of: site), isNotice: isNotice)
    }

    // Decision 2 and research 4, section 3. Only PHP in nginx gets FastCGI values. A cached config
    // ignores them. Statamic has the files of Laravel. So it counts as Laravel.
    static func hostMode(of site: Site, layout: SiteLayout, isNotice: Bool) -> ShareHostMode {
        guard site.kind == .php, site.server == .nginx, layout.projectType == .laravel, !isNotice else {
            return .localHost
        }

        let folder = URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory)
        let root = LaravelProject.root(containing: folder) ?? folder
        let cachedConfig = root.appending(path: "bootstrap/cache/config.php")

        return FileManager.default.fileExists(atPath: cachedConfig.path(percentEncoded: false)) ? .localHost : .publicHost
    }

    // The step of 4c before the ports (4b, prepareShare). The check of njs comes first. So each link
    // gets it. This is also true for a target without a site (the coordinator, 2026-11-20).
    func prepareShareHosts(_ record: ShareRecord, target: ShareTarget, project: ShareProject?) async throws {
        guard let nginx = await newestRuntime(named: "nginx"), Self.nginxModules(of: nginx).contains(Self.njsModule) else {
            throw RuntimeError.unsupported(ShareText.njsMissing)
        }

        let id = record.id
        let mode = record.mode

        guard let project, let site = project.site else {
            shareHostPlans[id] = .plain
            return
        }

        let state = await stateStore.current()
        let env = Self.shareEnv(of: site)
        let httpsPort = state.ports[ServiceCatalog.httpsPortKey] ?? 443
        let httpPort = state.ports[ServiceCatalog.httpPortKey] ?? 80
        let redirectHost = mode == .localHost ? await probedRedirectHost(id, target: target, httpsPort: httpsPort) : nil

        // A stop during the probe ended the link already. Its end then forgot the plan before it was
        // there. A failure of the install of cloudflared cancels the probe (prepareShare).
        try Task.checkCancellation()
        try await ensureStarting(id)

        shareHostPlans[id] = ShareHostPlan(
            redirectHost: redirectHost,
            extraHosts: shareExtraHosts(of: target, redirectHost: redirectHost, env: env, targets: shareTargets(state)),
            envValues: mode == .publicHost ? Self.publicEnvValues(in: env, host: target.host, httpsPort: httpsPort, httpPort: httpPort) : [:],
            reverb: Self.reverb(in: env, port: knownReverbPort(of: target, main: project.main, in: state)),
            usesWordPress: SiteLayout(of: site).projectType.isWordPress,
            php: site.kind == .php ? site.php : nil,
            phpInNginx: site.kind == .php && site.server == .nginx
        )
    }

    // The second local hosts of a target (F5): its other names and each host of Nexus that its .env
    // names. They do not hold the host of the link or the host that the site redirects to.
    func shareExtraHosts(of target: ShareTarget, redirectHost: String?, env: [String: String], targets: [String: ShareTarget]) -> [String] {
        let own = Set([target.host, redirectHost].compactMap { $0 })
        let known = Set(targets.values.flatMap(\.names))
        let hosts = Set(target.names + Self.envHosts(in: env, known: known)).subtracting(own)

        return hosts.filter { !$0.contains("*") }.sorted()
    }

    // The confirm sheet names the second local hosts (owner, 2026-11-20: question 1). The sheet comes
    // before the probe of F1. So an alias that the site redirects to is in this list too.
    func sharePreviewHosts(of target: ShareTarget, project: ShareProject?, targets: [String: ShareTarget]) -> [String] {
        guard let site = project?.site else {
            return []
        }

        return shareExtraHosts(of: target, redirectHost: nil, env: Self.shareEnv(of: site), targets: targets)
    }

    // The values of SiteShare.fastcgiValues of 4c. A request of the link gets them only for a PHP
    // site in nginx. Each key of the site wins over a key of the .env.
    func shareFastCGIValues(of record: ShareRecord) -> [String: String] {
        let plan = shareHostPlans[record.id] ?? .plain

        guard plan.phpInNginx else {
            return [:]
        }

        let host = Self.publicHostValue
        var values = ["NEXUS_SHARE_HOST": host]

        guard record.mode == .publicHost else {
            return values
        }

        values["HTTP_HOST"] = host
        values["SERVER_NAME"] = host
        values["SERVER_PORT"] = "443"
        values["APP_URL"] = "https://\(host)"
        values["SESSION_DOMAIN"] = "null"

        if plan.reverb != nil {
            values["REVERB_HOST"] = host
            values["REVERB_PORT"] = "443"
            values["REVERB_SCHEME"] = "https"
        }

        return values.merging(plan.envValues) { own, _ in own }
    }

    // The environment of the build of a Build link (4e). The build runs after nexusd reads the
    // public host.
    func viteEnvironment(of record: ShareRecord) -> [String: String] {
        guard let publicHost = record.publicHost else {
            return [:]
        }

        return Self.viteReverbValues(publicHost: publicHost, usesReverb: shareHostPlans[record.id]?.reverb != nil)
    }

    // A link of a WordPress site needs the prepend file of its PHP version for the filters of
    // WooCommerce.
    func linkNeedsStub(line: String, state: EngineState) -> Bool {
        state.shares.contains { record in
            guard record.state.isActive, let plan = shareHostPlans[record.id] else {
                return false
            }

            return plan.usesWordPress && plan.php == line
        }
    }

    // The end of a link: its njs module goes and the plan goes.
    func forgetShareHosts(_ id: String) {
        try? FileManager.default.removeItem(at: paths.shareScript(id))
        shareHostPlans[id] = nil
    }

    // Each share block needs njs for the rewrite of the headers and the reverse rewrite. So the
    // module loads with each share block. This is also true when the user turned it off (the
    // coordinator, 2026-11-20).
    static func modules(_ modules: [String], available: Set<String>, withShares: Bool) -> [String] {
        guard withShares, available.contains(njsModule), !modules.contains(njsModule) else {
            return modules
        }

        return modules + [njsModule]
    }

    // The njs module of each share block, written before the check of nginx.
    func writeShareScripts(_ shares: [ShareBlock], settings: NginxSettings) throws {
        let scripts = shares.compactMap { share in share.rewriteScript.map { (share: share, file: $0) } }

        guard !scripts.isEmpty else {
            return
        }

        try FileManager.default.createDirectory(at: paths.shareFolder, withIntermediateDirectories: true)

        for script in scripts {
            _ = try Self.writeIfChanged(try ShareRewrite.script(for: script.share, settings: settings), to: script.file)
        }
    }

    // F3: each key whose value names the local host, with its value for nginx. Only a whole host
    // counts. So admin.shop.test does not match shop.test. The mail keys keep the tag of each mail.
    // A value with $ stays out. phpdotenv then fills a value such as ${APP_DOMAIN} from the FastCGI
    // value of APP_DOMAIN.
    static func publicEnvValues(in env: [String: String], host: String, httpsPort: Int, httpPort: Int) -> [String: String] {
        let ownKeys: Set<String> = reverb(in: env, port: nil) == nil
            ? ["APP_URL", "SESSION_DOMAIN"]
            : ["APP_URL", "SESSION_DOMAIN", "REVERB_HOST", "REVERB_PORT", "REVERB_SCHEME"]
        let url = "https://\(publicHostValue)"
        let forms = [
            (from: "https://\(host):\(httpsPort)", to: url),
            (from: "https://\(host)", to: url),
            (from: "http://\(host):\(httpPort)", to: url),
            (from: "http://\(host)", to: url),
            (from: "\(host):\(httpsPort)", to: publicHostValue),
            (from: host, to: publicHostValue),
        ]
        var values: [String: String] = [:]

        for (key, value) in env where !ownKeys.contains(key) && !["MAIL_", "DB_", "REDIS_"].contains(where: { key.hasPrefix($0) }) {
            guard ConfigText.isSafeKey(key), isSafeValue(value) else {
                continue
            }

            let changed = replacingWholeHosts(in: value, forms: forms)

            if changed != value {
                values[key] = changed
            }
        }

        return values
    }

    // The hosts of known in the values of env, as whole hosts.
    static func envHosts(in env: [String: String], known: Set<String>) -> [String] {
        let text = env.keys.sorted().compactMap { env[$0] }.joined(separator: "\n")

        return known.filter { host in
            replacingWholeHosts(in: text, forms: [(from: host, to: "")]) != text
        }.sorted()
    }

    // F4 from the .env and the known port. Without a known port the port of the .env counts.
    static func reverb(in env: [String: String], port: Int?) -> ShareReverb? {
        let connections = [env["BROADCAST_CONNECTION"], env["BROADCAST_DRIVER"]].compactMap { $0?.lowercased() }

        guard connections.contains("reverb"), let key = env["REVERB_APP_KEY"], let appID = env["REVERB_APP_ID"], isReverbName(key), isReverbName(appID) else {
            return nil
        }

        return ShareReverb(port: port ?? env["REVERB_SERVER_PORT"].flatMap { Int($0) } ?? reverbDefaultPort, key: key, appID: appID)
    }

    // One GET for / to nginx with the local host (research 4, F1). curl does not follow a redirect.
    // --resolve sends the request to this Mac without the DNS of macOS. -k accepts the certificate of
    // Nexus.
    static func redirectProbe(host: String, httpsPort: Int) async -> String? {
        let url = "https://\(host)\(NginxSettings.portSuffix(httpsPort, standard: 443))/"
        let command = Command(
            executable: URL(filePath: "/usr/bin/curl"),
            arguments: ["-sk", "--max-time", "5", "--resolve", "\(host):\(httpsPort):127.0.0.1", "-o", "/dev/null", "-w", "%{http_code} %{redirect_url}", "-H", "Accept: text/html", url]
        )

        guard let output = try? await CommandRunner.run(command) else {
            return nil
        }

        return probeAnswer(output.standardOutput)
    }

    // The answer of curl is "<status> <URL>". nil is no answer yet: no connection or a site that
    // starts (502, 503 or 504). An empty text is an answer without a redirect.
    static func probeAnswer(_ output: String) -> String? {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1).map(String.init)

        guard let status = parts.first.flatMap({ Int($0) }), status != 0, ![502, 503, 504].contains(status) else {
            return nil
        }

        guard [301, 302, 303, 307, 308].contains(status), parts.count == 2 else {
            return ""
        }

        return parts[1]
    }

    // Only another name of the same target counts. A redirect to a host of another site or of the
    // internet keeps the main host.
    static func redirectHost(from location: String, names: [String], host: String) -> String? {
        guard let found = URLComponents(string: location)?.host?.lowercased(), found != host, !found.contains("*"), names.contains(found) else {
            return nil
        }

        return found
    }

    // The probe is a page of the site. So it can start a stopped workspace and the programs that
    // start with a page, as the first visitor does. A site that starts answers 502, 503 or 504.
    private func probedRedirectHost(_ id: String, target: ShareTarget, httpsPort: Int) async -> String? {
        let probe = shareRedirectProbe
        let deadline = ContinuousClock.now + Self.shareProbeWait

        while true {
            if let answer = await probe(target.host, httpsPort) {
                return Self.redirectHost(from: answer, names: target.names, host: target.host)
            }

            guard ContinuousClock.now < deadline, !Task.isCancelled, (try? await ensureStarting(id)) != nil else {
                return nil
            }

            try? await Task.sleep(for: Self.shareProbeInterval)
        }
    }

    // The main checkout keeps the Reverb port of its configuration. A workspace has its own port.
    private func knownReverbPort(of target: ShareTarget, main: Site, in state: EngineState) -> Int? {
        let key = ProjectFolder.workspaceKey(of: main)

        guard let name = target.workspace else {
            let plan = mainProcessPlans[key]
            return plan?.ports["reverb"] ?? plan?.reverbPort
        }

        return state.worktrees[key]?.workspaces.first { $0.name == name }?.ports["reverb"]
    }

    private static func shareEnv(of site: Site) -> [String: String] {
        let folder = URL(filePath: ProjectFolder.projectFolder(of: site), directoryHint: .isDirectory)
        return EnvFile.values(of: folder.appending(path: ".env"))
    }

    // A whole host: the character before it is no letter, digit, hyphen or dot. The character after
    // it is no letter, digit or hyphen. It is also no dot before a letter or a digit. At one place
    // the first form wins.
    private static func replacingWholeHosts(in value: String, forms: [(from: String, to: String)]) -> String {
        let alternatives = forms.map { NSRegularExpression.escapedPattern(for: $0.from) }.joined(separator: "|")

        guard let pattern = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9.-])(?:\(alternatives))(?![A-Za-z0-9-]|\\.[A-Za-z0-9])", options: .caseInsensitive) else {
            return value
        }

        let text = value as NSString
        var result = ""
        var last = 0

        for match in pattern.matches(in: value, range: NSRange(location: 0, length: text.length)) {
            let found = text.substring(with: match.range)
            result += text.substring(with: NSRange(location: last, length: match.range.location - last))
            result += forms.first { $0.from.caseInsensitiveCompare(found) == .orderedSame }?.to ?? found
            last = match.range.location + match.range.length
        }

        return result + text.substring(from: last)
    }

    // A value goes between double quotes in a map of nginx. A $ would be a variable of nginx.
    private static func isSafeValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains { "\"\\$".unicodeScalars.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }

    private static func isReverbName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
}
