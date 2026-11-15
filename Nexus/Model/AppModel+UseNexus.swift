import Foundation
import NexusCore
import NexusIPC

// One "Use Nexus" for one host. database is the database of the copy, for its task. result holds
// the end of a run that stopped or failed.
struct UseNexusRun: Equatable {
    let request: UseNexusRequest
    let database: String?
    var result: ImportResult?
}

// "Use Nexus…" of a Laravel site (owner, 2026-11-14). The flow is the flow of an import: the sheet
// shows the end while it is open, and an alert shows a failure otherwise. nexusd changes the .env
// only after the copy. So a stop or a failure leaves the .env as it was.
extension AppModel {
    // The probe can take some seconds. Without nexusd, only shop.test of the sample data gets the
    // plan of the design.
    func useNexusInfo(of site: SiteItem) async -> UseNexusInfo? {
        guard isLive else {
            return site.host == "shop.test" ? Self.sampleUseNexusInfo : nil
        }

        guard case .answer(.useNexusInfo(let info))? = await outcome(of: .useNexusInfo(host: site.host)) else {
            return nil
        }

        return info
    }

    func startUseNexus(_ request: UseNexusRequest, database: String?) {
        let host = request.host
        useNexusRuns[host] = UseNexusRun(request: request, database: database)
        useNexusDone[host] = nil

        guard isLive else {
            if !request.copy {
                let server = Self.sampleUseNexusInfo.database?.choices.first { $0.instance == request.instance }?.name
                finishUseNexus(request, message: UseNexusInfo.doneMessage(database: database, server: server, step: .made, keys: request.changes.count))
            }

            return
        }

        Task {
            switch await outcome(of: .useNexus(request)) {
            case .answer(.done(let message)):
                finishUseNexus(request, message: message)
            case .answer(.stopped(let message)):
                endUseNexus(request, with: .stopped(message))
            case .failure(let message):
                failUseNexus(request, message: message)
            case .portInUse(let conflict):
                failUseNexus(request, message: conflict.description)
            default:
                failUseNexus(request, message: "nexusd gave no answer. Open \"Use Nexus…\" again.")
            }
        }
    }

    func useNexusTask(of host: String) -> TaskInfo? {
        guard let run = useNexusRuns[host], run.request.copy, let instance = run.request.instance, let database = run.database else {
            return nil
        }

        return importTask(instance: instance, name: database)
    }

    func stopUseNexusCopy(of host: String) {
        guard isLive else {
            useNexusRuns[host]?.result = .stopped("The copy of shop stopped. mysql-8.4 has no database shop. Nexus did not change the .env.")
            return
        }

        if let task = useNexusTask(of: host) {
            stopTask(task.id)
        }
    }

    private func finishUseNexus(_ request: UseNexusRequest, message: String) {
        let host = request.host
        let title = UseNexusInfo.doneTitle(host: host)
        useNexusRuns[host] = nil
        useNexusDone[host] = DoneMessage(title: title, message: message)
        useNexusChanges += 1

        guard request.copy else {
            return
        }

        if let instance = request.instance, let service = service(instance) {
            loadDatabases(of: service)
        }

        Notifier.post(title, message, target: .site(host: host), setting: AppPreference.notifyImportDone)
    }

    private func failUseNexus(_ request: UseNexusRequest, message: String) {
        if request.copy {
            // The alert has the same title. So a click on the notification passes the alert.
            Notifier.post(UseNexusInfo.failedTitle(host: request.host), message, target: .site(host: request.host), setting: AppPreference.notifyImportDone)
        }

        endUseNexus(request, with: .failed(message))
    }

    // The open sheet shows the end of the run. With the sheet closed, an alert shows a failure. A
    // stop then shows nothing, because the .env and the instance stay as they were.
    private func endUseNexus(_ request: UseNexusRequest, with result: ImportResult) {
        let host = request.host

        guard useNexusInSheet == host else {
            useNexusRuns[host] = nil

            if case .failed(let message) = result {
                failure = ActionFailure(title: UseNexusInfo.failedTitle(host: host), message: message, place: .window)
            }

            return
        }

        useNexusRuns[host]?.result = result
    }

    // The sample of the design "Sheet Use Nexus": a MAMP PRO site with Redis.
    static let sampleUseNexusInfo = UseNexusInfo(
        host: "shop.test",
        url: "https://shop.test:8443",
        appURL: EnvValueChange(key: "APP_URL", oldValue: "http://localhost:8888", newValue: "https://shop.test:8443"),
        appURLValue: "http://localhost:8888",
        database: UseNexusDatabase(connection: "mysql", database: "shop", choices: [
            UseNexusChoice(
                instance: "mysql-8.4",
                name: "MySQL 8.4",
                changes: [
                    EnvValueChange(key: "DB_HOST", oldValue: "localhost", newValue: "127.0.0.1"),
                    EnvValueChange(key: "DB_PORT", oldValue: "8889", newValue: "13306"),
                    EnvValueChange(key: "DB_SOCKET", oldValue: "/Applications/MAMP/tmp/mysql/mysql.sock", newValue: nil),
                    EnvValueChange(key: "DB_PASSWORD", oldValue: "root", newValue: ""),
                ],
                databaseExists: false,
                canCopy: true
            ),
        ]),
        redis: [EnvValueChange(key: "REDIS_PORT", oldValue: "6379", newValue: "16379")]
    )
}
