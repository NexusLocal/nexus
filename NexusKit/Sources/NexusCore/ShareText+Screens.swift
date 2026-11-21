import Foundation

// The texts of the app screens of the links (group 4, 4g). They are in NexusCore, because the app
// has no test target. They have their own file, because other parts add texts to ShareText.swift
// at the same time.
extension ShareText {
    // The texts of the approved design where the contract of 4g differs (owner, 2026-11-20): the
    // Share button ("Share Button States"), the share panel ("Site · Public link") and the footer of
    // Settings > Sharing ("Settings Sharing").
    public static let shareButton = "Share…"
    public static let linkOpensButton = "The link opens…"
    public static let publicButton = "Public"
    public static let notOpenedTitle = "The link did not open."
    public static let tryAgain = "Try Again"
    public static let endsKey = "The link ends"
    public static let visitorsKey = "Visitors"
    public static let stylesKey = "Styles and scripts"
    public static let defaultsFooter = "The confirmation window shows these defaults. A change there applies to that one share only."

    // The value of "The link ends" in the share panel: 18:40, or "When I stop it".
    public static func endValue(_ endsAt: Date?, in zone: TimeZone = .current) -> String {
        endsAt.map { time($0, in: zone) } ?? ShareDuration.untilStopped.title
    }

    // The bar of the Site screen and the help of the mark (ux-texts.md).
    public static func publicUntil(_ host: String, endsAt: Date?, in zone: TimeZone = .current) -> String {
        let end = endsAt.map { "until \(time($0, in: zone))" } ?? until(nil)

        return "\(host) is public \(end)."
    }

    // "2 visitors, the last one 1 minute ago" (ux-texts.md). nexusd cuts lastVisit to its minute.
    public static func visitors(_ count: Int, lastVisit: Date?, now: Date = .now) -> String {
        guard count > 0 else {
            return "No visitors yet"
        }

        guard let lastVisit else {
            return Count.text(count, "visitor")
        }

        return "\(Count.text(count, "visitor")), the last one \(WorkspaceActivity.age(of: lastVisit, now: now))"
    }

    // The count stops at 99+ (owner, 2026-11-17).
    public static func requestsButton(_ count: Int) -> String {
        "Requests (\(count > 99 ? "99+" : String(count)))"
    }

    // The menu bar panel with more than 5 links (owner, 2026-11-17).
    public static func openLinks(_ count: Int) -> String {
        count == 1 ? "1 public link is open" : "\(count) public links are open"
    }

    // A step names the part and says what it does (owner, 2026-11-17).
    public static func stepTitle(_ step: ShareStep) -> String {
        switch step {
        case .downloadCloudflared: "Download cloudflared, the program that makes the public links"
        case .buildAssets: "Build the styles and scripts with Vite"
        case .openLink: "Open the link at Cloudflare"
        }
    }

    // The text of the notification after an end that the user did not ask for. Stop, a quit and a
    // removal of the site give nil, because the user did them.
    public static func stoppedNotification(_ reason: ShareEndReason, endsAt: Date?, in zone: TimeZone = .current) -> String? {
        switch reason {
        case .sleep:
            sleepNotification
        case .connectionLost:
            "The link stopped after a long break in the network connection. \(shareAgainHint)"
        case .nexusdStopped:
            "The link stopped when the background service of Nexus restarted, for example for an update. \(shareAgainHint)"
        case .endTime:
            endsAt.map { "The link stopped at its end time of \(time($0, in: zone)). The old address no longer works." }
                ?? "The link stopped at its end time. The old address no longer works."
        case .failed(let reason):
            reason
        case .stopped, .appQuit, .siteGone:
            nil
        }
    }

    // The end of the approved text after a sleep (ux-texts.md, "After a sleep").
    private static let shareAgainHint = "The old address no longer works. Share the site again and send the new address to the people who need it."

    // The alert before a quit (owner, 2026-11-17: question 1 of review-4ab).
    public static func quitTitle(_ count: Int) -> String {
        "Quit Nexus and stop \(Count.text(count, "public link"))?"
    }

    public static let quitMessage = "Nexus stops each public link when it quits. Then the links no longer work for visitors."

    // The line of the update window. A quick link ends at the restart of nexusd (4b).
    public static func updateLine(_ count: Int) -> String {
        count == 1
            ? "1 public link stops too. Its address then no longer works."
            : "\(count) public links stop too. Their addresses then no longer work."
    }

}

// The choices of Settings > Sharing and of the confirm sheet (ux-texts.md).
extension ShareDuration {
    public var title: String {
        switch self {
        case .oneHour: "After 1 hour"
        case .fourHours: "After 4 hours"
        case .eightHours: "After 8 hours"
        case .untilStopped: "When I stop it"
        }
    }
}

extension ShareViteMode {
    public var title: String {
        switch self {
        case .live: "Live"
        case .build: "Build"
        }
    }
}

extension ShareAddressKind {
    public var title: String {
        switch self {
        case .random: "A new random address"
        case .ownDomain: "An address on my domain"
        }
    }
}

// The orange lines of the confirm sheet (4g). The text of customAccessRules is text 7 of 4d. The
// text of mixHot is text 17 of 4e (owner, 2026-11-20).
extension ShareWarning {
    public var text: String {
        switch self {
        case .sendsRealMail:
            "This site can send real mail. Visitors can make it send mail."
        case .oauthLogin:
            "Logins with Google, GitHub or another OAuth provider do not work on a random address. Use your own domain for them."
        case .serverSentEvents:
            "A page can stream text, for example an AI answer. On a random address that text arrives all at once."
        case .customAccessRules:
            "The custom nginx lines of this site allow or deny addresses. The web server of Nexus (nginx) sees each visitor as this Mac. So these lines do not stop visitors."
        case .viteInTerminal:
            "Vite runs in a terminal. Nexus cannot stop it for Build. Stop it there first, or choose Live."
        case .mixHot:
            "This site uses Laravel Mix with npm run hot. Visitors cannot load the styles and scripts of that hot server. Stop npm run hot and run npm run prod first."
        }
    }

    // The rules of the confirm sheet for the options of the sheet. Vite in a terminal matters only
    // for Build. OAuth and streamed text work on an own domain (4d).
    public func applies(to options: ShareOptions) -> Bool {
        if self == .viteInTerminal, options.viteMode != .build {
            return false
        }

        return !(onlyForRandomAddress && options.address == .ownDomain)
    }
}
