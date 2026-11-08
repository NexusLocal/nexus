import Foundation
import NexusCore
import NexusIPC

struct NewSiteRun {
    let site: NewSite
    var result: NewSiteResult?
    var trashing = false
    var trashProblem: String?
}

enum NewSiteResult {
    case created(CreatedSite)
    case failed(SiteCreationFailure)
    // nexusd refused the values before a step ran. The form shows the reason.
    case refused(String)
    // The user stopped it. The form shows the values again, so a second try needs no typing.
    case stopped
}

// A new site from a template (Phase 4, 3m). The task goes on when the user closes the sheet. A new
// site that runs opens in the browser. A failure and the one-time password of WordPress open the
// sheet again, so the user sees them.
extension AppModel {
    func startNewSite(_ site: NewSite) {
        newSiteRun = NewSiteRun(site: site)

        Task {
            let outcome = await outcome(of: .createSite(site))

            switch outcome {
            case .answer(.siteCreated(let created)):
                finishNewSite(created, template: site.template)
            case .answer(.siteNotCreated(let failure)):
                newSiteRun?.result = .failed(failure)
                sheet = .newSite
            case .answer(.stopped):
                newSiteRun?.result = .stopped
            case .failure(let message):
                newSiteRun?.result = .refused(message)
                sheet = .newSite
            case .portInUse(let conflict):
                newSiteRun?.result = .refused(conflict.description)
                sheet = .newSite
            default:
                newSiteRun = nil
            }
        }
    }

    private func finishNewSite(_ created: CreatedSite, template: SiteTemplate) {
        selection = .site(created.host)

        guard template == .wordpress else {
            newSiteRun = nil
            if case .newSite = sheet {
                sheet = nil
            }
            openInBrowser(created.url)
            return
        }

        newSiteRun?.result = .created(created)
        sheet = .newSite
    }

    var newSiteTask: TaskInfo? {
        guard let site = newSiteRun?.site else {
            return nil
        }

        return tasks.first { $0.work == .createSite(name: site.name, template: site.template) }
    }

    func endNewSite() {
        newSiteRun = nil
        sheet = nil
    }

    // The folder and the database of a failed new site. nexusd removes only what that task made.
    func trashNewSiteLeftovers(_ failure: SiteCreationFailure) {
        newSiteRun?.trashing = true
        newSiteRun?.trashProblem = nil

        Task {
            switch await outcome(of: .removeSiteLeftovers(id: failure.id)) {
            case .answer(.done):
                endNewSite()
            case .failure(let message):
                newSiteRun?.trashing = false
                newSiteRun?.trashProblem = message
            default:
                newSiteRun?.trashing = false
            }
        }
    }

    // The URL of a new host, with the HTTPS port of the sites that exist.
    func newSiteURL(host: String) -> String {
        let port = allSites.lazy.compactMap { URL(string: $0.url)?.port }.first
        return port.map { "https://\(host):\($0)" } ?? "https://\(host)"
    }

    // A parked folder first, because each new folder in it becomes a site anyway.
    var newSiteFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let parked = (siteList?.parkedFolders ?? []).map { URL(filePath: $0, directoryHint: .isDirectory) }
        let usual = ["Development", "Sites", "Projects", "Code"].map { home.appending(path: $0, directoryHint: .isDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }

        return parked + usual + [home]
    }
}
