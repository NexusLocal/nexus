import AppKit
import NexusCore
import NexusIPC

// The Logs screen (group 7). Each site and each of its workspaces is a place.
extension AppModel {
    var logPlaces: [LogPlace] {
        let places = allSites.flatMap { LogPlace.places(of: $0.logSource) }

        #if DEBUG
        if CommandLine.arguments.contains("--sample") {
            return SampleLogs.places(places)
        }
        #endif

        return places
    }

    // "Show logs" of a site, and "Show log" of a Node.js app with the file of its output.
    func showLogs(of host: String, file: String? = nil) {
        logs.setPlaces(logPlaces)
        logs.choosePlace(host)
        logs.preferFile(file)
        selection = .logs
    }

    // The web page of the logs is a page of the server of the dumps page.
    func openLogPage() {
        guard let page = dumpState?.page, var components = URLComponents(string: page) else {
            return
        }

        components.path = "/logs"
        components.queryItems = logs.placeID.map { [URLQueryItem(name: "place", value: $0)] }

        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }
}

extension SiteItem {
    var logSource: LogPlace.Source {
        LogPlace.Source(
            hosts: [host] + aliases,
            folder: folder,
            kind: kind,
            projectType: projectType,
            php: php,
            appLog: app?.log,
            workspaces: workspaces.map { workspace in
                LogPlace.Source.Workspace(name: workspace.name, hosts: workspace.hosts ?? [], folder: workspace.folder, worktree: workspace.worktree, appLog: workspace.app?.log)
            }
        )
    }
}
