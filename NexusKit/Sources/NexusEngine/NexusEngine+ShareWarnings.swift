import Foundation
import NexusCore
import NexusIPC
import NexusLaravel

// The warnings of the confirm sheet (group 4, 4d). They read files and the mail check of the Site
// screen. They run no npm and no WP-CLI. The preview gives oauthLogin and serverSentEvents also
// for an own domain. The sheet hides them there (ShareWarning.onlyForRandomAddress).
extension NexusEngine {
    // The order is the order of the design: mail, OAuth and streamed text. The warning of the custom
    // lines comes last, because the design does not have it. Only a PHP site in nginx gets its custom
    // nginx lines. Apache takes the address of the visitor from X-Forwarded-For. So Require ip of
    // Apache sees the visitor. project is shareProject(of: target).
    func protectionWarnings(of target: ShareTarget, project: ShareProject?) async -> [ShareWarning] {
        guard let project else {
            return []
        }

        async let mail = shareSendsRealMail(target, project: project)
        let folder = project.folder
        let hosts = target.names
        let files = await Task.detached {
            (oauth: ShareWarningCheck.usesOAuthLogin(folder: folder, hosts: hosts), streams: ShareWarningCheck.streamsText(folder: folder, until: .now + .seconds(2)))
        }.value
        let site = project.main
        let accessRules = site.kind == .php && site.server == .nginx && ShareWarningCheck.hasAccessRules(site.nginxLines ?? [])
        let sendsMail = await mail

        return (sendsMail ? [.sendsRealMail] : []) + (files.oauth ? [.oauthLogin] : []) + (files.streams ? [.serverSentEvents] : []) + (accessRules ? [.customAccessRules] : [])
    }

    // The mail check of the Site screen knows only the main checkout. So a workspace gets the same
    // check on its own folder. The copy of the database of a WordPress workspace keeps the active
    // plugins. So it gets the check of the main checkout. An error of the probe gives no warning
    // (owner, 2026-11-20). The check fails often while PHP starts.
    func shareSendsRealMail(_ target: ShareTarget, project: ShareProject?) async -> Bool {
        guard target.workspace != nil else {
            return ShareWarningCheck.sendsRealMail(await siteMail(host: target.site))
        }

        guard let project else {
            return false
        }

        let state = await stateStore.current()

        let site = project.main

        if site.kind == .php, PHPProject.type(of: site).isWordPress {
            return ShareWarningCheck.sendsRealMail(await siteMail(host: target.site))
        }

        do {
            let port = try await smtpPort(in: state)

            if site.kind == .node {
                let values = try Self.nodeEnvFiles(in: RealPath.of(project.folder)).reduce(into: [String: String]()) { all, file in
                    all.merge(EnvFile.values(in: file.text)) { _, later in later }
                }

                return ShareWarningCheck.isReal(NodeMail.route(values, nexusPort: port))
            }

            guard site.kind == .php, let root = LaravelProject.root(containing: project.folder) else {
                return false
            }

            let configuration = try await configuration(of: site, folder: RealPath.of(root))
            return ShareWarningCheck.isReal(LaravelMail.route(configuration, nexusPort: port))
        } catch {
            return false
        }
    }
}

// The checks of the files of a project. A test gives its own folders and its own end time. A new
// name is one line in a list.
enum ShareWarningCheck {
    static let oauthComposerNames: Set<String> = [
        "laravel/socialite",
        "laravel/workos",
        "hybridauth/hybridauth",
        "knpuniversity/oauth2-client-bundle",
        "hwi/oauth-bundle",
        "jumbojett/openid-connect-php",
    ]

    static let oauthComposerPrefixes = ["socialiteproviders/", "league/oauth2-", "auth0/"]

    static let oauthNodeNames: Set<String> = [
        "next-auth",
        "nuxt-auth-utils",
        "@sidebase/nuxt-auth",
        "arctic",
        "openid-client",
        "simple-oauth2",
        "grant",
        "better-auth",
    ]

    static let oauthNodePrefixes = ["@auth/", "@workos-inc/", "@clerk/", "@auth0/", "@okta/"]

    // A Passport strategy for a login with another service, for example passport-google-oauth20.
    // passport-local is a login with a password of the site itself.
    static let passportWords = ["oauth", "google", "github", "facebook", "apple", "microsoft", "azure", "openid"]

    static let oauthPluginWords = ["oauth", "openid", "social-login", "sociallogin", "single-sign-on", "nextend-facebook-connect", "login-with-google", "super-socializer"]

    static let redirectKeySuffixes = ["_REDIRECT_URI", "_REDIRECT_URL", "_CALLBACK_URI", "_CALLBACK_URL"]

    static let streamMarkers = ["text/event-stream", "eventStream(", "new EventSource(", "wire:stream", "useStream(", "useEventStream("]

    // A name skips each folder with that name. A path skips that folder below the project folder.
    static let skippedFolders: Set<String> = ["vendor", "node_modules", "storage", "bootstrap/cache", "public/build", "public/vendor", "dist", "build", "uploads"]

    static let streamExtensions: Set<String> = ["php", "js", "mjs", "cjs", "ts", "tsx", "jsx", "vue", "svelte", "astro"]

    static let largestStreamFile = 512 * 1_024

    // The plugins folders of WordPress: wp-content/plugins, web/app/plugins of Bedrock and a content
    // folder such as media/plugins.
    static let pluginFolderDepth = 3

    // The rule of the Site screen: a warning with a place where the mail goes. The warning of TLS
    // has no place. That mail fails and reaches nobody.
    static func sendsRealMail(_ mail: SiteMail) -> Bool {
        mail.warning != nil && mail.destination != nil
    }

    static func isReal(_ route: MailRoute?) -> Bool {
        guard case .real? = route else {
            return false
        }

        return true
    }

    static func usesOAuthLogin(folder: URL, hosts: [String]) -> Bool {
        let composer = packageNames(in: folder.appending(path: "composer.json"), sections: ["require", "require-dev"])
        let node = NodeProject.read(in: folder)?.dependencyNames ?? []

        if composer.contains(where: isOAuthComposerPackage) {
            return true
        }

        if node.contains(where: isOAuthNodePackage) {
            return true
        }

        if hasOAuthPlugin(below: folder) {
            return true
        }

        return hasRedirectKey(EnvFile.values(of: folder.appending(path: ".env")), naming: hosts)
    }

    static func isOAuthComposerPackage(_ name: String) -> Bool {
        let name = name.lowercased()
        return oauthComposerNames.contains(name) || oauthComposerPrefixes.contains { name.hasPrefix($0) }
    }

    static func isOAuthNodePackage(_ name: String) -> Bool {
        let name = name.lowercased()

        if oauthNodeNames.contains(name) || oauthNodePrefixes.contains(where: name.hasPrefix) {
            return true
        }

        return name.hasPrefix("passport-") && passportWords.contains { name.contains($0) }
    }

    private static func packageNames(in file: URL, sections: [String]) -> [String] {
        guard let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        return sections.flatMap { section in (json[section] as? [String: Any])?.keys.map { $0 } ?? [] }
    }

    private static func hasOAuthPlugin(below folder: URL) -> Bool {
        var level = [folder]

        for _ in 0..<pluginFolderDepth {
            let children = level.flatMap(subfolders)

            for child in children where ["plugins", "mu-plugins"].contains(child.lastPathComponent) {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: child.path(percentEncoded: false))) ?? []

                if names.contains(where: { name in oauthPluginWords.contains { name.lowercased().contains($0) } }) {
                    return true
                }
            }

            level = children.filter { !["vendor", "node_modules"].contains($0.lastPathComponent) }
        }

        return false
    }

    private static func subfolders(of folder: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    // A value such as ${APP_URL}/auth/callback gets the value of APP_URL first.
    static func hasRedirectKey(_ values: [String: String], naming hosts: [String]) -> Bool {
        let names = Set(hosts.map { $0.lowercased() })

        return values.contains { key, value in
            guard redirectKeySuffixes.contains(where: key.uppercased().hasSuffix) else {
                return false
            }

            let expanded = values.reduce(value) { text, entry in text.replacingOccurrences(of: "${\(entry.key)}", with: entry.value) }
            return URL(string: expanded)?.host().map { names.contains($0.lowercased()) } ?? false
        }
    }

    // At the end time the walk stops and gives false. A large project then gets no warning. The
    // sheet does not wait longer.
    static func streamsText(folder: URL, until end: ContinuousClock.Instant) -> Bool {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]

        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return false
        }

        let root = folder.standardizedFileURL.path(percentEncoded: false)

        for case let file as URL in files {
            guard ContinuousClock.now < end else {
                return false
            }

            let values = try? file.resourceValues(forKeys: Set(keys))

            if values?.isDirectory == true {
                let path = file.standardizedFileURL.path(percentEncoded: false)
                let relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))

                if skippedFolders.contains(file.lastPathComponent) || skippedFolders.contains(relative) {
                    files.skipDescendants()
                }

                continue
            }

            guard streamExtensions.contains(file.pathExtension.lowercased()), (values?.fileSize ?? .max) <= largestStreamFile else {
                continue
            }

            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }

            if streamMarkers.contains(where: text.contains) {
                return true
            }
        }

        return false
    }

    // Custom nginx lines with allow or deny (owner, 2026-11-20). nginx sees 127.0.0.1 for each
    // visitor. So these lines do not stop a visitor. A comment of a line does not count.
    static func hasAccessRules(_ lines: [String]) -> Bool {
        lines.contains { line in
            let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return code.range(of: #"(?:^|[{;\s])(?:allow|deny)\s"#, options: .regularExpression) != nil
        }
    }
}
