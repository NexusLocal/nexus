import AppKit
import NexusCore
import NexusIPC
import UserNotifications

// The state of the link of one host for the Share button and its panel.
enum PublicLinkState: Equatable {
    case none
    case starting(ShareStep?)
    case open(ShareInfo)
    case failed(String)
}

// The notification of a link that stopped has the button "Share Again" (owner, 2026-11-17). The
// app registers the category at its launch.
enum PublicLinkNotification {
    static let categoryID = "publicLinkStopped"
    static let shareAgainID = "shareAgain"

    static var category: UNNotificationCategory {
        let shareAgain = UNNotificationAction(identifier: shareAgainID, title: "Share Again", options: [.foreground])
        return UNNotificationCategory(identifier: categoryID, actions: [shareAgain], intentIdentifiers: [])
    }
}

// The public links (group 4, 4g). nexusd keeps the links and the defaults. The app shows them,
// asks before each link and posts a notification after an end.
extension AppModel {
    // The map of the links by host for a new list of sites. A workspace of two sites of one project
    // shows once. A value that stays the same is not set again. So no view draws again for it.
    func showLinks(of entries: [SiteEntry]) {
        let links = Dictionary(entries.flatMap(\.sites).flatMap { site in [site.share] + site.workspaces.map(\.share) }.compactMap { $0 }.map { ($0.host, $0) }) { first, _ in first }
        let hasActive = links.values.contains { $0.state.isActive }

        if links != publicLinksByHost {
            publicLinksByHost = links
        }

        if hasActive != hasActivePublicLink {
            hasActivePublicLink = hasActive
        }
    }

    // Each link of the sites and the workspaces in the order of its host. An ended link is in the
    // list too.
    var publicLinks: [ShareInfo] {
        publicLinksByHost.values.sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
    }

    // The links that start or are open.
    var activePublicLinks: [ShareInfo] {
        publicLinks.filter(\.state.isActive)
    }

    func activeLinks(of site: SiteItem) -> [ShareInfo] {
        ([site.share] + site.workspaces.map(\.share)).compactMap { $0 }.filter(\.state.isActive)
    }

    func publicLink(host: String) -> ShareInfo? {
        publicLinksByHost[host]
    }

    // The count of the requests of a link with the list on. The app counts them in its dump list.
    // So a busy link does not send the site list each second (group 4, 4f). The sample data has
    // its own count.
    func requestCount(of link: ShareInfo) -> Int? {
        guard isLive, link.requestCount != nil else {
            return link.requestCount
        }

        return dumpRequests.count { request in request.publicLink?.host == link.host }
    }

    func linkState(of host: String) -> PublicLinkState {
        if let link = publicLink(host: host) {
            switch link.state {
            case .open: return .open(link)
            case .starting(let step): return .starting(step)
            case .ended: break
            }
        }

        if startingShares.contains(host) {
            return .starting(nil)
        }

        return shareFailures[host].map(PublicLinkState.failed) ?? .none
    }

    // The Site screen of a link. The link of a workspace also names the workspace.
    func linkPlace(of host: String) -> (site: String, workspace: String?)? {
        if site(host) != nil {
            return (host, nil)
        }

        for site in allSites {
            if let workspace = site.workspaces.first(where: { $0.hosts?.contains(host) == true }) {
                return (site.host, workspace.name)
            }
        }

        return nil
    }

    // The Site screen with the panel of the Share button, or with the mark of the workspace row. A
    // popover does not open while a sheet of the window closes. So the panel opens a moment later.
    func showLink(of host: String) {
        guard let place = linkPlace(of: host) else {
            return
        }

        selection = .site(place.site)

        if let workspace = place.workspace {
            markedRow = .workspace(site: place.site, name: workspace)
            return
        }

        Task {
            try? await Task.sleep(for: .milliseconds(400))

            if selection == .site(place.site) {
                sharePanelHost = host
            }
        }
    }

    // nexusd keeps the defaults. The sample data keeps them in the settings.
    var shareDefaults: ShareOptions {
        siteList?.shareDefaults ?? settings.shareDefaults
    }

    func setShareDefaults(_ options: ShareOptions) {
        guard isLive else {
            settings.shareDefaults = options
            return
        }

        send(.setShareDefaults(options), failure: "The defaults for new links did not change", place: .settings)
    }

    // "Share…", the Share button without a link and "Share Again" open the confirm sheet
    // (decision 3).
    func askToShare(host: String) {
        sheet = .share(host: host)
    }

    // The sample data has its own preview. A failure gives the text of nexusd.
    func sharePreview(host: String) async -> (preview: SharePreview?, problem: String?) {
        guard isLive else {
            return (Self.sampleSharePreview(host: host, variant: ShareSheet.debugPreview, defaults: shareDefaults, ownDomain: connectedOwnDomain?.domain), nil)
        }

        switch await outcome(of: .sharePreview(host: host)) {
        case .answer(.sharePreview(let preview)):
            return (preview, nil)
        case .failure(let message):
            return (nil, message)
        default:
            return (nil, nil)
        }
    }

    // The sheet closes at once. The Share button or the workspace row then shows the start. A
    // start that failed shows its reason in the panel of the Share button. An alert shows it when
    // that panel cannot show: for a workspace, or on another screen (question 5 of the owner).
    func startShare(_ start: ShareStart) {
        let host = start.host
        shareFailures[host] = nil
        cancelledStarts.remove(host)
        showLink(of: host)

        guard isLive else {
            startSampleShare(start)
            return
        }

        startingShares.insert(host)

        Task {
            let reply = await outcome(of: .startShare(start))
            startingShares.remove(host)

            guard case .failure(let message) = reply, cancelledStarts.remove(host) == nil else {
                return
            }

            shareFailures[host] = message

            if let place = linkPlace(of: host), place.workspace == nil, selection == .site(place.site) {
                sharePanelHost = host
                return
            }

            failure = ActionFailure(title: "The link to \(host) did not open", message: message, place: .window)
        }
    }

    func clearShareFailure(host: String) {
        shareFailures[host] = nil
    }

    func stopShare(host: String, from place: ActionPlace = .window) {
        if startingShares.contains(host) {
            cancelledStarts.insert(host)
        }

        guard isLive else {
            changeSampleLink(host, to: nil)
            return
        }

        send(.stopShare(host: host), failure: "The link to \(host) did not stop", place: place)
    }

    func stopAllShares(from place: ActionPlace = .window) {
        cancelledStarts.formUnion(startingShares)

        guard isLive else {
            activePublicLinks.forEach { changeSampleLink($0.host, to: nil) }
            return
        }

        send(.stopAllShares(appQuit: false), failure: "Nexus did not stop the public links", place: place)
    }

    // Build Again of a link with Build (4e). The button shows a spinner until the answer.
    func rebuildShare(host: String) {
        guard isLive else {
            return
        }

        rebuildingShares.insert(host)

        Task {
            await perform(.rebuildShare(host: host), failure: "Nexus did not build the styles and scripts of \(host) again", place: .window)
            rebuildingShares.remove(host)
        }
    }

    // The quit asks only while a link is active. After an uninstall and without nexusd the list
    // is old. So the quit does not ask then.
    var linksToStopAtQuit: Int {
        guard uninstalled == nil else {
            return 0
        }

        if case .unreachable = nexusdProblem {
            return 0
        }

        return activePublicLinks.count
    }

    // A quit ends each link (overview, 4b). The quit waits at most 10 seconds for nexusd. A stop
    // of cloudflared takes at most 5 seconds (contract 4b, change 26). A task group waits for each
    // of its tasks at its end. So the first of two tasks ends the wait through a stream.
    func stopAllSharesBeforeQuit() async {
        guard isLive else {
            return
        }

        let (ends, end) = AsyncStream.makeStream(of: Void.self)

        Task {
            _ = await outcome(of: .stopAllShares(appQuit: true))
            end.yield()
        }

        Task {
            try? await Task.sleep(for: .seconds(10))
            end.yield()
        }

        for await _ in ends {
            break
        }

        end.finish()
    }

    // A link that was open and ended without a click of the user gets a notification (owner,
    // 2026-11-20: question 1). The first list after a launch only gets noted. A start that
    // failed gets none. The panel, an alert or nexus share shows it.
    func notifyStoppedLinks(in list: SiteList) {
        let links = Self.links(in: list)
        let known = knownLinkStates
        knownLinkStates = Dictionary(links.map { (Self.linkKey($0), $0.state) }, uniquingKeysWith: { first, _ in first })

        guard let known else {
            return
        }

        var notified: Set<String> = []

        for link in links {
            let key = Self.linkKey(link)

            guard known[key] == .open, case .ended(let reason) = link.state, let body = ShareText.stoppedNotification(reason, endsAt: link.endsAt), notified.insert(key).inserted else {
                continue
            }

            Notifier.post(ShareText.stoppedTitle(link.host), body, target: .publicLink(host: link.host), setting: AppPreference.notifyLinkStopped, category: PublicLinkNotification.categoryID)
        }
    }

    private static func links(in list: SiteList) -> [ShareInfo] {
        list.sites.flatMap { site in [site.share] + (site.workspaces ?? []).map(\.share) }.compactMap { $0 }
    }

    // A new link of the same host has another start time.
    private static func linkKey(_ link: ShareInfo) -> String {
        "\(link.host) \(link.started.timeIntervalSince1970)"
    }

    // The sample data has no nexusd. Share and Stop change the link of a site. A workspace link of
    // the sample data stays as it is, because WorkspaceInfo has only let fields.
    func changeSampleLink(_ host: String, to link: ShareInfo?) {
        siteEntries = siteEntries.map { entry in
            entry.changingSite(host) { site in
                site.share = link
            }
        }
    }

    // An address on the own domain of the sample data is <label>.<the connected sample domain> (4h).
    private func startSampleShare(_ start: ShareStart) {
        let options = start.options(defaults: shareDefaults)
        let password = options.password ? Self.samplePassword : nil
        let domain = options.address == .ownDomain ? connectedOwnDomain?.domain : nil
        let address = domain.map { OwnDomainName.address(label: start.label ?? OwnDomainName.defaultLabel(of: start.host), domain: $0) }
            ?? "calm-river-tree-lamp.trycloudflare.com"

        changeSampleLink(start.host, to: Self.sampleLink(host: start.host, site: start.host, address: address, endsAt: options.duration.end(from: .now), visitors: 0, lastVisit: nil, requests: options.keepsRequests ? 0 : nil, password: password, viteMode: options.viteMode))
    }
}
