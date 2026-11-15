import NexusCore
import SwiftUI

// The custom lines of the webserver that the site uses (owner, 2026-11-14). Each workspace of the
// site gets the same lines. The design of this section is "Site Webserver Lines" in nexus.pen. The
// section follows the saved webserver, not the picker.
struct SiteLinesSection: View {
    @Environment(AppModel.self) private var model
    let site: SiteItem

    var body: some View {
        let key = site.linesKey
        let server = site.webServer

        CustomLinesSection(
            title: "Custom \(server.displayName) lines",
            saveTitle: "Save and reload",
            lines: Binding(
                get: { model.siteLinesDrafts.lines(of: key, saved: site.serverLines) },
                set: { model.siteLinesDrafts.edit(key, to: $0, saved: site.serverLines) }
            ),
            error: model.siteLinesDrafts.errors[key],
            subject: site.host,
            runs: site.problem == nil && model.service(server.serviceID)?.isActive == true,
            noun: "lines",
            changed: model.siteLinesDrafts.drafts[key] != nil,
            saving: model.siteLinesDrafts.saving.contains(key),
            footer: server == .apache ? apacheFooter : nginxFooter,
            revert: { model.siteLinesDrafts.revert(key) },
            save: { model.saveSiteLines(of: site) }
        )
    }

    private var nginxFooter: String {
        "Nexus adds these lines to the server block of \(site.host), before its own locations. Nexus checks them with nginx -t before nginx reloads. When a line has an error, \(site.host) keeps the old lines. Each workspace of \(site.host) gets the same lines."
    }

    private var apacheFooter: String {
        "Nexus adds these lines to the VirtualHost of \(site.host). Nexus checks them with httpd -t before Apache reloads. When a line has an error, \(site.host) keeps the old lines. Each workspace of \(site.host) gets the same lines."
    }
}
