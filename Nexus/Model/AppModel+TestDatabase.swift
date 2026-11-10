import Foundation
import NexusCore
import NexusIPC
import NexusMCP

struct NewTestDatabase {
    let name: String
    let instance: String
}

// What the user chose in the sheet "Choose a database for the tests".
enum TestDatabaseAction {
    case use(TestDatabasePlan, makes: NewTestDatabase?)
    case keep
}

extension SiteItem {
    // A site on public/ has phpunit.xml and the env files one folder up, in the project folder.
    var projectFolder: URL {
        NexusCore.ProjectFolder.projectFolderURL(ofSiteFolder: URL(filePath: folder, directoryHint: .isDirectory))
    }
}

// The help for tests that use the development database. The user is in charge. Nexus only
// writes the env file of the tests, and makes a database when the user asks for it.
extension AppModel {
    func keepsTestDatabase(of site: SiteItem) -> Bool {
        keptTestDatabases.contains(site.folder)
    }

    // Nil when nexusd cannot list them, for example while the server does not run.
    func databaseSizes(on instance: String) async -> [DatabaseSize]? {
        guard case .answer(.databaseSizes(let sizes))? = await outcome(of: .databaseSizes(instance: instance)) else {
            return nil
        }

        return sizes
    }

    // Only a new database needs nexusd. The env file and "Keep it as it is" do not.
    func apply(_ action: TestDatabaseAction, to site: SiteItem) async {
        switch action {
        case .keep:
            setKeepsTestDatabase(true, of: site)
        case .use(let plan, let database):
            if let database {
                guard isLive else {
                    failure = ActionFailure(title: "Nexus did not make the database \(database.name)", message: "Nexus cannot reach its background service.", place: .window)
                    return
                }

                guard await perform(.createDatabase(.instance(database.instance), name: database.name), failure: "Nexus did not make the database \(database.name)", place: .window) != nil else {
                    return
                }
            }

            do {
                let backup = try plan.apply(projectFolder: site.projectFolder)
                ActivityTracker.log.write("tests", "\(site.host): \(plan.file) has \(plan.changeText)\(backup.map { ", backup \($0)" } ?? "")")
                setKeepsTestDatabase(false, of: site)
            } catch {
                failure = ActionFailure(title: "Nexus did not change \(plan.file)", message: ErrorText.plain(error), place: .window)
            }
        }
    }

    // A site whose tests no longer use the development database forgets "Keep it as it is". So
    // the warning shows again when they use it again.
    func setKeepsTestDatabase(_ keeps: Bool, of site: SiteItem) {
        guard keeps != keepsTestDatabase(of: site) else {
            return
        }

        if keeps {
            keptTestDatabases.insert(site.folder)
        } else {
            keptTestDatabases.remove(site.folder)
        }

        UserDefaults.standard.set(keptTestDatabases.sorted(), forKey: AppPreference.keptTestDatabases)
    }
}
