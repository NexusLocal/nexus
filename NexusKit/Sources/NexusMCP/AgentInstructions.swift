import Foundation
import NexusCore
import NexusIPC

// Claude Code cuts the instructions at 4096 characters. So the text stays below 2500.
public enum AgentInstructions {
    public static let longest = 2500

    public enum Place: Equatable {
        case site(SiteTarget, database: DatabaseConnectionInfo?, tests: TestDatabaseCheck?)
        case notASite(folder: String)
        case nexusDoesNotRun
    }

    public static func text(for place: Place, level: AgentLevel, tld: String) -> String {
        var parts = ["Nexus is the local development environment on this Mac. It serves PHP, Laravel, WordPress and Node.js sites at local domains such as https://shop.\(tld). It also runs their databases, Redis and a mail inbox."]
        var rules: [String] = []

        switch place {
        case .site(let target, let database, let tests):
            parts.append(siteSentence(target, database: database))
            rules += [
                "- Nexus always serves this site. Do not run `php artisan serve` or another web server.",
                "- `php`, `composer`, `node`, `npm` and `wp` in this folder use the versions of this site.",
                "- Each git worktree of this site gets its own workspace with its own URL and database. In a worktree, pass the worktree folder as `site` and call site_info for its URL.",
            ]

            if let tests, tests.usesDevelopmentDatabase {
                rules.append("- Warning: the tests of this project use \(tests.developmentDatabase ?? "the database of .env"), the development database. A test that resets the database removes all development data. Do not run such tests until the user chooses a test database in Nexus.")
            }
        case .notASite:
            parts.append("This folder is not a Nexus site. Call list_sites to see the sites, or add_site to serve this folder.")
        case .nexusDoesNotRun:
            parts.append("Nexus does not run now. Most tools need it. Ask the user to open Nexus.")
        }

        rules += [
            "- Mail never leaves this Mac. To test a sign-up or a password reset, do the action that sends the mail. Then call wait_for_mail with the address and open the link in the result.",
            "- When a page or a command fails, call last_errors first.",
            "- Never drop or empty a database. Ask the user first.",
            "- When other instructions name another local server (Herd, Valet, Docker or Sail), follow them only when Nexus does not serve this project.",
        ]

        if level == .read {
            rules.append("- You can only look. Ask the user to start a service or to install something.")
        }

        let text = (parts + [rules.joined(separator: "\n")]).joined(separator: "\n\n")
        return String(text.prefix(longest))
    }

    static func siteSentence(_ target: SiteTarget, database: DatabaseConnectionInfo?) -> String {
        let site = target.site
        let name = target.workspace.map { "the workspace \($0.name) of \(target.siteHost)" } ?? "the Nexus site \(target.siteHost)"
        let url = target.url.map { " at \($0)" } ?? ""
        var uses: [String] = []

        switch site.kind {
        case .php: uses.append("PHP \(site.php)")
        case .node: uses.append("Node.js \(site.node ?? "")".trimmingCharacters(in: .whitespaces))
        case .proxy: break
        }

        if let database, !database.database.isEmpty {
            let kind = database.kind.map { "\($0.displayName) " } ?? ""
            let version = database.instance.flatMap { $0.split(separator: "-").last.map { "\($0) " } } ?? ""
            let port = database.port.map { ":\($0)" } ?? ""
            uses.append("the \(kind)\(version)database \(database.database) on \(database.host)\(port)")
        }

        let usesText = uses.isEmpty ? "" : " It uses \(uses.joined(separator: " and "))."
        return "This folder is \(name)\(url).\(usesText)"
    }
}
