import Foundation

// The texts of the links that more than one part shows (group 4). The app, nexus share and the MCP
// server use them. The approved texts come from docs/group4/ux-texts.md.
public enum ShareText {
    public static let terms = "Links go through Cloudflare. The terms of Cloudflare apply to each link."
    public static let termsURL = URL(string: "https://www.cloudflare.com/website-terms/")!
    public static let sleepHelp = "\(sleepStopsLink) Its address then no longer works."

    // The first two sentences of each help line about sleep.
    static let sleepStopsLink = "The link works while this Mac is awake and online. After a sleep of more than a few minutes the link stops."
    public static let warning = "Anyone with the link can open this site. Visitors see the data in your local database and can do what a visitor of the site can do."
    public static let sleepNotification = "The link stopped while your Mac was asleep. The old address no longer works. Share the site again and send the new address to the people who need it."

    // The refusals and the failures of a start (4b). The app, nexus share and the line "did not
    // open" show them. A text names the part and says what it does (owner, review-4ab question 21).
    public static let nginxNotRunning = "The web server of Nexus (nginx) does not run. Start the services of Nexus. Then try again."
    public static let ownDomainMissing = "Your own domain is not set up. Set it up in Settings > Sharing, or use a new random address."
    public static let noAddress = "Cloudflare gave no address for the link within 30 seconds. Try again later."
    public static let tooManyLinks = "Cloudflare refuses new links from this Mac for a short time. Try again in a few minutes."
    public static let noConnection = "The program that makes the public links (cloudflared) did not connect to Cloudflare within 60 seconds. Check the network connection of this Mac. Then try again."
    public static let addressFails = "The address of the link does not work after 60 seconds. Try again later."

    public static func stoppedBeforeOpen(log: String) -> String {
        "The program that makes the public links (cloudflared) stopped before the link opened. Its log is \(log)."
    }

    public static func cloudflaredStopped(log: String) -> String {
        "The program that makes the public links (cloudflared) stopped. Its log is \(log)."
    }

    public static func portNotOpen(_ port: Int) -> String {
        "The web server of Nexus (nginx) did not open port \(port) for the link. Try again."
    }

    // The texts of the host of a link (4c). The owner approved them on 2026-11-20.
    public static let njsMissing = "A public link needs the njs module of nginx, the web server of Nexus. The installed nginx does not have it. Update nginx in Packages. Then try again."

    // The line of the confirm sheet that names the second local hosts. It is no warning, because the
    // link works for these hosts.
    public static func alsoReaches(_ hosts: [String]) -> String? {
        guard !hosts.isEmpty else {
            return nil
        }

        return "Visitors can also open \(EnglishList.joined(hosts)) through this link."
    }

    // 4d: the password file of a link with "Ask visitors for a password".
    public static func passwordNotSaved(_ reason: String) -> String {
        "Nexus cannot save the password of the link in its data folder. \(reason)"
    }

    // The answers of the other requests (4b).
    public static let noLinkOpen = "No link is open."
    public static let defaultsSaved = "Nexus saved the defaults for new links."

    // The answer of a stop: the title of the notification as a sentence.
    public static func linkStopped(_ host: String) -> String {
        "\(stoppedTitle(host))."
    }

    public static func noOpenLink(_ host: String) -> String {
        "\(host) has no open link."
    }

    public static func stoppedLinks(_ count: Int) -> String {
        "Nexus stopped \(Count.text(count, "link"))."
    }

    // The output of nexus share (4b).
    public static let staysOpen = "The link stays open until you stop it."
    public static let opensNow = "opens now"
    public static let forOrUntilStopped = "Use --for or --until-stopped, not both."

    public static func opening(_ host: String) -> String {
        "Nexus opens a link to \(host). This can take a minute."
    }

    public static func endsAt(_ date: Date, in zone: TimeZone = .current) -> String {
        "The link ends at \(time(date, in: zone))."
    }

    public static func passwordLine(_ password: String) -> String {
        "The user name is nexus. The password is \(password)."
    }

    public static func stopHint(_ host: String) -> String {
        "Stop the link with: nexus share stop \(host)"
    }

    public static func openAlready(_ host: String) -> String {
        "\(host) has an open link already. Nexus did not change its options."
    }

    public static func ownDomainSleepHelp(_ domain: String) -> String {
        "Your address on \(domain) stays the same."
    }

    public static func stoppedTitle(_ host: String) -> String {
        "The link to \(host) stopped"
    }

    // The time of the end in the time zone of the Mac, for example 18:40. One formatter serves the
    // zone of the start of the program.
    public static func time(_ date: Date, in zone: TimeZone = .current) -> String {
        let formatter = zone == timeFormatter.timeZone ? timeFormatter : makeTimeFormatter(in: zone)
        return formatter.string(from: date)
    }

    private static let timeFormatter = makeTimeFormatter(in: .current)

    private static func makeTimeFormatter(in zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    // "until 18:40" or "until you stop it".
    public static func until(_ endsAt: Date?) -> String {
        endsAt.map { "until \(time($0))" } ?? "until you stop it"
    }

    // The lines of activity.log. A line never holds the public address, the password or the share
    // id. The Vite part shows only for a site that uses Vite.
    public static func opensLine(host: String, options: ShareOptions, endsAt: Date?, usesVite: Bool) -> String {
        let parts: [String?] = [
            endsAt.map { "ends \(time($0))" } ?? "ends when you stop it",
            options.password ? "password on" : "password off",
            options.hidesErrors ? "error details hidden" : "error details shown",
            usesVite ? (options.viteMode == .live ? "Vite Live" : "Vite Build") : nil,
            options.keepsRequests ? "requests on" : "requests off",
        ]

        return "Nexus opens a link to \(host): \(parts.compactMap { $0 }.joined(separator: ", "))."
    }

    public static func openLine(_ host: String) -> String {
        "The link to \(host) is open."
    }

    public static func notOpenedLine(_ host: String, reason: ShareEndReason) -> String {
        "The link to \(host) did not open: \(reason.logText)"
    }

    public static func stoppedLine(_ host: String, reason: ShareEndReason) -> String {
        "The link to \(host) stopped: \(reason.logText)"
    }

    // The line of a build for a link (4e, overview "The activity log"). Build Again writes it too.
    public static func buildLine(_ host: String) -> String {
        "Nexus builds the assets of \(host) for its link."
    }

    // The texts of 4a. A start that fails gives its text as the reason of the link. A text for the
    // user names the part and says what it does. The lines of activity.log stay technical.
    public enum Cloudflared {
        public static func noPackageList(_ reason: String) -> String {
            "Nexus cannot download cloudflared, the program that makes the public links. Check that this Mac is online. \(reason)"
        }

        public static let notInPackageList = "The downloads of Nexus have no cloudflared, the program that makes the public links. Try again later."

        public static let noBinary = "Nexus did not get a complete download of cloudflared, the program that makes the public links. Try again later."

        public static func inUse(host: String) -> String {
            "The link to \(host) uses cloudflared, the program that makes the public links. Stop the link first."
        }

        public static func download(_ version: String) -> String {
            "Nexus downloads cloudflared \(version) before a link opens."
        }

        public static func update(from old: String, to new: String) -> String {
            "Nexus updates cloudflared \(old) to \(new) before a link opens."
        }

        public static func updateFailed(from old: String, to new: String, reason: String) -> String {
            "Nexus did not update cloudflared \(old) to \(new). The link uses \(old). \(reason)"
        }

        public static func oldPackageList(_ version: String, reason: String) -> String {
            "Nexus cannot read the package list. The link uses cloudflared \(version). \(reason)"
        }
    }

    // The texts of 4e that nexusd gives (owner, 4e question 6).
    public enum Vite {
        public static let inTerminal = ShareWarning.viteInTerminal.text
        public static let inTerminalWithoutLive = "Vite runs in a terminal. Nexus cannot stop it for Build. Stop it there first."
        public static let noBuildScript = "Nexus cannot build the styles and scripts of this site. Its package.json has no build script."

        // The approved text of the owner (2026-11-20). It is the same with and without a port in
        // the file.
        public static let hotFileStays = "Nexus cannot build the styles and scripts of this site. The file public/hot names no dev server that answers. Remove public/hot. Then share the site again."

        public static func notIgnored(_ output: String) -> String {
            "Nexus cannot build the styles and scripts of this site. git does not ignore \(output). A build would change files that git sees."
        }

        public static func stopsForBuild(_ host: String) -> String {
            "Nexus stops this program, because a public link of \(host) uses Build."
        }

        public static func buildFailed(_ command: String, log: String) -> String {
            "The build of the styles and scripts (\(command)) did not work. Its log is \(log)."
        }

        public static func buildTooLong(_ command: String, log: String) -> String {
            "The build of the styles and scripts (\(command)) did not end in 10 minutes. Nexus stopped it. Its log is \(log)."
        }

        public static func builtAgain(_ host: String) -> String {
            "Nexus built the styles and scripts of \(host) again."
        }

        public static func notOpenYet(_ host: String) -> String {
            "The link to \(host) is not open yet. Try again when it is open."
        }

        public static func noBuild(_ host: String) -> String {
            "The link to \(host) does not use Build. Build Again works only with Build."
        }

        public static func removedOutput(_ output: String) -> String {
            "Nexus removed \(output), because the build of a public link made it."
        }
    }
}
