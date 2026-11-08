import Foundation
import NexusCore
import NexusIPC

struct NewSiteRun {
    let site: NewSite
    // A site from a backup (3f) has the values of the import sheet and the format that nexusd found.
    var importing: SiteImport?
    var format: BackupFormat?
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
            await finish(await outcome(of: .createSite(site)), sheet: .newSite)
        }
    }

    // An import shows its end in the sheet, also without a password, because the user logs in with
    // an account of the original site.
    func startImport(_ request: SiteImport, format: BackupFormat?) {
        newSiteRun = NewSiteRun(site: NewSite(template: .wordpress, name: request.name, parent: request.parent, git: request.git, database: request.database), importing: request, format: format)

        Task {
            await finish(await outcome(of: .importSite(request)), sheet: .importSite(backup: URL(filePath: request.backup)))
        }
    }

    private func finish(_ outcome: RequestOutcome?, sheet kind: SheetKind) async {
        switch outcome {
        case .answer(.siteCreated(let created)):
            finishNewSite(created, sheet: kind)
        case .answer(.siteNotCreated(let failure)):
            newSiteRun?.result = .failed(failure)
            sheet = kind
        case .answer(.stopped):
            newSiteRun?.result = .stopped
        case .failure(let message):
            newSiteRun?.result = .refused(message)
            sheet = kind
        case .portInUse(let conflict):
            newSiteRun?.result = .refused(conflict.description)
            sheet = kind
        default:
            newSiteRun = nil
        }
    }

    // The answer to the import sheet before an import: what nexusd found in the backup.
    func inspectBackup(_ backup: URL) async -> Result<BackupInfo, ImportProblem> {
        switch await outcome(of: .inspectBackup(path: backup.path(percentEncoded: false))) {
        case .answer(.backup(let info)):
            .success(info)
        case .failure(let message):
            .failure(ImportProblem(message: message))
        default:
            .failure(ImportProblem(message: "Nexus cannot read the backup now."))
        }
    }

    private func finishNewSite(_ created: CreatedSite, sheet kind: SheetKind) {
        selection = .site(created.host)

        // WordPress shows its password, and an import says how to log in. Both stay in the sheet.
        guard newSiteRun?.site.template != .wordpress else {
            newSiteRun?.result = .created(created)
            sheet = kind
            return
        }

        newSiteRun = nil

        if case .newSite = sheet {
            sheet = nil
        }

        openInBrowser(created.url)
    }

    var newSiteTask: TaskInfo? {
        guard let run = newSiteRun else {
            return nil
        }

        let work: TaskWork = run.importing == nil ? .createSite(name: run.site.name, template: run.site.template) : .importSite(name: run.site.name)
        return tasks.first { $0.work == work }
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
