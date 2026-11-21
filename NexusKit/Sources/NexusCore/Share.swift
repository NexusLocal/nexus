import Foundation

// "The link ends" (owner, 2026-11-17). The raw value is the number of minutes, as DevServerStop.
// 0 is "When I stop it". The order of the cases is the order of the picker.
public enum ShareDuration: Int, Codable, Sendable, CaseIterable {
    case oneHour = 60
    case fourHours = 240
    case eightHours = 480
    case untilStopped = 0

    // The end of a link that starts at start, nil for "When I stop it".
    public func end(from start: Date) -> Date? {
        self == .untilStopped ? nil : start.addingTimeInterval(TimeInterval(rawValue * 60))
    }
}

// "Styles and scripts of Vite sites" (owner, 2026-11-17: a dropdown).
public enum ShareViteMode: String, Codable, Sendable, CaseIterable {
    case live
    case build
}

// "Address". ownDomain shows only after the setup of a domain.
public enum ShareAddressKind: String, Codable, Sendable {
    case random
    case ownDomain = "own_domain"
}

// The options of one link. EngineState.shareDefaults holds the defaults of Settings > Sharing. A
// key that is not in the JSON gets the value of standard.
public struct ShareOptions: Codable, Sendable, Hashable {
    public var duration: ShareDuration
    public var password: Bool
    public var hidesErrors: Bool
    public var viteMode: ShareViteMode
    public var keepsRequests: Bool
    public var address: ShareAddressKind

    public static let standard = ShareOptions(duration: .eightHours, password: false, hidesErrors: true, viteMode: .live, keepsRequests: false, address: .random)

    public init(duration: ShareDuration, password: Bool, hidesErrors: Bool, viteMode: ShareViteMode, keepsRequests: Bool, address: ShareAddressKind) {
        self.duration = duration
        self.password = password
        self.hidesErrors = hidesErrors
        self.viteMode = viteMode
        self.keepsRequests = keepsRequests
        self.address = address
    }

    // A value of a newer nexusd also gets the value of standard. decodeWithoutLoss then still finds
    // a changed value in a request, because the value that comes back is not the value that was sent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = ShareOptions.standard

        duration = (try? container.decodeIfPresent(ShareDuration.self, forKey: .duration)) ?? standard.duration
        password = (try? container.decodeIfPresent(Bool.self, forKey: .password)) ?? standard.password
        hidesErrors = (try? container.decodeIfPresent(Bool.self, forKey: .hidesErrors)) ?? standard.hidesErrors
        viteMode = (try? container.decodeIfPresent(ShareViteMode.self, forKey: .viteMode)) ?? standard.viteMode
        keepsRequests = (try? container.decodeIfPresent(Bool.self, forKey: .keepsRequests)) ?? standard.keepsRequests
        address = (try? container.decodeIfPresent(ShareAddressKind.self, forKey: .address)) ?? standard.address
    }
}

// The host that the site sees (decision 2).
public enum ShareHostMode: String, Codable, Sendable {
    case publicHost = "public_host"
    case localHost = "local_host"
}

// The steps of the start, in the order of the share panel.
public enum ShareStep: String, Codable, Sendable {
    case downloadCloudflared = "download_cloudflared"
    case buildAssets = "build_assets"
    case openLink = "open_link"
}

public enum ShareEndReason: Codable, Sendable, Hashable {
    case stopped
    case endTime
    case sleep
    case connectionLost
    case appQuit
    case nexusdStopped
    case siteGone
    case failed(String)
}

public enum ShareState: Codable, Sendable, Hashable {
    case starting(ShareStep)
    case open
    case ended(ShareEndReason)
}

// The warnings of the confirm sheet. 4d gives the first four and 4e the others. 4g gives the
// texts (ShareWarning.text in ShareText.swift).
public enum ShareWarning: String, Codable, Sendable, CaseIterable {
    case sendsRealMail = "sends_real_mail"
    case oauthLogin = "oauth_login"
    case serverSentEvents = "server_sent_events"
    // Custom nginx lines with allow or deny do not stop a visitor (group 4, 4d).
    case customAccessRules = "custom_access_rules"
    case viteInTerminal = "vite_in_terminal"
    // 4e: a Laravel Mix site that runs npm run hot (owner, 4e question 5).
    case mixHot = "mix_hot"

    // 4d: OAuth and streamed text work on an own domain (owner, 2026-11-17). The sheet can change
    // the address after the preview. So the preview gives these warnings and the sheet hides them.
    public var onlyForRandomAddress: Bool {
        self == .oauthLogin || self == .serverSentEvents
    }
}

// One link in config/state.json. id is 32 random hex characters and the value of X-Nexus-Share.
// host is the first host of the site or the workspace. The share block sends it. An alias names the
// same link. site is the main host of the site. label is the label on the own domain. port is 0
// until nexusd gives the ports. metricsPort is nil for an own-domain link, because one cloudflared
// serves all of them. publicHost and password go at the end of the link. 4d sets password and 4h
// sets label.
public struct ShareRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let host: String
    public let site: String
    public let workspace: String?
    public let options: ShareOptions
    public let mode: ShareHostMode
    public var label: String?
    public var publicHost: String?
    public var password: String?
    public var port: Int
    public var metricsPort: Int?
    public let started: Date
    public var endsAt: Date?
    public var state: ShareState
    // 4e: the option of Vite applies to this link. liveBlocked is the text of an old Vite version.
    public var usesVite: Bool
    public var liveBlocked: String?

    public init(
        id: String,
        host: String,
        site: String,
        workspace: String? = nil,
        options: ShareOptions,
        mode: ShareHostMode,
        label: String? = nil,
        publicHost: String? = nil,
        password: String? = nil,
        port: Int = 0,
        metricsPort: Int? = nil,
        started: Date,
        endsAt: Date? = nil,
        state: ShareState,
        usesVite: Bool = false,
        liveBlocked: String? = nil
    ) {
        self.id = id
        self.host = host
        self.site = site
        self.workspace = workspace
        self.options = options
        self.mode = mode
        self.label = label
        self.publicHost = publicHost
        self.password = password
        self.port = port
        self.metricsPort = metricsPort
        self.started = started
        self.endsAt = endsAt
        self.state = state
        self.usesVite = usesVite
        self.liveBlocked = liveBlocked
    }

    // 4e: the link serves a build of the styles and scripts.
    public var buildsAssets: Bool {
        usesVite && options.viteMode == .build
    }
}

// A request of a link in the dump list (4f). It is in NexusCore, because DumpedRequest is in
// NexusCore and NexusCore has no dependency. host is the local host of the link (ShareRecord.host),
// because the public host of an own-domain link stays the same for each link.
public struct PublicLinkRequest: Codable, Sendable, Hashable {
    public let host: String
    public let visitor: String?
    public let size: Int?
    public let contentType: String?

    public init(host: String, visitor: String?, size: Int?, contentType: String?) {
        self.host = host
        self.visitor = visitor
        self.size = size
        self.contentType = contentType
    }
}

extension ShareState {
    // A link that starts or is open holds its ports and its program.
    public var isActive: Bool {
        if case .ended = self {
            return false
        }

        return true
    }
}

extension ShareEndReason {
    // The reason after "stopped: " in activity.log, in nexus share list and in the MCP field ended.
    // It never holds the address, the password or the share id. A reason names the part and says
    // what it does (owner, review-4ab question 21).
    public var logText: String {
        switch self {
        case .stopped: "the user stopped it."
        case .endTime: "the end time passed."
        case .sleep: "Cloudflare removed the link during a sleep."
        case .connectionLost: "Cloudflare removed the link after a long break in the network connection."
        case .appQuit: "the Nexus app quit."
        case .nexusdStopped: "the background service of Nexus (nexusd) restarted, for example for an update."
        case .siteGone: "Nexus no longer has this site or workspace, or its host changed."
        case .failed(let reason): reason
        }
    }
}
